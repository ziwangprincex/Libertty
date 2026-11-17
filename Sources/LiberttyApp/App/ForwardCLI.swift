import Foundation
import LiberttyCore

/// `libertty +forward`: carry a port between this Mac and a host Libertty is
/// connected to (the same forwards the palette's Forward Port page makes and
/// Settings ▸ Remote Hosts lists).
///   +forward open TARGET     a port on the host, reachable here; TARGET is a
///                            port, a host:port the host can reach, or a URL
///   +forward share PORT      a port on this Mac, reachable there
///   +forward ls              what's forwarded now
///   +forward close ID|--all
/// `--host HOST` says which host (the CLI takes it off the line); without it,
/// the host the pane this runs in is on. The running Libertty holds the
/// forwards — it closes them when a host's last window goes — so these ask
/// it to act, and print what it answers.
enum ForwardCLI {
    static func run(_ args: [String]) -> Int32 {
        let sub = args.first ?? "ls"
        var rest = Array(args.dropFirst()), all = false, browser = false
        rest.removeAll {
            if $0 == "--all" { all = true; return true }
            if $0 == "--browser" { browser = true; return true }
            return false
        }
        if let unknown = rest.first(where: { $0.hasPrefix("--") }) {
            return fail("unknown option \(unknown)", CLI.ExitCode.usage)
        }
        switch sub {
        case "ls":
            guard rest.isEmpty else { return usage() }
            return ask(["op": "ls"])
        case "open":
            guard rest.count == 1, let target = rest.first else { return usage() }
            guard PortForward.target(target) != nil else {
                return fail("not a port, host:port or URL: \(target)", CLI.ExitCode.usage)
            }
            return ask(["op": "open", "target": target, "browser": browser ? "1" : "0"])
        case "share":
            guard rest.count == 1, let text = rest.first else { return usage() }
            guard let port = Int(text), (1...65535).contains(port) else {
                return fail("share takes a port of this Mac's, 1 to 65535", CLI.ExitCode.usage)
            }
            return ask(["op": "share", "target": String(port)])
        case "close":
            guard all ? rest.isEmpty : rest.count == 1 else { return usage() }
            return ask(["op": "close", "target": all ? "" : (rest.first ?? ""), "all": all ? "1" : "0"])
        default:
            return usage()
        }
    }

    /// Ask the running Libertty, and say what it answered.
    private static func ask(_ request: [String: String]) -> Int32 {
        guard CLI.liberttyRunning else { return fail("Libertty isn't running", CLI.ExitCode.unreachable) }
        var info = request
        info["kind"] = "forward"
        info["host"] = CLI.host?.destination ?? ""
        // Which pane this runs in, so Libertty knows whose host to use.
        info["session"] = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"] ?? ""
        // Listing is answered at once; making or closing one runs ssh over
        // the host's connection first, which takes a moment.
        let answer = RemoteControl.request(info, timeout: request["op"] == "ls" ? 5 : 20)
        switch answer?["result"] {
        case "ok":
            let text = answer?["message"] ?? ""
            if !text.isEmpty { print(text) }
            return CLI.ExitCode.ok
        case "no-host":
            return fail("no host: run this in a pane on one, or give --host HOST", CLI.ExitCode.usage)
        case "not-connected":
            return fail(answer?["message"] ?? "that host isn't connected", CLI.ExitCode.unreachable)
        case "no-forward":
            return fail(answer?["message"] ?? "no such forward (libertty +forward ls)", CLI.ExitCode.notFound)
        case "refused":
            return fail(answer?["message"] ?? RemoteControlPolicy.message, CLI.ExitCode.failure)
        case "error":
            return fail(answer?["message"] ?? "it couldn't be forwarded", CLI.ExitCode.failure)
        default:
            return fail("Libertty didn't answer (one older than this command?)", CLI.ExitCode.unreachable)
        }
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("libertty: \(message)\n".utf8))
        return status
    }

    private static func usage() -> Int32 {
        fail("usage: libertty +forward open TARGET | share PORT | ls | close ID|--all  [--host HOST]", CLI.ExitCode.usage)
    }
}
