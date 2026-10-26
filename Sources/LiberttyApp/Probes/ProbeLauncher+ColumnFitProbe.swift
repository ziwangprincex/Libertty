#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --scrollbar-probe`: the scrollbar model through output and scrolling.
    /// `Libertty --column-fit-probe`: where a window goes when a side column
    /// comes or goes on a screen (the UI probe's windows have none).
    static func columnFitProbe() -> Never {
        let visible = NSRect(x: 0, y: 25, width: 1920, height: 1030)
        var failed = 0
        func show(_ label: String, _ grown: NSRect, from old: NSRect, _ want: NSRect) {
            let got = TerminalWindowController.onScreen(grown, from: old, visible: visible)
            if got != want { failed += 1 }
            print("\(got == want ? "ok  " : "FAIL") \(label): \(NSStringFromRect(got))" + (got == want ? "" : ", not \(NSStringFromRect(want))"))
        }
        let old = NSRect(x: 500, y: 200, width: 900, height: 600)
        // The sidebar comes in on the left (the window grows by 250 there).
        show("room on the left", NSRect(x: 250, y: 200, width: 1150, height: 600), from: old,
             NSRect(x: 250, y: 200, width: 1150, height: 600))
        show("at the left edge: moved right", NSRect(x: -150, y: 200, width: 1150, height: 600),
             from: NSRect(x: 100, y: 200, width: 900, height: 600), NSRect(x: 0, y: 200, width: 1150, height: 600))
        // The inspector comes in on the right.
        show("at the right edge: moved left", NSRect(x: 1000, y: 200, width: 1150, height: 600),
             from: NSRect(x: 1000, y: 200, width: 900, height: 600), NSRect(x: 770, y: 200, width: 1150, height: 600))
        show("wider than the screen: as wide as it", NSRect(x: 0, y: 200, width: 2100, height: 600),
             from: NSRect(x: 0, y: 200, width: 1850, height: 600), NSRect(x: 0, y: 200, width: 1920, height: 600))
        show("partly off the screen: left as asked", NSRect(x: -400, y: 200, width: 1150, height: 600),
             from: NSRect(x: -150, y: 200, width: 900, height: 600), NSRect(x: -400, y: 200, width: 1150, height: 600))
        let fills = TerminalWindowController.fills(NSRect(x: 0, y: 25, width: 1920, height: 1030), visible: visible)
        let not = TerminalWindowController.fills(old, visible: visible)
        if !(fills && !not) { failed += 1 }
        print("\(fills && !not ? "ok  " : "FAIL") filling the screen: \(fills), a smaller window: \(not)")
        if failed == 0 { print("column-fit: all passed") }
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
