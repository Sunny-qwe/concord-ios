import Foundation
import SQLite3
import CryptoKit
import Compression

// MARK: - FlClash-format backup / restore
//
// One zip, FlClash v0.9.5-rs.1's format (lib/common/backup.dart), so a
// backup written here opens in real FlClash and vice versa:
//
//   config.json            Config.toJson + "version": 1
//   database.sqlite        Drift snapshot, schema version 26
//   profiles/<snowflake>.yaml
//   scripts/<snowflake>.js
//   providers/rules/<md5(id + "@" + url)>   local rule providers only
//   mitm/modules/<snowflake>.txt            local MITM modules only
//   mitm/resources/<sha256[0..<32]>[.ext]   local modules' attachments only
//
// No manifest file. Missing files on disk are skipped at write time;
// path-traversal / absolute names are skipped at extract time (a
// backup is untrusted input). Restore extracts to staging first,
// copies the files named by the restored rows before writing any
// rows, and keeps replaced files under staging/replaced/ for a
// putBack rollback when a row write fails.
//
// LOSSY EDGES (documented, not silent):
// - Our IDs are UUID strings; upstream uses snowflake int64. A
//   stable UUID<->int64 map lives in UserDefaults
//   (ConcordiOS.flclashBackup.idMap.v1) so re-export is stable.
//   Imported foreign snowflakes get fresh UUIDs, persisted the
//   same way. Our snowflakes are time-ordered like upstream's
//   (epoch 2024-01-01, worker 1) but the sequence is local.
// - Upstream global Rules / ProxyGroups / ClashProviders /
//   ProxyDialers live in the DB; ours live embedded in profile
//   YAML (rules:, proxy-groups:, rule-providers:) plus the
//   AddedRulesStore overlay. Export parses them OUT of the YAML
//   into rows; import treats the restored YAML file as
//   authoritative and does NOT re-inject those rows (the YAML
//   already carries them). Global rules (profile_id NULL) DO
//   round-trip via AddedRulesStore; per-profile disabled global
//   rules round-trip via its disabled list.
// - Upstream Scripts are config JS. Ours has no config-script
//   store: MitmScriptStore scripts fill the table instead, and a
//   Scripts row referenced by a profile's scriptId is an extend
//   script (ExtendConfigStore.scriptText). A foreign config script
//   therefore lands in ScriptsView as a MITM script — delete it
//   there if it does not belong.
// - Per-profile extend data that has no upstream row: ExtendSettings
//   .profileRules are exported as profile-owned rules and recovered
//   on import by the not-in-YAML heuristic (a foreign backup's
//   profile rules ARE its YAML rules, so only the extra ones come
//   back as extend rules); .matchTarget round-trips via the profile
//   row's exitTargets {"MATCH": target}. The old concord-ios format
//   still preserves them exactly, with no heuristic involved.
// - selectedMap / unfoldSet are exported empty: our per-group
//   picks live only in ProxyStore memory, not on disk.
// - IconRecords / IconSets / IpQualities rows are present in the
//   snapshot schema but empty, and are DROPPED on restore —
//   upstream drops them too (faithful).
// - Geo DBs, diagnostics, logs, caches, snapshots and the MITM CA
//   are never in a FlClash-format export (they re-seed /
//   re-download; faithful). The old format still backs them up
//   where it already did.
// - accessControlProps has no store here: export writes the
//   upstream defaults, import keeps the current value (there is
//   none to keep — the carve-out is a no-op, matching upstream's
//   "keep when the backup has none" for the desktop case).
// - excludeSSIDs has no store here: exported empty, ignored on
//   import. Hosts (patchClashConfig.hosts) are likewise not
//   carried: our hosts.json is not wired into config.json.
// - The restore strategy is a persisted setting, not a per-restore
//   choice (upstream). onlyProfiles restores ALL rows + files and
//   only skips applying the Config (upstream semantics, NOT the
//   old in-page meaning).

enum FlClashBackupError: LocalizedError {
    /// Not a ZIP, no config.json, config.json not an object, or
    /// version not an int — upstream BackupFailure.invalid.
    case invalid
    /// config version > 1 or DB schema > 26 — upstream
    /// BackupFailure.newerVersion.
    case newerVersion
    /// version == 0 / absent: the legacy list-embedding path.
    /// Rejected for now with a clear message; do not guess at it.
    case legacyVersion
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalid: return "无效备份文件"
        case .newerVersion: return "该备份来自更高版本的应用，请先更新应用再恢复"
        case .legacyVersion: return "该备份是旧版格式（version 0），暂不支持恢复"
        case .io(let detail): return detail
        }
    }
}

/// The Drift schema version a FlClash v0.9.5-rs.1 database carries.
enum FlClashBackupSchema {
    static let configVersion = 1
    static let databaseVersion = 26
}

// MARK: - UUID <-> snowflake map

/// Stable, persisted map between our string IDs and upstream's
/// int64 snowflakes. Keys are namespaced ("profile:<uuid>",
/// "module:<id>", "script:<id>", "proxy:<id>", "rule:<profile>:<md5>",
/// "group:<profile>:<name>", "provider:<profile>:<name>") so
/// different entity kinds never collide.
enum FlClashIdMap {
    static let defaultsKey = "ConcordiOS.flclashBackup.idMap.v1"

    private static var cached: [String: Int64]?
    private static var sequence: Int64 = 0

    static func load() -> [String: Int64] {
        if let cached { return cached }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            cached = [:]
            return [:]
        }
        cached = decoded
        return decoded
    }

    private static func save(_ map: [String: Int64]) {
        cached = map
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Snowflake for a namespaced key, allocating (and persisting)
    /// one when absent. Time-ordered like upstream's Snowflake
    /// (epoch 2024-01-01, worker 1, 12-bit sequence).
    static func snowflake(forKey key: String) -> Int64 {
        var map = load()
        if let existing = map[key] { return existing }
        let twepoch: Int64 = 1_704_067_200_000
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        sequence = (sequence + 1) & 0xFFF
        var candidate = ((now - twepoch) << 22) | (1 << 12) | sequence
        if candidate <= 0 { candidate = Int64.random(in: 1...Int64.max) }
        while map.values.contains(candidate) {
            sequence = (sequence + 1) & 0xFFF
            candidate = ((now - twepoch) << 22) | (1 << 12) | sequence
        }
        map[key] = candidate
        save(map)
        return candidate
    }

    static func snowflake(forProfile id: UUID) -> Int64 {
        snowflake(forKey: "profile:\(id.uuidString)")
    }

    static func uuid(forProfileSnowflake id: Int64) -> UUID {
        uuid(forKey: "profile", snowflake: id)
    }

    /// UUID for a foreign snowflake, allocating (and persisting)
    /// one when absent. The reverse lookup reuses the same map.
    static func uuid(forKey namespace: String, snowflake id: Int64) -> UUID {
        var map = load()
        if let key = map.first(where: { $0.value == id && $0.key.hasPrefix(namespace + ":") })?.key,
           let uuid = UUID(uuidString: String(key.dropFirst(namespace.count + 1))) {
            return uuid
        }
        // Namespaced by the snowflake itself when the key is not a
        // UUID (e.g. a MITM module id that is not a UUID string).
        let uuid = UUID()
        map["\(namespace):\(uuid.uuidString)"] = id
        save(map)
        return uuid
    }

    /// The string ID (UUID or opaque) behind a snowflake, when the
    /// map already knows it. Used for MITM modules / scripts /
    /// custom proxies, whose ids are opaque strings, not UUIDs.
    static func stringId(forKey namespace: String, snowflake id: Int64) -> String? {
        let map = load()
        return map.first(where: { $0.value == id && $0.key.hasPrefix(namespace + ":") })?.key
            .dropFirst(namespace.count + 1).description
    }

    static func snowflake(forStringId id: String, namespace: String) -> Int64 {
        snowflake(forKey: "\(namespace):\(id)")
    }

    /// Record an explicit string-id <-> snowflake pair (used on
    /// import when a foreign snowflake gets a fresh local id).
    static func record(namespace: String, stringId: String, snowflake: Int64) {
        var map = load()
        map["\(namespace):\(stringId)"] = snowflake
        save(map)
    }
}

// MARK: - WebDAV password obfuscation (upstream, models/common.dart)
//
// XOR with a 16-byte nonce and a fixed 16-byte mask, base64url,
// "v1.<nonce>.<obfuscated>". Deliberately NOT a security boundary
// (upstream's own comment); it only stops accidental plain-text
// disclosure. Plain-text legacy values are tolerated on read.

enum FlClashDavPassword {
    private static let mask: [UInt8] = [
        0x9d, 0x42, 0xe7, 0x1b, 0x68, 0xb4, 0x35, 0xca,
        0x7f, 0x20, 0xd1, 0x56, 0x83, 0xfa, 0x0c, 0xa9,
    ]

    static func encode(_ password: String) -> String {
        guard !password.isEmpty else { return "" }
        let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let bytes = [UInt8](password.utf8)
        let obfuscated = bytes.enumerated().map { index, byte in
            byte ^ nonce[index % nonce.count] ^ mask[index % mask.count]
        }
        return "v1." + base64url(Data(nonce)) + "." + base64url(Data(obfuscated))
    }

    static func decode(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let nonce = base64urlDecode(String(parts[1])),
              let obfuscated = base64urlDecode(String(parts[2])),
              nonce.count == 16 else {
            // Plain-text legacy value: tolerated on read (upstream).
            return value
        }
        let bytes = obfuscated.enumerated().map { index, byte in
            byte ^ nonce[index % nonce.count] ^ mask[index % mask.count]
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func base64urlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Hashes

enum FlClashHash {
    /// Upstream ClashProvider.fileName: '$id@$url'.toMd5().
    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Upstream mitmResourceName: sha256(bytes)[0..<32] + ext.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mitmResourceName(source: String, bytes: Data) -> String {
        let hash = String(sha256Hex(bytes).prefix(32))
        let ext = (source as NSString).pathExtension
        let suffix = ext.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil
            ? "." + ext.lowercased() : ""
        return hash + suffix
    }
}

// MARK: - JSON helpers (JSONSerialization-shaped values)

enum FlClashJSON {
    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let i as Int: return Int64(i)
        case let i as Int64: return i
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        int64(value).map { Int($0) }
    }

    static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue ?? value as? Bool
    }

    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? value as? Double
    }

    static func string(_ value: Any?) -> String? {
        value as? String ?? (value as? NSNumber)?.stringValue
    }

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func stringList(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { string($0) } ?? []
    }

    static func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = dict(value) else { return [:] }
        var out: [String: String] = [:]
        for (key, raw) in dict { if let s = string(raw) { out[key] = s } }
        return out
    }

    /// [String: Any] -> JSON text (sorted keys, for the Drift
    /// map/set columns, which store JSON strings).
    static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// JSONValue -> plain Any for JSONSerialization / Drift JSON.
    static func any(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let items): return items.map { any($0) }
        case .object(let dict): return dict.mapValues { any($0) }
        }
    }

    /// Plain Any (from JSONSerialization) -> JSONValue.
    static func jsonValue(_ value: Any?) -> JSONValue {
        switch value {
        case nil, is NSNull: return .null
        case let n as NSNumber:
            // NSNumber hides Bool; match upstream's JSON round-trip
            // by asking the ObjC type.
            if String(cString: n.objCType) == "c" { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n as CFNumber) { return .double(n.doubleValue) }
            return .int(n.int64Value)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { jsonValue($0) })
        case let d as [String: Any]: return .object(d.mapValues { jsonValue($0) })
        default: return .string("\(value!)")
        }
    }
}

// MARK: - Rule.parse port (upstream models/clash_config.dart)
//
// Splits "TYPE,payload,target[,no-resolve][,src]". AND/OR/NOT carry
// a comma payload (everything but the last field); RULE-SET stores
// the payload as ruleProvider; SUB-RULE stores the target as
// subRule; MATCH stores only a target.

struct FlClashRuleParts {
    var ruleAction: String
    var content: String? = nil
    var ruleTarget: String? = nil
    var ruleProvider: String? = nil
    var subRule: String? = nil
    var noResolve: Bool
    var src: Bool
    var customExit: Bool
}

enum FlClashRule {
    static let commaPayloadActions: Set<String> = ["AND", "OR", "NOT"]

    static func parse(_ value: String) -> FlClashRuleParts {
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let type = fields.first?.uppercased() ?? ""
        guard !type.isEmpty else {
            return FlClashRuleParts(ruleAction: "DOMAIN", ruleTarget: "DIRECT",
                                    noResolve: false, src: false, customExit: false)
        }
        let rest = Array(fields.dropFirst())
        var payload: String?
        var target: String?
        var params: [String] = []
        if type == "MATCH" {
            target = rest.first
        } else if commaPayloadActions.contains(type) {
            target = rest.last
            payload = rest.count > 1 ? rest.dropLast().joined(separator: ",") : nil
        } else {
            payload = rest.first
            target = rest.count > 1 ? rest[1] : nil
            params = Array(rest.dropFirst(2))
        }
        if payload?.isEmpty == true { payload = nil }
        if target?.isEmpty == true { target = nil }
        return FlClashRuleParts(
            ruleAction: type,
            content: type == "RULE-SET" ? nil : payload,
            ruleTarget: type == "SUB-RULE" ? nil : target,
            ruleProvider: type == "RULE-SET" ? payload : nil,
            subRule: type == "SUB-RULE" ? target : nil,
            noResolve: params.contains("no-resolve"),
            src: params.contains("src"),
            customExit: type == "MATCH")
    }

    /// Rebuild the raw rule string (upstream Rule.rawValue).
    static func rawValue(_ parts: FlClashRuleParts) -> String {
        if parts.ruleAction == "MATCH" {
            return parts.ruleTarget.map { "MATCH,\($0)" } ?? "MATCH"
        }
        var fields = [parts.ruleAction]
        if parts.ruleAction == "RULE-SET" {
            if let provider = parts.ruleProvider { fields.append(provider) }
        } else if let content = parts.content {
            fields.append(content)
        }
        let target = parts.ruleAction == "SUB-RULE" ? parts.subRule : parts.ruleTarget
        if let target { fields.append(target) }
        if parts.noResolve { fields.append("no-resolve") }
        if parts.src { fields.append("src") }
        return fields.joined(separator: ",")
    }
}

// MARK: - YAML extraction (profile YAML -> Drift rows)

/// The three YAML sections that become Drift rows. Parsed with the
/// app's own YamlParser; a profile whose YAML does not parse
/// contributes no rows (its file is still exported verbatim).
struct FlClashYamlSections {
    var rules: [String] = []
    var proxyGroups: [[String: JSONValue]] = []
    var ruleProviders: [(name: String, definition: [String: JSONValue])] = []
}

