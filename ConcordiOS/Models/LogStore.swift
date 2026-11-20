import Foundation
import Combine

// MARK: - Log store (FlClash: Logs page)
// Backed by Concord log.watch (stream of LogEntry) and core.lastWarnings.
// In `.sample` mode the entries are the built-in sample log lines.

enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    var id: String { rawValue }
}

final class LogStore: ObservableObject {
    @Published var entries: [ConcordLogEntry] = []
    @Published var levelFilter: LogLevelFilter = .all
    @Published var searchText = ""
    @Published var autoScroll = true
    @Published var warnings: [ConcordWarning] = []
    @Published var lastError: String?

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var filtered: [ConcordLogEntry] {
        entries.filter { entry in
            let levelOK = levelFilter == .all || entry.level.uppercased() == levelFilter.rawValue
            let textOK = searchText.isEmpty || entry.text.localizedCaseInsensitiveContains(searchText)
            return levelOK && textOK
        }
    }

    var exportText: String {
        filtered.map { "[\(ConcordFormat.time($0.time))] [\($0.level.uppercased())] \($0.text)" }.joined(separator: "\n")
    }

    /// Full export for the Logs page share/copy (v0.2.35): the core
    /// log lines PLUS the diagnostic lines that explain a failure —
    /// core warnings, the app-core boot report (GeoSeed outcome per
    /// file + boot result, incl. the GeoIP download failure), the
    /// extension's VPN startup diagnostic, and the last log-pull
    /// error — in ONE text, so the user can send it as-is. Uses ALL
    /// entries, not `filtered`: a bug report must not silently drop
    /// lines the on-screen level filter hides. Credential-looking
    /// values (subscription URLs carrying a token/password) are
    /// redacted; see redactForExport.
    var fullExportText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var sections: [String] = []
        sections.append("""
            Concord iOS 日志导出
            导出时间：\(Self.fullTimestamp(Int64(Date().timeIntervalSince1970 * 1000)))
            应用版本：\(version)
            VPN 状态：\(TunnelManager.shared.isRunning ? "运行中" : "未运行")
            日志条数：\(entries.count)
            """)
        if entries.isEmpty {
            sections.append("== 核心日志 ==\n（无日志）")
        } else {
            let lines = entries.map {
                "[\(Self.fullTimestamp($0.time))] [\($0.level.uppercased())] \($0.text)"
            }
            sections.append("== 核心日志 ==\n" + lines.joined(separator: "\n"))
        }
        if warnings.isEmpty {
            sections.append("== 核心警告 ==\n（无）")
        } else {
            sections.append("== 核心警告 ==\n" + warnings.map(\.message).joined(separator: "\n"))
        }
        sections.append("== 应用内核心启动诊断 ==\n" + (AppCore.lastBootReportText() ?? "暂无记录（尚未在应用内启动过核心）"))
        sections.append("== 最近一次测速诊断 ==\n" + (AppCore.lastDelayTestReportText() ?? "暂无记录（尚未测速，或本次测速未写入诊断）"))
        sections.append("== VPN 启动诊断 ==\n" + (TunnelManager.shared.lastStartupDiagnostic() ?? "暂无最近的 VPN 启动诊断（扩展未写入或已超过 180 秒）"))
        if let lastError {
            sections.append("== 日志拉取错误 ==\n\(lastError)")
        }
        sections.append("注：订阅链接中的 token / 密码等敏感信息已在导出时隐藏。")
        return Self.redactForExport(sections.joined(separator: "\n\n"))
    }

    /// Writes fullExportText to a timestamped .txt file in tmp and
    /// returns its URL for the share sheet.
    func exportLogFile() throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("concord-logs-\(stamp.string(from: Date())).txt")
        try fullExportText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Full date-time for the export (the on-screen time is
    /// HH:mm:ss only; a bug report needs the date too).
    private static func fullTimestamp(_ epochMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Hides credential-looking values before a log leaves the
    /// device: query/form values after token/secret/password/auth/
    /// api-key names, and the password part of user:password@ in
    /// URLs (subscription links). Everything else is left verbatim
    /// — the point of the export is the real error text.
    private static func redactForExport(_ text: String) -> String {
        let patterns = [
            "([?&](token|secret|password|passwd|auth|api[-_]?key|access[-_]?key)[=:])[^&\\s]*",
            "(://[^/\\s:]+:)[^@\\s]*(@)",
        ]
        var result = text
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = index == 0 ? "$1[已隐藏]" : "$1[已隐藏]$2"
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    @MainActor
    func refresh() async {
        do {
            let fresh = try await client.logEntries()
            // The stream replays the buffered entries; keep the newest
            // copy of each (id = time + text) and sort oldest first.
            var merged = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for entry in fresh { merged[entry.id] = entry }
            entries = merged.values.sorted { $0.time < $1.time }
            warnings = try await client.lastWarnings()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
