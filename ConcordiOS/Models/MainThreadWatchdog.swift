import Foundation

// MARK: - Main-thread watchdog (v0.2.102, CPU sampling v0.2.103, stack sampling v0.2.169)
//
// The DNS sheet freeze (v0.2.99-v0.2.101) was diagnosed from code
// alone three times and the diagnosis was wrong three times — and
// the user cannot produce a hang report / sysdiagnose, so the app
// now watches its own main thread. A background thread pings the
// main queue every 0.5s; if the main thread does not run the ping
// within ~2s, the stall is recorded (timestamp + the last noted
// user action) in UserDefaults and surfaced in the log export, so
// a future freeze leaves exact evidence: when it stalled and what
// the user last did.
//
// v0.2.103: the stall line also carries the main thread's CPU %
// over the stall window, sampled via thread_info /
// THREAD_BASIC_INFO on the main thread's Mach port (captured in
// start()). That settles spin vs block on the next occurrence: a
// layout/state feedback loop spins at ~100% of one core, while a
// deadlock/semaphore block sits at ~0%.
//
// v0.2.169: the stall line ALSO carries the main thread's call
// stack, sampled at the moment the stall is detected. The 168
// VPN-start freeze (19:27:50, CPU 0%) proved the watchdog's
// original limit: it could time a block and rule out a spin, but
// it could not name the call that parked the thread — and static
// auditing of the start path found no provable sync block (the
// five coreQueue.sync sites were excluded by experiment, the
// On-Demand read-back loop had zero log hits). Sampling uses the
// same Mach port: the background thread suspends the (already
// unresponsive) main thread, reads its state with
// thread_get_state, walks the frame-pointer chain with
// vm_read_overwritten, and resolves each address to image+offset
// with dladdr. The suspend window is a few microseconds of
// reads, always paired with a resume (defer), and every Mach call
// is checked — a failed sample just leaves the stall line
// without a stack, never a crash. The stack is stored under its
// own key (latest stall only) and appended to the same export
// section as the stall lines.

enum MainThreadWatchdog {
    private static let storageKey = "concord.mainThreadWatchdog"
    /// Latest sampled stack, one per stall (overwritten each
    /// time); the stall lines above keep the history, this key
    /// keeps the one stack that belongs to the newest stall.
    private static let stackStorageKey = "concord.mainThreadWatchdog.stack"
    private static let maxLines = 32
    /// Frames kept per sampled stack (PC + return addresses).
    private static let maxStackFrames = 16
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
                // v0.2.169: sample the stuck stack FIRST, before
                // building the stall line. Sampling suspends the
                // main thread briefly (it is already unresponsive)
                // and must never run while state.lock is held or
                // take it while suspended — the main thread could
                // be parked inside noteAction holding it. The
                // line below (lastActionDescription,
                // cpuDescription) takes the lock, so it runs only
                // after the sample has resumed the thread.
                if let stack = sampleMainThreadStack(pingSentAt: sentAt) {
                    recordStack(stack)
                }
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

    // MARK: - Stack sampling (v0.2.169)

    /// Suspends the main thread, reads its PC/SP/FP with
    /// thread_get_state, walks the frame-pointer chain, resolves
    /// each address to image+offset with dladdr, and resumes the
    /// thread. Called only from the ping loop after a stall is
    /// detected, with no lock held. Returns nil when the port is
    /// not captured or any Mach step fails — the caller then
    /// records the stall line without a stack. The suspend is
    /// brief (a handful of small reads) and always paired with a
    /// resume via defer, so even a false-positive stall (app
    /// backgrounded) costs the main thread a sub-millisecond
    /// pause at most.
    private static func sampleMainThreadStack(pingSentAt: Date) -> String? {
        state.lock.lock()
        let thread = state.mainThread
        state.lock.unlock()
        guard let thread else { return nil }
        guard thread_suspend(thread) == KERN_SUCCESS else { return nil }
        defer { thread_resume(thread) }
        guard let addresses = threadStackAddresses(thread) else { return nil }
        var lines: [String] = ["[\(timeString(Date()))] main-thread stack at stall (ping sent \(timeString(pingSentAt))):"]
        for (index, address) in addresses.enumerated() {
            lines.append("  #\(index) \(symbolicated(address))")
        }
        return lines.joined(separator: "\n")
    }

