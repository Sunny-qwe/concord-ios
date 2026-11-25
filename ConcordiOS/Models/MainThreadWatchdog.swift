import Foundation

// MARK: - Main-thread watchdog (v0.2.102)
//
// The DNS sheet freeze (v0.2.99-v0.2.101) was diagnosed from code
// alone three times and the diagnosis was wrong three times — and
// the user cannot produce a hang report / sysdiagnose, so the app
// now watches its own main thread. A background thread pings the
// main queue every 0.5s; if the main thread does not run the ping
// within ~2s, the stall is recorded (timestamp + the last noted
// user action) in UserDefaults and surfaced in the log export, so
// a future freeze leaves exact evidence: when it stalled and what
// the user last did. It cannot capture the stuck call stack (that
// needs Mach thread_get_state or MetricKit); it proves a
// main-thread stall and times it precisely.

enum MainThreadWatchdog {
    private static let storageKey = "concord.mainThreadWatchdog"
    private static let maxLines = 12
    /// Ping interval and stall threshold.
    private static let pingInterval: TimeInterval = 0.5
    private static let stallThreshold: TimeInterval = 2.0

    /// Mutable state, guarded by its own lock: the ping loop runs
    /// on a background thread while start / noteAction run on the
    /// main thread. @unchecked Sendable because every access goes
    /// through the lock — no DispatchSemaphore anywhere (the app
    /// has none; this keeps the Swift 6 Sendable story simple).
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var started = false
        var lastAction: String?
        var lastActionAt: Date?
        var pingPending = false
        var pingSentAt = Date()
    }
    private static let state = State()

    /// Starts the background ping loop. Idempotent; call once from
    /// the app entry point (main thread).
    static func start() {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.started else { return }
        state.started = true
        DispatchQueue.global(qos: .background).async {
            pingLoop()
        }
    }

    /// Notes a user action for the next stall line. Call from
    /// main-thread UI code only.
    static func noteAction(_ action: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.lastAction = action
        state.lastActionAt = Date()
    }

    private static func lastActionDescription() -> String {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let action = state.lastAction else { return "—" }
        return "\(action) at \(timeString(state.lastActionAt ?? Date()))"
    }

    /// Sends a ping, waits for the pong, and records a stall when
    /// the main thread does not answer within the threshold. One
    /// freeze yields one stall line (the loop waits for the pong
    /// before resuming), plus a recovery line when the main thread
    /// comes back.
    private static func pingLoop() {
        while true {
            let sentAt = Date()
            state.lock.lock()
            state.pingPending = true
            state.pingSentAt = sentAt
            state.lock.unlock()
            DispatchQueue.main.async {
                state.lock.lock()
                state.pingPending = false
                state.lock.unlock()
            }
            var stalled = false
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                state.lock.lock()
                let pending = state.pingPending
                let sent = state.pingSentAt
                state.lock.unlock()
                if !pending { break }
                if Date().timeIntervalSince(sent) > stallThreshold {
                    stalled = true
                    break
                }
            }
            if stalled {
                record("main thread stalled >\(Int(stallThreshold))s (ping sent \(timeString(sentAt)); last action: \(lastActionDescription()))")
                while true {
                    Thread.sleep(forTimeInterval: 0.5)
                    state.lock.lock()
                    let pending = state.pingPending
                    state.lock.unlock()
                    if !pending { break }
                }
                record("main thread recovered at \(timeString(Date()))")
            }
            Thread.sleep(forTimeInterval: pingInterval)
        }
    }

    /// Appends one timestamped line (last 12 kept), same pattern
    /// as ZombieProbeDiagnostics.
    private static func record(_ line: String) {
        var lines = UserDefaults.standard.string(forKey: storageKey)
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        lines.append("[\(timeString(Date()))] \(line)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: storageKey)
    }

    static func lastDiagnosticText() -> String? {
        guard let text = UserDefaults.standard.string(forKey: storageKey),
              !text.isEmpty else { return nil }
        return text
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
