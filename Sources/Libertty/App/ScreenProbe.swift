import AppKit
import CoreMedia
import ScreenCaptureKit

/// `Libertty --screen-probe OUTDIR` (tests/screen.sh): what the screen shows,
/// not what the views draw (`--ui-probe` can't see the window server). A
/// real window on the main screen, for half a minute, shows a test pattern
/// in its terminal — two bands of blocks — and ScreenCaptureKit records the
/// display there frame by frame, as the window server composites it, while
/// the window is hidden and brought back, another app's window comes in
/// front and goes (Stage Manager's strip), its sidebar folds, it's resized,
/// miniaturized, and a second window opens on its session. Beside the
/// terminal, a square AppKit draws is the ruler: a frame where the
/// terminal's pattern isn't the ruler's scale — the terminal's last frame
/// mapped squeezed or stretched onto its view, while the rest of the window
/// is as it should be — fails. (The whole window scaled, as in Stage
/// Manager's strip or the Dock's genie, isn't judged.) Needs Screen
/// Recording permission for whatever runs it: it says so, and skips, without.
@MainActor
enum ScreenProbe {
    /// One frame's pattern: how wide and tall it came out next to the first
    /// frame's, at the ruler's scale (1: as it should be); nil where there's
    /// nothing to judge (the window hidden, a frame still blank, the window
    /// as a whole drawn smaller or larger).
    struct Measure { var time: Double; var width: Double?; var height: Double? }

