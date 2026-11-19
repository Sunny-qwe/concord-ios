import Foundation
import Combine

// MARK: - Backup / restore (FlClash: backup & restore)
// FlClash can export all of its data and import it back. There is no
// Concord API for this — it is pure client work: the backup is ONE
// zip file holding every app-owned file in the App Group container
// (profiles, config.yaml, settings JSONs, MITM modules + resources)
// plus a userdefaults.json capturing the UserDefaults blobs the
// stores keep there (profiles metadata, settings, theme, core mode).
// Live snapshots (snapshots/*.json) are NOT backed up: the extension
// rewrites them continuously and they regenerate on the next refresh.
//
// The zip is written and read by ZipArchive below — a minimal
// stored-only (method 0, no compression) ZIP reader/writer, so the
// app needs no third-party dependency. The files are mostly small
// YAML/JSON, so storing them uncompressed is fine.
//
// Restore is all-or-nothing: the zip is unpacked to a staging dir
// and validated (manifest + CRCs) BEFORE anything is touched; the
// current container is safety-copied first, and any failure during
// the replace rolls the safety copy back. A corrupt file therefore
// reports a clear error and leaves the app untouched.

/// Minimal stored-only ZIP (method 0) writer/reader. Only what the
/// backup needs: no compression, no encryption, no multi-disk.
enum ZipArchive {
    struct Entry {
        let path: String
        let data: Data
    }

    enum ZipError: LocalizedError {
        case invalidArchive(String)
        case unsupportedMethod
        case corruptEntry(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let detail): return "不是有效的备份文件（\(detail)）"
            case .unsupportedMethod: return "备份文件用了不支持的压缩方式（只支持未压缩存储）"
            case .corruptEntry(let detail): return "备份文件损坏：\(detail)"
            }
        }
    }

    // MARK: CRC-32 (IEEE 802.3)

    private static let crcTable: [UInt32] = {
        (0..<256).map { index in
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
            }
            return crc
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: DOS date/time

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2))
        let dosDate = UInt16(((year - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (time, dosDate)
    }

    // MARK: Little-endian appends

    private static func append16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func append32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
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

    // MARK: Create

    static func create(entries: [Entry], date: Date = Date()) throws -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(date)
        for entry in entries {
            guard let nameData = entry.path.data(using: .utf8) else { continue }
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            // Local file header.
            append32(&out, 0x04034B50)
            append16(&out, 20) // version needed
            append16(&out, 0) // flags
            append16(&out, 0) // method: stored
            append16(&out, dosTime)
            append16(&out, dosDate)
            append32(&out, crc)
            append32(&out, UInt32(entry.data.count))
            append32(&out, UInt32(entry.data.count))
            append16(&out, UInt16(nameData.count))
            append16(&out, 0) // extra length
            out.append(nameData)
            out.append(entry.data)
            // Central directory record.
            append32(&central, 0x02014B50)
            append16(&central, 20) // version made by
            append16(&central, 20) // version needed
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, dosTime)
            append16(&central, dosDate)
            append32(&central, crc)
            append32(&central, UInt32(entry.data.count))
            append32(&central, UInt32(entry.data.count))
            append16(&central, UInt16(nameData.count))
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0)
            append32(&central, 0) // external attributes
            append32(&central, offset)
            central.append(nameData)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory.
        append32(&out, 0x06054B50)
        append16(&out, 0)
        append16(&out, 0)
        append16(&out, UInt16(entries.count))
        append16(&out, UInt16(entries.count))
        append32(&out, UInt32(central.count))
        append32(&out, centralOffset)
        append16(&out, 0)
        return out
    }

    // MARK: Extract

    static func extract(_ data: Data) throws -> [Entry] {
        // Find the end-of-central-directory record (last 64 KiB + 22).
        let scanStart = max(0, data.count - 65_557)
        var eocd = -1
        var cursor = data.count - 22
        while cursor >= scanStart {
            if read32(data, cursor) == 0x06054B50 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard eocd >= 0 else {
            throw ZipError.invalidArchive("找不到 ZIP 结束标记")
        }
        let count = Int(read16(data, eocd + 10))
        let centralOffset = Int(read32(data, eocd + 16))
        guard count > 0, centralOffset >= 0, centralOffset < data.count else {
            throw ZipError.invalidArchive("中央目录为空或越界")
        }
        var entries: [Entry] = []
        var offset = centralOffset
        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014B50 else {
                throw ZipError.invalidArchive("中央目录损坏")
            }
            let method = read16(data, offset + 10)
            let crc = read32(data, offset + 16)
            let compressedSize = Int(read32(data, offset + 20))
            let uncompressedSize = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipError.invalidArchive("文件名越界")
            }
            guard let path = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw ZipError.invalidArchive("文件名不是 UTF-8")
            }
            // Reject directory traversal and absolute paths: a backup
            // must never write outside the App Group container.
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw ZipError.corruptEntry("非法路径 \(path)")
            }
            guard method == 0 else { throw ZipError.unsupportedMethod }
            // Local header: 30 bytes + name + extra, then the data.
            guard localOffset + 30 <= data.count, read32(data, localOffset) == 0x04034B50 else {
                throw ZipError.invalidArchive("本地文件头损坏")
            }
            let localNameLength = Int(read16(data, localOffset + 26))
            let localExtraLength = Int(read16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count,
                  compressedSize == uncompressedSize else {
                throw ZipError.corruptEntry("文件 \(path) 长度不对")
            }
            let fileData = data[dataStart..<(dataStart + compressedSize)]
            guard crc32(fileData) == crc else {
                throw ZipError.corruptEntry("文件 \(path) 校验失败")
            }
            entries.append(Entry(path: path, data: Data(fileData)))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }
}