enum FlClashYaml {
    static func sections(of yamlText: String) -> FlClashYamlSections {
        var out = FlClashYamlSections()
        guard let parsed = try? YamlParser.parse(yamlText),
              let top = parsed.objectValue else { return out }
        if let rules = top["rules"]?.arrayValue {
            out.rules = rules.compactMap { $0.stringValue }
        }
        if let groups = top["proxy-groups"]?.arrayValue {
            out.proxyGroups = groups.compactMap { $0.objectValue }
        }
        if let providers = top["rule-providers"]?.objectValue {
            out.ruleProviders = providers.map { (name: $0.key, definition: $0.value.objectValue ?? [:]) }
                .sorted { $0.name < $1.name }
        }
        return out
    }

    static func string(_ dict: [String: JSONValue], _ key: String) -> String? {
        dict[key]?.stringValue
    }

    static func stringList(_ dict: [String: JSONValue], _ key: String) -> [String]? {
        dict[key]?.arrayValue?.compactMap { $0.stringValue }
    }
}

// MARK: - SQLite (system lib, no wrapper dependency)

/// Minimal SQLite3 C-API wrapper: open (read-only or create),
/// exec, and row queries with bound parameters. Values come back
/// as Int64 / Double / String / Data / nil, keyed by column name.
final class FlClashSQLite {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw FlClashBackupError.io("打开数据库失败：\(message)")
        }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    @discardableResult
    func exec(_ sql: String) throws -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw FlClashBackupError.io("数据库执行失败：\(message)")
        }
        return true
    }

    func query(_ sql: String, params: [FlClashSQLiteValue] = []) throws -> [[String: Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw FlClashBackupError.io("数据库查询准备失败：\(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            switch param {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                sqlite3_bind_text(stmt, idx, v, -1, FlClashSQLite.transient)
            case .data(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), FlClashSQLite.transient) }
            }
        }
        var rows: [[String: Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(stmt, i)
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    row[name] = bytes.map { Data(bytes: $0, count: count) }
                default: row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }

    func insert(_ sql: String, params: [FlClashSQLiteValue]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw FlClashBackupError.io("数据库写入准备失败：\(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            switch param {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                sqlite3_bind_text(stmt, idx, v, -1, FlClashSQLite.transient)
            case .data(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), FlClashSQLite.transient) }
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FlClashBackupError.io("数据库写入失败：\(String(cString: sqlite3_errmsg(db)))")
        }
    }

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// user_version from the file header (big-endian int32 at byte
    /// 60) — read WITHOUT opening the DB, so no migration runs
    /// (upstream backup.dart _readSchemaVersion).
    static func headerUserVersion(of data: Data) throws -> Int {
        guard data.count >= 64 else { throw FlClashBackupError.invalid }
        let b = [data[60], data[61], data[62], data[63]]
        let value = (Int32(b[0]) << 24) | (Int32(b[1]) << 16) | (Int32(b[2]) << 8) | Int32(b[3])
        return Int(value)
    }
}

enum FlClashSQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case data(Data)
}

// MARK: - Drift DDL (copied from lib/database/generated/database.g.dart
// + the table definitions in lib/database/*.dart, verified field by
// field: Drift stores Int as INTEGER, Text as TEXT, Bool as INTEGER
// with CHECK (col IN (0, 1)), DateTime as INTEGER milliseconds
// since epoch, enums as their TEXT names, and maps/sets as JSON
// strings. "order" is a quoted TEXT indexing key. Only the 9 tables
// restore reads get rows; icon_records / icon_sets / ip_qualities
// are created empty so the snapshot opens in real FlClash, which
// drops their rows on restore anyway.)

enum FlClashDDL {
    static let createTables = [
        """
        CREATE TABLE profiles (
          id INTEGER NOT NULL,
          type TEXT NOT NULL,
          label TEXT NOT NULL,
          current_group_name TEXT,
          url TEXT NOT NULL,
          age_secret_key TEXT,
          last_update_date INTEGER,
          extend_type TEXT NOT NULL,
          script_id INTEGER,
          match_target TEXT,
          exit_targets TEXT,
          auto_update_duration_millis INTEGER NOT NULL,
          subscription_info TEXT,
          auto_update INTEGER NOT NULL CHECK ("auto_update" IN (0, 1)),
          selected_map TEXT NOT NULL,
          unfold_set TEXT NOT NULL,
          "order" INTEGER,
          overrides TEXT,
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE scripts (
          id INTEGER NOT NULL,
          label TEXT NOT NULL,
          last_update_time INTEGER NOT NULL,
          url TEXT,
          "order" INTEGER,
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE rules (
          id INTEGER NOT NULL,
          profile_id INTEGER REFERENCES profiles (id) ON DELETE CASCADE,
          rule_action TEXT NOT NULL,
          content TEXT,
          rule_target TEXT,
          rule_provider TEXT,
          sub_rule TEXT,
          no_resolve INTEGER NOT NULL DEFAULT 0 CHECK ("no_resolve" IN (0, 1)),
          src INTEGER NOT NULL DEFAULT 0 CHECK ("src" IN (0, 1)),
          "order" TEXT,
          custom_exit INTEGER NOT NULL DEFAULT 0 CHECK ("custom_exit" IN (0, 1)),
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE disabled_rules (
          profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
          rule_id INTEGER NOT NULL REFERENCES rules (id) ON DELETE CASCADE,
          PRIMARY KEY (profile_id, rule_id)
        )
        """,
        """
        CREATE TABLE proxy_groups (
          id INTEGER NOT NULL,
          profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          proxies TEXT,
          use TEXT,
          definition TEXT NOT NULL DEFAULT '{}',
          "order" TEXT,
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE icon_records (
          url TEXT NOT NULL,
          last_accessed INTEGER NOT NULL,
          PRIMARY KEY (url)
        )
        """,
        """
        CREATE TABLE icon_sets (
          id INTEGER NOT NULL,
          name TEXT NOT NULL,
          url TEXT NOT NULL,
          icons TEXT NOT NULL,
          last_update_time INTEGER,
          "order" INTEGER,
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE clash_providers (
          id INTEGER NOT NULL,
          kind TEXT NOT NULL,
          label TEXT NOT NULL,
          url TEXT NOT NULL,
          behavior TEXT,
          format TEXT,
          "order" INTEGER,
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE custom_proxies (
          id INTEGER NOT NULL,
          definition TEXT NOT NULL,
          "order" TEXT,
          empty_options TEXT,
          PRIMARY KEY (id)
        )
        """,
        """
        CREATE TABLE proxy_dialers (
          profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
          proxy_id INTEGER NOT NULL REFERENCES custom_proxies (id) ON DELETE CASCADE,
          target TEXT NOT NULL,
          PRIMARY KEY (profile_id, proxy_id)
        )
        """,
        """
        CREATE TABLE ip_qualities (
          ip TEXT NOT NULL,
          quality TEXT NOT NULL,
          checked_at INTEGER NOT NULL,
          PRIMARY KEY (ip)
        )
        """,
        """
        CREATE TABLE mitm_modules (
          id INTEGER NOT NULL,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          url TEXT,
          enabled INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)),
          "order" INTEGER,
          arguments TEXT NOT NULL DEFAULT '{}',
          resources TEXT NOT NULL DEFAULT '{}',
          system TEXT,
          scripts INTEGER NOT NULL DEFAULT 0,
          asks_consent INTEGER NOT NULL DEFAULT 0 CHECK ("asks_consent" IN (0, 1)),
          accepted INTEGER,
          last_update_time INTEGER NOT NULL,
          PRIMARY KEY (id)
        )
        """,
        "CREATE INDEX idx_rule_target ON rules (rule_target)",
        "CREATE INDEX idx_rules_profile_order ON rules (profile_id, \"order\")",
        "CREATE INDEX idx_proxy_groups_profile_order ON proxy_groups (profile_id, \"order\")",
        "CREATE INDEX last_accessed_url ON icon_records (last_accessed, url)",
    ]

}

// MARK: - Decoded snapshot (MigrationData equivalent)

struct FlClashProfileRow {
    var id: Int64
    var type: String
    var label: String
    var currentGroupName: String?
    var url: String
    var ageSecretKey: String?
    var lastUpdateDateMillis: Int64?
    var extendType: String
    var scriptId: Int64?
    var exitTargets: [String: String]?
    var autoUpdateDurationMillis: Int64
    var subscriptionInfo: [String: Any]?
    var autoUpdate: Bool
    var selectedMap: [String: String]
    var unfoldSet: [String]
    var order: Int64?
    var overrides: [String: Any]?
}

struct FlClashScriptRow {
    var id: Int64
    var label: String
    var lastUpdateTimeMillis: Int64
    var url: String?
    var order: Int64?
}

struct FlClashRuleRow {
    var id: Int64
    var profileId: Int64?
    var ruleAction: String
    var content: String?
    var ruleTarget: String?
    var ruleProvider: String?
    var subRule: String?
    var noResolve: Bool
    var src: Bool
    var order: String?
    var customExit: Bool
}

struct FlClashProxyGroupRow {
    var id: Int64
    var profileId: Int64
    var name: String
    var type: String
    var proxies: [String]?
    var use: [String]?
    var definition: [String: Any]
    var order: String?
}

struct FlClashProviderRow {
    var id: Int64
    var kind: String
    var label: String
    var url: String
    var behavior: String?
    var format: String?
    var order: Int64?
}

struct FlClashCustomProxyRow {
    var id: Int64
    var definition: [String: Any]
    var order: String?
    var emptyOptions: [String]?
}

struct FlClashMitmModuleRow {
    var id: Int64
    var name: String
    var description: String
    var url: String?
    var enabled: Bool
    var order: Int64?
    var arguments: [String: String]
    var resources: [String: String]
    var system: String?
    var scripts: Int64
    var asksConsent: Bool
    var accepted: Bool?
    var lastUpdateTimeMillis: Int64
}

/// Everything a FlClash backup carries: the config map, the 9
/// tables restore reads (in upstream's order), and the staged file
/// entries keyed by their archive path.
struct FlClashBackupData {
    var config: [String: Any]
    var configVersion: Int
    var hasDatabase: Bool
    var profiles: [FlClashProfileRow] = []
    var scripts: [FlClashScriptRow] = []
    var rules: [FlClashRuleRow] = []
    var disabledRules: [(profileId: Int64, ruleId: Int64)] = []
    var proxyGroups: [FlClashProxyGroupRow] = []
    var clashProviders: [FlClashProviderRow] = []
    var customProxies: [FlClashCustomProxyRow] = []
    var proxyDialers: [(profileId: Int64, proxyId: Int64, target: String)] = []
    var mitmModules: [FlClashMitmModuleRow] = []
    /// Staged file entries (profiles/*.yaml, scripts/*.js,
    /// providers/rules/*, mitm/*) that passed the traversal check.
    var files: [String: Data] = [:]
}

// MARK: - Database snapshot: build (export) / read (import)

