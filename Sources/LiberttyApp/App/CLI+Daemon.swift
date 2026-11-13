import AppKit
import LiberttyCore

/// `libertty +daemon status|stop|restart|logs` and `+clients`: liberttyd
/// itself, this Mac's or (with --host) another machine's.
extension CLI {
    static func daemonCommand(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +daemon status [--json] | stop [--if-idle | --force] | restart | logs [-f] [--lines N]"
        let words = args.filter { !$0.hasPrefix("-") }
        guard let sub = words.first else { fail(usage); return ExitCode.usage }
        switch sub {
        case "status":
            guard args.allSatisfy({ $0 == sub || $0 == "--json" }) else { fail(usage); return ExitCode.usage }
            return daemonStatus(json: args.contains("--json"))
        case "stop":
            guard args.allSatisfy({ [sub, "--if-idle", "--force"].contains($0) }),
                  !(args.contains("--if-idle") && args.contains("--force")) else { fail(usage); return ExitCode.usage }
            return stopDaemon(ifIdle: args.contains("--if-idle"), force: args.contains("--force"))
        case "restart":
            guard args == [sub] else { fail(usage); return ExitCode.usage }
            return restartDaemon()
        case "logs":
            var lines = 50, follow = false
            let rest = args.filter { $0 != sub }
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "-f", "--follow": follow = true
                case "--lines", "-n":
                    guard i + 1 < rest.count, let n = Int(rest[i + 1]), n >= 0 else { fail(usage); return ExitCode.usage }
                    lines = n
                    i += 1
                default: fail(usage); return ExitCode.usage
                }
                i += 1
            }
            return daemonLogs(lines: lines, follow: follow)
        default:
            fail(usage)
            return ExitCode.usage
        }
    }

    private static var whereDaemon: String { host.map { " on \($0.destination)" } ?? "" }

    // MARK: status

    private static func daemonStatus(json: Bool) -> Int32 {
        var info: [String: Any]
        switch DaemonClient.request(.info, needing: "admin", address: daemon) {
        case .answered(let frame):
            info = frame.json
        case .unsupported:
            // An older liberttyd: what its welcome and its list say.
            guard let welcome = DaemonClient.hello(address: daemon) else { return notRunning(json: json) }
            let sessions = DaemonClient.sessions(address: daemon) ?? []
            info = ["version": welcome.version, "build": welcome.build, "pid": Int(welcome.pid), "features": welcome.features,
                    "sessions": sessions.count, "shown": sessions.filter { $0.clients > 0 }.count, "old": true]
        case .unanswered:
            return notRunning(json: json)
        }
        info["ok"] = nil
        if let host { info["host"] = host.destination }
        if json {
            let data = (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return ExitCode.ok
        }
        let pid = info["pid"] as? Int ?? 0
        print("liberttyd \(pid)\(whereDaemon)  build \(info["build"] as? String ?? "?"), protocol \(info["version"] as? Int ?? 0)")
        func row(_ name: String, _ value: String) { print("  " + name.padding(toLength: 10, withPad: " ", startingAt: 0) + value) }
        if let socket = info["socket"] as? String { row("socket", tilde(socket)) }
        if let log = info["log"] as? String { row("log", tilde(log)) }
        if let started = info["started"] as? Double {
            let since = Date(timeIntervalSince1970: started)
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd HH:mm"
            row("running", "since \(format.string(from: since)) (\(duration(Date().timeIntervalSince(since))))")
        }
        let sessions = info["sessions"] as? Int ?? 0, shown = info["shown"] as? Int ?? 0
        row("sessions", sessions == 0 ? "none" : "\(sessions) (\(shown) shown, \(sessions - shown) detached)")
        if let clients = info["clients"] as? Int { row("clients", "\(clients) (libertty +clients)") }
        if info["old"] as? Bool == true {
            print("  (an older liberttyd: restart Libertty, or libertty +daemon restart, to update it)")
        }
        return ExitCode.ok
    }

    private static func notRunning(json: Bool) -> Int32 {
        if json {
            var info: [String: Any] = ["running": false]
            if let host { info["host"] = host.destination }
            let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
        } else if let host {
            fail("can't reach liberttyd on \(host.destination)"
                 + ((host.lastError as? LocalizedError)?.errorDescription.map { ": " + $0 } ?? ""))
        } else {
            print("liberttyd isn't running (\(tilde(Wire.socketPath)))")
        }
        return ExitCode.unreachable
    }

    // MARK: stop

    /// Without --force it ends no program: with sessions it refuses (or,
    /// --if-idle, leaves liberttyd running and says so).
    private static func stopDaemon(ifIdle: Bool, force: Bool) -> Int32 {
        guard let welcome = DaemonClient.hello(address: daemon) else {
            print("liberttyd\(whereDaemon) isn't running")
            return ExitCode.ok
        }
        // The sessions that keep it running, or nil once it's told to stop.
        var kept: Int?
        if force {
            guard DaemonClient.request(.shutdown, address: daemon) != nil else { return noAnswer() }
        } else if welcome.features.contains("admin") {
            // liberttyd decides, so no session starts between a look and the stop.
            guard let frame = DaemonClient.request(.shutdown, json: ["ifIdle": true], address: daemon) else { return noAnswer() }
            if frame.json["ok"] as? Bool == false { kept = frame.json["sessions"] as? Int ?? 0 }
        } else {
            // An older one stops whatever it has: look first.
            let count = DaemonClient.sessions(address: daemon)?.count ?? 0
            if count > 0 {
                kept = count
            } else if DaemonClient.request(.shutdown, address: daemon) == nil {
                return noAnswer()
            }
        }
        if let count = kept {
            if ifIdle {
                print("liberttyd\(whereDaemon) has \(count) session\(count == 1 ? "" : "s"); left running")
                return ExitCode.ok
            }
            fail("liberttyd\(whereDaemon) has \(count) session\(count == 1 ? "" : "s"): --force ends them, "
                 + "--if-idle stops it only once there are none")
            return ExitCode.failure
        }
        // Gone once nothing answers on the socket any more (or another one does).
        var tries = 0
        while tries < 40, DaemonClient.hello(timeout: 0.25, address: daemon)?.pid == welcome.pid {
            usleep(50_000)
            tries += 1
        }
        print("stopped liberttyd \(welcome.pid)\(whereDaemon)")
        return ExitCode.ok
    }

    private static func noAnswer() -> Int32 {
        fail("liberttyd\(whereDaemon) didn't answer")
        return ExitCode.unreachable
    }

    // MARK: restart

    /// A new liberttyd takes every session over, as an update's does: the
    /// programs keep running, windows reconnect.
    private static func restartDaemon() -> Int32 {
        guard let old = DaemonClient.hello(address: daemon) else {
            fail("liberttyd\(whereDaemon) isn't running")
            return ExitCode.unreachable
        }
        var new: pid_t?
        switch DaemonClient.request(.restart, needing: "admin", address: daemon) {
        case .answered(let frame):
            guard frame.json["ok"] as? Bool == true, let pid = frame.json["pid"] as? Int else {
                fail(frame.json["error"] as? String ?? "liberttyd\(whereDaemon) couldn't restart")
                return ExitCode.failure
            }
            // Up once it answers in the old one's place.
            for _ in 0..<150 {
                if let w = DaemonClient.hello(timeout: 0.5, address: daemon), w.pid == pid_t(pid) { new = w.pid; break }
                usleep(100_000)
            }
        case .unsupported:
            // Too old to restart itself: this Libertty's liberttyd takes over (as at its launch).
            guard host == nil, let exe = Persistence.daemonExecutable else {
                fail("this liberttyd can't restart itself; connecting from an updated Libertty replaces it")
                return ExitCode.failure
            }
            new = DaemonClient.replace(executable: exe, logPath: Persistence.logPath)
        case .unanswered:
            fail("liberttyd\(whereDaemon) didn't answer")
            return ExitCode.unreachable
        }
        guard let new else {
            fail("the new liberttyd\(whereDaemon) didn't come up (see libertty +daemon logs)")
            return ExitCode.failure
        }
        let count = DaemonClient.sessions(address: daemon)?.count ?? 0
        print("liberttyd \(old.pid) → \(new)\(whereDaemon): \(count) session\(count == 1 ? "" : "s") kept")
        return ExitCode.ok
    }

    // MARK: logs

    /// Its log's last `lines` lines; -f then prints what's added until ^C.
    /// liberttyd says where it writes; without one (not running, older),
    /// this Mac's log file is read directly.
    private static func daemonLogs(lines: Int, follow: Bool) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var offset: Int
        var path: String
        if let (text, end, at) = logChunk(from: nil, lines: lines) {
            print(text, terminator: "")
            (offset, path) = (end, at)
        } else {
            if let host {
                fail("can't read liberttyd's log on \(host.destination) (it isn't running, or it's older)")
                return ExitCode.unreachable
            }
            guard let (text, end) = DaemonServer.readLog(Persistence.logPath, from: nil, lines: lines) else {
                fail("no log at \(tilde(Persistence.logPath))")
                return ExitCode.failure
            }
            print(text, terminator: "")
            (offset, path) = (end, Persistence.logPath)
        }
        guard follow else { return ExitCode.ok }
        while true {
            usleep(500_000)
            if var chunk = logChunk(from: offset, lines: nil) {
                // Another file (a liberttyd that started since, after the log
                // was moved aside): from its beginning.
                if chunk.2 != path, let fresh = logChunk(from: 0, lines: nil) { chunk = fresh }
                print(chunk.0, terminator: "")
                (offset, path) = (chunk.1, chunk.2)
            } else if host == nil, let (text, end) = DaemonServer.readLog(path, from: offset, lines: nil) {
                // No liberttyd (between a stop and a start): the file itself.
                print(text, terminator: "")
                offset = end
            }
        }
    }

    /// One `log` answer: its text, where it ends, and the file it's from.
    private static func logChunk(from: Int?, lines: Int?) -> (String, Int, String)? {
        var request: [String: Any] = [:]
        if let from { request["from"] = from }
        if let lines { request["lines"] = lines }
        guard case .answered(let frame) = DaemonClient.request(.log, json: request, needing: "admin", address: daemon),
              frame.json["ok"] as? Bool == true, let text = frame.json["text"] as? String,
              let end = frame.json["end"] as? Int, let path = frame.json["path"] as? String else { return nil }
        return (text, end, path)
    }

    // MARK: clients

    /// `+clients [--json]`: who is connected to liberttyd, by process.
    static func clients(_ args: [String]) -> Int32 {
        guard args.allSatisfy({ $0 == "--json" }) else { fail("usage: libertty +clients [--json]"); return ExitCode.usage }
        let list: [ConnectedClient]
        switch DaemonClient.request(.clients, needing: "admin", address: daemon) {
        case .answered(let frame):
            struct Answer: Decodable { var clients: [ConnectedClient] }
            guard let answer = frame.decode(Answer.self) else { fail("liberttyd's answer made no sense"); return ExitCode.failure }
            list = answer.clients
        case .unsupported:
            fail("this liberttyd doesn't say who is connected; restart Libertty (or libertty +daemon restart) to update it")
            return ExitCode.failure
        case .unanswered:
            return notRunning(json: false)
        }
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: (try? encoder.encode(list)) ?? Data("[]".utf8), as: UTF8.self))
            return ExitCode.ok
        }
        guard !list.isEmpty else {
            print("nothing else is connected to liberttyd\(whereDaemon)")
            return ExitCode.ok
        }
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        // One line per process: a window has a connection per session it shows.
        var order: [Int32] = []
        var byProcess: [Int32: [ConnectedClient]] = [:]
        for c in list {
            if byProcess[c.pid] == nil { order.append(c.pid) }
            byProcess[c.pid, default: []].append(c)
        }
        for pid in order {
            let group = byProcess[pid] ?? []
            guard let first = group.first else { continue }
            let shown = group.compactMap(\.session)
            var what: [String] = []
            if !shown.isEmpty { what.append("shows " + shown.joined(separator: " ")) }
            if group.contains(where: \.listening) { what.append("follows events") }
            let waited = group.flatMap(\.waiting)
            if !waited.isEmpty { what.append("waits on " + waited.joined(separator: " ")) }
            if what.isEmpty { what.append("connected") }
            let name = describe(first)
            let since = format.string(from: Date(timeIntervalSince1970: group.map(\.since).min() ?? first.since))
            print(name.padding(toLength: max(16, name.count), withPad: " ", startingAt: 0) + "  "
                  + (pid > 0 ? "pid \(pid)" : "pid ?").padding(toLength: 10, withPad: " ", startingAt: 0)
                  + "since \(since)  " + what.joined(separator: "; "))
        }
        return ExitCode.ok
    }

    /// Who it is: the app's windows, the command line, a Mac through ssh.
    private static func describe(_ c: ConnectedClient) -> String {
        if let client = c.client { return client.hasPrefix("cli ") ? "libertty " + client.dropFirst(4) : client }
        switch c.process {
        case "liberttyd": return "ssh bridge (a Mac)"
        case "Libertty": return c.session != nil ? "Libertty" : "libertty"
        case "": return "?"
        default: return c.process
        }
    }

    private static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}
