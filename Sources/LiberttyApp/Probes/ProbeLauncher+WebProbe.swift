#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --web-probe`: Web Access on a private port with one pane; a
    /// WebSocket client checks the page, the secret, the screen and typing.
    @MainActor
    static func webProbe() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        var failed: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("\(name): \(ok)")
            if !ok { failed.append(name) }
        }
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return done()
        }
        do {
            let session = try TerminalSession(size: GridSize(cols: 50, rows: 8, widthPx: 0, heightPx: 0))
            try session.start(command: "printf 'web-ok\\n'; exec cat")
            let web = WebAccess.shared
            web.panes = { [WebPane(id: "p1", title: "probe", place: "probe window", host: nil, session: session)] }
            var config = Config()
            config.webAccess = "local"
            config.webAccessPort = Int(ProcessInfo.processInfo.environment["LIBERTTY_WEB_PORT"] ?? "") ?? 17682
            web.apply(config)
            check("listening", wait(5) { web.listening })
            let base = "http://127.0.0.1:\(web.port)"

            // The page, with its nonce policy.
            var page: (Int, String, String)?
            URLSession.shared.dataTask(with: URL(string: base + "/")!) { data, response, _ in
                let http = response as? HTTPURLResponse
                page = (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "",
                        String(decoding: data ?? Data(), as: UTF8.self))
            }.resume()
            _ = wait(5) { page != nil }
            check("page", page?.0 == 200 && page?.2.contains("<title>Libertty</title>") == true)
            check("script needs the nonce", page?.1.contains("script-src 'nonce-") == true && page?.1.contains("script-src 'unsafe") == false)

            final class Inbox: @unchecked Sendable {
                let lock = NSLock()
                var messages: [[String: Any]] = []
                var closed = false
                func add(_ m: [String: Any]) { lock.withLock { messages.append(m) } }
                func all() -> [[String: Any]] { lock.withLock { messages } }
            }
            func open(_ token: String, origin: String? = nil) -> (URLSessionWebSocketTask, Inbox) {
                var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(web.port)/ws?t=\(token)")!)
                if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
                let task = URLSession.shared.webSocketTask(with: request)
                let inbox = Inbox()
                // On URLSession's queue, not the main actor: it only fills the inbox.
                @Sendable func next() {
                    task.receive { result in
                        switch result {
                        case .success(.string(let text)):
                            if let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { inbox.add(m) }
                            next()
                        case .success: next()
                        case .failure: inbox.lock.withLock { inbox.closed = true }
                        }
                    }
                }
                task.resume()
                next()
                return (task, inbox)
            }
            func send(_ task: URLSessionWebSocketTask, _ message: [String: Any]) {
                let data = try! JSONSerialization.data(withJSONObject: message)
                task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
            }

            let (bad, badInbox) = open("not-the-secret")
            check("wrong secret refused", wait(5) { badInbox.lock.withLock { badInbox.closed } } && badInbox.all().isEmpty)
            bad.cancel()
            let (foreign, foreignInbox) = open(web.token, origin: "https://evil.example")
            check("other sites refused", wait(5) { foreignInbox.lock.withLock { foreignInbox.closed } } && foreignInbox.all().isEmpty)
            foreign.cancel()

            let (task, inbox) = open(web.token)
            check("hello", wait(5) { inbox.all().contains { $0["t"] as? String == "hello" } })
            check("panes listed", wait(5) { inbox.all().contains { ($0["panes"] as? [[String: Any]])?.first?["id"] as? String == "p1" } })
            send(task, ["t": "watch", "id": "p1"])
            func screen() -> String { inbox.all().last { $0["t"] as? String == "screen" }?["html"] as? String ?? "" }
            check("screen", wait(5) { screen().contains("web-ok") })
            check("palette sent once", inbox.all().filter { $0["t"] as? String == "style" }.count == 1)
            send(task, ["t": "text", "text": "typed-in"])
            send(task, ["t": "key", "code": "Enter", "key": "Enter"])
            check("typing", wait(5) { screen().components(separatedBy: "typed-in").count >= 3 })  // echoed, then printed by cat
            send(task, ["t": "key", "code": "KeyC", "key": "c", "ctrl": true])
            check("ctrl-c through the encoder", wait(5) { session.hasExited })
            task.cancel()

            // My tailnet (a stand-in Tailscale, LIBERTTY_TAILSCALE): tailscale
            // serve takes the port, the link is the Mac's tailnet name over
            // HTTPS, and a page from there may connect (served as 127.0.0.1).
            if let log = ProcessInfo.processInfo.environment["FAKE_TAILSCALE_LOG"] {
                config.webAccess = "tailscale"
                web.apply(config)
                let name = "probe-mac.tail1234.ts.net"
                check("tailscale: listening, named", wait(5) { web.listening && web.tailnetName == name })
                if !web.listening { print("  (not listening: \(web.lastError ?? "no error"))") }
                check("tailscale: the link", web.links == ["https://\(name):\(web.port)/#\(web.token)"])
                let asked = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
                check("tailscale: serve took the port", asked().contains("serve --bg --https=\(web.port) http://127.0.0.1:\(web.port)"))
                let (tailnet, tailnetInbox) = open(web.token, origin: "https://\(name):\(web.port)")
                check("tailscale: a page from the tailnet name connects", wait(5) { tailnetInbox.all().contains { $0["t"] as? String == "hello" } })
                tailnet.cancel()
                let (other, otherInbox) = open(web.token, origin: "https://evil.example")
                check("tailscale: other sites still refused", wait(5) { otherInbox.lock.withLock { otherInbox.closed } } && otherInbox.all().isEmpty)
                other.cancel()
                web.stop()
                check("tailscale: serve let go of the port", wait(5) { asked().contains("serve --https=\(web.port) off") })
            }
            web.stop()
            print(failed.isEmpty ? "web-probe: all passed" : "web-probe failed: \(failed)")
            exit(failed.isEmpty ? 0 : 1)
        } catch {
            print("web-probe: \(error)")
            exit(1)
        }
    }
}
#endif
