#if LIBERTTY_PROBES
import AppKit
import Carbon.HIToolbox
import QuartzCore

/// `Libertty --latency-trace [--count N] [-e COMMAND]`: types into the first
/// window's shell and measures, per keystroke, the time from the key event to
/// the presentation of the frame that shows the echo:
///
///   key → (encode, pty write, the shell's echo, pty read, parse) → output
///   output → (frame pacing, render, compositor) → presented on screen
///
/// Keys alternate `a` and Backspace, so the line never grows. This is the
/// software part of typing latency; keyboard scan and display scanout add a
/// roughly constant few milliseconds on top for every terminal.
final class LatencyTrace {
    static var requested: Bool { CommandLine.arguments.contains("--latency-trace") }

    private static var current: LatencyTrace?

    static func start(controller: TerminalWindowController) {
        let args = CommandLine.arguments
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 200
        // Let the shell come up and draw its prompt first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let trace = LatencyTrace(controller: controller, count: count)
            current = trace
            trace.next()
        }
    }

    private let view: TerminalView
    private let count: Int
    private var sent = 0
    private var keyTime: CFTimeInterval = 0
    private var outputBefore: UInt64 = 0
    private var waiting = false
    private var echo: [Double] = [], render: [Double] = [], total: [Double] = []

    private init(controller: TerminalWindowController, count: Int) {
        view = controller.focusedTerminal
        self.count = count
        // `--fastest`: measure on the highest refresh display.
        if CommandLine.arguments.contains("--fastest"), let window = view.window,
           let fastest = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            var frame = window.frame
            frame.origin = NSPoint(x: fastest.visibleFrame.midX - frame.width / 2, y: fastest.visibleFrame.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        view.onFramePresented = { [weak self] mark, time in self?.presented(mark: mark, at: time) }
    }

    private func next() {
        guard sent < count else { return finish() }
        let backspace = sent % 2 == 1
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: backspace ? "\u{7f}" : "a", charactersIgnoringModifiers: backspace ? "\u{7f}" : "a",
            isARepeat: false, keyCode: UInt16(backspace ? kVK_Delete : kVK_ANSI_A)) else { return finish() }
        sent += 1
        outputBefore = view.session.outputMark.count
        waiting = true
        keyTime = CACurrentMediaTime()
        view.keyDown(with: event)
        // A key that produced no echo (it shouldn't) doesn't stall the run.
        let n = sent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.waiting, self.sent == n else { return }
            self.waiting = false
            self.next()
        }
    }

    private func presented(mark: UInt64, at time: CFTimeInterval) {
        guard waiting, mark > outputBefore, time > keyTime else { return }
        waiting = false
        let output = view.session.outputMark.time
        total.append((time - keyTime) * 1000)
        if output >= keyTime, output <= time {
            echo.append((output - keyTime) * 1000)
            render.append((time - output) * 1000)
        }
        // Space keystrokes out like typing (~30 per second), off the frame grid.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033 + Double.random(in: 0...0.008)) { [weak self] in self?.next() }
    }

    private func finish() {
        func stats(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "no samples" }
            let s = v.sorted()
            return String(format: "median %5.2f  p95 %5.2f  max %5.2f ms", s[s.count / 2], s[s.count * 95 / 100], s.last!)
        }
        let refresh = 1000 / Double(view.window?.screen?.maximumFramesPerSecond ?? 60)
        let w = view.window
        print(String(format: "latency-trace: %d keystrokes, display %.1f ms, key=%d visible=%d active=%d",
                     total.count, refresh, w?.isKeyWindow == true ? 1 : 0,
                     w?.occlusionState.contains(.visible) == true ? 1 : 0, NSApp.isActive ? 1 : 0))
        print("  key → on screen:  \(stats(total))")
        print("  key → echo:       \(stats(echo))")
        print("  echo → on screen: \(stats(render))")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
#endif
