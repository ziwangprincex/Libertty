#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --resize-bench`: cost of one grid resize (reflow) with a full
    /// scrollback, as a live window resize or split drag pays every frame.
    static func resizeBench() {
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, 120, 40) == GHOSTTY_SUCCESS, let terminal else { exit(1) }
        var lines = 10_000
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        // Fill the scrollback with wrapped, styled lines like real output.
        var text = ""
        for i in 0..<12_000 {
            text += "\u{1b}[3\(i % 8)m\(i) " + String(repeating: "lorem ipsum dolor sit amet ", count: 3 + i % 5) + "\u{1b}[0m\r\n"
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }

        var times: [Double] = []
        for i in 0..<200 {
            let cols = UInt16(80 + (i % 2 == 0 ? i % 60 : 60 - i % 60))
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            _ = ghostty_terminal_resize(terminal, cols, 40, 16, 31)
            times.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
        }
        times.sort()
        print(String(format: "resize with full scrollback: median %.2f ms, p95 %.2f ms, max %.2f ms",
                     times[times.count / 2], times[times.count * 95 / 100], times.last!))
        ghostty_terminal_free(terminal)
        exit(0)
    }
}
#endif