    /// The ruler: a square in a color nothing else has, drawn by AppKit
    /// (so never squeezed with the terminal), over the sidebar's empty foot.
    final class Ruler: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
            layer?.zPosition = 10
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }

    /// `--screen-cover-probe SECONDS`: another app's window (this binary,
    /// run apart) in front for a while, then gone — what makes Stage Manager
    /// send the probe's window to its strip and bring it back.
    static func cover(seconds: Double) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 260, y: screen.visibleFrame.midY - 150, width: 520, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Libertty screen probe"
        let label = NSTextField(labelWithString: "Libertty's screen probe: another app's window, for a moment.")
        label.frame = NSRect(x: 30, y: 130, width: 460, height: 40)
        window.contentView?.addSubview(label)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        exit(0)
    }

    /// The pattern: two bands of five blocks, rows 3–4 and 14–15, each
    /// block six cells wide with three between; one color (magenta, which
    /// nothing else on the window has).
    static let pattern = (1...5).map { _ in "\u{1b}[48;2;255;0;255m      \u{1b}[0m   " }.joined()
    static var command: String {
        "printf '\\033[?25l\\033[2J\\033[3;3H\(pattern)\\033[4;3H\(pattern)\\033[14;3H\(pattern)\\033[15;3H\(pattern)'; exec sleep 600"
    }

    static func run(output: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        // A regular app, as Libertty is: Stage Manager and the Dock treat
        // its windows as they do Libertty's (an accessory's they leave be).
        app.setActivationPolicy(.regular)
        Probe.running = true
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        // In (the probe's own) liberttyd: a second window can show the session.
        Persistence.setUp(wanted: true)

        let controller: TerminalWindowController
        do {
            controller = try TerminalWindowController(config: Config(), cols: 80, rows: 24)
            try controller.start(command: command, workingDirectory: NSTemporaryDirectory())
        } catch {
            print("screen-probe: couldn't open a window: \(error)")
            exit(1)
        }
        let window = controller.window!
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 60, y: visible.maxY - 60))
        if let content = window.contentView {
            let ruler = Ruler(frame: NSRect(x: 24, y: 24, width: 56, height: 56))
            ruler.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(ruler, positioned: .above, relativeTo: nil)
        }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pump(2.0)
        // Someone's using the Mac (macOS keeps their app in front): this
        // isn't the time — and the window couldn't be judged as it shows.
        guard app.isActive else {
            print("screen-probe: skipped — another app stays in front; run it while you're away from the Mac (it takes the screen for about 40 s)")
            exit(0)
        }

        let recorder = Recorder()
        guard recorder.attach(to: window) else {
            print("screen-probe: skipped — no Screen Recording permission for what runs it (System Settings ▸ Privacy & Security), or the window isn't capturable")
            exit(0)
        }
        var failures = 0
        /// `from`: seconds after `recorder.mark()` before frames count.
        func scenario(_ name: String, from: Double? = nil, _ act: () -> Void) {
            recorder.begin()
            pump(0.3)
            act()
            pump(1.0 + (from ?? 0))
            var frames = recorder.end()
            if let from, let mark = recorder.marked { frames = frames.filter { $0.time >= mark + from } }
            let found = frames.filter { $0.width != nil && $0.height != nil }
            let off = found.filter { abs($0.width! - 1) > 0.04 || abs($0.height! - 1) > 0.04 }
            if found.isEmpty {
                print("FAIL  screen-probe \(name): the pattern wasn't in any of \(frames.count) frames")
                failures += 1
            } else if let worst = off.max(by: { max(abs($0.width! - 1), abs($0.height! - 1)) < max(abs($1.width! - 1), abs($1.height! - 1)) }) {
                print(String(format: "FAIL  screen-probe %@: %d of %d frames out of size, the worst at %.0f%% wide, %.0f%% tall (%.3f s in)",
                             name, off.count, found.count, worst.width! * 100, worst.height! * 100, worst.time))
                recorder.saveWorst(to: output + "/screen-\(name).png")
                failures += 1
            } else {
                print("ok    screen-probe \(name): \(found.count) frames, every one at its size")
            }
        }

        guard recorder.reference() else {
            print("FAIL  screen-probe: no pattern on the window to measure (\(recorder.lastProblem))")
            recorder.saveLast(to: output + "/screen-reference.png")
            exit(1)
        }
        scenario("window brought back") {
            window.orderOut(nil)
            pump(0.5)
            window.orderFrontRegardless()
        }
        // Hidden and shown again as the Dock or ⌘H and a click do: with
        // Stage Manager, the window comes back on its stage.
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pump(0.8)
        scenario("app hidden and shown") {
            app.hide(nil)
            pump(0.8)
            app.unhide(nil)
            app.activate(ignoringOtherApps: true)
        }
        // Another app's window in front, then this one again (⌘Tab, a
        // click; with Stage Manager the window goes to the strip and comes
        // back from it): this binary, run apart, is the other app.
        scenario("another app's window in front, then back") {
            let other = Process()
            other.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            other.arguments = ["--screen-cover-probe", "1.5"]
            other.standardOutput = FileHandle.nullDevice
            other.standardError = FileHandle.nullDevice
            guard (try? other.run()) != nil else { return print("      (couldn't start the other app)") }
            while other.isRunning { pump(0.05) }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            pump(0.5)
        }
        scenario("sidebar folded and shown") {
            controller.toggleSidebar()
            pump(0.8)
            controller.toggleSidebar()
        }
        scenario("window resized") {
            var frame = window.frame
            frame.size.width += 160
            frame.size.height += 90
            frame.origin.y -= 90
            window.setFrame(frame, display: true, animate: true)
            pump(0.6)
            frame.size.width -= 160
            frame.size.height -= 90
            frame.origin.y += 90
            window.setFrame(frame, display: true, animate: true)
        }
        // (Not judged while the Dock's genie squeezes the whole window.)
        scenario("window miniaturized and back", from: 0.9) {
            window.miniaturize(nil)
            pump(1.2)
            recorder.mark()
            window.deminiaturize(nil)
        }
        // Launching onto sessions that kept running: a new window's first
        // frames show the session's screen at once.
        var opened: TerminalWindowController?
        scenario("a window opening on a running session") {
            window.orderOut(nil)
            pump(0.5)
            guard let id = controller.focusedTerminal.session.persistentID,
                  let session = try? TerminalSession.attach(id, config: Config()),
                  let pane = try? TerminalView(session: session, config: Config()) else {
                print("      (couldn't show the session in another window)")
                return
            }
            let second = TerminalWindowController(restoring: [TerminalTab(pane: pane)], selected: 0, frame: window.frame,
                                                  showSidebar: true, showInspector: false, config: Config())
            second.markRestored(unstarted: [])
            try? second.start()
            second.window?.setFrame(window.frame, display: false)
            second.window?.orderFrontRegardless()
            opened = second
            recorder.includeOwnWindows()
        }
        recorder.stop()
        opened?.window?.orderOut(nil)
        window.orderOut(nil)
        print(failures == 0 ? "screen-probe: all passed" : "screen-probe: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The window's frames from ScreenCaptureKit, each measured as it comes.
    final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
        private var stream: SCStream?
        private let queue = DispatchQueue(label: "screen-probe")
        private let lock = NSLock()
        private var recording = false
        private var started = Date()
        private var frames: [Measure] = []
        /// The first frame's pattern and ruler, in pixels: the bands' span
        /// across and down, the ruler's sides.
        private var span: (width: Double, height: Double)?
        private var rulerSize: (width: Double, height: Double)?
        private var last: CGImage?
        private var worst: (score: Double, image: CGImage)?
        private(set) var lastProblem = "no frames"

        /// A stream of the window alone, at up to 120 frames a second.
        @MainActor
        func attach(to window: NSWindow) -> Bool {
            var content: SCShareableContent?
            var done = false
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { found, _ in
                content = found
                done = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !done, Date() < deadline { ScreenProbe.pump(0.05) }
            // The display, where the window is (what's on the screen: a
            // window's own capture is drawn apart from how the window server
            // composites it), with room for it to grow — but only this
            // process's windows on it: nothing of anyone else's is recorded.
            let screen = window.screen ?? NSScreen.main!
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content?.displays.first(where: { $0.displayID == displayID }) else { return false }
            let mine = content?.windows.filter { $0.owningApplication?.processID == getpid() } ?? []
            guard !mine.isEmpty else { return false }
            self.display = display
            let filter = SCContentFilter(display: display, including: mine)
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            let frame = window.frame
            // Display points from its top-left corner.
            let region = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY - 100,
                                width: frame.width + 200, height: frame.height + 200)
            config.sourceRect = region
            config.width = Int(region.width * scale)
            config.height = Int(region.height * scale)
            config.scalesToFit = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false
            config.queueDepth = 6
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) } catch { return false }
            var started = false, failed = false
            stream.startCapture { error in
                if error == nil { started = true } else { failed = true }
            }
            while !started, !failed, Date() < deadline { ScreenProbe.pump(0.05) }
            guard started else { return false }
            self.stream = stream
            return true
        }

        private var display: SCDisplay?

        /// This process's windows again (one opened since): only they are recorded.
        @MainActor
        func includeOwnWindows() {
            var done = false
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
                guard let self, let display = self.display,
                      let mine = content?.windows.filter({ $0.owningApplication?.processID == getpid() }), !mine.isEmpty else {
                    done = true
                    return
                }
                self.stream?.updateContentFilter(SCContentFilter(display: display, including: mine)) { _ in done = true }
            }
            let deadline = Date().addingTimeInterval(3)
            while !done, Date() < deadline { ScreenProbe.pump(0.05) }
        }

        @MainActor
        func stop() { stream?.stopCapture { _ in } }

        /// Wait for a frame with the pattern, and take its size as the one to keep.
        @MainActor
        func reference() -> Bool {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                if lock.withLock({ span != nil }) { return true }
                ScreenProbe.pump(0.05)
            }
            return false
        }

        /// When `mark` was last called, in the scenario's time.
        private(set) var marked: Double?

        @MainActor
        func mark() { lock.withLock { marked = Date().timeIntervalSince(started) } }

        @MainActor
        func begin() {
            lock.withLock {
                marked = nil
                frames = []
                worst = nil
                started = Date()
                recording = true
            }
        }

        @MainActor
        func end() -> [Measure] {
            lock.withLock {
                recording = false
                return frames
            }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, buffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
            let measured = Self.measure(pixels)
            let ruler = Self.ruler(pixels)
            let image = Self.image(pixels)
            lock.withLock {
                last = image
                guard let measured, let ruler else {
                    lastProblem = measured == nil ? "a frame without the pattern" : "a frame without the ruler"
                    if recording { frames.append(Measure(time: Date().timeIntervalSince(started), width: nil, height: nil)) }
                    return
                }
                guard let span, let rulerSize else {
                    self.span = measured
                    self.rulerSize = ruler
                    return
                }
                guard recording else { return }
                // The window as a whole smaller or larger (the strip, the
                // genie, a frame mid-way): nothing to judge.
                let scale = (ruler.width / rulerSize.width, ruler.height / rulerSize.height)
                guard abs(scale.0 - 1) < 0.03, abs(scale.1 - 1) < 0.03 else {
                    frames.append(Measure(time: Date().timeIntervalSince(started), width: nil, height: nil))
                    return
                }
                let m = Measure(time: Date().timeIntervalSince(started), width: measured.width / span.width / scale.0,
                                height: measured.height / span.height / scale.1)
                frames.append(m)
                let score = max(abs(m.width! - 1), abs(m.height! - 1))
                if score > 0.04, score > (worst?.score ?? 0), let image { worst = (score, image) }
            }
        }

        /// The pattern in a frame: from the first block's left edge to the
        /// last one's right, along the top band's middle; from the top band's
        /// top to the bottom band's bottom, down the first block's middle.
        static func measure(_ buffer: CVPixelBuffer) -> (width: Double, height: Double)? {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let p = base.assumingMemoryBound(to: UInt8.self)
            func magenta(_ x: Int, _ y: Int) -> Bool {
                let i = y * stride + x * 4  // BGRA
                return p[i + 2] > 190 && p[i + 1] < 90 && p[i] > 190
            }
            // The topmost row with the pattern: the top band's top.
            var top = -1, left = Int.max, right = -1
            for y in Swift.stride(from: 0, to: h, by: 2) {
                var hit = false
                for x in Swift.stride(from: 0, to: w, by: 3) where magenta(x, y) { hit = true; break }
                if hit { top = y; break }
            }
            guard top >= 0 else { return nil }
            // Across, a few rows into the band.
            let row = min(h - 1, top + 6)
            for x in 0..<w where magenta(x, row) {
                left = min(left, x)
                right = max(right, x)
            }
            guard right > left else { return nil }
            // Down, through the first block's middle: the bands' outer edges.
            let column = left + 10
            var first = -1, lastY = -1
            for y in 0..<h where magenta(column, y) {
                if first < 0 { first = y }
                lastY = y
            }
            guard first >= 0, lastY > first + 20 else { return nil }
            return (Double(right - left + 1), Double(lastY - first + 1))
        }

        /// The ruler's sides in a frame: found on a coarse grid, then traced
        /// out to its edges along the row and the column through it.
        static func ruler(_ buffer: CVPixelBuffer) -> (width: Double, height: Double)? {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let p = base.assumingMemoryBound(to: UInt8.self)
            func cyan(_ x: Int, _ y: Int) -> Bool {
                guard x >= 0, y >= 0, x < w, y < h else { return false }
                let i = y * stride + x * 4  // BGRA
                return p[i + 2] < 60 && p[i + 1] > 200 && p[i] > 200
            }
            var hit: (Int, Int)?
            search: for y in Swift.stride(from: 0, to: h, by: 8) {
                for x in Swift.stride(from: 0, to: w, by: 8) where cyan(x, y) { hit = (x, y); break search }
            }
            guard var (x, y) = hit else { return nil }
            // Its middle first (the hit may be on an edge), then its sides from there.
            var l = x, r = x, t = y, b = y
            while cyan(l - 1, y) { l -= 1 }
            while cyan(r + 1, y) { r += 1 }
            x = (l + r) / 2
            while cyan(x, t - 1) { t -= 1 }
            while cyan(x, b + 1) { b += 1 }
            y = (t + b) / 2
            l = x; r = x
            while cyan(l - 1, y) { l -= 1 }
            while cyan(r + 1, y) { r += 1 }
            guard r - l > 8, b - t > 8 else { return nil }
            return (Double(r - l + 1), Double(b - t + 1))
        }

        static func image(_ buffer: CVPixelBuffer) -> CGImage? {
            var image: CGImage?
            VTCreateCGImage(buffer, &image)
            return image
        }

        @MainActor
        func saveWorst(to path: String) { lock.withLock { worst?.image }.map { Self.write($0, to: path) } }
        @MainActor
        func saveLast(to path: String) { lock.withLock { last }.map { Self.write($0, to: path) } }

        static func write(_ image: CGImage, to path: String) {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("      (the frame: \(path))")
        }
    }
}

import VideoToolbox

private func VTCreateCGImage(_ buffer: CVPixelBuffer, _ image: inout CGImage?) {
    VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
}
