#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --command-probe zsh|bash`: run two commands in that shell with
    /// Libertty's integration and print the command-finished events it reports.
    static func commandProbe(shell: String) -> Never {
        final class Events: TerminalSessionDelegate {
            func sessionNeedsRender(_ session: TerminalSession) {}
            func sessionTitleChanged(_ session: TerminalSession, title: String) {}
            func sessionBell(_ session: TerminalSession) {}
            func sessionProgramStatusChanged(_ session: TerminalSession) {}
            func sessionExited(_ session: TerminalSession, status: Int32) {}
            func sessionCommandFinished(_ session: TerminalSession, command: String, exitCode: Int32?, duration: TimeInterval) {
                print(String(format: "finished: %@ exit=%@ after %.1fs", command, exitCode.map { String($0) } ?? "?", duration))
            }
            func sessionDesktopNotification(_ session: TerminalSession, title: String, body: String) {
                print("notification: \(title) / \(body)")
            }
            func sessionProgressChanged(_ session: TerminalSession) {
                print("progress: \(String(describing: session.progress))")
            }
        }
        do {
            setenv("SHELL", "/bin/\(shell)", 1)
            let session = try TerminalSession(size: GridSize(cols: 100, rows: 30, widthPx: 0, heightPx: 0))
            let events = Events()
            session.delegate = events
            try session.start(shellPath: "/bin/\(shell)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            session.sendText("sleep 0.3; echo 'a;b' >/dev/null\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            session.sendText("printf '\\e]9;4;1;42\\a\\e]777;notify;Build;done\\a'; false\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            if CommandLine.arguments.contains("--screen") {
                session.selectAll()
                print(session.selectedText() ?? "")
            }
            exit(0)
        } catch {
            print("command-probe: \(error)")
            exit(1)
        }
    }
}
#endif
