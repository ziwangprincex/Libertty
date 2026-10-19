import AppKit
import ScreenCaptureKit

/// The screen-sharing block (Tern's screen): a display or a window, captured
/// with ScreenCaptureKit and shown on the page as JPEG frames — through this
/// side, on this Mac, no network and no stream server. Needs Screen
/// Recording permission (System Settings ▸ Privacy & Security).
final class ScreenShareBlock: BlockService {
    static let symbol = "rectangle.on.rectangle"
    weak var host: BlockHost?
    let title = "Screen"
    /// `own=1`: only Libertty's own windows (what the probe uses: it never
    /// sees a display or another app's window).
    let ownOnly: Bool

    init(url: URL) {
        ownOnly = Blocks.parameter("own", of: url) == "1"
    }

    private var stream: SCStream?
    private var capturer: Capturer?
    /// Each start gets a number; one that finishes late stops itself, and
    /// only the current one's stop is remembered.
    private var generation = 0
    /// A frame on its way to the page: another waits (no queue of frames).
    private var sending = false
    private let queue = DispatchQueue(label: "dev.libertty.screen")
    /// Frames a second, the width to scale to: the page's, kept small on purpose.
    private var fps = 10
    private var width = 1280
    private var started = false

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        switch method {
        case "sources":
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: !self.ownOnly)
                    let displays = self.ownOnly ? [] : content.displays.map { d in
                        ["id": String(d.displayID), "kind": "display", "name": Self.name(of: d), "width": d.width, "height": d.height]
                    }
                    let mine = getpid()
                    let shown = content.windows.filter { w in
                        if self.ownOnly { return w.owningApplication?.processID == mine && w.frame.width > 80 }
                        return w.isOnScreen && w.frame.width > 80 && w.frame.height > 80 && !(w.title ?? "").isEmpty
                    }
                    let windows: [[String: Any]] = shown.prefix(60).map { w in
                        let app = w.owningApplication?.applicationName ?? "", title = w.title ?? ""
                        let label = app.isEmpty ? title : app + " — " + title
                        return ["id": String(w.windowID), "kind": "window", "name": label, "app": app,
                                "width": Int(w.frame.width), "height": Int(w.frame.height)]
                    }
                    reply(.success(["displays": displays, "windows": windows]))
                } catch {
                    reply(.failure(BlockError("Screen Recording permission is needed for this (System Settings ▸ Privacy & Security ▸ Screen Recording), then reopen Libertty. \(error.localizedDescription)")))
                }
            }
        case "start":
            let id = params["id"] as? String ?? "", kind = params["kind"] as? String ?? "display"
            fps = min(30, max(1, params["fps"] as? Int ?? 10))
            width = min(2560, max(320, params["width"] as? Int ?? 1280))
            // On the main actor: its state (the stream, the generation) is the
            // main thread's, as stop and close are; the awaits run elsewhere.
            Task { @MainActor in
                do { reply(.success(try await start(id: id, kind: kind, fps: fps, width: width))) } catch { reply(.failure(BlockError(error.localizedDescription))) }
            }
        case "stop":
            generation += 1
            DispatchQueue.main.async { self.stop() }
            reply(.success(true))
        case "frameShown":
            DispatchQueue.main.async { self.frameShown() }
            reply(.success(true))
        default:
            reply(.failure(BlockError("unknown call \(method)")))
        }
    }

    private static func name(of display: SCDisplay) -> String {
        let screens = NSScreen.screens
        if let match = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) {
            return match.localizedName
        }
        return "Display \(display.displayID)"
    }

    @MainActor
    private func start(id: String, kind: String, fps: Int, width: Int) async throws -> [String: Any] {
        stop()
        if ownOnly, kind != "window" { throw BlockError("Only Libertty's own windows here.") }
        // A window that isn't on any Space right now is still listed (and unscreen bits excluded).
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: !ownOnly && kind != "window")
        let filter: SCContentFilter
        let size: CGSize
        if kind == "window" {
            // Never a display in its place: the screen isn't what was asked for.
            guard let windowID = UInt32(id), let window = content.windows.first(where: { $0.windowID == windowID }),
                  !ownOnly || window.owningApplication?.processID == getpid() else {
                throw BlockError("That window isn't there anymore. Pick another.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        } else if let display = content.displays.first(where: { String($0.displayID) == id }) ?? content.displays.first {
            filter = SCContentFilter(display: display, excludingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        } else {
            throw BlockError("Nothing to capture.")
        }
        let config = SCStreamConfiguration()
        let scale = min(1, CGFloat(width) / max(size.width, 1))
        config.width = Int(size.width * scale) / 2 * 2
        config.height = Int(size.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // A window's own background, not the desktop behind it.
        config.ignoreShadowsSingleWindow = true
        generation += 1
        let run = generation
        // Frames come on the capture queue; the page is spoken to on the main thread.
        let page = PageLink(self)
        let capturer = Capturer(fps: fps) { jpeg, w, h in
            DispatchQueue.main.async {
                guard let share = page.share, share.generation == run else { return }
                // One frame at a time: a page slower than the stream skips, it doesn't queue.
                guard !share.sending else { return }
                share.sending = true
                share.host?.send("frame", ["data": jpeg, "width": w, "height": h])
            }
        } onError: { text in
            DispatchQueue.main.async { page.share?.host?.send("error", ["message": text]) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: capturer)
        try stream.addStreamOutput(capturer, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        // Another start came while this one was starting, or the tab went: stop this one.
        guard run == generation, !closed else {
            try? await stream.stopCapture()
            throw BlockError("Stopped.")
        }
        self.capturer = capturer
        self.stream = stream
        self.fps = fps
        started = true
        return ["width": config.width, "height": config.height, "fps": fps]
    }

    /// The page took its frame (it's drawn it): the next may come.
    func frameShown() { sending = false }

    private func stop() {
        guard started else { return }
        started = false
        let s = stream
        stream = nil
        capturer = nil
        s?.stopCapture { _ in }
    }

    /// Closed: a start still on its way stops what it started.
    private var closed = false
    func close() { closed = true; generation += 1; stop() }
    func suspend() { generation += 1; stop() }

}

/// The stream's frames: one in `fps` becomes a JPEG for the page.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let fps: Int
    private var last = Date.distantPast
    private let onFrame: (String, Int, Int) -> Void
    private let onError: (String) -> Void
    init(fps: Int, onFrame: @escaping (String, Int, Int) -> Void, onError: @escaping (String) -> Void) {
        self.fps = fps
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The first frames of a stream are often empty: skip them.
        if let raw = CMGetAttachment(sampleBuffer, key: SCStreamFrameInfo.status.rawValue as CFString, attachmentModeOut: nil) as? NSNumber,
           raw.intValue != SCFrameStatus.complete.rawValue { return }
        let now = Date()
        guard now.timeIntervalSince(last) >= 1.0 / Double(fps) else { return }
        last = now
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage() else { return }
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        onFrame(jpeg.base64EncodedString(), width, height)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error.localizedDescription) }
}

/// The block, held weakly, for the capture queue to reach (only ever used on the main thread).
private final class PageLink: @unchecked Sendable {
    weak var share: ScreenShareBlock?
    init(_ share: ScreenShareBlock) { self.share = share }
}
