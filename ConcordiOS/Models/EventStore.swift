import Foundation
import Combine

// MARK: - Event store (core events feed)
// Backed by Concord events.watch (stream of CoreEvent). The
// extension accumulates events into the App Group snapshot file
// (cap 500) because the app only reads it when the Events tab is
// opened; the file IS the buffer. CoreEvent has no id, so rows are
// keyed by a content hash (see `key(for:)`).
//
// Event kinds (upstream crates/proto/src/types/live.rs CoreEvent):
// resourceUpdate (provider update, phase updating/updated/failed/
// unchanged), dialerLoop, delay, fatal, stateChanged.
//
// Timestamps: CoreEvent carries NO timestamp of its own (the core
// sends no time field), so the store stamps each event with the
// time the app first saw it (`receivedAt`) and keeps it across
// refreshes by merging on a content key. Two events with identical
// content share one row (they are the same event re-read); a
// stateChanged event's `change` payload is not part of the key.
// Sample data is stamped the same way, so the rows look right in
// sample mode too.

/// One core event with the time the app first saw it.
struct StampedCoreEvent: Identifiable {
    var id: String { key }
    let key: String
    let event: ConcordCoreEvent
    let receivedAt: Date

    /// Epoch millis for ConcordFormat.time (same "HH:mm:ss" column
    /// as the log rows).
    var receivedAtMillis: Int64 { Int64(receivedAt.timeIntervalSince1970 * 1000) }
}

final class EventStore: ObservableObject {
    @Published var entries: [StampedCoreEvent] = []
    @Published var searchText = ""
    @Published var typeFilter = "全部"
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var eventTypes: [String] {
        var types = ["全部"]
        types.append(contentsOf: Set(entries.map { $0.event.type }).sorted())
        return types
    }

    var filtered: [StampedCoreEvent] {
        entries.filter { entry in
            let typeOK = typeFilter == "全部" || entry.event.type == typeFilter
            let textOK = searchText.isEmpty
                || entry.event.summary.localizedCaseInsensitiveContains(searchText)
            return typeOK && textOK
        }
    }

    /// Content key for merge/dedupe. `change` is excluded (see the
    /// header comment); `seq` identifies stateChanged events.
    private static func key(for event: ConcordCoreEvent) -> String {
        [
            event.type,
            event.kind ?? "",
            event.name ?? "",
            event.phase ?? "",
            event.error ?? "",
            event.url ?? "",
            event.value.map(String.init) ?? "",
            event.message ?? "",
            event.seq.map(String.init) ?? "",
            event.origin ?? "",
        ].joined(separator: "|")
    }

    @MainActor
    func refresh() async {
        do {
            let fresh = try await client.eventEntries()
            let now = Date()
            var byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
            for event in fresh {
                let key = Self.key(for: event)
                if byKey[key] == nil {
                    byKey[key] = StampedCoreEvent(key: key, event: event, receivedAt: now)
                }
            }
            // Keep only events still in the latest buffer (the
            // extension drops old ones past its 500 cap), oldest
            // first; drop anything past the cap the same way.
            let freshKeys = Set(fresh.map { Self.key(for: $0) })
            var merged = byKey.values.filter { freshKeys.contains($0.key) }
            merged.sort { $0.receivedAt < $1.receivedAt }
            if merged.count > 500 { merged.removeFirst(merged.count - 500) }
            entries = merged
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
