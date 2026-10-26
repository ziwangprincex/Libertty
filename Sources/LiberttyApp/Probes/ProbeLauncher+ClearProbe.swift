#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --clear-probe`: ⌘K in a liberttyd session must clear liberttyd's copy
    /// too; prints how many lines liberttyd still has before and after.
    static func clearProbe() -> Never {
        Persistence.setUp(wanted: true)
        do {
            let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 400, heightPx: 200))
            try session.start(command: "seq 1 50; sleep 5")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func liberttydLines() -> Int {
                guard let id = session.persistentID,
                      let text = DaemonClient.request(.capture, json: ["id": id, "scrollback": true])?.json["text"] as? String
                else { return -1 }
                return text.split(separator: "\n").count
            }
            let before = liberttydLines()
            session.clearScreen()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let window = session.scrollbackText().split(separator: "\n").count
            print("liberttyd lines before ⌘K: \(before), after: \(liberttydLines()), window: \(window)")
            session.terminate()

            // ⌘K while the output stops inside an escape sequence: the clear
            // waits for its end instead of cutting it into literal text.
            let split = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 400, heightPx: 200))
            try split.start(command: "printf 'x\\033[38;5;'; sleep 0.8; printf '196mRED\\n'; sleep 0.4; printf 'AFTER\\n'; sleep 5")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            split.clearScreen()
            RunLoop.main.run(until: Date().addingTimeInterval(1.4))
            let text = split.persistentID.flatMap {
                DaemonClient.request(.capture, json: ["id": $0, "scrollback": true])?.json["text"] as? String
            } ?? ""
            let windowText = split.scrollbackText()
            func intact(_ t: String) -> Bool { t.contains("AFTER") && !t.contains("196m") }
            print("mid-sequence: liberttyd \(intact(text) ? "intact" : "broken: \(text.debugDescription)"), window \(intact(windowText) ? "intact" : "broken")")
            split.terminate()
            exit(0)
        } catch {
            print("clear-probe: \(error)")
            exit(1)
        }
    }
}
#endif
