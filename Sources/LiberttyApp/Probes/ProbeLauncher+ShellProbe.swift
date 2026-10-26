#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --shell-probe zsh|bash|fish LINE`: type LINE into that shell
    /// (with Libertty's integration and environment) and print the screen.
    static func shellProbe(shell: String, input: String) -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 100, rows: 20, widthPx: 0, heightPx: 0))
            try session.start(shellPath: shell.hasPrefix("/") ? shell : "/bin/\(shell)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            session.sendText(input + "\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            session.selectAll()
            print(session.selectedText() ?? "")
            exit(0)
        } catch {
            print("shell-probe: \(error)")
            exit(1)
        }
    }
}
#endif
