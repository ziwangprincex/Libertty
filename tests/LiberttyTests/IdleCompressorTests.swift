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

        // History changed with no output (a resize reflowing it): the
        // sleepers' look sees that and it ticks again, compressing what came back.
        let slow = IdleCompressor(queue: DispatchQueue(label: "test.slow"), first: 0.05, tick: 0.05) { body in
            lock.withLock { body(terminal) }
        }
        defer { slow.stop() }
        #expect(Self.waitUntil(20) { slow.isDormant })
        compressor.stop()
        lock.withLock {
            var cols: UInt16 = 100, rows: UInt16 = 30
            _ = ghostty_terminal_resize(terminal, cols, rows, 0, 0)
            (cols, rows) = (80, 24)
            _ = ghostty_terminal_resize(terminal, cols, rows, 0, 0)
        }
        #expect(slow.isDormant)
        IdleCompressor.lookAtSleepers()
        #expect(Self.waitUntil(20) { !slow.isDormant })
        #expect(Self.waitUntil(20) { slow.isDormant })

        lock.withLock {
            Self.write(terminal, lines: 20_000, tag: "b")
            slow.wake()
        }
        #expect(!slow.isDormant)
        #expect(Self.waitUntil(20) { slow.isDormant })
        #expect(lock.withLock { Self.compressedPages(terminal) } > first)
    }
}