    /// The main thread's PC plus the return addresses up the
    /// frame chain (at most maxStackFrames). The thread must
    /// already be suspended by the caller.
    private static func threadStackAddresses(_ thread: thread_t) -> [UInt64]? {
#if arch(arm64)
        var tstate = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &tstate) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var addresses: [UInt64] = [tstate.__pc]
        // The link register is the current frame's return
        // address; the chain below continues from the saved
        // frame records.
        if tstate.__lr != 0 { addresses.append(tstate.__lr) }
        var framePointer = tstate.__fp
        while addresses.count < maxStackFrames {
            guard let (previousFP, savedLR) = readFrameRecord(at: framePointer) else { break }
            // Frame records point up the stack (higher
            // addresses); a step that goes backwards, stays, or
            // jumps absurdly far means a corrupt chain — stop
            // instead of chasing garbage.
            guard previousFP != 0, savedLR != 0,
                  previousFP > framePointer,
                  previousFP - framePointer < 0x100000 else { break }
            addresses.append(savedLR)
            framePointer = previousFP
        }
        return addresses
#elseif arch(x86_64)
        var tstate = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &tstate) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_flavor_t(x86_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var addresses: [UInt64] = [tstate.__rip]
        var framePointer = tstate.__rbp
        while addresses.count < maxStackFrames {
            guard let (previousFP, returnAddress) = readFrameRecord(at: framePointer) else { break }
            guard previousFP != 0, returnAddress != 0,
                  previousFP > framePointer,
                  previousFP - framePointer < 0x100000 else { break }
            addresses.append(returnAddress)
            framePointer = previousFP
        }
        return addresses
#else
        return nil
#endif
    }

    /// One frame record at `address`: (previous frame pointer,
    /// saved return address). arm64: [fp] = saved x29, [fp+8] =
    /// saved x30 (LR). x86_64: [rbp] = saved rbp, [rbp+8] =
    /// return address. Reads the suspended thread's stack with
    /// vm_read_overwritten; any failure ends the walk.
    private static func readFrameRecord(at address: UInt64) -> (UInt64, UInt64)? {
        guard address != 0, address % 8 == 0 else { return nil }
        var pair: (UInt64, UInt64) = (0, 0)
        var outSize: vm_size_t = 0
        let result = withUnsafeMutablePointer(to: &pair) { rawPointer in
            vm_read_overwritten(
                mach_task_self(),
                vm_address_t(address),
                vm_size_t(MemoryLayout<(UInt64, UInt64)>.size),
                vm_address_t(UInt(bitPattern: UnsafeRawPointer(rawPointer))),
                &outSize)
        }
        guard result == KERN_SUCCESS,
              outSize == MemoryLayout<(UInt64, UInt64)>.size else { return nil }
        return pair
    }

    /// "0x1a2b3c4 FlClash+0x12345 (symbol+0x10)" — the image
    /// name plus the offset from the image base is the
    /// authoritative part (it can be symbolicated later against
    /// the build's dSYM); the dladdr symbol name is a bonus that
    /// may be absent or approximate on a stripped release binary.
    private static func symbolicated(_ address: UInt64) -> String {
        let hex = String(format: "0x%llx", address)
        guard address != 0 else { return "\(hex) (null)" }
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
              let fname = info.dli_fname,
              let fbase = info.dli_fbase else {
            return hex
        }
        let image = String(cString: fname).split(separator: "/").last.map(String.init) ?? String(cString: fname)
        let offset = address - UInt(bitPattern: fbase)
        var text = "\(hex) \(image)+0x\(String(offset, radix: 16))"
        if let sname = info.dli_sname,
           let saddr = info.dli_saddr {
            let symbol = String(cString: sname)
            let symbolOffset = address - UInt(bitPattern: saddr)
            text += " (\(symbol)+0x\(String(symbolOffset, radix: 16)))"
        }
        return text
    }

    /// Appends one timestamped line (last maxLines kept), same pattern
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

    /// Stores the latest sampled stack (overwrites the previous
    /// one); the stall lines above keep the history, this key
    /// keeps the stack that belongs to the newest stall.
    private static func recordStack(_ stack: String) {
        UserDefaults.standard.set(stack, forKey: stackStorageKey)
    }

    static func lastDiagnosticText() -> String? {
        guard let text = UserDefaults.standard.string(forKey: storageKey),
              !text.isEmpty else { return nil }
        return text
    }

    /// The stack sampled at the newest stall, if any.
    static func lastStackText() -> String? {
        guard let text = UserDefaults.standard.string(forKey: stackStorageKey),
              !text.isEmpty else { return nil }
        return text
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        // v0.2.169: the date is part of the line — HH:mm:ss alone
        // made stalls from different days indistinguishable (the
        // 08:08/09:15 lines in the 168 export were out of order
        // for exactly this reason).
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
