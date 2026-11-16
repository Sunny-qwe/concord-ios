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

    func clear() {
        entries.removeAll()
    }
}
