// swiftc -O bench/keylat.swift -o build/keylat; build/keylat PID [count]: typing latency of one terminal window, measured from
// outside the app the same way for every terminal. Streams that window alone
// with ScreenCaptureKit (frames arrive as the compositor makes them), posts
// a key to the app (alternating "a" and Backspace, so the line never grows),
// and times key → the first frame whose cursor line changed.
// Needs Accessibility (posting keys) and Screen Recording (window capture).
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: keylat PID [count]"); exit(2) }
let count = args.count > 2 ? Int(args[2]) ?? 60 : 60

/// The latest frame: its rows of pixels (BGRA) and when it was made.
final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    var latest: (data: [UInt8], width: Int, height: Int, time: UInt64)?
    var arrived = DispatchSemaphore(value: 0)

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let image = buffer.imageBuffer else { return }
        // Only frames that carry new content.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        // When the compositor showed it (mach ticks), not when it reached us.
        var now = DispatchTime.now().uptimeNanoseconds
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let display = attachments.first?[.displayTime] as? UInt64 {
            now = display * UInt64(timebase.numer) / UInt64(timebase.denom)
        }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        var data = [UInt8](repeating: 0, count: width * 4 * height)
        for y in 0..<height {
            memcpy(&data[y * width * 4], base + y * rowBytes, width * 4)
        }
        lock.withLock { latest = (data, width, height, now) }
        arrived.signal()
    }
}

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
/// Now, on the same clock as frames' display times.
func nowNanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

let frames = Frames()
let ready = DispatchSemaphore(value: 0)
var stream: SCStream?
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
        }) else { print("no window for pid \(pid)"); exit(1) }
        print("window \(window.windowID) \(window.frame)")
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try s.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
        try await s.startCapture()
        stream = s
        ready.signal()
    } catch {
        print("capture failed: \(error)")
        exit(1)
    }
}
ready.wait()

func latest() -> (data: [UInt8], width: Int, height: Int, time: UInt64)? { frames.lock.withLock { frames.latest } }

/// Wait until the stream has been quiet (no new frame) for `quiet` seconds.
@discardableResult
func settle(_ quiet: Double = 0.25, max: Double = 2) -> Bool {
    let end = Date().addingTimeInterval(max)
    while Date() < end {
        if frames.arrived.wait(timeout: .now() + quiet) == .timedOut { return true }
    }
    return false
}
var neverQuiet = 0

let source = CGEventSource(stateID: .hidSystemState)
func post(_ key: CGKeyCode, _ char: String?) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
        if let char { e.keyboardSetUnicodeString(stringLength: char.utf16.count, unicodeString: Array(char.utf16)) }
        e.postToPid(pid)
    }
}
let keyA: CGKeyCode = 0x00, backspace: CGKeyCode = 0x33

/// Rows that differ between two frames.
func changedRows(_ a: [UInt8], _ b: [UInt8], width: Int) -> [Int] {
    let stride = width * 4
    return (0..<(min(a.count, b.count) / stride)).filter { y in a[(y * stride)..<((y + 1) * stride)] != b[(y * stride)..<((y + 1) * stride)] }
}

// Calibrate on one keystroke: the rows the echo changes (the cursor line),
// so a blinking cursor or a clock elsewhere doesn't count.
settle()
guard let first = latest() else { print("no frames (Screen Recording?)"); exit(1) }
post(keyA, "a")
Thread.sleep(forTimeInterval: 0.5)
settle()
guard let typed = latest() else { exit(1) }
let rows = changedRows(first.data, typed.data, width: first.width)
guard let top = rows.min(), let bottom = rows.max() else { print("the echo changed nothing on screen"); exit(1) }
print("echo rows \(top)–\(bottom) of \(first.height)")
post(backspace, nil)
Thread.sleep(forTimeInterval: 0.5)
let width = first.width
func line(_ data: [UInt8]) -> ArraySlice<UInt8> { data[(top * width * 4)..<((bottom + 1) * width * 4)] }

var samples: [Double] = []
var timeouts = 0
for i in 0..<count {
    if !settle(0.12, max: 1) { neverQuiet += 1 }
    // A random wait after the quiet frame, so keys don't lock to frame times.
    Thread.sleep(forTimeInterval: Double.random(in: 0..<0.017))
    // The target must hold the keyboard for the whole run.
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { print("ABORT: the target lost the front"); exit(1) }
    guard let base = latest() else { break }
    let reference = line(base.data)
    let start = nowNanos()
    if i % 2 == 0 { post(keyA, "a") } else { post(backspace, nil) }
    var hit: UInt64?
    while hit == nil, nowNanos() - start < 500_000_000 {
        guard frames.arrived.wait(timeout: .now() + 0.5) == .success, let f = latest(), f.time > start else { continue }
        if line(f.data) != reference { hit = f.time }
    }
    if let hit { samples.append(Double(hit - start) / 1e6) } else { timeouts += 1 }
    // Random spacing, so keys don't lock to a frame boundary.
    Thread.sleep(forTimeInterval: 0.08 + Double.random(in: 0..<0.06))
}
if count % 2 == 1 { post(backspace, nil) }

let sorted = samples.sorted()
func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
if neverQuiet > 0 { print("WARNING: \(neverQuiet) keys were sent while the window kept changing (a blinking cursor?)") }
print(String(format: "RESULT samples %d  timeouts %d  min %.1f  median %.1f  p95 %.1f  max %.1f ms",
             sorted.count, timeouts, sorted.first ?? 0, pct(0.5), pct(0.95), sorted.last ?? 0))
let done = DispatchSemaphore(value: 0)
Task { try? await stream?.stopCapture(); done.signal() }
_ = done.wait(timeout: .now() + 2)
exit(0)