enum FlClashDatabase {
    /// Build a Drift-shaped database.sqlite from decoded rows and
    /// return its bytes. Fresh file (not VACUUM INTO — there is no
    /// live Drift DB here to vacuum from); the schema, types and
    /// user_version = 26 are what a reader checks.
    static func buildData(_ data: FlClashBackupData) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flclash-database-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try FlClashSQLite(path: url.path, readOnly: false)
        try db.exec("PRAGMA foreign_keys = OFF")
        for sql in FlClashDDL.createTables { try db.exec(sql) }
        for row in data.profiles {
            try db.insert(
                """
                INSERT OR REPLACE INTO profiles
                (id, type, label, current_group_name, url, age_secret_key,
                 last_update_date, extend_type, script_id, match_target,
                 exit_targets, auto_update_duration_millis, subscription_info,
                 auto_update, selected_map, unfold_set, "order", overrides)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .int(row.id), .text(row.type), .text(row.label),
                    row.currentGroupName.map { .text($0) } ?? .null,
                    .text(row.url),
                    row.ageSecretKey.map { .text($0) } ?? .null,
                    row.lastUpdateDateMillis.map { .int($0) } ?? .null,
                    .text(row.extendType),
                    row.scriptId.map { .int($0) } ?? .null,
                    row.exitTargets.map { FlClashJSON.jsonString($0).map { .text($0) } ?? .null } ?? .null,
                    .int(row.autoUpdateDurationMillis),
                    row.subscriptionInfo.map { FlClashJSON.jsonString($0).map { .text($0) } ?? .null } ?? .null,
                    .int(row.autoUpdate ? 1 : 0),
                    .text(FlClashJSON.jsonString(row.selectedMap) ?? "{}"),
                    .text(FlClashJSON.jsonString(row.unfoldSet) ?? "[]"),
                    row.order.map { .int($0) } ?? .null,
                    row.overrides.map { FlClashJSON.jsonString($0).map { .text($0) } ?? .null } ?? .null,
                ])
        }
        for row in data.scripts {
            try db.insert(
                "INSERT OR REPLACE INTO scripts (id, label, last_update_time, url, \"order\") VALUES (?, ?, ?, ?, ?)",
                params: [.int(row.id), .text(row.label), .int(row.lastUpdateTimeMillis),
                         row.url.map { .text($0) } ?? .null,
                         row.order.map { .int($0) } ?? .null])
        }
        for row in data.rules {
            try db.insert(
                """
                INSERT OR REPLACE INTO rules
                (id, profile_id, rule_action, content, rule_target, rule_provider,
                 sub_rule, no_resolve, src, "order", custom_exit)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .int(row.id),
                    row.profileId.map { .int($0) } ?? .null,
                    .text(row.ruleAction),
                    row.content.map { .text($0) } ?? .null,
                    row.ruleTarget.map { .text($0) } ?? .null,
                    row.ruleProvider.map { .text($0) } ?? .null,
                    row.subRule.map { .text($0) } ?? .null,
                    .int(row.noResolve ? 1 : 0), .int(row.src ? 1 : 0),
                    row.order.map { .text($0) } ?? .null,
                    .int(row.customExit ? 1 : 0),
                ])
        }
        for (profileId, ruleId) in data.disabledRules {
            try db.insert(
                "INSERT OR REPLACE INTO disabled_rules (profile_id, rule_id) VALUES (?, ?)",
                params: [.int(profileId), .int(ruleId)])
        }
        for row in data.proxyGroups {
            try db.insert(
                """
                INSERT OR REPLACE INTO proxy_groups
                (id, profile_id, name, type, proxies, use, definition, "order")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .int(row.id), .int(row.profileId), .text(row.name), .text(row.type),
                    row.proxies.map { FlClashJSON.jsonString($0).map { .text($0) } ?? .null } ?? .null,
                    row.use.map { FlClashJSON.jsonString($0).map { .text($0) } ?? .null } ?? .null,
                    .text(FlClashJSON.jsonString(row.definition) ?? "{}"),
                    row.order.map { .text($0) } ?? .null,
                ])
        }
        for row in data.clashProviders {
            try db.insert(
                """
                INSERT OR REPLACE INTO clash_providers
                (id, kind, label, url, behavior, format, "order")
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .int(row.id), .text(row.kind), .text(row.label), .text(row.url),
                    row.behavior.map { .text($0) } ?? .null,
                    row.format.map { .text($0) } ?? .null,
                    row.order.map { .int($0) } ?? .null,
                ])
        }
        for row in data.customProxies {
            try db.insert(
                "INSERT OR REPLACE INTO custom_proxies (id, definition, \"order\", empty_options) VALUES (?, ?, ?, ?)",
                params: [
                    .int(row.id),
                    .text(FlClashJSON.jsonString(row.definition) ?? "{}"),
                    row.order.map { .text($0) } ?? .null,
                    row.emptyOptions.map { FlClashJSON.jsonString($0).map { .text($0) } ?? .null } ?? .null,
                ])
        }
        for (profileId, proxyId, target) in data.proxyDialers {
            try db.insert(
                "INSERT OR REPLACE INTO proxy_dialers (profile_id, proxy_id, target) VALUES (?, ?, ?)",
                params: [.int(profileId), .int(proxyId), .text(target)])
        }
        for row in data.mitmModules {
            try db.insert(
                """
                INSERT OR REPLACE INTO mitm_modules
                (id, name, description, url, enabled, "order", arguments,
                 resources, system, scripts, asks_consent, accepted, last_update_time)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                params: [
                    .int(row.id), .text(row.name), .text(row.description),
                    row.url.map { .text($0) } ?? .null,
                    .int(row.enabled ? 1 : 0),
                    row.order.map { .int($0) } ?? .null,
                    .text(FlClashJSON.jsonString(row.arguments) ?? "{}"),
                    .text(FlClashJSON.jsonString(row.resources) ?? "{}"),
                    row.system.map { .text($0) } ?? .null,
                    .int(row.scripts),
                    .int(row.asksConsent ? 1 : 0),
                    row.accepted.map { .int($0 ? 1 : 0) } ?? .null,
                    .int(row.lastUpdateTimeMillis),
                ])
        }
        try db.exec("PRAGMA user_version = 26")
        // Close before reading the bytes back: the handle must be
        // gone so the file on disk is the finished snapshot.
        db.close()
        let bytes = try Data(contentsOf: url)
        return bytes
    }

    /// Read the 9 tables restore reads, in upstream's order. A row
    /// that cannot be decoded is skipped, not fatal (upstream's
    /// readable() does the same per row).
    static func readData(_ data: FlClashBackupData, databaseBytes: Data) throws -> FlClashBackupData {
        var out = data
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flclash-restore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try databaseBytes.write(to: url, options: .atomic)
        let db = try FlClashSQLite(path: url.path, readOnly: true)
        let rows = try db.query("SELECT * FROM profiles ORDER BY \"order\" ASC, id ASC")
        for row in rows {
            guard let id = FlClashJSON.int64(row["id"]),
                  let type = FlClashJSON.string(row["type"]),
                  let label = FlClashJSON.string(row["label"]),
                  let urlString = FlClashJSON.string(row["url"]),
                  let extendType = FlClashJSON.string(row["extend_type"]),
                  let duration = FlClashJSON.int64(row["auto_update_duration_millis"]),
                  let autoUpdate = FlClashJSON.int64(row["auto_update"]),
                  let selectedMap = FlClashJSON.string(row["selected_map"]),
                  let unfoldSet = FlClashJSON.string(row["unfold_set"]) else { continue }
            out.profiles.append(FlClashProfileRow(
                id: id, type: type, label: label,
                currentGroupName: FlClashJSON.string(row["current_group_name"]),
                url: urlString,
                ageSecretKey: FlClashJSON.string(row["age_secret_key"]),
                lastUpdateDateMillis: FlClashJSON.int64(row["last_update_date"]),
                extendType: extendType,
                scriptId: FlClashJSON.int64(row["script_id"]),
                exitTargets: (FlClashJSON.string(row["exit_targets"]).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .map { FlClashJSON.stringMap($0) },
                autoUpdateDurationMillis: duration,
                subscriptionInfo: (FlClashJSON.string(row["subscription_info"]).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] },
                autoUpdate: autoUpdate != 0,
                selectedMap: (selectedMap.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .map { FlClashJSON.stringMap($0) } ?? [:],
                unfoldSet: (unfoldSet.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
                    .map { FlClashJSON.stringList($0) } ?? [],
                order: FlClashJSON.int64(row["order"]),
                overrides: (FlClashJSON.string(row["overrides"]).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }))
        }
        for row in try db.query("SELECT * FROM scripts ORDER BY \"order\" ASC, id ASC") {
            guard let id = FlClashJSON.int64(row["id"]),
                  let label = FlClashJSON.string(row["label"]),
                  let updated = FlClashJSON.int64(row["last_update_time"]) else { continue }
            out.scripts.append(FlClashScriptRow(
                id: id, label: label, lastUpdateTimeMillis: updated,
                url: FlClashJSON.string(row["url"]),
                order: FlClashJSON.int64(row["order"])))
        }
        for row in try db.query("SELECT * FROM rules ORDER BY \"order\" ASC") {
            guard let id = FlClashJSON.int64(row["id"]),
                  let action = FlClashJSON.string(row["rule_action"]) else { continue }
            out.rules.append(FlClashRuleRow(
                id: id, profileId: FlClashJSON.int64(row["profile_id"]),
                ruleAction: action,
                content: FlClashJSON.string(row["content"]),
                ruleTarget: FlClashJSON.string(row["rule_target"]),
                ruleProvider: FlClashJSON.string(row["rule_provider"]),
                subRule: FlClashJSON.string(row["sub_rule"]),
                noResolve: FlClashJSON.int64(row["no_resolve"]) == 1,
                src: FlClashJSON.int64(row["src"]) == 1,
                order: FlClashJSON.string(row["order"]),
                customExit: FlClashJSON.int64(row["custom_exit"]) == 1))
        }
        for row in try db.query("SELECT * FROM disabled_rules") {
            if let p = FlClashJSON.int64(row["profile_id"]),
               let r = FlClashJSON.int64(row["rule_id"]) {
                out.disabledRules.append((profileId: p, ruleId: r))
            }
        }
        for row in try db.query("SELECT * FROM proxy_groups ORDER BY \"order\" ASC") {
            guard let id = FlClashJSON.int64(row["id"]),
                  let profileId = FlClashJSON.int64(row["profile_id"]),
                  let name = FlClashJSON.string(row["name"]),
                  let type = FlClashJSON.string(row["type"]) else { continue }
            let definition = (FlClashJSON.string(row["definition"]).flatMap { $0.data(using: .utf8) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            out.proxyGroups.append(FlClashProxyGroupRow(
                id: id, profileId: profileId, name: name, type: type,
                proxies: (FlClashJSON.string(row["proxies"]).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
                    .map { FlClashJSON.stringList($0) },
                use: (FlClashJSON.string(row["use"]).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
                    .map { FlClashJSON.stringList($0) },
                definition: definition,
                order: FlClashJSON.string(row["order"])))
        }
        for row in try db.query("SELECT * FROM clash_providers ORDER BY \"order\" ASC, id ASC") {
            guard let id = FlClashJSON.int64(row["id"]),
                  let kind = FlClashJSON.string(row["kind"]),
                  let label = FlClashJSON.string(row["label"]),
                  let urlString = FlClashJSON.string(row["url"]) else { continue }
            out.clashProviders.append(FlClashProviderRow(
                id: id, kind: kind, label: label, url: urlString,
                behavior: FlClashJSON.string(row["behavior"]),
                format: FlClashJSON.string(row["format"]),
                order: FlClashJSON.int64(row["order"])))
        }
        for row in try db.query("SELECT * FROM custom_proxies ORDER BY \"order\" ASC") {
            guard let id = FlClashJSON.int64(row["id"]),
                  let definitionText = FlClashJSON.string(row["definition"]),
                  let definitionData = definitionText.data(using: .utf8),
                  let definition = try? JSONSerialization.jsonObject(with: definitionData) as? [String: Any] else { continue }
            out.customProxies.append(FlClashCustomProxyRow(
                id: id, definition: definition,
                order: FlClashJSON.string(row["order"]),
                emptyOptions: (FlClashJSON.string(row["empty_options"]).flatMap { $0.data(using: .utf8) })
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
                    .map { FlClashJSON.stringList($0) }))
        }
        for row in try db.query("SELECT * FROM proxy_dialers") {
            if let p = FlClashJSON.int64(row["profile_id"]),
               let x = FlClashJSON.int64(row["proxy_id"]),
               let target = FlClashJSON.string(row["target"]) {
                out.proxyDialers.append((profileId: p, proxyId: x, target: target))
            }
        }
        for row in try db.query("SELECT * FROM mitm_modules ORDER BY \"order\" ASC, id ASC") {
            guard let id = FlClashJSON.int64(row["id"]),
                  let name = FlClashJSON.string(row["name"]),
                  let updated = FlClashJSON.int64(row["last_update_time"]) else { continue }
            let arguments = (FlClashJSON.string(row["arguments"]).flatMap { $0.data(using: .utf8) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map { FlClashJSON.stringMap($0) } ?? [:]
            let resources = (FlClashJSON.string(row["resources"]).flatMap { $0.data(using: .utf8) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map { FlClashJSON.stringMap($0) } ?? [:]
            out.mitmModules.append(FlClashMitmModuleRow(
                id: id, name: name,
                description: FlClashJSON.string(row["description"]) ?? "",
                url: FlClashJSON.string(row["url"]),
                enabled: FlClashJSON.int64(row["enabled"]) == 1,
                order: FlClashJSON.int64(row["order"]),
                arguments: arguments, resources: resources,
                system: FlClashJSON.string(row["system"]),
                scripts: FlClashJSON.int64(row["scripts"]) ?? 0,
                asksConsent: FlClashJSON.int64(row["asks_consent"]) == 1,
                accepted: FlClashJSON.int64(row["accepted"]).map { $0 == 1 },
                lastUpdateTimeMillis: updated))
        }
        return out
    }
}

// MARK: - Archive reading (upstream readBackupArchive)

enum FlClashArchiveReader {
    /// Validate + decode a FlClash backup zip into MigrationData.
    /// Throws .invalid / .newerVersion / .legacyVersion.
    static func read(zipData: Data) throws -> FlClashBackupData {
        let entries: [ZipArchive.Entry]
        do {
            entries = try ZipArchive.extract(zipData)
        } catch let error as ZipArchive.ZipError {
            // ZipArchive throws on traversal; upstream skips those
            // entries silently. Fall back to the tolerant walk.
            if case .corruptEntry(let detail) = error, detail.contains("非法路径") {
                entries = try extractTolerant(zipData)
            } else {
                throw FlClashBackupError.invalid
            }
        } catch {
            throw FlClashBackupError.invalid
        }
        var byPath: [String: Data] = [:]
        for entry in entries { byPath[entry.path] = entry.data }
        guard let configData = byPath["config.json"],
              let configObject = try? JSONSerialization.jsonObject(with: configData),
              let config = configObject as? [String: Any] else {
            throw FlClashBackupError.invalid
        }
        let versionRaw = config["version"]
        guard versionRaw != nil else { throw FlClashBackupError.legacyVersion }
        guard let version = FlClashJSON.int(versionRaw) else {
            throw FlClashBackupError.invalid
        }
        if version > FlClashBackupSchema.configVersion { throw FlClashBackupError.newerVersion }
        if version == 0 { throw FlClashBackupError.legacyVersion }
        var data = FlClashBackupData(config: config, configVersion: version, hasDatabase: false)
        // Staged files: only the entry names a restore can name.
        // (Traversal already filtered by the extractors above.)
        for (path, bytes) in byPath where path != "config.json" && path != "database.sqlite" {
            data.files[path] = bytes
        }
        guard let databaseBytes = byPath["database.sqlite"] else {
            // Valid config.json without database.sqlite restores
            // config-only (upstream: not an error).
            return data
        }
        let schemaVersion = try FlClashSQLite.headerUserVersion(of: databaseBytes)
        if schemaVersion > FlClashBackupSchema.databaseVersion {
            throw FlClashBackupError.newerVersion
        }
        data.hasDatabase = true
        return try FlClashDatabase.readData(data, databaseBytes: databaseBytes)
    }

    /// Central-directory walk that SKIPS (never throws for)
    /// traversal / absolute names, unsupported methods and CRC
    /// failures, mirroring upstream's _extract skip behaviour.
    /// Stored + deflate entries only.
    static func extractTolerant(_ data: Data) throws -> [ZipArchive.Entry] {
        guard let eocd = findEOCD(data) else { throw FlClashBackupError.invalid }
        let count = Int(read16(data, eocd + 10))
        let centralOffset = Int(read32(data, eocd + 16))
        guard count > 0, centralOffset >= 0, centralOffset < data.count else {
            throw FlClashBackupError.invalid
        }
        var entries: [ZipArchive.Entry] = []
        var offset = centralOffset
        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014B50 else { break }
            let method = Int(read16(data, offset + 10))
            let crc = read32(data, offset + 16)
            let compressedSize = Int(read32(data, offset + 20))
            let uncompressedSize = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))
            let nameStart = offset + 46
            offset = nameStart + nameLength + extraLength + commentLength
            guard nameStart + nameLength <= data.count,
                  let path = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8),
                  isSafeEntryPath(path),
                  (method == 0 || method == 8),
                  localOffset + 30 <= data.count,
                  read32(data, localOffset) == 0x04034B50 else { continue }
            let localNameLength = Int(read16(data, localOffset + 26))
            let localExtraLength = Int(read16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count else { continue }
            let fileData: Data
            if method == 0 {
                guard compressedSize == uncompressedSize else { continue }
                fileData = Data(data[dataStart..<(dataStart + compressedSize)])
            } else if let inflated = inflateRawDeflate(
                Data(data[dataStart..<(dataStart + compressedSize)]),
                expectedSize: uncompressedSize), inflated.count == uncompressedSize {
                fileData = inflated
            } else { continue }
            guard ZipArchive.crc32(fileData) == crc else { continue }
            entries.append(ZipArchive.Entry(path: path, data: fileData))
        }
        return entries
    }

    /// Upstream _stagedEntryPath: normalised, relative, and inside
    /// the staging dir. Backslashes count as separators too.
    static func isSafeEntryPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .filter { $0 != "." }
        if normalized.isEmpty { return false }
        if path.hasPrefix("/") || path.hasPrefix("\\") { return false }
        // Collapse ".." the way posix.normalize does; a leading
        // ".." (or one that climbs out) is unsafe.
        var depth = 0
        for part in normalized {
            if part == ".." {
                depth -= 1
                if depth < 0 { return false }
            } else {
                depth += 1
            }
        }
        return true
    }

    private static func findEOCD(_ data: Data) -> Int? {
        let scanStart = max(0, data.count - 65_557)
        var cursor = data.count - 22
        while cursor >= scanStart {
            if read32(data, cursor) == 0x06054B50 { return cursor }
            cursor -= 1
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    /// Raw-deflate inflate (same zlib-header trick as
    /// ZipArchive.inflateRawDeflate, which is private).
    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty, expectedSize >= 0 else { return Data() }
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        var input = Data([0x78, 0x01])
        input.append(data)
        var output = Data()
        output.reserveCapacity(expectedSize)
        let chunkSize = 65_536
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        return input.withUnsafeBytes { inputPtr -> Data? in
            guard let inputBase = inputPtr.baseAddress else { return nil }
            stream.src_ptr = inputBase.assumingMemoryBound(to: UInt8.self)
            stream.src_size = input.count
            while true {
                let produced: Int = outBuffer.withUnsafeMutableBytes { outPtr -> Int in
                    guard let outBase = outPtr.baseAddress else { return 0 }
                    stream.dst_ptr = outBase.assumingMemoryBound(to: UInt8.self)
                    stream.dst_size = chunkSize
                    let status = compression_stream_process(&stream, 0)
                    let count = chunkSize - stream.dst_size
                    if count > 0 {
                        output.append(outBase.assumingMemoryBound(to: UInt8.self), count: count)
                    }
                    if status == COMPRESSION_STATUS_END { return -1 }
                    if status == COMPRESSION_STATUS_ERROR { return -2 }
                    return count
                }
                if produced == -1 { break }
                if produced == -2 || (produced == 0 && stream.src_size == 0) { break }
            }
            return output
        }
    }
}

// MARK: - Export

/// Everything the FlClash export needs, snapshotted by the caller
/// (BackupView) from the live stores. File-backed stores that are
/// not environment objects are read through fresh instances that
/// load from disk on init.
struct FlClashExportContext {
    var profiles: [Profile]
    var profileYAMLs: [UUID: String]
    var settings: SettingsStore
    var theme: ThemeStore
    var proxyStyle: ProxyStyleStore
    var webdav: WebDAVAccount
    var restoreStrategy: BackupStore.RestoreStrategy
    var mitmModules: [MitmModule]
    var mitmModuleTexts: [String: String]
    var mitmScripts: [MitmScript]
    var mitmScriptContents: [String: String]
    var customProxies: [CustomProxy]
    var rawProxies: [JSONValue]
    var addedRules: [String]
    var disabledAddedRules: [String]
    var extendSettings: [String: ExtendSettings]
    var overrideGlobal: [String: [String: JSONValue]]
    var overrideProfiles: [String: [String: [String: JSONValue]]]
    var container: URL
}

enum FlClashExport {
    static func buildEntries(context: FlClashExportContext) throws -> [ZipArchive.Entry] {
        let data = try buildData(context: context)
        let configBytes = try JSONSerialization.data(
            withJSONObject: data.config, options: [.sortedKeys])
        var entries: [ZipArchive.Entry] = [
            ZipArchive.Entry(path: "config.json", data: configBytes),
            ZipArchive.Entry(path: "database.sqlite", data: try FlClashDatabase.buildData(data)),
        ]
        entries.append(contentsOf: data.files.map { ZipArchive.Entry(path: $0.key, data: $0.value) }
            .sorted { $0.path < $1.path })
        return entries
    }

    static func fileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Upstream getBackupFileName: FlClash_backup_YYYY-MM-DD.zip
        // (DateTime.show is yyyy-MM-dd).
        return "FlClash_backup_\(formatter.string(from: date)).zip"
    }

    static func buildData(context: FlClashExportContext) throws -> FlClashBackupData {
        var data = FlClashBackupData(
            config: buildConfig(context: context), configVersion: 1, hasDatabase: true)
        var ruleIdByRaw: [String: Int64] = [:]
        var nextRuleOrder = 0
        func orderKey(_ index: Int) -> String { String(format: "%08d", index) }

        // Scripts from extend settings first (they are referenced
        // by profiles.scriptId), then MITM scripts.
        var extendScriptIdByProfile: [UUID: Int64] = [:]
        for profile in context.profiles {
            guard let extend = context.extendSettings[profile.id.uuidString],
                  extend.mode == .script, extend.scriptEnabled,
                  !extend.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let snowflake = FlClashIdMap.snowflake(forKey: "extendscript:\(profile.id.uuidString)")
            extendScriptIdByProfile[profile.id] = snowflake
            data.scripts.append(FlClashScriptRow(
                id: snowflake, label: "\(profile.name) 扩展脚本",
                lastUpdateTimeMillis: Int64(Date().timeIntervalSince1970 * 1000),
                url: nil, order: nil))
            data.files["scripts/\(snowflake).js"] = Data(extend.scriptText.utf8)
        }
        for script in context.mitmScripts {
            let snowflake = FlClashIdMap.snowflake(forStringId: script.id, namespace: "script")
            data.scripts.append(FlClashScriptRow(
                id: snowflake, label: script.label,
                lastUpdateTimeMillis: Int64(script.lastUpdateTime.timeIntervalSince1970 * 1000),
                url: script.url, order: Int64(script.order)))
            if let content = context.mitmScriptContents[script.id] {
                data.files["scripts/\(snowflake).js"] = Data(content.utf8)
            }
        }

        for (index, profile) in context.profiles.enumerated() {
            let snowflake = FlClashIdMap.snowflake(forProfile: profile.id)
            let extend = context.extendSettings[profile.id.uuidString]
            let yaml = context.profileYAMLs[profile.id] ?? ""
            let sections = FlClashYaml.sections(of: yaml)
            var subscription: [String: Any]?
            if let info = profile.subscriptionInfo {
                subscription = ["upload": info.upload, "download": info.download,
                                "total": info.total, "expire": info.expire]
            }
            data.profiles.append(FlClashProfileRow(
                id: snowflake,
                type: profile.kind == .url ? "url" : "file",
                label: profile.name,
                currentGroupName: nil,
                url: profile.urlString ?? "",
                ageSecretKey: profile.ageSecretKey,
                lastUpdateDateMillis: profile.updatedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                extendType: extendScriptIdByProfile[profile.id] != nil ? "script" : "standard",
                scriptId: extendScriptIdByProfile[profile.id],
                exitTargets: (extend?.matchTarget ?? "").isEmpty
                    ? nil : ["MATCH": extend!.matchTarget],
                autoUpdateDurationMillis: Int64((profile.autoUpdateIntervalMinutes ?? 0) * 60 * 1000),
                subscriptionInfo: subscription,
                autoUpdate: profile.autoUpdate,
                selectedMap: [:],
                unfoldSet: [],
                order: Int64(index),
                overrides: profileOverridesJSON(context: context, profileId: profile.id.uuidString)))
            if !yaml.isEmpty {
                data.files["profiles/\(snowflake).yaml"] = Data(yaml.utf8)
            }
            // Rules + proxy-groups + rule-providers parsed out of
            // the profile YAML (upstream keeps them in the DB).
            for (ruleIndex, raw) in sections.rules.enumerated() {
                let parts = FlClashRule.parse(raw)
                let ruleId = FlClashIdMap.snowflake(
                    forKey: "rule:\(profile.id.uuidString):\(FlClashHash.md5Hex(raw))")
                ruleIdByRaw[raw] = ruleId
                data.rules.append(FlClashRuleRow(
                    id: ruleId, profileId: snowflake, ruleAction: parts.ruleAction,
                    content: parts.content, ruleTarget: parts.ruleTarget,
                    ruleProvider: parts.ruleProvider, subRule: parts.subRule,
                    noResolve: parts.noResolve, src: parts.src,
                    order: orderKey(ruleIndex), customExit: parts.customExit))
            }
            for (groupIndex, group) in sections.proxyGroups.enumerated() {
                let name = FlClashYaml.string(group, "name") ?? ""
                let groupId = FlClashIdMap.snowflake(
                    forKey: "group:\(profile.id.uuidString):\(name)")
                var definition: [String: Any] = [:]
                for (key, value) in group where key != "name" && key != "type"
                        && key != "proxies" && key != "use" {
                    definition[key] = FlClashJSON.any(value)
                }
                data.proxyGroups.append(FlClashProxyGroupRow(
                    id: groupId, profileId: snowflake, name: name,
                    type: FlClashYaml.string(group, "type") ?? "select",
                    proxies: FlClashYaml.stringList(group, "proxies"),
                    use: FlClashYaml.stringList(group, "use"),
                    definition: definition, order: orderKey(groupIndex)))
            }
            for provider in sections.ruleProviders {
                let type = FlClashYaml.string(provider.definition, "type") ?? "http"
                let providerId = FlClashIdMap.snowflake(
                    forKey: "provider:\(profile.id.uuidString):\(provider.name)")
                let isLocal = type == "file"
                let url = isLocal ? "" : (FlClashYaml.string(provider.definition, "url") ?? "")
                let behavior = FlClashYaml.string(provider.definition, "behavior") ?? "classical"
                let format = FlClashYaml.string(provider.definition, "format") ?? "yaml"
                data.clashProviders.append(FlClashProviderRow(
                    id: providerId, kind: "rule", label: provider.name, url: url,
                    behavior: behavior, format: format, order: nil))
                if isLocal, let path = FlClashYaml.string(provider.definition, "path") {
                    let fileURL = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : context.container.appendingPathComponent(path)
                    if let bytes = try? Data(contentsOf: fileURL) {
                        let fileName = FlClashHash.md5Hex("\(providerId)@\(url)")
                        data.files["providers/rules/\(fileName)"] = bytes
                    }
                }
            }
            // Per-profile extend rules: exported as profile-owned
            // rules (visible to FlClash); our own import recovers
            // them by the not-in-YAML heuristic.
            if let extend, !extend.profileRules.isEmpty {
                for (ruleIndex, raw) in extend.profileRules.enumerated() {
                    let parts = FlClashRule.parse(raw)
                    let ruleId = FlClashIdMap.snowflake(
                        forKey: "rule:\(profile.id.uuidString):extend:\(FlClashHash.md5Hex(raw))")
                    data.rules.append(FlClashRuleRow(
                        id: ruleId, profileId: snowflake, ruleAction: parts.ruleAction,
                        content: parts.content, ruleTarget: parts.ruleTarget,
                        ruleProvider: parts.ruleProvider, subRule: parts.subRule,
                        noResolve: parts.noResolve, src: parts.src,
                        order: orderKey(10_000 + ruleIndex), customExit: parts.customExit))
                }
            }
        }

        // Global rules (profile_id NULL) + disabled global rules,
        // disabled once per profile (our disabled list is global).
        for raw in context.addedRules {
            let parts = FlClashRule.parse(raw)
            let ruleId = FlClashIdMap.snowflake(forKey: "rule:global:\(FlClashHash.md5Hex(raw))")
            ruleIdByRaw[raw] = ruleId
            data.rules.append(FlClashRuleRow(
                id: ruleId, profileId: nil, ruleAction: parts.ruleAction,
                content: parts.content, ruleTarget: parts.ruleTarget,
                ruleProvider: parts.ruleProvider, subRule: parts.subRule,
                noResolve: parts.noResolve, src: parts.src,
                order: orderKey(nextRuleOrder), customExit: parts.customExit))
            nextRuleOrder += 1
        }
        for raw in context.disabledAddedRules {
            guard let ruleId = ruleIdByRaw[raw] else { continue }
            for profile in context.profiles {
                data.disabledRules.append((
                    profileId: FlClashIdMap.snowflake(forProfile: profile.id),
                    ruleId: ruleId))
            }
        }

        // Custom proxies: form proxies first, then raw definitions.
        // A definition with keys outside the form set is raw on
        // import; form definitions stay form-shaped.
        for (index, proxy) in context.customProxies.enumerated() {
            let snowflake = FlClashIdMap.snowflake(forStringId: proxy.id, namespace: "proxy")
            var definition: [String: Any] = [
                "name": proxy.name, "type": proxy.type,
                "server": proxy.server, "port": proxy.port,
            ]
            if !proxy.password.isEmpty { definition["password"] = proxy.password }
            if !proxy.uuid.isEmpty { definition["uuid"] = proxy.uuid }
            if !proxy.cipher.isEmpty { definition["cipher"] = proxy.cipher }
            if proxy.tls { definition["tls"] = true }
            if !proxy.sni.isEmpty { definition["sni"] = proxy.sni }
            if !proxy.network.isEmpty { definition["network"] = proxy.network }
            if proxy.udp { definition["udp"] = true }
            data.customProxies.append(FlClashCustomProxyRow(
                id: snowflake, definition: definition,
                order: orderKey(index), emptyOptions: []))
        }
        for (index, raw) in context.rawProxies.enumerated() {
            guard let definition = FlClashJSON.any(raw) as? [String: Any] else { continue }
            let name = FlClashJSON.string(definition["name"]) ?? "raw-\(index)"
            let snowflake = FlClashIdMap.snowflake(forKey: "rawproxy:\(name)")
            data.customProxies.append(FlClashCustomProxyRow(
                id: snowflake, definition: definition,
                order: orderKey(10_000 + index), emptyOptions: []))
        }

        // MITM modules: local ones carry their text + attachments.
        for module in context.mitmModules {
            let snowflake = FlClashIdMap.snowflake(forStringId: module.id, namespace: "module")
            data.mitmModules.append(FlClashMitmModuleRow(
                id: snowflake, name: module.name, description: module.description,
                url: module.url, enabled: module.enabled, order: Int64(module.order),
                arguments: module.arguments, resources: module.resources,
                system: module.system, scripts: Int64(module.scripts),
                asksConsent: module.asksConsent, accepted: module.accepted,
                lastUpdateTimeMillis: Int64(module.lastUpdateTime.timeIntervalSince1970 * 1000)))
            guard !module.isRemote else { continue }
            if let text = context.mitmModuleTexts[module.id] {
                data.files["mitm/modules/\(snowflake).txt"] = Data(text.utf8)
            }
            for (_, resourceName) in module.resources {
                guard FlClashArchiveReader.isSafeEntryPath(resourceName),
                      !resourceName.contains("/"),
                      resourceName != "." && resourceName != "..",
                      !resourceName.lowercased().hasPrefix("http://"),
                      !resourceName.lowercased().hasPrefix("https://"),
                      !resourceName.hasPrefix("inline:") else { continue }
                let fileURL = context.container
                    .appendingPathComponent("mitm").appendingPathComponent("resources")
                    .appendingPathComponent(resourceName)
                if let bytes = try? Data(contentsOf: fileURL) {
                    data.files["mitm/resources/\(resourceName)"] = bytes
                }
            }
        }
        return data
    }

    /// ProfileOverrides JSON for one profile: our per-profile
    /// OverrideStore sections (dns / tun / sniffer / ntp) plus the
    /// *-override-keys sets listing exactly the keys present.
    /// The `general` section has no upstream per-profile home and
    /// is dropped (its keys live in patchClashConfig instead).
    private static func profileOverridesJSON(
        context: FlClashExportContext, profileId: String) -> [String: Any]? {
        guard let sections = context.overrideProfiles[profileId], !sections.isEmpty else {
            return nil
        }
        func sectionDict(_ name: String) -> [String: Any] {
            guard let values = sections[name] else { return [:] }
            return values.mapValues { FlClashJSON.any($0) }
        }
        func sectionKeys(_ name: String) -> [String] {
            sections[name].map { Array($0.keys).sorted() } ?? []
        }
        var out: [String: Any] = [:]
        let dns = sectionDict("dns")
        if !dns.isEmpty {
            out["dns"] = dns
            out["dns-override-keys"] = sectionKeys("dns")
        }
        let tun = sectionDict("tun")
        if !tun.isEmpty {
            out["tun"] = tun
            out["tun-override-keys"] = sectionKeys("tun")
        }
        let sniffer = sectionDict("sniffer")
        if !sniffer.isEmpty {
            out["sniffer"] = sniffer
            out["sniffer-override-keys"] = sectionKeys("sniffer")
        }
        let ntp = sectionDict("ntp")
        if !ntp.isEmpty {
            out["ntp"] = ntp
            out["ntp-override-keys"] = sectionKeys("ntp")
        }
        out["proxy-providers"] = [String: Any]()
        return out.isEmpty ? nil : out
    }
}

// MARK: - config.json: build (export) / apply (import)

extension FlClashExport {
    /// Config.toJson + "version": 1. Each section names its source
    /// store in the comment above it; keys with no source here are
    /// upstream defaults (see the lossy-edges header).
    static func buildConfig(context: FlClashExportContext) -> [String: Any] {
        let settings = context.settings
        let theme = context.theme
        let defaults = UserDefaults.standard
        let accentARGB = themeAccentARGB(context: context)
        var primaryColors = [accentARGB]
        for hex in theme.customColors {
            if let argb = parseHexColor(hex) { primaryColors.append(argb) }
        }
        var themeProps: [String: Any] = [
            "primaryColor": accentARGB,
            "primaryColors": primaryColors,
            "themeMode": theme.appearance.rawValue,
            "colorStyle": theme.colorStyle.rawValue,
            "pureBlack": theme.pureBlack,
            "sidebarBlur": false,
            "liquidGlass": theme.liquidGlass.rawValue,
            "textScale": [
                "enable": theme.textScaleEnabled,
                "scale": theme.textScale,
            ] as [String: Any],
        ]
        if let font = defaults.string(forKey: "ConcordiOS.font.family.v1"),
           !font.isEmpty {
            themeProps["systemFontFamily"] = font
        }
        var appSettingProps: [String: Any] = [
            "dashboardWidgets": [],
            "onlyStatisticsProxy": settings.onlyStatisticsProxy,
            "showNotificationStopAction": true,
            "autoLaunch": false,
            "silentLaunch": false,
            "autoRun": settings.autoRun,
            "openLogs": settings.openLogs,
            "closeConnections": settings.autoCloseConnections,
            "delayTestTimeout": settings.delayTestTimeout,
            "tabAnimation": theme.tabAnimation.rawValue,
            "floatingNavigationBar": theme.navBarStyle == .floating,
            "autoCheckUpdate": settings.autoCheckUpdate,
            "updateChannel": settings.updateChannel == .prerelease ? "pre" : "stable",
            "acceptedDisclaimerVersion":
                (defaults.bool(forKey: "ConcordiOS.disclaimer.consented") ? 1 : 0),
            "minimizeOnExit": true,
            "developerMode": settings.developerMode,
            "restoreStrategy": context.restoreStrategy.rawValue,
            "checkCertificate": settings.checkCertificate,
            "userAgents": settings.userAgents,
            "hideIp": settings.hideIp,
            "editorLineWrap": false,
            "editorFontSize": "standard",
            "serviceOrder": [],
            "disabledServices": [],
            "tableColumnWidths": [:] as [String: Any],
        ]
        // filters: none stored here; upstream defaultFilters.
        appSettingProps["filters"] = []
        let dav = context.webdav
        let davProps: [String: Any] = [
            "uri": dav.url,
            "user": dav.username,
            "password": FlClashDavPassword.encode(dav.password),
            // Upstream default file name is backup.zip; ours keeps
            // the user's file name when set.
            "fileName": dav.fileName.isEmpty ? "backup.zip" : dav.fileName,
        ]
        let networkProps: [String: Any] = [
            "systemProxy": settings.systemProxy,
            "bypassDomain": settings.bypassDomain,
            "pacMode": false,
            "pacScript": "",
            "bypassPrivateRoute": settings.bypassPrivateRoute,
            "appendSystemDns": settings.appendSystemDns,
            "authentication": [
                "enable": settings.authEnabled,
                "username": settings.authUsername,
                "password": settings.authPassword,
            ] as [String: Any],
        ]
        let vpnProps: [String: Any] = [
            "enable": true,
            "systemProxy": settings.systemProxy,
            "ipv6": settings.ipv6,
            "allowBypass": true,
            "dnsHijacking": settings.dnsHijack,
            // No access-control store here: upstream defaults.
            "accessControlProps": [
                "enable": false,
                "mode": "rejectSelected",
                "acceptList": [],
                "rejectList": [],
                "sort": "none",
                "isFilterSystemApp": true,
                "isFilterNonInternetApp": true,
            ] as [String: Any],
        ]
        let proxiesStyleProps: [String: Any] = [
            "type": context.proxyStyle.style == .icons ? "list" : context.proxyStyle.style.rawValue,
            "sortType": proxySortName(context.proxyStyle.sort),
            "layout": proxyLayoutName(context.proxyStyle.layout),
            "iconStyle": proxyIconStyleName(context.proxyStyle.iconStyle),
            "cardType": proxyCardTypeName(context.proxyStyle.cardType),
            "hideTimeoutProxies": context.proxyStyle.hideTimeout,
        ]
        var patch = buildPatchClashConfig(context: context)
        // Global overrides win over the settings-derived patch for
        // the keys they enable (the effective values a real FlClash
        // would apply). Sniffer/NTP have no patch home upstream.
        if let general = context.overrideGlobal["general"] {
            for (key, value) in general { patch[key] = FlClashJSON.any(value) }
        }
        if var dns = patch["dns"] as? [String: Any],
           let dnsOverrides = context.overrideGlobal["dns"] {
            for (key, value) in dnsOverrides { dns[key] = FlClashJSON.any(value) }
            patch["dns"] = dns
        }
        if var tun = patch["tun"] as? [String: Any],
           let tunOverrides = context.overrideGlobal["tun"] {
            for (key, value) in tunOverrides { tun[key] = FlClashJSON.any(value) }
            patch["tun"] = tun
        }
        var config: [String: Any] = [
            "version": FlClashBackupSchema.configVersion,
            "hotKeyActions": [],
            "appSettingProps": appSettingProps,
            "davProps": davProps,
            "networkProps": networkProps,
            "vpnProps": vpnProps,
            "themeProps": themeProps,
            "proxiesStyleProps": proxiesStyleProps,
            "windowGeometry": ["width": 0, "height": 0] as [String: Any],
            "patchClashConfig": patch,
            "excludeSSIDs": [],
        ]
        if let active = context.profiles.first(where: { $0.isActive }) {
            config["currentProfileId"] = FlClashIdMap.snowflake(forProfile: active.id)
        } else {
            config["currentProfileId"] = NSNull()
        }
        return config
    }

    private static func buildPatchClashConfig(context: FlClashExportContext) -> [String: Any] {
        let settings = context.settings
        let defaults = UserDefaults.standard
        var dns: [String: Any] = [
            "enable": settings.dnsEnabled,
            "listen": settings.dnsListen,
            "listen-routing-mark": defaults.integer(forKey: "ConcordiOS.dnsListenRoutingMark"),
            "prefer-h3": settings.dnsPreferH3,
            "use-hosts": settings.dnsUseHosts,
            "use-system-hosts": settings.dnsUseSystemHosts,
            "respect-rules": settings.dnsRespectRules,
            "ipv6": settings.dnsIpv6,
            "ipv6-timeout": settings.dnsIpv6Timeout,
            "cache-algorithm": settings.dnsCacheAlgorithm,
            "cache-max-size": settings.dnsCacheMaxSize,
            "enhanced-mode": settings.dnsEnhancedMode,
            "fake-ip-range": settings.dnsFakeIpRange,
            "fake-ip-range6": settings.dnsFakeIpRange6,
            "fake-ip-filter": settings.dnsFakeIpFilter,
            "fake-ip-filter-mode": settings.dnsFakeIpFilterMode,
            "fake-ip-ttl": settings.dnsFakeIpTtl,
            "nameserver-policy": settings.dnsNameserverPolicy,
            "default-nameserver": settings.dnsDefaultNameserver,
            "nameserver": [settings.dnsNameserver] + settings.dnsExtraNameservers,
            "fallback": settings.dnsFallback,
            "proxy-server-nameserver": settings.dnsProxyServerNameserver,
            "proxy-server-nameserver-policy": settings.dnsProxyServerNameserverPolicy,
            "direct-nameserver": settings.dnsDirectNameserver,
            "direct-nameserver-follow-policy": settings.dnsDirectNameserverFollowPolicy,
        ]
        var fallbackFilter: [String: Any] = ["geoip": settings.dnsFallbackFilterGeoip]
        if !settings.dnsFallbackFilterGeoipCode.isEmpty {
            fallbackFilter["geoip-code"] = settings.dnsFallbackFilterGeoipCode
        }
        if !settings.dnsFallbackFilterGeosite.isEmpty {
            fallbackFilter["geosite"] = settings.dnsFallbackFilterGeosite
        }
        if !settings.dnsFallbackFilterIpcidr.isEmpty {
            fallbackFilter["ipcidr"] = settings.dnsFallbackFilterIpcidr
        }
        if !settings.dnsFallbackFilterDomain.isEmpty {
            fallbackFilter["domain"] = settings.dnsFallbackFilterDomain
        }
        dns["fallback-filter"] = fallbackFilter
        if settings.dnsFallbackLazyQuery { dns["fallback-lazy-query"] = true }
        var geoXUrl: [String: String] = [:]
        if let url = defaults.string(forKey: "ConcordiOS.geoURL.MMDB"), !url.isEmpty { geoXUrl["mmdb"] = url }
        if let url = defaults.string(forKey: "ConcordiOS.geoURL.GEOSITE"), !url.isEmpty { geoXUrl["geosite"] = url }
        if let url = defaults.string(forKey: "ConcordiOS.geoURL.ASN"), !url.isEmpty { geoXUrl["asn"] = url }
        let mitmHostnames = settings.mitmHostnames
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var mitm: [String: Any] = [
            "enable": settings.mitmEnabled,
            "hostname": mitmHostnames,
            "skip-server-cert-verify": settings.mitmSkipServerCertVerify,
            "auto-quic-block": settings.mitmAutoQuicBlock,
            "h2": defaults.bool(forKey: "ConcordiOS.mitmH2"),
            "decrypt-untrusted": defaults.bool(forKey: "ConcordiOS.mitmDecryptUntrusted"),
            "capture": settings.mitmCapture,
            "capture-entries": settings.mitmCaptureEntries,
        ]
        if !settings.mitmTrustedFingerprint.isEmpty {
            mitm["trusted-fingerprint"] = settings.mitmTrustedFingerprint
        }
        var patch: [String: Any] = [
            "mixed-port": settings.mixedPort,
            "socks-port": settings.socksPort,
            "port": 0,
            "redir-port": defaults.integer(forKey: "ConcordiOS.redirPort"),
            "tproxy-port": defaults.integer(forKey: "ConcordiOS.tproxyPort"),
            "mode": settings.mode.rawValue,
            "allow-lan": settings.allowLan,
            "log-level": settings.logLevel.rawValue,
            "ipv6": settings.ipv6,
            "find-process-mode": settings.findProcessModeSetting,
            "interface-name-mode": settings.interfaceNameMode,
            "interface-name": settings.interfaceName,
            "keep-alive-interval": settings.keepAliveInterval,
            "keep-alive-idle": settings.keepAliveIdle,
            "disable-keep-alive": settings.disableKeepAlive,
            "routing-mark": 0,
            "unified-delay": settings.unifiedDelay,
            "tcp-concurrent": settings.tcpConcurrent,
            // Upstream Tun has no stack / DNS fields; our TUN
            // stack + DNS live in tunnel.json and are NOT exported
            // (a real FlClash uses its own TUN defaults).
            "tun": [
                "enable": settings.tunEnabled,
                "device": "Lumen",
                "route-address": [],
                "mtu": settings.tunMtu,
                "route-exclude-address": settings.routeExcludeAddress,
            ] as [String: Any],
            "dns": dns,
            "dns-override-keys": [],
            "tun-override": [:] as [String: Any],
            "tun-override-keys": [],
            "geox-url": geoXUrl,
            "external-controller": settings.externalControllerEnabled ? "127.0.0.1:9090" : "",
            "secret": settings.externalControllerSecret,
            "external-controller-cors": true,
            "hosts": [:] as [String: Any],
            "geo-auto-update": defaults.bool(forKey: "ConcordiOS.geoAutoUpdate"),
            "geo-update-interval": defaults.integer(forKey: "ConcordiOS.geoAutoUpdateHours"),
            "test-url": "https://www.gstatic.com/generate_204",
            "general-override-keys": [],
            "mitm": mitm,
        ]
        if !settings.globalUa.isEmpty { patch["global-ua"] = settings.globalUa }
        return patch
    }

    // MARK: Theme / style name mapping

    /// 0xFFRRGGBB, upstream's int colour. Custom accent wins;
    /// otherwise the accent preset's RGB (ThemeStore colours).
    static func themeAccentARGB(context: FlClashExportContext) -> Int {
        if let hex = context.theme.customAccentHex, let argb = parseHexColor(hex) {
            return argb
        }
        switch context.theme.accent {
        case .blue: return 0xFF007AFF
        case .green: return 0xFF34C759
        case .purple: return 0xFFAF52DE
        case .orange: return 0xFFFF9500
        case .teal: return 0xFF00A9AD
        case .magenta: return 0xFFB86CA2
        }
    }

    static func parseHexColor(_ hex: String) -> Int? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return 0xFF00_0000 | value
    }

    private static func proxySortName(_ sort: ProxySort) -> String {
        switch sort {
        case .default: return "none"
        case .delay: return "delay"
        case .name: return "name"
        }
    }

    private static func proxyLayoutName(_ layout: ProxyStyleStore.Layout) -> String {
        switch layout {
        case .loose: return "loose"
        case .standard: return "standard"
        case .tight: return "tight"
        }
    }

    private static func proxyCardTypeName(_ card: ProxyStyleStore.CardType) -> String {
        switch card {
        case .loose: return "loose"
        case .standard: return "standard"
        case .compact: return "compact"
        }
    }

    private static func proxyIconStyleName(_ style: ProxyStyleStore.IconStyle) -> String {
        switch style {
        case .filled: return "filled"
        case .plain: return "plain"
        case .hidden: return "hidden"
        }
    }
}

// MARK: - config.json: apply (import)

/// Applies a decoded config.json onto the live stores, upstream
/// applyRestore semantics: davProps falls back to the current
/// value when the backup has none; accessControlProps is kept
/// when the backup has none (no store here — a no-op); every other
/// section is applied field by field, unknown keys ignored
/// (Config.safeFromJson salvage behaviour). Never throws: a bad
/// field is skipped, the rest still applies.
enum FlClashConfigApply {
    static func apply(
        _ config: [String: Any],
        settings: SettingsStore,
        theme: ThemeStore,
        proxyStyle: ProxyStyleStore,
        backupStore: BackupStore) {
        let defaults = UserDefaults.standard
        if let app = FlClashJSON.dict(config["appSettingProps"]) {
            if let v = FlClashJSON.bool(app["onlyStatisticsProxy"]) { settings.onlyStatisticsProxy = v }
            if let v = FlClashJSON.int(app["delayTestTimeout"]) { settings.delayTestTimeout = v }
            if let v = FlClashJSON.bool(app["autoCheckUpdate"]) { settings.autoCheckUpdate = v }
            if let raw = FlClashJSON.string(app["updateChannel"]) {
                settings.updateChannel = raw == "pre" ? .prerelease : .stable
            }
            if let v = FlClashJSON.bool(app["developerMode"]) { settings.developerMode = v }
            if let v = FlClashJSON.bool(app["hideIp"]) { settings.hideIp = v }
            if let v = FlClashJSON.bool(app["closeConnections"]) { settings.autoCloseConnections = v }
            if let v = FlClashJSON.bool(app["checkCertificate"]) { settings.checkCertificate = v }
            if let v = FlClashJSON.bool(app["openLogs"]) { settings.openLogs = v }
            if let v = FlClashJSON.bool(app["autoRun"]) { settings.autoRun = v }
            if let list = FlClashJSON.array(app["userAgents"]) {
                settings.userAgents = list.compactMap { FlClashJSON.string($0) }
            }
            if let raw = FlClashJSON.string(app["restoreStrategy"]),
               let strategy = BackupStore.RestoreStrategy(rawValue: raw) {
                backupStore.restoreStrategy = strategy
            }
            if let raw = FlClashJSON.string(app["tabAnimation"]) {
                theme.tabAnimation = raw == "fade" ? .fade : .slide
            }
            if let v = FlClashJSON.bool(app["floatingNavigationBar"]) {
                theme.navBarStyle = v ? .floating : .docked
            }
            if let v = FlClashJSON.int(app["acceptedDisclaimerVersion"]), v > 0 {
                defaults.set(true, forKey: "ConcordiOS.disclaimer.consented")
            }
        }
        // davProps falls back to the current value when absent.
        if let dav = FlClashJSON.dict(config["davProps"]) {
            if let v = FlClashJSON.string(dav["uri"]) { defaults.set(v, forKey: "ConcordiOS.webdav.url") }
            if let v = FlClashJSON.string(dav["user"]) { defaults.set(v, forKey: "ConcordiOS.webdav.username") }
            if let raw = FlClashJSON.string(dav["password"]) {
                defaults.set(FlClashDavPassword.decode(raw), forKey: "ConcordiOS.webdav.password")
            }
            if let v = FlClashJSON.string(dav["fileName"]) { defaults.set(v, forKey: "ConcordiOS.webdav.fileName") }
        }
        if let network = FlClashJSON.dict(config["networkProps"]) {
            if let v = FlClashJSON.bool(network["systemProxy"]) { settings.systemProxy = v }
            if let list = FlClashJSON.array(network["bypassDomain"]) {
                settings.bypassDomain = list.compactMap { FlClashJSON.string($0) }
            }
            if let v = FlClashJSON.bool(network["bypassPrivateRoute"]) { settings.bypassPrivateRoute = v }
            if let v = FlClashJSON.bool(network["appendSystemDns"]) { settings.appendSystemDns = v }
            if let auth = FlClashJSON.dict(network["authentication"]) {
                if let v = FlClashJSON.bool(auth["enable"]) { settings.authEnabled = v }
                if let v = FlClashJSON.string(auth["username"]) { settings.authUsername = v }
                if let v = FlClashJSON.string(auth["password"]) { settings.authPassword = v }
            }
        }
        if let vpn = FlClashJSON.dict(config["vpnProps"]) {
            if let v = FlClashJSON.bool(vpn["systemProxy"]) { settings.systemProxy = v }
            if let v = FlClashJSON.bool(vpn["ipv6"]) { settings.ipv6 = v }
            if let v = FlClashJSON.bool(vpn["dnsHijacking"]) { settings.dnsHijack = v }
            // accessControlProps: kept when the backup has none,
            // and there is no access-control store here to apply
            // it to — intentionally a no-op (see header).
        }
        if let themeProps = FlClashJSON.dict(config["themeProps"]) {
            if let raw = FlClashJSON.string(themeProps["themeMode"]),
               let mode = ThemeAppearance(rawValue: raw) {
                theme.appearance = mode
            }
            if let raw = FlClashJSON.string(themeProps["colorStyle"]),
               let style = ThemeColorStyle(rawValue: raw) {
                theme.colorStyle = style
            }
            if let v = FlClashJSON.bool(themeProps["pureBlack"]) { theme.pureBlack = v }
            if let raw = FlClashJSON.string(themeProps["liquidGlass"]),
               let mode = ThemeLiquidGlassMode(rawValue: raw) {
                theme.liquidGlass = mode
            }
            if let scale = FlClashJSON.dict(themeProps["textScale"]) {
                if let v = FlClashJSON.bool(scale["enable"]) { theme.textScaleEnabled = v }
                if let v = FlClashJSON.double(scale["scale"]) { theme.textScale = v }
            }
            if let font = FlClashJSON.string(themeProps["systemFontFamily"]), !font.isEmpty {
                defaults.set(font, forKey: "ConcordiOS.font.family.v1")
            }
            applyAccent(themeProps: themeProps, theme: theme)
            theme.save()
        }
        if let styleProps = FlClashJSON.dict(config["proxiesStyleProps"]) {
            if let raw = FlClashJSON.string(styleProps["type"]) {
                proxyStyle.style = raw == "tab" ? .tab : .list
            }
            if let raw = FlClashJSON.string(styleProps["sortType"]) {
                proxyStyle.sort = raw == "delay" ? .delay : raw == "name" ? .name : .default
            }
            if let raw = FlClashJSON.string(styleProps["layout"]) {
                proxyStyle.layout = layout(from: raw)
            }
            if let raw = FlClashJSON.string(styleProps["cardType"]) {
                proxyStyle.cardType = cardType(from: raw)
            }
            if let raw = FlClashJSON.string(styleProps["iconStyle"]) {
                proxyStyle.iconStyle = iconStyle(from: raw)
            }
            if let v = FlClashJSON.bool(styleProps["hideTimeoutProxies"]) {
                proxyStyle.hideTimeout = v
            }
        }
        if let patch = FlClashJSON.dict(config["patchClashConfig"]) {
            applyPatch(patch, settings: settings)
        }
        // excludeSSIDs: no store here — ignored (see header).
        settings.save()
    }

    /// Nearest preset accent by RGB distance; a colour far from
    /// every preset becomes a custom accent hex instead.
    private static func applyAccent(themeProps: [String: Any], theme: ThemeStore) {
        let candidates = FlClashJSON.array(themeProps["primaryColors"]) ?? []
        let raw = candidates.first ?? themeProps["primaryColor"]
        guard let argb = FlClashJSON.int64(raw) else { return }
        let rgb = Int(argb & 0xFFFFFF)
        let presets: [(ThemeAccent, Int)] = [
            (.blue, 0x007AFF), (.green, 0x34C759), (.purple, 0xAF52DE),
            (.orange, 0xFF9500), (.teal, 0x00A9AD), (.magenta, 0xB86CA2),
        ]
        func distance(_ a: Int, _ b: Int) -> Int {
            let dr = ((a >> 16) & 0xFF) - ((b >> 16) & 0xFF)
            let dg = ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF)
            let db = (a & 0xFF) - (b & 0xFF)
            return dr * dr + dg * dg + db * db
        }
        if let best = presets.min(by: { distance($0.1, rgb) < distance($1.1, rgb) }),
           distance(best.1, rgb) < 40 * 40 * 3 {
            theme.accent = best.0
            theme.customAccentHex = nil
        } else {
            theme.customAccentHex = String(format: "#%06X", rgb)
        }
    }

    private static func layout(from raw: String) -> ProxyStyleStore.Layout {
        switch raw {
        case "loose": return .loose
        case "tight": return .tight
        default: return .standard
        }
    }

    private static func cardType(from raw: String) -> ProxyStyleStore.CardType {
        switch raw {
        case "loose": return .loose
        case "compact": return .compact
        default: return .standard
        }
    }

    private static func iconStyle(from raw: String) -> ProxyStyleStore.IconStyle {
        switch raw {
        case "plain": return .plain
        case "hidden": return .hidden
        default: return .filled
        }
    }

    private static func applyPatch(_ patch: [String: Any], settings: SettingsStore) {
        let defaults = UserDefaults.standard
        func int(_ key: String) -> Int? { FlClashJSON.int(patch[key]) }
        func bool(_ key: String) -> Bool? { FlClashJSON.bool(patch[key]) }
        func string(_ key: String) -> String? { FlClashJSON.string(patch[key]) }
        if let v = int("mixed-port"), (1...65535).contains(v) { settings.mixedPort = v }
        if let v = int("socks-port") { settings.socksPort = v }
        if let v = int("redir-port") { defaults.set(v, forKey: "ConcordiOS.redirPort") }
        if let v = int("tproxy-port") { defaults.set(v, forKey: "ConcordiOS.tproxyPort") }
        if let raw = string("mode"), let mode = OutboundMode(rawValue: raw) { settings.mode = mode }
        if let v = bool("allow-lan") { settings.allowLan = v }
        if let raw = string("log-level"), let level = LogLevel(rawValue: raw) { settings.logLevel = level }
        if let v = bool("ipv6") { settings.ipv6 = v }
        if let v = string("find-process-mode") { settings.findProcessModeSetting = v }
        if let v = string("interface-name-mode") { settings.interfaceNameMode = v }
        if let v = string("interface-name") { settings.interfaceName = v }
        if let v = int("keep-alive-interval") { settings.keepAliveInterval = v }
        if let v = int("keep-alive-idle") { settings.keepAliveIdle = v }
        if let v = bool("disable-keep-alive") { settings.disableKeepAlive = v }
        if let v = bool("unified-delay") { settings.unifiedDelay = v }
        if let v = bool("tcp-concurrent") { settings.tcpConcurrent = v }
        if let v = string("global-ua") { settings.globalUa = v }
        if let raw = string("external-controller") {
            settings.externalControllerEnabled = !raw.isEmpty
        }
        if let v = string("secret") { settings.externalControllerSecret = v }
        if let geo = FlClashJSON.dict(patch["geox-url"]) {
            if let v = FlClashJSON.string(geo["mmdb"]) { defaults.set(v, forKey: "ConcordiOS.geoURL.MMDB") }
            if let v = FlClashJSON.string(geo["geosite"]) { defaults.set(v, forKey: "ConcordiOS.geoURL.GEOSITE") }
            if let v = FlClashJSON.string(geo["asn"]) { defaults.set(v, forKey: "ConcordiOS.geoURL.ASN") }
        }
        if let v = bool("geo-auto-update") { defaults.set(v, forKey: "ConcordiOS.geoAutoUpdate") }
        if let v = int("geo-update-interval") { defaults.set(v, forKey: "ConcordiOS.geoAutoUpdateHours") }
        if let tun = FlClashJSON.dict(patch["tun"]) {
            if let v = FlClashJSON.bool(tun["enable"]) { settings.tunEnabled = v }
            if let v = FlClashJSON.int(tun["mtu"]) { settings.tunMtu = v }
            if let list = FlClashJSON.array(tun["route-exclude-address"]) {
                settings.routeExcludeAddress = list.compactMap { FlClashJSON.string($0) }
            }
        }
        if let dns = FlClashJSON.dict(patch["dns"]) {
            applyDns(dns, settings: settings)
        }
        if let mitm = FlClashJSON.dict(patch["mitm"]) {
            if let v = FlClashJSON.bool(mitm["enable"]) { settings.mitmEnabled = v }
            if let list = FlClashJSON.array(mitm["hostname"]) {
                settings.mitmHostnames = list.compactMap { FlClashJSON.string($0) }.joined(separator: ",")
            }
            if let v = FlClashJSON.bool(mitm["skip-server-cert-verify"]) {
                settings.mitmSkipServerCertVerify = v
            }
            if let v = FlClashJSON.bool(mitm["auto-quic-block"]) { settings.mitmAutoQuicBlock = v }
            if let v = FlClashJSON.bool(mitm["h2"]) { defaults.set(v, forKey: "ConcordiOS.mitmH2") }
            if let v = FlClashJSON.bool(mitm["decrypt-untrusted"]) {
                defaults.set(v, forKey: "ConcordiOS.mitmDecryptUntrusted")
            }
            if let v = FlClashJSON.string(mitm["trusted-fingerprint"]) {
                settings.mitmTrustedFingerprint = v
            }
            if let v = FlClashJSON.bool(mitm["capture"]) { settings.mitmCapture = v }
            if let v = FlClashJSON.int(mitm["capture-entries"]) { settings.mitmCaptureEntries = v }
        }
    }

    private static func applyDns(_ dns: [String: Any], settings: SettingsStore) {
        let defaults = UserDefaults.standard
        func bool(_ key: String) -> Bool? { FlClashJSON.bool(dns[key]) }
        func int(_ key: String) -> Int? { FlClashJSON.int(dns[key]) }
        func string(_ key: String) -> String? { FlClashJSON.string(dns[key]) }
        func list(_ key: String) -> [String]? {
            FlClashJSON.array(dns[key]).map { $0.compactMap { FlClashJSON.string($0) } }
        }
        func map(_ key: String) -> [String: String]? {
            FlClashJSON.dict(dns[key]).map { FlClashJSON.stringMap($0) }
        }
        if let v = bool("enable") { settings.dnsEnabled = v }
        if let v = string("listen") { settings.dnsListen = v }
        if let v = int("listen-routing-mark") { defaults.set(v, forKey: "ConcordiOS.dnsListenRoutingMark") }
        if let v = bool("prefer-h3") { settings.dnsPreferH3 = v }
        if let v = bool("use-hosts") { settings.dnsUseHosts = v }
        if let v = bool("use-system-hosts") { settings.dnsUseSystemHosts = v }
        if let v = bool("respect-rules") { settings.dnsRespectRules = v }
        if let v = bool("ipv6") { settings.dnsIpv6 = v }
        if let v = int("ipv6-timeout") { settings.dnsIpv6Timeout = v }
        if let v = string("cache-algorithm") { settings.dnsCacheAlgorithm = v }
        if let v = int("cache-max-size") { settings.dnsCacheMaxSize = v }
        if let v = string("enhanced-mode") { settings.dnsEnhancedMode = v }
        if let v = string("fake-ip-range") { settings.dnsFakeIpRange = v }
        if let v = string("fake-ip-range6") { settings.dnsFakeIpRange6 = v }
        if let v = list("fake-ip-filter") { settings.dnsFakeIpFilter = v }
        if let v = string("fake-ip-filter-mode") { settings.dnsFakeIpFilterMode = v }
        if let v = int("fake-ip-ttl") { settings.dnsFakeIpTtl = v }
        if let v = map("nameserver-policy") { settings.dnsNameserverPolicy = v }
        if let v = list("default-nameserver") { settings.dnsDefaultNameserver = v }
        if let v = list("nameserver"), let first = v.first {
            settings.dnsNameserver = first
            settings.dnsExtraNameservers = Array(v.dropFirst())
        }
        if let v = list("fallback") { settings.dnsFallback = v }
        if let v = bool("fallback-lazy-query") { settings.dnsFallbackLazyQuery = v }
        if let v = list("proxy-server-nameserver") { settings.dnsProxyServerNameserver = v }
        if let v = map("proxy-server-nameserver-policy") { settings.dnsProxyServerNameserverPolicy = v }
        if let v = list("direct-nameserver") { settings.dnsDirectNameserver = v }
        if let v = bool("direct-nameserver-follow-policy") { settings.dnsDirectNameserverFollowPolicy = v }
        if let filter = FlClashJSON.dict(dns["fallback-filter"]) {
            if let v = FlClashJSON.bool(filter["geoip"]) { settings.dnsFallbackFilterGeoip = v }
            if let v = FlClashJSON.string(filter["geoip-code"]) { settings.dnsFallbackFilterGeoipCode = v }
            if let v = FlClashJSON.array(filter["geosite"]) {
                settings.dnsFallbackFilterGeosite = v.compactMap { FlClashJSON.string($0) }
            }
            if let v = FlClashJSON.array(filter["ipcidr"]) {
                settings.dnsFallbackFilterIpcidr = v.compactMap { FlClashJSON.string($0) }
            }
            if let v = FlClashJSON.array(filter["domain"]) {
                settings.dnsFallbackFilterDomain = v.compactMap { FlClashJSON.string($0) }
            }
        }
    }
}

// MARK: - Import: apply decoded rows + files + config

/// Applies a decoded FlClash backup. Files named by the restored
/// rows are copied staging -> home BEFORE any row is written
/// (upstream _copyStagedFiles), with replaced files kept for a
/// putBack rollback; a failure during the row writes restores the
/// replaced files and the touched UserDefaults keys and rethrows.
/// Config is applied last and never rolls back (upstream).
enum FlClashRestore {
    struct Outcome {
        var profiles: Int
        var scripts: Int
        var mitmScripts: Int
        var extendScripts: Int
        var globalRules: Int
        var customProxies: Int
        var mitmModules: Int
        var configApplied: Bool
    }

    /// Entry names BackupEntries.ofData(data) would name, mapped to
    /// OUR container layout. Entries the backup carries but no row
    /// names are ignored (upstream ofData semantics).
    static func targetPaths(for data: FlClashBackupData) -> [String: String] {
        var map: [String: String] = [:]
        for profile in data.profiles {
            let uuid = FlClashIdMap.uuid(forProfileSnowflake: profile.id)
            map["profiles/\(profile.id).yaml"] = "profiles/\(uuid.uuidString).yaml"
        }
        let extendScriptIds = Set(data.profiles.compactMap { $0.scriptId })
        for script in data.scripts where !extendScriptIds.contains(script.id) {
            if let id = FlClashIdMap.stringId(forKey: "script", snowflake: script.id) {
                map["scripts/\(script.id).js"] = "mitm/scripts/\(id).js"
            }
        }
        for provider in data.clashProviders {
            let fileName = FlClashHash.md5Hex("\(provider.id)@\(provider.url)")
            map["providers/rules/\(fileName)"] = "providers/rules/\(fileName)"
        }
        for module in data.mitmModules where module.url == nil {
            if let id = FlClashIdMap.stringId(forKey: "module", snowflake: module.id) {
                map["mitm/modules/\(module.id).txt"] = "mitm-modules/\(id).txt"
            }
            for (_, resourceName) in module.resources {
                guard FlClashArchiveReader.isSafeEntryPath(resourceName),
                      !resourceName.contains("/") else { continue }
                map["mitm/resources/\(resourceName)"] = "mitm/resources/\(resourceName)"
            }
        }
        return map
    }

    static func apply(
        _ data: FlClashBackupData,
        scope: BackupStore.RestoreScope,
        strategy: BackupStore.RestoreStrategy,
        container: URL,
        settings: SettingsStore,
        theme: ThemeStore,
        proxyStyle: ProxyStyleStore,
        backupStore: BackupStore) async throws -> (Outcome, String) {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("flclash-restore-\(UUID().uuidString)")
        let replacedDir = staging.appendingPathComponent("replaced")
        try fileManager.createDirectory(at: replacedDir, withIntermediateDirectories: true)
        // UserDefaults keys the row/config writes may touch, for
        // rollback. (The live Settings/Theme stores are reloaded
        // by the caller after a failure too, so their in-memory
        // state cannot outlive a rollback.)
        let udKeys = [
            "ConcordiOS.profiles.v1",
            "ConcordiOS.settings.v1", "ConcordiOS.theme.v1", "ConcordiOS.mode.v1",
            "ConcordiOS.webdav.url", "ConcordiOS.webdav.username",
            "ConcordiOS.webdav.password", "ConcordiOS.webdav.fileName",
            "ConcordiOS.geoURL.MMDB", "ConcordiOS.geoURL.GEOSITE", "ConcordiOS.geoURL.ASN",
            "ConcordiOS.geoAutoUpdate", "ConcordiOS.geoAutoUpdateHours",
            "ConcordiOS.disclaimer.consented",
            "ConcordiOS.redirPort", "ConcordiOS.tproxyPort",
            "ConcordiOS.dnsListenRoutingMark",
            "ConcordiOS.mitmH2", "ConcordiOS.mitmDecryptUntrusted",
            "ConcordiOS.font.family.v1",
            "ConcordiOS.proxies.style", "ConcordiOS.proxies.sort",
            "ConcordiOS.proxies.layout", "ConcordiOS.proxies.cardType",
            "ConcordiOS.proxies.iconStyle", "ConcordiOS.proxies.hideTimeout",
            "ConcordiOS.backup.restoreStrategy",
            "ConcordiOS.overrides.v1",
        ]
        var savedUD: [String: Any?] = [:]
        for key in udKeys { savedUD[key] = UserDefaults.standard.object(forKey: key) }
        // Store files the row writes may replace, for rollback.
        let storeFiles = [
            "mitm-modules/modules.json",
            "mitm/scripts/scripts.json",
            "custom-proxies.json", "custom-proxies-raw.json",
            "filter-overrides.json",
            "added-rules.json", "added-rules-disabled.json",
            "extend-config.json", "overrides.json",
        ]
        var savedFiles: [String: Data?] = [:]
        for relative in storeFiles {
            let url = container.appendingPathComponent(relative)
            savedFiles[relative] = try? Data(contentsOf: url)
        }
        // Copy staged files first; replaced originals go under
        // staging/replaced/ for putBack.
        var copied: [(target: URL, replaced: Bool, backupURL: URL?)] = []
        let targets = targetPaths(for: data)
        do {
            for (entry, targetRelative) in targets {
                guard let bytes = data.files[entry] else { continue }
                let target = container.appendingPathComponent(targetRelative)
                let replaced = fileManager.fileExists(atPath: target.path)
                var backupURL: URL?
                if replaced {
                    backupURL = replacedDir.appendingPathComponent(targetRelative)
                    try fileManager.createDirectory(
                        at: backupURL!.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: target, to: backupURL!)
                }
                copied.append((target: target, replaced: replaced, backupURL: backupURL))
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
        } catch {
            putBack(copied: copied)
            try? fileManager.removeItem(at: staging)
            throw FlClashBackupError.io("恢复文件失败：\(error.localizedDescription)")
        }
        do {
            let outcome = try await applyRows(
                data, strategy: strategy, container: container)
            // Config applies last (onlyProfiles skips it entirely);
            // a config failure does not roll back the rows.
            var configApplied = false
            if scope == .all {
                FlClashConfigApply.apply(
                    data.config, settings: settings, theme: theme,
                    proxyStyle: proxyStyle, backupStore: backupStore)
                configApplied = true
                applyActiveProfile(data: data, scope: scope, container: container)
            }
            try? fileManager.removeItem(at: staging)
            // Replaced-provider caches + stale .mrs equivalents.
            clearReplacedProviderCaches(data: data, container: container)
            let outcomeWithConfig = Outcome(
                profiles: outcome.profiles, scripts: outcome.scripts,
                mitmScripts: outcome.mitmScripts, extendScripts: outcome.extendScripts,
                globalRules: outcome.globalRules, customProxies: outcome.customProxies,
                mitmModules: outcome.mitmModules, configApplied: configApplied)
            return (outcomeWithConfig, summary(outcomeWithConfig, scope: scope))
        } catch {
            putBack(copied: copied)
            for (relative, bytes) in savedFiles {
                let url = container.appendingPathComponent(relative)
                if let bytes {
                    try? bytes.write(to: url, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: url)
                }
            }
            for (key, object) in savedUD {
                if let object {
                    UserDefaults.standard.set(object, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func putBack(
        copied: [(target: URL, replaced: Bool, backupURL: URL?)]) {
        for item in copied {
            if item.replaced, let backupURL = item.backupURL {
                try? FileManager.default.copyItem(at: backupURL, to: item.target)
            } else if !item.replaced {
                try? FileManager.default.removeItem(at: item.target)
            }
        }
    }

    /// Delete provider cache files no current provider names, and
    /// any compiled .mrs left under providers/ (upstream
    /// _clearReplacedProviderCaches + _clearOutdatedCompiledRuleSets).
    /// "Current" means the providers in the FINAL profile YAMLs
    /// (merged state, not just the backup's rows), so a compatible
    /// restore never deletes a kept profile's cache.
    private static func clearReplacedProviderCaches(data: FlClashBackupData, container: URL) {
        var kept = Set(data.clashProviders.map {
            FlClashHash.md5Hex("\($0.id)@\($0.url)")
        })
        if let blob = UserDefaults.standard.data(forKey: "ConcordiOS.profiles.v1"),
           let profiles = try? JSONDecoder().decode([Profile].self, from: blob) {
            for profile in profiles {
                let yamlURL = container.appendingPathComponent("profiles/\(profile.id.uuidString).yaml")
                guard let text = try? String(contentsOf: yamlURL, encoding: .utf8) else { continue }
                for provider in FlClashYaml.sections(of: text).ruleProviders {
                    let type = FlClashYaml.string(provider.definition, "type") ?? "http"
                    let url = type == "file" ? "" : (FlClashYaml.string(provider.definition, "url") ?? "")
                    let id = FlClashIdMap.snowflake(
                        forKey: "provider:\(profile.id.uuidString):\(provider.name)")
                    kept.insert(FlClashHash.md5Hex("\(id)@\(url)"))
                }
            }
        }
        let dir = container.appendingPathComponent("providers").appendingPathComponent("rules")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in items {
            if url.pathExtension == "mrs" || !kept.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func summary(_ outcome: Outcome, scope: BackupStore.RestoreScope) -> String {
        var bits: [String] = []
        if outcome.profiles > 0 { bits.append("\(outcome.profiles) 个配置") }
        if outcome.globalRules > 0 { bits.append("\(outcome.globalRules) 条全局规则") }
        if outcome.customProxies > 0 { bits.append("\(outcome.customProxies) 个自定义代理") }
        if outcome.mitmModules > 0 { bits.append("\(outcome.mitmModules) 个 MITM 模块") }
        if outcome.mitmScripts > 0 { bits.append("\(outcome.mitmScripts) 个脚本") }
        if outcome.extendScripts > 0 { bits.append("\(outcome.extendScripts) 个扩展脚本") }
        let what = bits.isEmpty ? "备份数据" : bits.joined(separator: "、")
        let configNote = scope == .all
            ? (outcome.configApplied ? "设置已按备份恢复。" : "设置未恢复。")
            : "设置保持不变（仅恢复配置模式只跳过设置；配置、规则、脚本与 MITM 模块仍已恢复）。"
        // Note the upstream trap in plain words: onlyProfiles still
        // restores the rows + files above; only the Config is skipped.
        return "已恢复\(what)。\(configNote)各页面会自动重新加载；VPN 正在运行时建议重启一次 VPN，让核心用恢复后的配置重新启动。"
    }

    // MARK: Row writes

    private static func applyRows(
        _ data: FlClashBackupData,
        strategy: BackupStore.RestoreStrategy,
        container: URL) async throws -> Outcome {
        let fileManager = FileManager.default
        var outcome = Outcome(
            profiles: 0, scripts: data.scripts.count, mitmScripts: 0,
            extendScripts: 0, globalRules: 0, customProxies: 0,
            mitmModules: 0, configApplied: false)
        let activeSnowflake = FlClashJSON.int64(data.config["currentProfileId"])
        let activeUUID = activeSnowflake.map { FlClashIdMap.uuid(forProfileSnowflake: $0) }

        // --- Profiles (meta in UserDefaults; YAML files already copied).
        var currentProfiles: [Profile] = []
        if let blob = UserDefaults.standard.data(forKey: "ConcordiOS.profiles.v1"),
           let decoded = try? JSONDecoder().decode([Profile].self, from: blob) {
            currentProfiles = decoded
        }
        var importedProfiles: [Profile] = []
        for row in data.profiles {
            let uuid = FlClashIdMap.uuid(forProfileSnowflake: row.id)
            let isActive = activeUUID == uuid
            importedProfiles.append(Profile(
                id: uuid, name: row.label,
                kind: row.type == "url" ? .url : .file,
                urlString: row.url.isEmpty ? nil : row.url,
                fileName: nil,
                updatedAt: row.lastUpdateDateMillis.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                },
                isActive: isActive,
                note: nil,
                ageSecretKey: row.ageSecretKey,
                autoUpdate: row.autoUpdate,
                autoUpdateIntervalMinutes: row.autoUpdateDurationMillis > 0
                    ? Int(row.autoUpdateDurationMillis / 60_000) : nil,
                subscriptionInfo: row.subscriptionInfo.map {
                    SubscriptionInfo(
                        upload: FlClashJSON.int64($0["upload"]) ?? 0,
                        download: FlClashJSON.int64($0["download"]) ?? 0,
                        total: FlClashJSON.int64($0["total"]) ?? 0,
                        expire: FlClashJSON.int64($0["expire"]) ?? 0)
                }))
        }
        let mergedProfiles: [Profile]
        switch strategy {
        case .compatible:
            // If the backup names an active profile, it wins and
            // every other profile goes inactive; otherwise the
            // current active flag survives per profile.
            let importedActiveId = importedProfiles.first(where: { $0.isActive })?.id
            var byId = Dictionary(uniqueKeysWithValues: currentProfiles.map { ($0.id, $0) })
            var order = currentProfiles.map { $0.id }
            for profile in importedProfiles {
                if byId[profile.id] == nil { order.append(profile.id) }
                var replacement = profile
                if let importedActiveId {
                    replacement.isActive = profile.id == importedActiveId
                } else if let existing = byId[profile.id] {
                    replacement.isActive = existing.isActive
                }
                byId[profile.id] = replacement
            }
            mergedProfiles = order.compactMap { byId[$0] }
        case .override:
            mergedProfiles = importedProfiles
        }
        // Never leave the app profile-less: if nothing is active
        // (e.g. onlyProfiles + override dropped the active one),
        // activate the first profile.
        var finalProfiles = mergedProfiles
        if !finalProfiles.contains(where: { $0.isActive }), !finalProfiles.isEmpty {
            finalProfiles[0].isActive = true
        }
        if let blob = try? JSONEncoder().encode(finalProfiles) {
            UserDefaults.standard.set(blob, forKey: "ConcordiOS.profiles.v1")
        }
        outcome.profiles = importedProfiles.count

        // --- Scripts: extend scripts vs MITM scripts, split by
        // whether a profile row references the id.
        let extendScriptIds = Set(data.profiles.compactMap { $0.scriptId })
        let extendStore = ExtendConfigStore()
        var mitmScripts: [MitmScript] = []
        for row in data.scripts {
            if extendScriptIds.contains(row.id) {
                guard let profileRow = data.profiles.first(where: { $0.scriptId == row.id }) else { continue }
                let uuid = FlClashIdMap.uuid(forProfileSnowflake: profileRow.id)
                let js = data.files["scripts/\(row.id).js"]
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                var settings = extendStore.settings(for: uuid)
                settings.mode = .script
                settings.scriptText = js
                settings.scriptEnabled = true
                extendStore.update(settings, for: uuid)
                outcome.extendScripts += 1
            } else {
                let id = FlClashIdMap.stringId(forKey: "script", snowflake: row.id)
                    ?? UUID().uuidString
                FlClashIdMap.record(namespace: "script", stringId: id, snowflake: row.id)
                mitmScripts.append(MitmScript(
                    id: id, label: row.label, url: row.url,
                    lastUpdateTime: Date(timeIntervalSince1970: TimeInterval(row.lastUpdateTimeMillis) / 1000),
                    order: Int(row.order ?? 0)))
            }
        }
        // MITM scripts: compatible merges (save() upserts one
        // script: its .js + resource copy + registry entry); for
        // override, drop scripts the backup does not name first.
        let scriptStore = MitmScriptStore()
        if strategy == .override {
            for existing in scriptStore.scripts where !mitmScripts.contains(where: { $0.id == existing.id }) {
                await scriptStore.delete(existing)
            }
        }
        for script in mitmScripts {
            let content = data.files["scripts/\(scriptIdSnowflake(script: script, data: data)).js"]
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            await scriptStore.save(script, content: content)
            outcome.mitmScripts += 1
        }

        // --- Global rules (profile_id NULL) + disabled global rules.
        let ruleRawById: [Int64: String] = Dictionary(
            uniqueKeysWithValues: data.rules.map { row in
                (row.id, FlClashRule.rawValue(FlClashRuleParts(
                    ruleAction: row.ruleAction, content: row.content,
                    ruleTarget: row.ruleTarget, ruleProvider: row.ruleProvider,
                    subRule: row.subRule, noResolve: row.noResolve, src: row.src,
                    customExit: row.customExit)))
            })
        let globalRaws = data.rules.filter { $0.profileId == nil }
            .compactMap { ruleRawById[$0.id] }
        let addedStore = AddedRulesStore()
        switch strategy {
        case .compatible:
            var merged = addedStore.rules
            for raw in globalRaws where !merged.contains(raw) { merged.append(raw) }
            addedStore.rules = merged
        case .override:
            addedStore.rules = globalRaws
        }
        outcome.globalRules = globalRaws.count
        let disabledGlobalIds = Set(data.disabledRules.map { $0.ruleId })
        let disabledRaws = disabledGlobalIds.compactMap { ruleRawById[$0] }
            .filter { globalRaws.contains($0) }
        switch strategy {
        case .compatible:
            var merged = addedStore.disabledRules
            for raw in disabledRaws where !merged.contains(raw) { merged.append(raw) }
            addedStore.disabledRules = merged
        case .override:
            addedStore.disabledRules = disabledRaws
        }
        addedStore.save()

        // --- Per-profile rules -> ExtendSettings.profileRules, but
        // only the ones NOT already in the restored YAML (a foreign
        // backup's profile rules ARE its YAML rules; ours adds the
        // extend rules on top). exitTargets MATCH -> matchTarget.
        for row in data.profiles {
            let uuid = FlClashIdMap.uuid(forProfileSnowflake: row.id)
            let yamlURL = container.appendingPathComponent("profiles/\(uuid.uuidString).yaml")
            let yamlRules = (try? String(contentsOf: yamlURL, encoding: .utf8))
                .map { FlClashYaml.sections(of: $0).rules } ?? []
            let extra = data.rules.filter { $0.profileId == row.id }
                .compactMap { ruleRawById[$0.id] }
                .filter { !yamlRules.contains($0) }
            var settings = extendStore.settings(for: uuid)
            switch strategy {
            case .compatible:
                for raw in extra where !settings.profileRules.contains(raw) {
                    settings.profileRules.append(raw)
                }
            case .override:
                settings.profileRules = extra
            }
            if let match = row.exitTargets?["MATCH"], !match.isEmpty {
                settings.matchTarget = match
            }
            extendStore.update(settings, for: uuid)
        }

        // --- Custom proxies.
        let proxyStore = CustomProxyStore()
        var importedForm: [CustomProxy] = []
        var importedRaw: [JSONValue] = []
        let formKeys: Set<String> = [
            "name", "type", "server", "port", "password", "uuid",
            "cipher", "tls", "sni", "network", "udp",
        ]
        for row in data.customProxies {
            let keys = Set(row.definition.keys)
            if keys.isSubset(of: formKeys) {
                let id = FlClashIdMap.stringId(forKey: "proxy", snowflake: row.id)
                    ?? UUID().uuidString
                FlClashIdMap.record(namespace: "proxy", stringId: id, snowflake: row.id)
                importedForm.append(CustomProxy(
                    id: id,
                    name: FlClashJSON.string(row.definition["name"]) ?? "",
                    type: FlClashJSON.string(row.definition["type"]) ?? "ss",
                    server: FlClashJSON.string(row.definition["server"]) ?? "",
                    port: FlClashJSON.int(row.definition["port"]) ?? 0,
                    password: FlClashJSON.string(row.definition["password"]) ?? "",
                    uuid: FlClashJSON.string(row.definition["uuid"]) ?? "",
                    cipher: FlClashJSON.string(row.definition["cipher"]) ?? "",
                    tls: FlClashJSON.bool(row.definition["tls"]) ?? false,
                    sni: FlClashJSON.string(row.definition["sni"]) ?? "",
                    network: FlClashJSON.string(row.definition["network"]) ?? "",
                    udp: FlClashJSON.bool(row.definition["udp"]) ?? false))
            } else {
                importedRaw.append(FlClashJSON.jsonValue(row.definition))
            }
        }
        switch strategy {
        case .compatible:
            var byId = Dictionary(uniqueKeysWithValues: proxyStore.proxies.map { ($0.id, $0) })
            for proxy in importedForm { byId[proxy.id] = proxy }
            proxyStore.proxies = proxyStore.proxies.map { byId[$0.id] ?? $0 }
                + importedForm.filter { imported in
                    proxyStore.proxies.allSatisfy { $0.id != imported.id }
                }
            var mergedRaw = proxyStore.rawProxies
            for raw in importedRaw where !mergedRaw.contains(raw) { mergedRaw.append(raw) }
            proxyStore.rawProxies = mergedRaw
        case .override:
            proxyStore.proxies = importedForm
            proxyStore.rawProxies = importedRaw
        }
        proxyStore.save()
        outcome.customProxies = data.customProxies.count

        // --- MITM modules: registry file written directly (the
        // live store reloads it); texts already copied above.
        var currentModules: [MitmModule] = []
        let modulesURL = container.appendingPathComponent("mitm-modules/modules.json")
        if let blob = try? Data(contentsOf: modulesURL),
           let decoded = try? JSONDecoder().decode([MitmModule].self, from: blob) {
            currentModules = decoded
        }
        var importedModules: [MitmModule] = []
        for row in data.mitmModules {
            let id = FlClashIdMap.stringId(forKey: "module", snowflake: row.id)
                ?? UUID().uuidString
            FlClashIdMap.record(namespace: "module", stringId: id, snowflake: row.id)
            importedModules.append(MitmModule(
                id: id, name: row.name, description: row.description,
                url: row.url, enabled: row.enabled,
                order: Int(row.order ?? 0),
                arguments: row.arguments, resources: row.resources,
                system: row.system,
                // Upstream `_withContent` stores the DECLARED script
                // count in `scripts` (declaredScripts.length), so
                // the backup row's scripts is the declared count —
                // which is what `declaredScripts` stores here
                // (v0.2.143, audit B42).
                declaredScripts: Int(row.scripts),
                scripts: Int(row.scripts),
                asksConsent: row.asksConsent, accepted: row.accepted,
                lastUpdateTime: Date(timeIntervalSince1970: TimeInterval(row.lastUpdateTimeMillis) / 1000)))
            // Foreign modules get fresh ids here, so their text /
            // attachments could not be staged by targetPaths (which
            // only knows already-mapped ids): write them now, from
            // the staged entries, under the new id.
            if row.url == nil, let textData = data.files["mitm/modules/\(row.id).txt"] {
                let textURL = container.appendingPathComponent("mitm-modules/\(id).txt")
                try? textData.write(to: textURL, options: .atomic)
            }
            for (_, resourceName) in row.resources {
                guard FlClashArchiveReader.isSafeEntryPath(resourceName),
                      !resourceName.contains("/"),
                      let bytes = data.files["mitm/resources/\(resourceName)"] else { continue }
                let resourceURL = container.appendingPathComponent("mitm/resources/\(resourceName)")
                try? FileManager.default.createDirectory(
                    at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: resourceURL, options: .atomic)
            }
        }
        let mergedModules: [MitmModule]
        switch strategy {
        case .compatible:
            var byId = Dictionary(uniqueKeysWithValues: currentModules.map { ($0.id, $0) })
            for module in importedModules { byId[module.id] = module }
            mergedModules = currentModules.map { byId[$0.id] ?? $0 }
                + importedModules.filter { imported in
                    currentModules.allSatisfy { $0.id != imported.id }
                }
        case .override:
            mergedModules = importedModules
        }
        if let blob = try? JSONEncoder().encode(mergedModules) {
            try fileManager.createDirectory(
                at: modulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.write(to: modulesURL, options: .atomic)
        }
        outcome.mitmModules = importedModules.count

        // --- Per-profile overrides (ProfileOverrides JSON ->
        // OverrideStore per-profile sections).
        let overrideStore = OverrideStore.shared
        for row in data.profiles {
            guard let overrides = row.overrides, !overrides.isEmpty else { continue }
            let uuid = FlClashIdMap.uuid(forProfileSnowflake: row.id).uuidString
            var sections: [String: [String: JSONValue]] = [:]
            for section in ["dns", "tun", "sniffer", "ntp"] {
                guard let dict = FlClashJSON.dict(overrides[section]) else { continue }
                let keysKey: String
                switch section {
                case "dns": keysKey = "dns-override-keys"
                case "tun": keysKey = "tun-override-keys"
                case "sniffer": keysKey = "sniffer-override-keys"
                default: keysKey = "ntp-override-keys"
                }
                let enabledKeys = FlClashJSON.array(overrides[keysKey])
                    .map { $0.compactMap { FlClashJSON.string($0) } }
                var values: [String: JSONValue] = [:]
                for (key, value) in dict {
                    if let enabledKeys, !enabledKeys.contains(key) { continue }
                    values[key] = FlClashJSON.jsonValue(value)
                }
                if !values.isEmpty { sections[section] = values }
            }
            if sections.isEmpty { continue }
            switch strategy {
            case .compatible:
                var merged = overrideStore.profiles[uuid] ?? [:]
                for (section, values) in sections {
                    var existing = merged[section] ?? [:]
                    for (key, value) in values { existing[key] = value }
                    merged[section] = existing
                }
                overrideStore.replaceScope(scope: uuid, values: merged)
            case .override:
                overrideStore.replaceScope(scope: uuid, values: sections)
            }
        }
        // ProxyGroups / ClashProviders / ProxyDialers rows: their
        // data lives in the restored profile YAML, which is
        // authoritative — no separate store write. (See header.)
        return outcome
    }

    private static func scriptIdSnowflake(script: MitmScript, data: FlClashBackupData) -> Int64 {
        data.scripts.first(where: {
            FlClashIdMap.stringId(forKey: "script", snowflake: $0.id) == script.id
        })?.id ?? 0
    }

    /// After the config applies, the active profile is the one
    /// config.currentProfileId names (upstream writeConfig). The
    /// profiles blob was already written with that flag in
    /// applyRows; this only covers the case where the config's
    /// current id names a profile the rows did not include.
    private static func applyActiveProfile(
        data: FlClashBackupData, scope: BackupStore.RestoreScope, container: URL) {
        guard scope == .all,
              let snowflake = FlClashJSON.int64(data.config["currentProfileId"]),
              let blob = UserDefaults.standard.data(forKey: "ConcordiOS.profiles.v1"),
              var profiles = try? JSONDecoder().decode([Profile].self, from: blob) else { return }
        let uuid = FlClashIdMap.uuid(forProfileSnowflake: snowflake)
        guard profiles.contains(where: { $0.id == uuid }) else { return }
        for index in profiles.indices {
            profiles[index].isActive = profiles[index].id == uuid
        }
        if let blob = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(blob, forKey: "ConcordiOS.profiles.v1")
        }
    }
}
