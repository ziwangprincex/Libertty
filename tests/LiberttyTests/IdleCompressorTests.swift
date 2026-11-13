import Foundation
import Testing
import CGhosttyVt
import LiberttyCore

/// Scrollback compression stops ticking once a quiet terminal is done, and
/// output starts it again: an idle session costs no wake-ups.
struct IdleCompressorTests {
    private static func terminal() -> GhosttyTerminal {
        var t: GhosttyTerminal?
        _ = ghostty_terminal_new(nil, &t, 80, 24)
        var unlimited = UInt.max
        _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimited)
        return t!
    }

    private static func write(_ terminal: GhosttyTerminal, lines: Int, tag: String) {
        let text = (0..<lines).map { "\(tag) line \($0) " + String(repeating: "x", count: 60) }.joined(separator: "\r\n") + "\r\n"
        let bytes = Array(text.utf8)
        ghostty_terminal_vt_write(terminal, bytes, bytes.count)
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private static func compressedPages(_ terminal: GhosttyTerminal) -> UInt64 {
        var usage = GhosttyTerminalMemoryUsage()
        usage.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage)
        return usage.primary_compressed_pages
    }

    @Test func sleepsWhenDoneAndWakesForOutput() {
        let lock = NSLock()
        let terminal = Self.terminal()
        defer { ghostty_terminal_free(terminal) }
        lock.withLock { Self.write(terminal, lines: 20_000, tag: "a") }
        #expect(Self.compressedPages(terminal) == 0)
        let compressor = IdleCompressor(queue: DispatchQueue(label: "test.compressor"), first: 0.05, tick: 0.05) { body in
            lock.withLock { body(terminal) }
        }
        defer { compressor.stop() }
        #expect(Self.waitUntil(20) { compressor.isDormant })
        let first = lock.withLock { Self.compressedPages(terminal) }
        #expect(first > 0)

        lock.withLock {
            Self.write(terminal, lines: 20_000, tag: "b")
            compressor.wake()
        }
        #expect(!compressor.isDormant)
        #expect(Self.waitUntil(20) { compressor.isDormant })
        #expect(lock.withLock { Self.compressedPages(terminal) } > first)
    }
}
