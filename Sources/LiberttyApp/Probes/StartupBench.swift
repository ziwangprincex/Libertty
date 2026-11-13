#if LIBERTTY_PROBES
import AppKit
import QuartzCore

/// `Libertty --startup-bench [--offscreen] [--persist]`: how long a launch
/// takes, through the app's own path (AppDelegate, a new window, its
/// shell), from the moment the process was created to
///
///   main → the app finished launching → its window shown → the window's
///   first frame on screen → the first frame showing the shell's output
///
/// then it exits. On screen by default (what you'd see); `--offscreen`
/// keeps the window off every screen and out of the Dock, for a Mac in use
/// (a frame there is drawn, not shown). `--persist`: its shell in (a
/// private) liberttyd, as with session-persistence. `--sample`: also where
/// the main thread spent each stage (its stack, every half millisecond,
/// counted per function). bench/startup.sh runs it several times and
/// reports the medians.
enum StartupBench {
    static let requested = CommandLine.arguments.contains("--startup-bench")
    static let offscreen = requested && CommandLine.arguments.contains("--offscreen")

    private static var marks: [(name: String, at: Double)] = []
    private static var finished = false

    /// A stage reached, now (wall-clock seconds, as the process's start).
    static func mark(_ name: String) {
        guard requested, !marks.contains(where: { $0.name == name }) else { return }
        marks.append((name, Date().timeIntervalSince1970))
    }

    /// The window is shown: wait for its frames.
    static func start(controller: TerminalWindowController) {
        guard requested else { return }
        mark("window")
        let view = controller.focusedTerminal
        view.onFramePresented = { [weak view] output, presented in
            // The frame was on screen at `presented` (host time), a moment
            // ago; off screen, or drawn with a resize, there's no time: done
            // drawing, now.
            let now = Date().timeIntervalSince1970
            let at = presented > 0 ? now - max(0, CACurrentMediaTime() - presented) : now
            if !marks.contains(where: { $0.name == "frame" }) { marks.append(("frame", at)) }
            if output > 0 {
                marks.append(("prompt", at))
                view?.onFramePresented = nil
                finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard !finished else { return }
            print("startup-bench failed: no prompt drawn in 15 s")
            exit(1)
        }
    }

    // MARK: Sampling (`--sample`): where the main thread's time goes

    nonisolated(unsafe) private static var samples: [(at: Double, frames: [UInt])] = []
    private static let samplesLock = NSLock()
    nonisolated(unsafe) private static var sampling = false

    static func startSampling() {
        guard requested, CommandLine.arguments.contains("--sample") else { return }
        let main = pthread_mach_thread_np(pthread_self())
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let bottom = top - UInt(pthread_get_stacksize_np(pthread_self()))
        sampling = true
        let thread = Thread {
            // Nothing allocates while the main thread is suspended (it may hold malloc's lock).
            let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: 128)
            var state = arm_thread_state64_t()
            while samplesLock.withLock({ sampling }) {
                var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
                var n = 0
                guard thread_suspend(main) == KERN_SUCCESS else { break }
                let got = withUnsafeMutablePointer(to: &state) {
                    $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                        thread_get_state(main, ARM_THREAD_STATE64, $0, &count)
                    }
                }
                if got == KERN_SUCCESS {
                    let strip: UInt = 0x0000_007F_FFFF_FFFF
                    buffer[0] = UInt(state.__pc) & strip
                    buffer[1] = UInt(state.__lr) & strip
                    n = 2
                    var fp = UInt(state.__fp)
                    while n < 128, fp >= bottom, fp + 16 <= top, fp % 8 == 0 {
                        let record = UnsafePointer<UInt>(bitPattern: fp)!
                        let next = record[0], lr = record[1] & strip
                        if lr != 0 { buffer[n] = lr; n += 1 }
                        guard next > fp else { break }
                        fp = next
                    }
                }
                thread_resume(main)
                let frames = Array(UnsafeBufferPointer(start: buffer, count: n))
                let now = Date().timeIntervalSince1970
                samplesLock.withLock { samples.append((now, frames)) }
                usleep(500)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The functions the main thread was in, by how many samples (inclusive), between marks.
    private static func report(from: String, to: String) {
        guard let a = marks.first(where: { $0.name == from })?.at, let b = marks.first(where: { $0.name == to })?.at else { return }
        let taken = samplesLock.withLock { samples.filter { $0.at >= a && $0.at <= b } }
        var counts: [String: Int] = [:]
        var names: [UInt: String] = [:]
        for sample in taken {
            var seen = Set<String>()
            for pc in sample.frames {
                let name: String
                if let n = names[pc] { name = n } else {
                    var info = Dl_info()
                    if dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let s = info.dli_sname { name = String(cString: s) } else { name = "?" }
                    names[pc] = name
                }
                if seen.insert(name).inserted { counts[name, default: 0] += 1 }
            }
        }
        print(String(format: "sampled %@ → %@: %d samples over %.0f ms", from, to, taken.count, (b - a) * 1000))
        for (name, n) in counts.sorted(by: { $0.value > $1.value }).prefix(70) { print("  \(n)  \(name)") }
    }

    private static func finish() {
        guard !finished else { return }
        finished = true
        if CommandLine.arguments.contains("--sample") {
            samplesLock.withLock { sampling = false }
            marks.sort { $0.at < $1.at }
            let names = marks.map(\.name)
            for (i, name) in names.enumerated() where i + 1 < names.count { report(from: name, to: names[i + 1]) }
        }
        let started = processStart()
        let line = marks.map { String(format: "%@ %.1f", $0.name, ($0.at - started) * 1000) }.joined(separator: "  ")
        print("startup-bench: \(line)  (ms since the process started; \(offscreen ? "off screen" : "on screen"), \(Persistence.enabled ? "liberttyd" : "direct pty"))")
        exit(0)
    }

    /// When the kernel made this process (its fork; exec and dyld come after).
    private static func processStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return marks.first?.at ?? 0 }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1e6
    }

    /// Hidden before it is shown, when off screen.
    static func place(_ window: NSWindow) {
        guard offscreen else { return }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }
}
#endif