// MARK: - Backup store

final class BackupStore: ObservableObject {
    static let manifestFileName = "manifest.json"
    static let userDefaultsFileName = "userdefaults.json"

    /// UserDefaults keys that hold app state (everything else in the
    /// backup is files in the App Group container).
    static let backupUserDefaultsKeys = [
        "ConcordiOS.profiles.v1",
        "ConcordiOS.settings.v1",
        "ConcordiOS.theme.v1",
        "ConcordiOS.mode.v1",
    ]

    /// Keys whose UserDefaults value is a String (the rest are Data).
    private static let stringKeys: Set<String> = ["ConcordiOS.mode.v1"]

    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var isWorking = false

    struct Manifest: Codable {
        let format: String
        let version: Int
        let appVersion: String
        let createdAt: TimeInterval
        let files: [String]
    }

    struct UserDefaultsBackup: Codable {
        /// key -> base64 of the raw value (Data as-is, String as UTF-8).
        let values: [String: String]
        let stringKeys: [String]
    }

    /// Build the backup zip in tmp and return its URL for ShareLink.
    /// Throws with a readable message on any failure.
    func createBackup() async throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        var entries: [ZipArchive.Entry] = []
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: container, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            // Skip dotfiles (e.g. the config editor's temporary
            // validation file) — they are working files, not data.
            if url.lastPathComponent.hasPrefix(".") { continue }
            let relative = url.path.replacingOccurrences(of: container.path + "/", with: "")
            // Live snapshots regenerate on the next refresh; they are
            // not app data and would only bloat the backup.
            if relative == "snapshots" || relative.hasPrefix("snapshots/") { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            entries.append(ZipArchive.Entry(path: relative, data: data))
            files.append(relative)
        }
        // UserDefaults blobs.
        var values: [String: String] = [:]
        for key in Self.backupUserDefaultsKeys {
            if Self.stringKeys.contains(key) {
                if let string = UserDefaults.standard.string(forKey: key),
                   let data = string.data(using: .utf8) {
                    values[key] = data.base64EncodedString()
                }
            } else if let data = UserDefaults.standard.data(forKey: key) {
                values[key] = data.base64EncodedString()
            }
        }
        let defaultsBackup = UserDefaultsBackup(values: values, stringKeys: Array(Self.stringKeys))
        entries.append(ZipArchive.Entry(
            path: Self.userDefaultsFileName,
            data: try JSONEncoder().encode(defaultsBackup)))
        let manifest = Manifest(
            format: "concord-ios-backup", version: 1, appVersion: "0.2.19",
            createdAt: Date().timeIntervalSince1970, files: files)
        entries.append(ZipArchive.Entry(
            path: Self.manifestFileName,
            data: try JSONEncoder().encode(manifest)))
        let zipData = try ZipArchive.create(entries: entries)
        let stamp = BackupStore.backupFileStamp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Concord-备份-\(stamp).zip")
        try zipData.write(to: url, options: .atomic)
        return url
    }

    private static func backupFileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }

    /// Restore a backup picked with fileImporter. All-or-nothing:
    /// validates the whole zip first, safety-copies the current
    /// container, then replaces it; any failure rolls back. Returns a
    /// human-readable summary (file count + what to do next).
    /// What a restore brings back (FlClash: 备份与恢复 -> 恢复选项）.
    enum RestoreScope: String, CaseIterable, Identifiable {
        /// Everything: all container files + all saved settings.
        case all = "恢复全部数据"
        /// Only the profiles (profiles/*.yaml + config.yaml) and the
        /// profile list: settings, theme, MITM modules and the rest
        /// stay as they are.
        case profilesOnly = "仅恢复配置"

        var id: String { rawValue }
    }

    func restore(from pickedURL: URL, scope: RestoreScope = .all) async throws -> String {
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }
        let zipData: Data
        do {
            zipData = try Data(contentsOf: pickedURL)
        } catch {
            throw NSError(domain: "ConcordiOS", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "读取备份文件失败：\(error.localizedDescription)"])
        }
        let entries = try ZipArchive.extract(zipData)
        var byPath: [String: Data] = [:]
        for entry in entries { byPath[entry.path] = entry.data }
        guard let manifestData = byPath[Self.manifestFileName],
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.format == "concord-ios-backup", manifest.version == 1 else {
            throw NSError(domain: "ConcordiOS", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "这不是 Concord iOS 的备份文件（缺少清单或版本不对），未做任何改动"])
        }
        guard let defaultsData = byPath[Self.userDefaultsFileName],
              let defaultsBackup = try? JSONDecoder().decode(UserDefaultsBackup.self, from: defaultsData) else {
            throw NSError(domain: "ConcordiOS", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "备份文件不完整（缺少应用数据），未做任何改动"])
        }
        for path in manifest.files where byPath[path] == nil {
            throw NSError(domain: "ConcordiOS", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "备份文件不完整（缺少 \(path)），未做任何改动"])
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        // Safety copy of the current state, for rollback. A
        // profiles-only restore only copies what it will replace.
        let safetyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Concord-恢复前备份-\(Self.backupFileStamp())")
        var savedDefaults: [String: Data?] = [:]
        for key in Self.backupUserDefaultsKeys {
            savedDefaults[key] = UserDefaults.standard.data(forKey: key)
        }
        let savedMode = UserDefaults.standard.string(forKey: "ConcordiOS.mode.v1")
        /// The container files this restore replaces.
        let filesToRestore: [String] = {
            switch scope {
            case .all: return manifest.files
            case .profilesOnly:
                return manifest.files.filter {
                    $0 == ConfigStore.configFileName || $0.hasPrefix("profiles/")
                }
            }
        }()
        do {
            try FileManager.default.createDirectory(at: safetyDir, withIntermediateDirectories: true)
            let items: [String]
            switch scope {
            case .all:
                items = try FileManager.default.contentsOfDirectory(atPath: container.path)
            case .profilesOnly:
                items = ["profiles", ConfigStore.configFileName].filter {
                    FileManager.default.fileExists(atPath: container.appendingPathComponent($0).path)
                }
            }
            for item in items {
                try FileManager.default.copyItem(
                    at: container.appendingPathComponent(item),
                    to: safetyDir.appendingPathComponent(item))
            }
        } catch {
            throw NSError(domain: "ConcordiOS", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "恢复前备份当前数据失败，未做任何改动：\(error.localizedDescription)"])
        }
        do {
            // Replace the container contents with the staged files.
            switch scope {
            case .all:
                let contents = try FileManager.default.contentsOfDirectory(atPath: container.path)
                for item in contents {
                    try FileManager.default.removeItem(at: container.appendingPathComponent(item))
                }
            case .profilesOnly:
                for item in ["profiles", ConfigStore.configFileName] {
                    let target = container.appendingPathComponent(item)
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                }
            }
            for path in filesToRestore {
                guard let data = byPath[path] else { continue }
                let target = container.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            // Restore the UserDefaults blobs (profiles-only restores
            // just the profile list).
            let defaultsKeys: [String] = {
                switch scope {
                case .all: return Self.backupUserDefaultsKeys
                case .profilesOnly: return ["ConcordiOS.profiles.v1"]
                }
            }()
            for key in defaultsKeys {
                if let base64 = defaultsBackup.values[key],
                   let data = Data(base64Encoded: base64) {
                    if defaultsBackup.stringKeys.contains(key),
                       let string = String(data: data, encoding: .utf8) {
                        UserDefaults.standard.set(string, forKey: key)
                    } else {
                        UserDefaults.standard.set(data, forKey: key)
                    }
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        } catch {
            // Roll back: restore the safety copy and the old defaults.
            try? BackupStore.rollback(container: container, safetyDir: safetyDir, scope: scope)
            for (key, data) in savedDefaults {
                if let data { UserDefaults.standard.set(data, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            if let savedMode {
                UserDefaults.standard.set(savedMode, forKey: "ConcordiOS.mode.v1")
            } else {
                UserDefaults.standard.removeObject(forKey: "ConcordiOS.mode.v1")
            }
            throw NSError(domain: "ConcordiOS", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "恢复中途失败，已恢复到恢复前状态：\(error.localizedDescription)"])
        }
        try? FileManager.default.removeItem(at: safetyDir)
        switch scope {
        case .all:
            return "已恢复 \(filesToRestore.count) 个文件（备份于 \(Self.backupDateString(manifest.createdAt))）。各页面会自动重新加载；VPN 正在运行时建议重启一次 VPN，让核心用恢复后的配置重新启动。"
        case .profilesOnly:
            return "已恢复配置：\(filesToRestore.count) 个配置文件（备份于 \(Self.backupDateString(manifest.createdAt))）。设置、主题、MITM 模块等未动；VPN 正在运行时建议重启一次 VPN。"
        }
    }

    /// Restore the safety copy after a failed restore. A
    /// profiles-only rollback touches only the profile files, so the
    /// rest of the container is never disturbed.
    private static func rollback(container: URL, safetyDir: URL, scope: RestoreScope) throws {
        switch scope {
        case .all:
            let contents = try FileManager.default.contentsOfDirectory(atPath: container.path)
            for item in contents {
                try FileManager.default.removeItem(at: container.appendingPathComponent(item))
            }
            let saved = try FileManager.default.contentsOfDirectory(atPath: safetyDir.path)
            for item in saved {
                try FileManager.default.copyItem(
                    at: safetyDir.appendingPathComponent(item),
                    to: container.appendingPathComponent(item))
            }
        case .profilesOnly:
            for item in ["profiles", ConfigStore.configFileName] {
                let target = container.appendingPathComponent(item)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                let saved = safetyDir.appendingPathComponent(item)
                if FileManager.default.fileExists(atPath: saved.path) {
                    try FileManager.default.copyItem(at: saved, to: target)
                }
            }
        }
    }

    private static func backupDateString(_ epoch: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
