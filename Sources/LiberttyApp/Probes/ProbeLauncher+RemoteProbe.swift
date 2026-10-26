#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --remote-probe HOST` (with tests/fixtures/fake-ssh as LIBERTTY_SSH):
    /// set the host up, run a session there, drop the link and bring it
    /// back, then reattach as a relaunched Libertty would.
    static func remoteProbe(host destination: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let host = RemoteHost.named(destination)
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return done()
        }
        var failed: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("\(name): \(ok)")
            if !ok { failed.append(name) }
        }
        do {
            let info = try host.prepare { print("progress: \($0)") }
            print("host: \(info.os) \(info.arch) terminfo=\(info.terminfo) shell=\((info.shell as NSString).lastPathComponent)")
            let size = GridSize(cols: 60, rows: 12, widthPx: 600, heightPx: 240)
            let session = try TerminalSession(size: size)
            session.start(on: host, workingDirectory: "/tmp", command: "echo remote-ok TERM=$TERM; pwd; sleep 60")
            check("link up", wait(15) { session.linkUp && session.scrollbackText().contains("remote-ok") })
            print("output: \(session.scrollbackText().split(separator: "\n").prefix(2).joined(separator: " | "))")
            let listed = DaemonClient.sessions(address: host.address)?.contains { $0.id == session.persistentID } ?? false
            check("listed on host", listed)

            // The windows this Mac shows the host's sessions in, kept there:
            // handed over as a save does (over the link that's up, in batch
            // mode, never logging in), read back as Connect to Host does.
            setenv("LIBERTTY_CLIENT_ID", "remote-probe", 1)
            let layout = SavedState(windows: [SavedWindow(frame: "", sidebar: true, inspector: false, fontSize: nil, selected: 0,
                                                          tabs: [SavedTab(panes: SavedPane(session: session.persistentID))],
                                                          host: destination)], savedAt: 1)
            let body = try JSONEncoder().encode(layout).withUnsafeBytes {
                Connection.headed(["client": Restoration.clientID, "local": false], body: $0)
            }
            var stored = false
            if case .answered(let reply) = DaemonClient.request(.storeLayout, payload: body, needing: "layout", timeout: 5,
                                                                address: host.quietAddress) {
                stored = reply.json["ok"] as? Bool == true
            }
            check("layout kept there", stored)
            var readBack = false
            if case .layout(let back, mine: true) = Restoration.held(at: host.address, local: false, timeout: 5) {
                readBack = back.windows.first?.tabs.first?.panes?.session == session.persistentID
            }
            check("layout read back", readBack)

            // The network goes away (bridges die, new ones fail), then comes back.
            let down = ProcessInfo.processInfo.environment["FAKE_SSH_DOWN"] ?? "/tmp/libertty-test/fake-ssh-down"
            FileManager.default.createFile(atPath: down, contents: nil)
            let kill = Process()
            // The bridges are processes here (fake-ssh), or there: then
            // FAKE_SSH_KILL is how to end them (docker-ssh's container).
            if let there = ProcessInfo.processInfo.environment["FAKE_SSH_KILL"], !there.isEmpty {
                kill.executableURL = URL(fileURLWithPath: "/bin/sh")
                kill.arguments = ["-c", there]
            } else {
                kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                kill.arguments = ["-f", info.liberttyd + " --bridge"]
            }
            try kill.run()
            kill.waitUntilExit()
            check("link down", wait(5) { !session.linkUp })
            try? FileManager.default.removeItem(atPath: down)
            check("link back", wait(15) { session.linkUp })
            check("kept", session.scrollbackText().contains("remote-ok"))

            // Libertty quits (the session lives on there) and comes back.
            let id = session.persistentID ?? ""
            session.detachForProbe()
            let again = try TerminalSession.reattach(id, host: host, size: size, workingDirectory: nil)
            check("reattached", wait(15) { again.linkUp && again.scrollbackText().contains("remote-ok") })
            again.terminate()
            check("ended there", wait(5) { !(DaemonClient.sessions(address: host.address)?.contains { $0.id == id } ?? true) })

            // The login shell there, with Libertty's integration from ~/.libertty.
            let shell = try TerminalSession(size: size)
            shell.start(on: host, workingDirectory: nil, command: nil)
            _ = wait(15) { shell.linkUp }
            _ = wait(8) { shell.scrollbackText().contains("%") || shell.scrollbackText().contains("$") }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            shell.sendText("sleep 2\n")
            check("busy while running", wait(3) { shell.hasForegroundProgram })
            check("idle at the prompt", wait(5) { !shell.hasForegroundProgram })
            shell.sendText("echo session=$LIBERTTY_SESSION\n")
            check("shell", wait(5) { shell.scrollbackText().contains("session=" + (shell.persistentID ?? "?")) })
            // Where that shell is, as the host has it: the pane's name and its
            // new splits go by it.
            check("folder there", wait(5) { shell.workingDirectory != nil })
            shell.terminate()
            print(failed.isEmpty ? "remote-probe: all passed" : "remote-probe failed: \(failed)")
            exit(failed.isEmpty ? 0 : 1)
        } catch {
            print("remote-probe: \(error.localizedDescription)")
            exit(1)
        }
    }
}
#endif
