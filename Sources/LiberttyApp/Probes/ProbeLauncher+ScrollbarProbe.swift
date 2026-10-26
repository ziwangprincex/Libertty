#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    static func scrollbarProbe() -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 400, heightPx: 200))
            try session.start(command: "seq 1 400; sleep 2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func show(_ label: String) {
                let s = session.scrollbar
                print("\(label): total \(s.total) offset \(s.offset) length \(s.length) scrollable \(s.scrollable)")
            }
            show("after output")
            session.scroll(toRow: 0)
            show("scrolled to top")
            session.scroll(toRow: 200)
            show("scrolled to 200")
            session.scrollToBottom()
            show("bottom")
            exit(0)
        } catch {
            print("scrollbar-probe: \(error)")
            exit(1)
        }
    }
}
#endif
