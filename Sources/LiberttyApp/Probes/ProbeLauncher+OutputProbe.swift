#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --output-probe zsh|bash`: run two commands, then select the
    /// last one's output (OSC 133 marks) and print it.
    static func outputProbe(shell: String) -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 80, rows: 30, widthPx: 0, heightPx: 0))
            try session.start(shellPath: "/bin/\(shell)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            session.sendText("echo first-command\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            session.sendText("printf 'out one\\nout two\\nout three\\n'\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let ok = session.selectLastCommandOutput()
            print("selected: \(ok)")
            print("[" + (session.selectedText() ?? "") + "]")
            // A command that prints nothing: there's no output of it to take
            // (not the one before's).
            session.sendText("cd .\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            print("after a silent command: \(session.selectLastCommandOutput() ? "selected [\(session.selectedText() ?? "")]" : "nothing")")
            exit(0)
        } catch {
            print("output-probe: \(error)")
            exit(1)
        }
    }
}
#endif
