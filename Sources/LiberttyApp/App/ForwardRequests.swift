import AppKit

/// What `libertty +forward` asks of the running Libertty (`RemoteControl`
/// kind "forward"), beside `PaneRequests`: which host the forward is on —
/// the one `--host` named, or the one the pane the command ran in is on —
/// and the forwards themselves.
///
/// ssh runs off the main thread, so an answer to a request that makes or
/// closes a forward comes back a moment later.
enum ForwardRequests {
    /// Handled (it was a forward request); false leaves `info` to the caller.
    static func handle(_ info: [String: String], in controllers: [TerminalWindowController]) -> Bool {
        guard info["kind"] == "forward" else { return false }
        let named = info["host"] ?? ""
        switch info["op"] ?? "ls" {
        case "ls":
            // Without a host, every forward Libertty holds.
            let list = named.isEmpty ? PortForwarder.shared.all : PortForwarder.shared.forwards(on: named)
            answer(info, "ok", list.map { "\($0.id)\t\($0.direction.rawValue)\t\($0.summary)" }.joined(separator: "\n"))
        case "close":
            close(info, named: named)
        case let op:
            guard let host = host(info, named: named, in: controllers) else {
                answer(info, "no-host", "")
                return true
            }
            make(info, op: op, on: host)
        }
        return true
    }

    /// The host to act on: the one `--host` named, else the one the pane
    /// running the command is on (a local pane has none to forward from).
    private static func host(_ info: [String: String], named: String,
                             in controllers: [TerminalWindowController]) -> RemoteHost? {
        if !named.isEmpty { return RemoteHost.named(named) }
        guard let session = info["session"], !session.isEmpty else { return nil }
        for controller in controllers where controller.pane(showing: session) != nil {
            if let host = controller.host { return host }
        }
        return nil
    }

    private static func make(_ info: [String: String], op: String, on host: RemoteHost) {
        let target = info["target"] ?? "", browser = info["browser"] == "1"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch op {
                case "open":
                    let (forward, url) = try PortForwarder.shared.open(target: target, on: host)
                    if browser, let url { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                    answer(info, "ok", url?.absoluteString ?? "127.0.0.1:\(forward.local)")
                case "share":
                    guard let port = Int(target) else { return answer(info, "error", "\(target) isn't a port number") }
                    let forward = try PortForwarder.shared.share(local: port, on: host)
                    answer(info, "ok", forward.summary)
                default:
                    answer(info, "error", "libertty +forward can't \(op)")
                }
            } catch PortForwarder.Failure.notConnected(let destination) {
                answer(info, "not-connected", "Libertty isn't connected to \(destination): connect to it first")
            } catch {
                answer(info, "error", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private static func close(_ info: [String: String], named: String) {
        let all = info["all"] == "1", id = info["target"] ?? ""
        // What it would close, before the ssh calls: so a name that matches
        // nothing is answered as such and not as "closed".
        let held = named.isEmpty ? PortForwarder.shared.all : PortForwarder.shared.forwards(on: named)
        let closing = all ? held : held.filter { $0.id == id }
        guard !closing.isEmpty else {
            return answer(info, all ? "ok" : "no-forward", all ? "" : "no forward \(id) (libertty +forward ls)")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if all {
                PortForwarder.shared.closeAll(on: named.isEmpty ? nil : named)
            } else {
                _ = PortForwarder.shared.close(id: id)
            }
            answer(info, "ok", closing.map { "closed \($0.id)" }.joined(separator: "\n"))
        }
    }

    /// Answered on the main thread, whichever one did the work.
    private static func answer(_ info: [String: String], _ result: String, _ message: String) {
        DispatchQueue.main.async { RemoteControl.answer(info, ["result": result, "message": message]) }
    }
}
