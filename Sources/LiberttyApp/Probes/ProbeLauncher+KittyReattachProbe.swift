#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --kitty-reattach-probe FIXTURE`: images shown in a liberttyd
    /// session are there again after detaching and attaching.
    static func kittyReattachProbe() -> Never {
        Persistence.setUp(wanted: true)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--kitty-reattach-probe"), i + 1 < args.count else { exit(2) }
        func placements(_ s: TerminalSession) -> [String] {
            let found = s.kittyImages(cellWidth: 16, cellHeight: 32) { _, _ in false }
            return found.draws.map { "\($0.imageID)@\(Int($0.rect.x)),\(Int($0.rect.y)) \(Int($0.rect.z))x\(Int($0.rect.w))" }
                + found.virtuals.map { "virtual \($0.imageID) \($0.columns)x\($0.rows) \($0.width)x\($0.height)px" }
        }
        do {
            let size = GridSize(cols: 60, rows: 14, widthPx: 960, heightPx: 448)
            let session = try TerminalSession(size: size)
            session.setCellSize(widthPx: 16, heightPx: 32)
            try session.start(command: "python3 \(args[i + 1]); sleep 30")
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let before = placements(session)
            guard let id = session.persistentID else { print("kitty-reattach: not in liberttyd"); exit(1) }
            session.detachForProbe()
            let again = try TerminalSession.attach(id)
            again.setCellSize(widthPx: 16, heightPx: 32)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let after = placements(again)
            print("before: \(before)")
            print("after:  \(after)")
            print(!before.isEmpty && before.sorted() == after.sorted() ? "kitty-reattach: images kept" : "kitty-reattach: lost")
            again.terminate()
            exit(0)
        } catch {
            print("kitty-reattach: \(error)")
            exit(1)
        }
    }
}
#endif
