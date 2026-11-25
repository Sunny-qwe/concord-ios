import Foundation

// MARK: - Main-thread watchdog (v0.2.102, CPU sampling v0.2.103)
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
//
// v0.2.103: the stall line also carries the main thread's CPU %
// over the stall window, sampled via thread_info /
// THREAD_BASIC_INFO on the main thread's Mach port (captured in
// start()). That settles spin vs block on the next occurrence: a
// layout/state feedback loop spins at ~100% of one core, while a
// deadlock/semaphore block sits at ~0%.

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
        /// The main thread's Mach port, captured in start() (see
        /// there). The ping loop samples its CPU time from the
        /// background thread — never via the main queue, so
        /// sampling still works while the main thread is stuck.
        var mainThread: thread_t?
    }
    private static let state = State()

    /// Starts the background ping loop. Idempotent; call once from
    /// the app entry point (main thread).
    static func start() {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.started else { return }
        state.started = true
        // v0.2.103: keep the main thread's Mach port so the ping
        // loop can sample its CPU time (thread_info /
        // THREAD_BASIC_INFO) without ever touching the main queue.
        // mach_thread_self() returns a send right to the CALLING
        // thread, so this capture must run on the main thread;
        // the fallback covers a non-main caller by capturing
        // asynchronously instead (sampling is then unavailable
        // until the capture lands). The main thread lives for the
        // whole process, so the port stays valid for the app's
        // lifetime and needs no deallocation.
        if Thread.isMainThread {
            state.mainThread = mach_thread_self()
        } else {
            DispatchQueue.main.async {
                state.lock.lock()
                state.mainThread = mach_thread_self()
                state.lock.unlock()
            }
        }
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
            // v0.2.103: baseline main-thread CPU time just before
            // the ping goes out, so the stall line can report how
            // much CPU the main thread burned while it was
            // unresponsive — a spin (layout/state feedback loop)
            // shows ~100% of one core over the stall window, a
            // block (deadlock/semaphore) shows ~0%.
            let cpuBefore = mainThreadCpuSeconds()
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
                record("main thread stalled >\(Int(stallThreshold))s (ping sent \(timeString(sentAt)); last action: \(lastActionDescription()); \(cpuDescription(cpuBefore: cpuBefore, since: sentAt)))")
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

    /// Main-thread CPU time (user + system, seconds) via
    /// thread_info / THREAD_BASIC_INFO on the port captured in
    /// start(). Same withMemoryRebound idiom as the task_info
    /// call in DashboardView.readAppMemoryBytes — no extra import
    /// and no C helper needed: the Mach APIs come in through
    /// Foundation/Darwin. Nil when the port is not captured yet
    /// or thread_info fails, so callers report "n/a" instead of a
    /// bogus number.
    private static func mainThreadCpuSeconds() -> Double? {
        state.lock.lock()
        let thread = state.mainThread
        state.lock.unlock()
        guard let thread else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// "main thread CPU 98% during stall" — the share of one core
    /// the main thread burned between the ping going out and the
    /// stall being detected. ~100% means it was spinning,
    /// ~0% means it was blocked. "main thread CPU n/a" when the
    /// port is not captured yet or a sample failed.
    private static func cpuDescription(cpuBefore: Double?, since sentAt: Date) -> String {
        guard let cpuBefore,
              let cpuNow = mainThreadCpuSeconds() else { return "main thread CPU n/a" }
        let wall = Date().timeIntervalSince(sentAt)
        guard wall > 0 else { return "main thread CPU n/a" }
        let percent = max(0, (cpuNow - cpuBefore) / wall * 100)
        return String(format: "main thread CPU %.0f%% during stall", percent)
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
