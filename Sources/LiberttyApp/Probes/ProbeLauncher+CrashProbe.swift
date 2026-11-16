#if LIBERTTY_PROBES
import AppKit
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --crash-probe`: liberttyd going away without a word (here a
    /// SIGKILL; a trap, jetsam) mustn't end its session or blank the window:
    /// its guardian starts another, the window keeps its screen and gives it
    /// back, and the program goes on.
    static func crashProbe() -> Never {
        Persistence.setUp(wanted: true)
        var failures: [String] = []
        func liberttyd() -> Int? { DaemonClient.request(.info, json: [:])?.json["pid"] as? Int }
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() {
                if Date() > deadline { return false }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return true
        }
        do {
            let session = try TerminalSession(size: GridSize(cols: 60, rows: 12, widthPx: 600, heightPx: 240))
            try session.start(command: "printf 'before-crash\\n'; read line; printf 'after-%s\\n' \"$line\"; sleep 30")
            guard let id = session.persistentID, let old = liberttyd() else {
                print("crash-probe: not in liberttyd")
                exit(1)
            }
            func captured() -> String {
                DaemonClient.request(.capture, json: ["id": id, "scrollback": true])?.json["text"] as? String ?? ""
            }
            _ = wait(5) { session.scrollbackText().contains("before-crash") }
            kill(pid_t(old), SIGKILL)
            // Down, then back through a new liberttyd.
            _ = wait(2) { !session.linkUp }
            if !wait(10, until: { session.linkUp && (liberttyd().map { $0 != old } ?? false) }) {
                failures.append("no new liberttyd took the session (link \(session.linkUp ? "up" : "down"))")
            }
            if session.hasExited { failures.append("the session ended") }
            if !session.scrollbackText().contains("before-crash") { failures.append("the window lost its screen") }
            if !wait(3, until: { captured().contains("before-crash") }) {
                failures.append("liberttyd didn't get the window's screen back: \(captured().debugDescription)")
            }
            session.sendText("still-here\r")
            if !wait(5, until: { session.scrollbackText().contains("after-still-here") }) {
                failures.append("the program didn't go on: \(session.scrollbackText().debugDescription)")
            }
            if !captured().contains("after-still-here") { failures.append("liberttyd's copy didn't go on") }
            session.terminate()
        } catch {
            print("crash-probe: \(error)")
            exit(1)
        }
        print(failures.isEmpty ? "crash-probe: all passed" : "crash-probe: \(failures.joined(separator: "; "))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
