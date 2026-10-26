#if LIBERTTY_PROBES
import AppKit
import QuartzCore

/// `Libertty --resize-trace [--splits N] [--divider] [--steps N]`: drives the
/// first window through per-frame size changes (with N extra split panes),
/// or with `--divider` drags the first split's divider instead, and prints
/// how long the main thread was blocked per step and how evenly the steps
/// landed on display frames. A hitch here is what a user feels as a laggy drag.
final class ResizeTrace: NSObject {
    private static var current: ResizeTrace?

    private static let steps: Int = {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--steps").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 240
    }()

    private static let divider = CommandLine.arguments.contains("--divider")

    static var requested: Bool { CommandLine.arguments.contains("--resize-trace") }

    static func start(window: NSWindow, controller: TerminalWindowController) {
        let args = CommandLine.arguments
        let splits = args.firstIndex(of: "--splits").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1
        // Let the shell come up before measuring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for i in 0..<splits {
                if i % 2 == 0 { controller.splitRight(nil) } else { controller.splitDown(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let trace = ResizeTrace(window: window)
                current = trace
                trace.begin()
            }
        }
    }

    private let window: NSWindow
    private let origin: NSRect
    private var link: CADisplayLink?
    private var step = 0
    private var lastTick: CFTimeInterval = 0
    private var blocked: [Double] = []
    private var intervals: [Double] = []

    private init(window: NSWindow) {
        self.window = window
        // `--fastest`: measure on the fastest display (ProMotion's 120 Hz is the hard case).
        if CommandLine.arguments.contains("--fastest"),
           let fastest = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }),
           window.screen != fastest {
            var frame = window.frame
            frame.origin = NSPoint(x: fastest.visibleFrame.midX - frame.width / 2, y: fastest.visibleFrame.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
        origin = window.frame
    }

    private func begin() {
        let link = window.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if lastTick > 0 { intervals.append((now - lastTick) * 1000) }
        lastTick = now
        guard step < Self.steps else { return finish() }
        // Grow and shrink by up to 300 points, like dragging the corner back and forth.
        let phase = Double(step) / 60 * .pi
        let delta = CGFloat(sin(phase) * 300)
        var frame = origin
        frame.size.width += delta
        frame.size.height += delta / 2
        frame.origin.y -= delta / 2
        let start = CACurrentMediaTime()
        if Self.divider, let container = splitContainer, !container.root.isLeaf {
            // Drag the first divider back and forth instead of the window edge.
            container.root.ratio = 0.5 + 0.3 * CGFloat(sin(phase))
            container.layoutPanes()
        } else {
            window.setFrame(frame, display: true)
        }
        let ms = (CACurrentMediaTime() - start) * 1000
        blocked.append(ms)
        if ms > 50 { print(String(format: "  step %d blocked %.0f ms", step, ms)); fflush(stdout) }
        step += 1
    }

    private func finish() {
        link?.invalidate()
        func stats(_ v: [Double]) -> String {
            let s = v.sorted()
            return String(format: "median %.2f  p95 %.2f  max %.2f ms",
                          s[s.count / 2], s[s.count * 95 / 100], s.last ?? 0)
        }
        let refresh = 1000 / Double(window.screen?.maximumFramesPerSecond ?? 60)
        let missed = intervals.filter { $0 > refresh * 1.5 }.count
        print("resize-trace \(Self.divider ? "divider" : "window") panes=\(controllerPaneCount())")
        print("  main thread per step: \(stats(blocked))")
        print("  step interval:        \(stats(intervals))")
        print("  missed frames: \(missed) of \(intervals.count) (refresh \(String(format: "%.1f", refresh)) ms)")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private var splitContainer: SplitContainerView? {
        (window.windowController as? TerminalWindowController)?.activeContainer
    }

    private func controllerPaneCount() -> Int { splitContainer?.panes.count ?? 0 }
}
#endif
