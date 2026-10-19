import AppKit
import CPty

/// The task manager block (Tern's): every process with its CPU and memory,
/// the ones under each terminal marked with that pane, details (command
/// line, folder, ports) for the one picked, and Quit / Force Quit. Read
/// through libproc; CPU is how much of one core it used since the last look.
final class TasksBlock: BlockService {
    static let symbol = "gauge.with.dots.needle.33percent"
    weak var host: BlockHost?
    let title = "Tasks"

    /// The last look: each process's start and CPU time (a reused pid is a
    /// new process), the machine's ticks, and when it was taken. Looks run one
    /// at a time (the page's timer, a refresh after Quit, a tab shown again).
    private var previous: [Int32: (started: Int64, cpu: UInt64)] = [:]
    private var previousAt: UInt64 = 0
    private var previousHost: (busy: UInt64, idle: UInt64)?
    private let queue = DispatchQueue(label: "dev.libertty.tasks")

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        switch method {
        case "list":
            // The terminals are the windows' (main thread); the rest is the kernel's.
            let terminals = host?.terminals() ?? []
            queue.async { reply(.success(self.list(terminals: terminals))) }
        case "details":
            guard let pid = (params["pid"] as? Int).flatMap(Int32.init(exactly:)), pid > 0 else { return reply(.failure(BlockError("which process?"))) }
            blockWork(reply) { Self.details(pid) }
        case "signal":
            // The process as listed: its pid and when it started (by now the pid may be another's).
            guard let pid = (params["pid"] as? Int).flatMap(Int32.init(exactly:)), pid > 1, let name = params["signal"] as? String,
                  let signal = ["TERM": SIGTERM, "KILL": SIGKILL, "INT": SIGINT, "STOP": SIGSTOP, "CONT": SIGCONT][name] else {
                return reply(.failure(BlockError("not a process or signal")))
            }
            let started = params["started"] as? Int
            blockWork(reply) { try Self.send(signal, to: pid, started: started.map(Int64.init)); return true }
        case "profile":
            // The profiler, with this process picked.
            guard let pid = params["pid"] as? Int, pid > 1 else { return reply(.failure(BlockError("which process?"))) }
            host?.openFile(Blocks.url("profiler", ["pid": String(pid)]), line: nil)
            reply(.success(true))
        case "reveal":
            guard let pane = params["pane"] as? String else { return reply(.failure(BlockError("which pane?"))) }
            host?.reveal(paneID: pane)
            reply(.success(true))
        case "openPort":
            guard let port = params["port"] as? Int, (1...65535).contains(port), let url = URL(string: "http://localhost:\(port)") else {
                return reply(.failure(BlockError("not a port")))
            }
            host?.openBrowser(url)
            reply(.success(true))
        case "openFolder":
            // Shown in Finder, never opened: a folder that's an app or a package would run.
            var isFolder: ObjCBool = false
            guard let path = params["path"] as? String, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return reply(.failure(BlockError("not a folder")))
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            reply(.success(true))
        default:
            reply(.failure(BlockError("unknown call \(method)")))
        }
    }

    private func list(terminals: [BlockTerminal]) -> [String: Any] {
        let cap = 8192
        var buffer = [libertty_proc](repeating: libertty_proc(), count: cap)
        let n = Int(libertty_proc_snapshot(&buffer, Int32(cap)))
        let now = DispatchTime.now().uptimeNanoseconds
        let earlier = previous, earlierAt = previousAt
        var seen: [Int32: (started: Int64, cpu: UInt64)] = [:]
        let me = getuid()
        // Which terminal each process is under: walk up its parents to a shell.
        var parent: [Int32: Int32] = [:]
        for i in 0..<n { parent[buffer[i].pid] = buffer[i].ppid }
        let shells = Dictionary(terminals.map { ($0.shell, $0) }, uniquingKeysWith: { a, _ in a })
        func terminal(of pid: Int32) -> BlockTerminal? {
            var p = pid, steps = 0
            while p > 1, steps < 64 {
                if let t = shells[p] { return t }
                guard let up = parent[p], up != p else { return nil }
                p = up
                steps += 1
            }
            return nil
        }
        let elapsed = earlierAt > 0 && now > earlierAt ? Double(now - earlierAt) : 0
        var rows: [[String: Any]] = []
        rows.reserveCapacity(n)
        for i in 0..<n {
            var p = buffer[i]
            let name = withUnsafePointer(to: &p.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            // Another user's process: no CPU or memory to read (nil, not 0).
            var cpu: Double? = nil
            if p.known != 0 {
                seen[p.pid] = (p.started, p.cpu_ns)
                cpu = 0
                if elapsed > 0, let before = earlier[p.pid], before.started == p.started, p.cpu_ns >= before.cpu {
                    cpu = Double(p.cpu_ns - before.cpu) / elapsed * 100
                }
            }
            var row: [String: Any] = [
                "pid": Int(p.pid), "ppid": Int(p.ppid), "name": name, "mine": p.uid == me, "known": p.known != 0,
                "cpu": cpu.map { ($0 * 10).rounded() / 10 } as Any? ?? NSNull(), "mem": Int(p.rss), "threads": Int(p.threads),
                "started": Int(p.started), "state": String(UnicodeScalar(UInt8(bitPattern: p.state))),
            ]
            if let t = terminal(of: p.pid) {
                row["pane"] = t.paneID
                row["terminal"] = t.name
                row["shell"] = t.shell == p.pid
            }
            rows.append(row)
        }
        // The machine's load from its own counters: every process, root's too.
        var busy: UInt64 = 0, idle: UInt64 = 0
        var machine = 0.0
        if libertty_host_cpu(&busy, &idle) != 0 {
            if let before = previousHost, busy >= before.busy, idle >= before.idle, busy + idle > before.busy + before.idle {
                machine = Double(busy - before.busy) / Double(busy - before.busy + idle - before.idle) * 100
            }
            previousHost = (busy, idle)
        }
        previous = seen
        previousAt = now
        return [
            "processes": rows, "cores": ProcessInfo.processInfo.activeProcessorCount,
            "memory": Int(ProcessInfo.processInfo.physicalMemory), "load": (machine * 10).rounded() / 10,
            "first": elapsed == 0, "self": Int(getpid()),
        ]
    }

    /// The command line, folder, listening ports and path of one process.
    private static func details(_ pid: Int32) -> [String: Any] {
        var argv = [CChar](repeating: 0, count: 4096)
        libertty_proc_argv(pid, &argv, Int32(argv.count))
        var cwd = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        libertty_proc_cwd(pid, &cwd, Int32(cwd.count))
        var ports = [UInt16](repeating: 0, count: 64)
        let count = Int(libertty_proc_listening_ports(pid, &ports, 64))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        // The command as typed: its name, then the arguments (argv[0] is left out of those).
        var name = [CChar](repeating: 0, count: 256)
        libertty_proc_name(pid, &name, 256)
        let arguments = String(cString: argv)
        return [
            "pid": Int(pid),
            "command": arguments.isEmpty ? String(cString: name) : String(cString: name) + " " + arguments,
            "cwd": String(cString: cwd),
            "ports": ports.prefix(count).map { Int($0) }.sorted(),
            "path": pathLength > 0 ? String(cString: path) : "",
        ]
    }

    /// Only to one's own processes, and never to Libertty or its session server
    /// (quitting them from here would take every terminal along).
    private static func send(_ signal: Int32, to pid: Int32, started: Int64?) throws {
        var info = proc_bsdshortinfo()
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 else {
            throw BlockError("That process has ended.")
        }
        guard info.pbsi_uid == getuid() else { throw BlockError("That process isn't yours.") }
        var seconds: Int64 = 0, micro: Int64 = 0
        if let started, libertty_proc_started(pid, &seconds, &micro) == 0 || seconds != started {
            throw BlockError("That process has ended (its number is another's now).")
        }
        guard pid != getpid() else { throw BlockError("That's Libertty itself.") }
        var name = [CChar](repeating: 0, count: 256)
        libertty_proc_name(pid, &name, 256)
        if String(cString: name) == "liberttyd" { throw BlockError("That's liberttyd: every terminal's programs run in it.") }
        guard kill(pid, signal) == 0 else { throw BlockError(String(cString: strerror(errno))) }
    }
}
