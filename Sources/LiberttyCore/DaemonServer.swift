import CGhosttyVt
import CPty
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import Dispatch
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif

/// liberttyd: holds every session's pty and a headless libghostty-vt terminal
/// fed with the same output, so windows can close and come back (the app
/// quits, crashes, or updates) while programs keep running.
///
/// Attaching sends a snapshot of the terminal (screen, scrollback, modes,
/// even an unfinished escape sequence), then the live output. The window
/// keeps its own replica for rendering and answers the program's queries;
/// liberttyd answers them itself only while no window is attached.
///
/// A newer liberttyd takes over from an older one without ending anything: the
/// old one hands each pty master (SCM_RIGHTS) and snapshot over and exits.
public final class DaemonServer {
    public static func main(_ arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let executable = currentExecutablePath() ?? arguments[0]
        if arguments.contains("--version") {
            print("liberttyd protocol \(Wire.version) build \(buildID(ofExecutable: executable))")
            exit(0)
        }
        // Run by Libertty through ssh on another machine: make sure a liberttyd
        // serves this user (`--ensure`), or carry one connection to it over
        // stdin and stdout (`--bridge`).
        if arguments.contains("--ensure") || arguments.contains("--bridge") {
            let env = ProcessInfo.processInfo.environment
            let home = env["LIBERTTY_HOME"] ?? userHomeDirectory().appendingPath(".libertty")
            let log = env["LIBERTTY_DAEMON_LOG"] ?? home.appendingPath("liberttyd.log")
            guard DaemonClient.ensureRunning(executable: executable, logPath: log, responsible: false) else {
                writeError("liberttyd: couldn't start (see \(log))\n")
                exit(1)
            }
            if arguments.contains("--ensure") {
                print("socket=\(Wire.socketPath)")
                exit(0)
            }
            let fd = libertty_sock_connect(Wire.socketPath)
            guard fd >= 0 else { exit(1) }
            exit(libertty_bridge(STDIN_FILENO, STDOUT_FILENO, fd) == 0 ? 0 : 1)
        }
        let path = Wire.socketPath
        Wire.prepareDirectory(for: path)
        let server = DaemonServer(path: path)
        // One liberttyd per socket: whoever holds the lock owns the path.
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if arguments.contains("--takeover") {
            server.takeOver()
            // The old liberttyd releases the lock as it exits.
            var tries = 0
            while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                tries += 1
                if tries > 500 { log("takeover: the old liberttyd still holds the lock"); exit(1) }
                usleep(10_000)
            }
        } else if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            log("another liberttyd serves \(path)")
            exit(0)
        }
        server.serve()
    }

    /// Identifies this liberttyd's build: the executable's size and modification
    /// time. The app compares it with the liberttyd it ships to decide on a takeover.
    public static func buildID(ofExecutable path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "unknown" }
        #if os(Linux)
        return "\(st.st_size)-\(st.st_mtim.tv_sec)"
        #else
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec)"
        #endif
    }

    private let path: String
    private let build: String
    private let lock = NSLock()
    private var sessions: [String: DaemonSession] = [:]
    private var connections = 0
    private var listener: Int32 = -1
    private var exitTimer: DispatchSourceTimer?
    private var handingOver = false
    /// The window layouts the app keeps here (`storeLayout`), opaque, one per
    /// Mac and kind: `local`, a Mac's own windows in its own liberttyd; else
    /// the windows a Mac shows this host's sessions in. A Mac gets its own
    /// back; one with none for this host gets the latest any Mac stored —
    /// never a Mac's own windows, which are its user's, on its screen.
    private var layouts: [String: Layout] = [:]
    private struct Layout {
        var client: String
        var local: Bool
        var data: Data
        var at: Double
    }
    private static func layoutKey(_ client: String, local: Bool) -> String { local ? "local:" + client : client }
    /// The newest so many, each at most so big (a layout is a few KB): all of
    /// them fit in the one frame a takeover carries them in.
    private static let maxLayouts = 32, maxLayoutBytes = 1 << 20

    /// What this liberttyd does beyond protocol 1's beginnings, in `welcome`:
    /// an app asks before it relies on any of it (an older liberttyd drops a
    /// request it doesn't know without a word).
    static let features = ["layout", "catchUp", "waitUntil", "events", "label", "inputMode", "sendKey", "report", "permissions",
                           "agentScreen", "foreground", "upload"]

    private init(path: String) {
        self.path = path
        build = Self.buildID(ofExecutable: currentExecutablePath() ?? CommandLine.arguments[0])
    }

    static func log(_ message: String) {
        let stamp = utcTimestamp()
        writeError("\(stamp) liberttyd[\(getpid())] \(message)\n")
    }

    // MARK: Serving

    /// The socket file it made (device, inode): what it removes as it goes.
    private var bound: (dev_t, ino_t)?

    /// Its socket file, gone with it — only if the path is still its own: one
    /// removed under it (its folder cleaned, a test starting over) may hold
    /// another liberttyd's by now, which must stay reachable.
    private func removeOwnSocket() {
        var st = stat()
        guard let bound, stat(path, &st) == 0, st.st_dev == bound.0, st.st_ino == bound.1 else { return }
        unlink(path)
    }

    private func serve() -> Never {
        listener = libertty_sock_listen(path)
        guard listener >= 0 else {
            Self.log("can't listen on \(path): \(String(cString: strerror(errno)))")
            exit(1)
        }
        var st = stat()
        if stat(path, &st) == 0 { bound = (st.st_dev, st.st_ino) }
        Self.log("listening on \(path) (build \(build), \(sessions.count) sessions)")
        scheduleExitIfIdle()
        keepFilesFresh()
        while true {
            let fd = libertty_sock_accept(listener)
            if fd < 0 {
                if errno == EPERM || errno == ECONNABORTED || errno == EINTR { continue }
                lock.lock()
                let over = handingOver
                lock.unlock()
                if over { Thread.sleep(forTimeInterval: 3600) }  // the takeover thread exits the process
                Self.log("accept failed: \(String(cString: strerror(errno)))")
                exit(1)
            }
            let connection = Connection(fd: fd)
            lock.lock()
            connections += 1
            exitTimer?.cancel()
            exitTimer = nil
            lock.unlock()
            let thread = Thread { [self] in
                handle(connection)
                lock.lock()
                connections -= 1
                lock.unlock()
                scheduleExitIfIdle()
            }
            thread.name = "liberttyd.connection"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// /tmp cleaners (systemd-tmpfiles) delete files untouched for days:
    /// touch the socket and its lock now and then.
    private func keepFilesFresh() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { [path] in
            for file in [path, path + ".lock"] { utimes(file, nil) }
        }
        timer.resume()
        freshness = timer
    }

    private var freshness: DispatchSourceTimer?

    /// Nothing to keep and nobody connected: go away after a grace period
    /// (a window about to open shouldn't pay for a cold start).
    private func scheduleExitIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard sessions.isEmpty, connections == 0, exitTimer == nil, !handingOver else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10)
        timer.setEventHandler { [self] in
            lock.lock()
            let idle = sessions.isEmpty && connections == 0 && !handingOver
            lock.unlock()
            guard idle else { return }
            Self.log("idle, exiting")
            removeOwnSocket()
            exit(0)
        }
        exitTimer = timer
        timer.resume()
    }

    private func session(_ id: String) -> DaemonSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    private func register(_ session: DaemonSession) {
        session.onEnd = { [weak self] ended in
            guard let self else { return }
            self.lock.lock()
            if self.sessions[ended.id] === ended { self.sessions[ended.id] = nil }
            self.lock.unlock()
            self.scheduleExitIfIdle()
        }
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
        DaemonEvents.shared.publish("session-started", session: session.id, ["command": session.command])
    }

    private func handle(_ connection: Connection) {
        connection.setSendTimeout(10)
        connection.setBufferSizes(1 << 21)
        var bound: DaemonSession?
        // `+wait` and `+events` askers that hang up stop being told.
        var waitedOn: [DaemonSession] = []
        var listener: DaemonEvents.Listener?
        defer {
            bound?.detach(connection)
            waitedOn.forEach { $0.dropWaiters(connection) }
            if let listener { DaemonEvents.shared.stop(listener) }
        }
        func fail(_ message: String) { connection.send(.result, json: ["ok": false, "error": message]) }

        while let frame = connection.receive() {
            switch frame.kind {
            case .hello:
                connection.send(.welcome, json: ["version": Wire.version, "build": build, "pid": Int(getpid()),
                                                 "features": Self.features])
            case .create:
                guard bound == nil, let request = frame.decode(CreateRequest.self) else { fail("bad create"); continue }
                guard session(request.id) == nil else { fail("session \(request.id) exists"); continue }
                do {
                    let s = try DaemonSession(request: request)
                    register(s)
                    s.attach(connection, sendSnapshot: false, catchUp: request.catchUp ?? false)
                    bound = s
                } catch {
                    fail("can't start \(request.executable): \(error)")
                }
            case .attach:
                guard bound == nil, let id = frame.json["id"] as? String else { fail("bad attach"); continue }
                guard let s = session(id) else { fail("no session \(id)"); continue }
                s.attach(connection, sendSnapshot: true, catchUp: frame.json["catchUp"] as? Bool ?? false)
                bound = s
            case .input:
                bound?.write(frame.payload, from: connection)
            case .reply:
                bound?.reply(frame.payload, from: connection)
            case .clear:
                bound?.requestClear(atPrompt: frame.json["atPrompt"] as? Bool ?? true)
            case .resize:
                guard frame.payload.count == 8 else { continue }
                let v = frame.payload.withUnsafeBytes { raw in (0..<4).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) } }
                bound?.resize(GridSize(cols: v[0], rows: v[1], widthPx: v[2], heightPx: v[3]), from: connection)
            case .kill:
                if let id = frame.json["id"] as? String {
                    guard let s = session(id) else { fail("no session \(id)"); continue }
                    s.terminate()
                    connection.send(.result, json: ["ok": true])
                } else {
                    // A pane closing: the program ends unless another window shows it.
                    bound?.close(from: connection)
                }
            case .list:
                lock.lock()
                let all = sessions.values.sorted { $0.created < $1.created }
                lock.unlock()
                let infos = all.map { $0.info() }
                let data = (try? JSONEncoder().encode(["sessions": infos])) ?? Data()
                connection.send(.result, data)
            case .capture:
                let json = frame.json
                guard let id = json["id"] as? String, let s = session(id) else { fail("no such session"); continue }
                // `format` is newer than capture: an older app asks for plain text by leaving it out.
                let format = (json["format"] as? String).flatMap(Snapshots.TextFormat.init) ?? .plain
                connection.send(.result, json: ["ok": true, "format": format.rawValue,
                                                "text": s.capture(scrollback: json["scrollback"] as? Bool ?? false, format: format)])
            case .sendKey:
                let json = frame.json
                guard let id = json["id"] as? String, let s = session(id) else { fail("no such session"); continue }
                let names = json["keys"] as? [String] ?? []
                let keys = names.map(KeySpec.init)
                if let bad = zip(names, keys).first(where: { $0.1 == nil })?.0 { fail("unknown key \(bad)"); continue }
                if let silent = s.press(keys.compactMap { $0 }) {
                    fail("\(names[silent]) sends nothing to this program; no keys sent")
                    continue
                }
                connection.send(.result, json: ["ok": true])
            case .report:
                // What the app reads on an agent's screen (it has the rules): a
                // `status` event as an OSC 7501 report's, for `+events --for`.
                let json = frame.json
                guard let id = json["id"] as? String, session(id) != nil else { fail("no such session"); continue }
                let states: Set<String> = ["idle", "working", "blocked", "done", "error", "clear"]
                guard let state = json["state"] as? String, states.contains(state) else { fail("no such state"); continue }
                DaemonEvents.shared.publish("status", session: id, [
                    "state": state, "record": json["record"] as? String ?? "", "app": json["app"] as? String ?? "",
                    "message": "", "title": "", "source": "screen",
                ])
                connection.send(.result, json: ["ok": true])
            case .upload:
                // A file a window pastes or drops on a pane here (another machine's, usually).
                guard let (header, body) = frame.headerAndBody, let batch = header["batch"] as? String,
                      let path = header["path"] as? String else { fail("bad upload"); continue }
                do {
                    connection.send(.result, json: ["ok": true, "path": try Uploads.store(body, batch: batch, relativePath: path)])
                } catch {
                    fail("\(error)")
                }
            case .permissions:
                // What macOS lets it (and so its sessions' programs) get at.
                connection.send(.result, json: ["ok": true, "access": PrivacyAccess.report()])
            case .rename:
                let json = frame.json
                guard let id = json["id"] as? String, let s = session(id) else { fail("no such session"); continue }
                s.rename(json["label"] as? String ?? "")
                connection.send(.result, json: ["ok": true, "label": s.label])
            case .send:
                let json = frame.json
                guard let id = json["id"] as? String, let s = session(id) else { fail("no such session"); continue }
                s.write(Data((json["text"] as? String ?? "").utf8), from: nil)
                connection.send(.result, json: ["ok": true])
            case .wait:
                let json = frame.json
                guard let id = json["id"] as? String, let s = session(id) else { fail("no such session"); continue }
                let until: DaemonSession.Until
                switch json["until"] as? String ?? "exit" {
                case "exit": until = .exit
                case "prompt": until = .prompt
                case "idle":
                    // A day at most: the product must fit (a trap here ends every session).
                    let ms = min(86_400_000, max(1, json["idleMs"] as? Int ?? 1000))
                    until = .idle(nanoseconds: UInt64(ms) * 1_000_000)
                default: fail("until: exit, prompt or idle"); continue
                }
                s.addWaiter(connection, until: until)
                waitedOn.append(s)
            case .events:
                guard listener == nil else { fail("already listening"); continue }
                let kinds = (frame.json["kinds"] as? [String]).map(Set.init)
                // The answer first: every event after it is an `event` frame.
                connection.send(.result, json: ["ok": true])
                listener = DaemonEvents.shared.listen(connection, kinds: kinds)
            case .configure:
                if let lines = frame.json["scrollback"] as? Int { bound?.setScrollback(lines) }
            case .storeLayout:
                // The windows a Mac shows these sessions in (the app's own
                // format): a host's come back on any Mac that connects, a
                // Mac's own survive the app losing its copy. Empty: that Mac
                // has no windows here any more.
                guard let (header, body) = frame.headerAndBody, let client = header["client"] as? String,
                      !client.isEmpty, body.count <= Self.maxLayoutBytes else { fail("bad layout"); continue }
                let local = header["local"] as? Bool ?? false
                lock.lock()
                // Mid-takeover the newer liberttyd's copy is already taken:
                // a layout taken now would be lost. The app tries again.
                let refused = handingOver
                if !refused {
                    let key = Self.layoutKey(client, local: local)
                    if body.isEmpty {
                        layouts[key] = nil
                    } else {
                        layouts[key] = Layout(client: client, local: local, data: body, at: Date().timeIntervalSince1970)
                        while layouts.count > Self.maxLayouts, let oldest = layouts.min(by: { $0.value.at < $1.value.at }) {
                            layouts[oldest.key] = nil
                        }
                    }
                }
                lock.unlock()
                if refused { fail("handing over"); continue }
                connection.send(.result, json: ["ok": true])
            case .loadLayout:
                // The asking Mac's own entry; for a host's windows, else the
                // latest any Mac stored.
                let json = frame.json
                let client = json["client"] as? String ?? ""
                let local = json["local"] as? Bool ?? false
                lock.lock()
                var pick = layouts[Self.layoutKey(client, local: local)]
                if pick == nil, !local { pick = layouts.values.filter { !$0.local }.max { $0.at < $1.at } }
                lock.unlock()
                let body = pick?.data ?? Data()
                _ = body.withUnsafeBytes { connection.send(.result, header: ["client": pick?.client ?? ""], body: $0) }
            case .takeover:
                handOver(to: connection)
            case .shutdown:
                lock.lock()
                let all = Array(sessions.values)
                lock.unlock()
                all.forEach { $0.terminate() }
                connection.send(.result, json: ["ok": true])
                Self.log("shutdown requested; ended \(all.count) sessions")
                removeOwnSocket()
                exit(0)
            default:
                fail("unexpected \(frame.kind)")
            }
        }
    }

    // MARK: Takeover

    /// Old side: give every session to the newer liberttyd on `connection`, then exit.
    private func handOver(to connection: Connection) {
        lock.lock()
        handingOver = true
        exitTimer?.cancel()
        let all = sessions.values.sorted { $0.created < $1.created }
        lock.unlock()
        // No new connections; the new liberttyd binds the path when we're done.
        sysShutdown(listener)
        Self.log("handing \(all.count) sessions over")
        connection.setReceiveTimeout(10)
        var handed = 0
        for s in all {
            guard let (fd, header, snapshot) = s.release() else { continue }
            let sent = snapshot.withUnsafeBytes { connection.send(.handoff, header: header, body: $0) }
            guard sent, let ack = connection.receive(), ack.kind == .ack, connection.sendDescriptor(fd) else {
                Self.log("takeover broke off after \(handed) sessions")
                close(fd)
                exit(1)
            }
            close(fd)
            handed += 1
        }
        lock.lock()
        let kept: [[String: Any]] = layouts.values.map {
            ["client": $0.client, "local": $0.local, "data": $0.data.base64EncodedString(), "at": $0.at]
        }
        lock.unlock()
        connection.send(.result, json: ["ok": true, "sessions": handed, "layouts": kept])
        Self.log("handed over \(handed) sessions; exiting")
        // exit(), not return: nothing may end the programs on the way out.
        exit(0)
    }

    /// New side: take every session from the liberttyd currently on the socket.
    private func takeOver() {
        guard let old = Connection.connect(to: path) else { return }
        old.setReceiveTimeout(15)
        old.send(.hello, json: ["version": Wire.version])
        guard let welcome = old.receive(), welcome.kind == .welcome else { return }
        let oldPID = welcome.json["pid"] as? Int ?? 0
        old.send(.takeover)
        var adopted = 0
        while let frame = old.receive() {
            if frame.kind == .result {
                // The windows' layouts come along with the sessions.
                if let kept = frame.json["layouts"] as? [[String: Any]] {
                    lock.lock()
                    for entry in kept {
                        guard let client = entry["client"] as? String, !client.isEmpty, let text = entry["data"] as? String,
                              let data = Data(base64Encoded: text), data.count <= Self.maxLayoutBytes else { continue }
                        let local = entry["local"] as? Bool ?? false
                        layouts[Self.layoutKey(client, local: local)] =
                            Layout(client: client, local: local, data: data, at: entry["at"] as? Double ?? 0)
                    }
                    lock.unlock()
                }
                break
            }
            guard frame.kind == .handoff, let (header, snapshot) = frame.headerAndBody else { continue }
            guard !old.hasBufferedBytes, old.send(.ack), let fd = old.receiveDescriptor() else {
                Self.log("takeover: lost the descriptor stream")
                break
            }
            do {
                let s = try DaemonSession(adopting: fd, header: header, snapshot: snapshot)
                register(s)
                adopted += 1
            } catch {
                Self.log("takeover: couldn't adopt a session: \(error)")
                close(fd)
            }
        }
        Self.log("took over \(adopted) sessions from liberttyd[\(oldPID)]")
        // The old one unlinks nothing; wait for it to be gone before binding.
        for _ in 0..<200 where oldPID > 0 && kill(pid_t(oldPID), 0) == 0 { usleep(10_000) }
    }
}

// MARK: - A session

final class DaemonSession {
    let id: String
    let created: Double
    let command: String
    private let pty: PTY
    private let terminal: GhosttyTerminal
    private let queue: DispatchQueue
    /// Guards the terminal and the attached clients. Output is queued for
    /// the windows and parsed under it, so an attach sees a snapshot and
    /// then exactly the output after it. Nothing is written to a socket
    /// under it: each window's outbox has its own thread (Outbox).
    private let lock = NSLock()
    private var clients: [Outbox] = []
    /// The window whose replies reach the program: the last to attach or type.
    private var primary: Connection?
    private var size: GridSize
    private var scrollback: Int
    private var pendingPtyResize: DispatchWorkItem?
    private var compressor: IdleCompressor?
    var onEnd: ((DaemonSession) -> Void)?

    // Where its shell is, from OSC 133 (under `lock`): at its prompt, and
    // whether a line was submitted since (that prompt is about to go, so
    // `+wait --until prompt` waits for the next one).
    private var atPrompt = false
    private var submitted = false
    /// A prompt came during this parse: its waiters are told after it.
    private var promptReached = false
    /// When the running command started (OSC 133 C), for how long it took.
    private var commandStarted: Double?
    /// When output last came (uptime ns), for `+wait --until idle=MS`.
    private var lastOutput = DispatchTime.now().uptimeNanoseconds
    /// What the parser reported, published once the lock is released.
    private var pendingEvents: [(kind: String, fields: [String: Any])] = []
    private var idleTimer: DispatchSourceTimer?
    /// The last OSC 9;4 progress as the agents' rules read it, after "9;" (under `lock`).
    private var progressCode = ""
    /// Who's in front, and what an agent there is doing (AgentWatch).
    private var agentWatch: AgentWatch?
    /// Who it last said is in front (under `lock`), for a window attaching.
    private var foregroundProgram: AgentWatch.Program?

    init(request: CreateRequest) throws {
        id = request.id
        created = Date().timeIntervalSince1970
        command = request.arguments.joined(separator: " ")
        size = GridSize(cols: request.cols, rows: request.rows, widthPx: request.widthPx, heightPx: request.heightPx)
        scrollback = request.scrollback
        queue = DispatchQueue(label: "liberttyd.session", qos: .userInteractive)
        var t: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &t, max(1, size.cols), max(1, size.rows)) == GHOSTTY_SUCCESS, let t else {
            throw DaemonError.terminal
        }
        terminal = t
        var environment = request.environment
        if request.inheritEnvironment == true {
            var base = ProcessInfo.processInfo.environment
            // Ours, not the session's.
            for key in ["PWD", "OLDPWD", "SHLVL", "_"] { base[key] = nil }
            environment = base.merging(request.environment) { $1 }
        }
        let directory = FileManager.default.fileExists(atPath: request.workingDirectory) ? request.workingDirectory
            : (ProcessInfo.processInfo.environment["HOME"] ?? "/")
        pty = try PTY(executable: request.executable, arguments: request.arguments,
                      environment: environment, workingDirectory: directory,
                      size: size, queue: queue)
        configure()
        DaemonServer.log("session \(id) started: \(command) (pid \(pty.pid))")
    }

    init(adopting fd: Int32, header: [String: Any], snapshot: Data) throws {
        id = header["id"] as? String ?? UUID().uuidString
        created = header["created"] as? Double ?? Date().timeIntervalSince1970
        command = header["command"] as? String ?? ""
        name = SessionInfo.cleanLabel(header["label"] as? String ?? "")
        let pid = pid_t(header["pid"] as? Int ?? 0)
        scrollback = header["scrollback"] as? Int ?? 10_000_000
        size = GridSize(cols: UInt16(header["cols"] as? Int ?? 80), rows: UInt16(header["rows"] as? Int ?? 24),
                        widthPx: UInt16(header["widthPx"] as? Int ?? 0), heightPx: UInt16(header["heightPx"] as? Int ?? 0))
        queue = DispatchQueue(label: "liberttyd.session", qos: .userInteractive)
        // A snapshot from an incompatible build only costs the screen contents.
        if let restored = Snapshots.decode(snapshot, trackContinuation: true) {
            terminal = restored
        } else {
            var t: GhosttyTerminal?
            guard ghostty_terminal_new(nil, &t, max(1, size.cols), max(1, size.rows)) == GHOSTTY_SUCCESS, let t else {
                throw DaemonError.terminal
            }
            terminal = t
        }
        pty = try PTY(adopting: fd, pid: pid, queue: queue)
        configure()
    }

    deinit {
        ghostty_terminal_free(terminal)
    }

    private func configure() {
        let me = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, me)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(daemonWritePty, to: UnsafeRawPointer.self))
        // What `+wait` and `+events` follow.
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
                                 unsafeBitCast(daemonSemanticPrompt, to: UnsafeRawPointer.self))
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                                 unsafeBitCast(daemonTitleChanged, to: UnsafeRawPointer.self))
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
                                 unsafeBitCast(daemonPwdChanged, to: UnsafeRawPointer.self))
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(daemonBell, to: UnsafeRawPointer.self))
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
                                 unsafeBitCast(daemonProgramStatus, to: UnsafeRawPointer.self))
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT,
                                 unsafeBitCast(daemonProgressReport, to: UnsafeRawPointer.self))
        TerminalDefaults.apply(to: terminal, scrollback: scrollback)
        KittyGraphics.enableForDaemon(on: terminal)
        // Snapshots must work mid-sequence: remember unfinished input.
        var continuation = 16 << 20
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation)

        agentWatch = AgentWatch(
            foreground: { [weak self] in
                guard let self else { return nil }
                return ForegroundProgram.process(master: self.pty.master, shell: self.pty.pid)
            },
            sight: { [weak self] in self?.sight() ?? .init(screen: "", title: "", progress: "") },
            publish: { [weak self] state, app in
                guard let self else { return }
                DaemonEvents.shared.publish("status", session: self.id, [
                    "state": state, "record": AgentWatch.record, "app": app, "message": "", "title": "", "source": "screen",
                ])
            },
            programChanged: { [weak self] program in self?.programChanged(program) })
        pty.onOutput = { [weak self] bytes in self?.output(bytes) }
        pty.onExit = { [weak self] status in self?.exited(status) }
        pty.onInputModeChange = { [weak self] mode in self?.inputModeChanged(mode) }
        pty.startReading()
        compressor = IdleCompressor(queue: queue) { [weak self] body in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            body(self.terminal)
        }
    }

    // MARK: Output (queue)

    private func output(_ bytes: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        // Windows first (they're waiting; a queue each, so none holds us
        // up), then our own copy.
        let raw = UnsafeRawBufferPointer(bytes)
        var lost = false
        for c in clients where !c.output(raw) { lost = true }
        // A window let go (too far behind to catch up): out of the list
        // now, so its replies stop counting and we answer for it if it was
        // the last one.
        if lost { forgetLost() }
        ghostty_terminal_vt_write(terminal, bytes.baseAddress, bytes.count)
        if pendingClear != nil { applyPendingClear() }
        lastOutput = DispatchTime.now().uptimeNanoseconds
        let reached = promptReached ? takeWaiters { $0.until == .prompt } : []
        promptReached = false
        let events = pendingEvents
        pendingEvents = []
        lock.unlock()
        // Unlocked: a waiter or a listener that doesn't read holds up only itself.
        for w in reached { w.connection.send(.result, json: ["ok": true, "reached": "prompt"]) }
        for e in events { DaemonEvents.shared.publish(e.kind, session: id, e.fields) }
        agentWatch?.poke()
    }

    // MARK: The program in front (AgentWatch)

    /// What an agent's rules read: the screen's rows as shown (no trailing
    /// empty ones), the title, the progress.
    private func sight() -> AgentWatch.Sight {
        lock.lock()
        defer { lock.unlock() }
        var rows = Snapshots.text(terminal, scrollback: false, format: .plain, unwrap: false)
            .split(separator: "\n", omittingEmptySubsequences: false)
        while rows.last?.isEmpty == true { rows.removeLast() }
        var t = GhosttyString()
        let title = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &t) == GHOSTTY_SUCCESS ? String(borrowed: t) : ""
        return .init(screen: rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n", title: title, progress: progressCode)
    }

    /// The windows hear who's in front (a remote host's tabs show its
    /// agent so), and so does `+events`.
    private func programChanged(_ program: AgentWatch.Program?) {
        let json = program?.json ?? ["name": ""]
        let frame = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        lock.lock()
        foregroundProgram = program
        for c in clients { c.send(.foreground, frame) }
        lock.unlock()
        DaemonEvents.shared.publish("program", session: id, ["name": program?.name ?? "", "agent": program?.agent ?? ""])
    }

    fileprivate func progressReported(_ code: String) { progressCode = code }

    // MARK: What the shell reports (vt_write, under `lock`)

    fileprivate func semanticPrompt(_ event: GhosttyTerminalSemanticPrompt) {
        switch event.kind {
        case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START where event.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY,
             GHOSTTY_SEMANTIC_PROMPT_INPUT_START:
            // (fish reports only the prompt's start; zsh and bash also when
            // input starts: either means the shell is waiting.)
            if !atPrompt { pendingEvents.append(("prompt", [:])) }
            if !atPrompt { agentWatch?.atPrompt() }
            atPrompt = true
            submitted = false
            promptReached = true
        case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START:
            atPrompt = false
            commandStarted = Date().timeIntervalSince1970
            pendingEvents.append(("command-started", ["command": String(borrowed: event.command)]))
        case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END:
            // Shells report an end at every prompt, a command or not.
            guard let started = commandStarted else { break }
            commandStarted = nil
            pendingEvents.append(("command-finished", [
                "exit": event.has_exit_code ? Int(event.exit_code) as Any : jsonNull,
                "milliseconds": Int(((Date().timeIntervalSince1970 - started) * 1000).rounded()),
            ]))
        default:
            break
        }
    }

    fileprivate func titleChanged() {
        var s = GhosttyString()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS else { return }
        pendingEvents.append(("title", ["title": String(borrowed: s)]))
    }

    fileprivate func pwdChanged() {
        var s = GhosttyString()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &s) == GHOSTTY_SUCCESS else { return }
        let raw = String(borrowed: s)
        pendingEvents.append(("directory", ["directory": SessionInfo.directory(fromPwd: raw) ?? raw]))
    }

    fileprivate func rang() { pendingEvents.append(("bell", [:])) }

    /// A program's report of what it does (OSC 7501): `status` events, which
    /// `+events --for blocked,…` follows.
    fileprivate func programStatus(_ fields: [String: Any]) {
        pendingEvents.append(("status", fields))
        agentWatch?.programReported(record: fields["record"] as? String ?? "", app: fields["app"] as? String ?? "",
                                    state: fields["state"] as? String ?? "")
    }

    /// Under `lock`: drop the windows whose outboxes hung up.
    private func forgetLost() {
        clients.removeAll { $0.isGone }
        if let p = primary, !clients.contains(where: { $0.connection === p }) { primary = clients.last?.connection }
    }

    /// What `libertty +wait` waits for: the program to end (told its exit
    /// status), the shell back at its prompt, or the output quiet so long.
    enum Until: Equatable {
        case exit
        case prompt
        case idle(nanoseconds: UInt64)
    }

    private struct Waiter {
        let connection: Connection
        let until: Until
        /// When it began (uptime ns): quiet only counts from then.
        let since: UInt64
    }
    private var waiters: [Waiter] = []
    /// Once the program has ended: its exit code (as `$?` shows it), and the
    /// raw status windows are told. A waiter or a window that comes between
    /// the end and the session leaving the list is told at once.
    private var endCode: Int32?
    private var endStatus: Int32?

    func addWaiter(_ connection: Connection, until: Until = .exit) {
        lock.lock()
        if let code = endCode {
            lock.unlock()
            connection.send(.result, json: ["ok": true, "status": Int(code)])
            return
        }
        // Already there: at a prompt nothing was submitted to since.
        if until == .prompt, atPrompt, !submitted {
            lock.unlock()
            connection.send(.result, json: ["ok": true, "reached": "prompt"])
            return
        }
        waiters.append(Waiter(connection: connection, until: until, since: DispatchTime.now().uptimeNanoseconds))
        if case .idle = until { startIdleTimer() }
        lock.unlock()
    }

    /// Its asker gave up (`--timeout`, or it was interrupted).
    func dropWaiters(_ connection: Connection) {
        lock.withLock { waiters.removeAll { $0.connection === connection } }
    }

    /// Under `lock`: the waiters that `done` says are done, out of the list.
    private func takeWaiters(where done: (Waiter) -> Bool) -> [Waiter] {
        let taken = waiters.filter(done)
        if !taken.isEmpty { waiters.removeAll(where: done) }
        return taken
    }

    /// Under `lock`. Checked often while anyone waits for quiet output;
    /// stopped when nobody does.
    private func startIdleTimer() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        idleTimer = timer
        timer.resume()
    }

    private func checkIdle() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let quiet = takeWaiters { w in
            guard case .idle(let wanted) = w.until else { return false }
            return now - max(lastOutput, w.since) >= wanted
        }
        if !waiters.contains(where: { if case .idle = $0.until { true } else { false } }) {
            idleTimer?.cancel()
            idleTimer = nil
        }
        lock.unlock()
        for w in quiet { w.connection.send(.result, json: ["ok": true, "reached": "idle"]) }
    }

    private func exited(_ status: Int32) {
        compressor?.stop()
        agentWatch?.end()
        // The shell's exit code, as `$?` would show it (128 + signal if killed).
        let code = PTY.exitCode(fromWaitStatus: status)
        lock.lock()
        endCode = code
        endStatus = status
        // A window that fell behind first gets where the session ended up.
        let behind = clients.filter(\.isBehind)
        if !behind.isEmpty {
            let frames = catchUpFrames()
            behind.forEach { $0.caughtUp(frames) }
        }
        let exitedFrame = (try? JSONSerialization.data(withJSONObject: ["status": Int(status)])) ?? Data()
        for c in clients {
            c.send(.exited, exitedFrame)
            c.finish()
        }
        let waiting = waiters
        waiters = []
        idleTimer?.cancel()
        idleTimer = nil
        clients = []
        primary = nil
        lock.unlock()
        // Unlocked: a waiter that doesn't read holds up only itself. One
        // waiting for a prompt or for quiet learns the program ended instead.
        for w in waiting {
            var reply: [String: Any] = ["ok": true, "status": Int(code)]
            if w.until != .exit { reply["ended"] = true }
            w.connection.send(.result, json: reply)
        }
        DaemonEvents.shared.publish("session-ended", session: id, ["status": Int(code)])
        DaemonServer.log("session \(id) ended (status \(status))")
        onEnd?(self)
    }

    /// Called from vt_write with `lock` held.
    fileprivate func terminalWantsToReply(_ data: UnsafePointer<UInt8>, _ len: Int) {
        // An attached window answers for itself; we stand in when there's
        // none — or when the one whose answers count is skipping output
        // (Outbox): it never sees the question, and a program waiting for
        // the answer would hang.
        if let p = primary, let window = clients.first(where: { $0.connection === p }), !window.isBehind { return }
        if primary == nil, !clients.isEmpty { return }
        pty.writeReply(Data(bytes: data, count: len))
    }

    // MARK: Clients (connection threads)

    /// `catchUp`: the window can take a snapshot mid-stream if it falls too
    /// far behind (Outbox).
    func attach(_ connection: Connection, sendSnapshot: Bool, catchUp: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let outbox = Outbox(connection, catchUp: catchUp, session: self)
        var header: [String: Any] = ["id": id, "pid": Int(pty.pid), "cols": Int(size.cols), "rows": Int(size.rows)]
        if !name.isEmpty { header["label"] = name }
        if let mode = inputMode {
            header["echo"] = mode.echo
            header["canonical"] = mode.canonical
        }
        if let program = foregroundProgram { header["program"] = program.json }
        // It watches agents' screens itself: the window needn't tell it what it reads (`report`).
        header["agentScreen"] = true
        // And tells every window the program's size as it changes (`ptySize`).
        header["sizes"] = true
        if sendSnapshot, let snapshot = Snapshots.encode(terminal) {
            header["snapshot"] = true
            outbox.send(.attached, snapshot.withUnsafeBytes { Connection.headed(header, body: $0) })
        } else {
            outbox.send(.attached, Connection.headed(header, body: UnsafeRawBufferPointer(start: nil, count: 0)))
        }
        if let status = endStatus {
            // It ended a moment ago (the session is about to leave the
            // list): the window sees where it ended, then that it did.
            let exited = (try? JSONSerialization.data(withJSONObject: ["status": Int(status)])) ?? Data()
            outbox.send(.exited, exited)
            outbox.finish()
            outbox.start()
            return
        }
        clients.append(outbox)
        primary = connection
        outbox.start()
    }

    /// A window that fell behind has written all it had: the session as it
    /// is now, in place of the output it skipped (its outbox's thread).
    func catchUp(_ outbox: Outbox) {
        lock.lock()
        defer { lock.unlock() }
        guard clients.contains(where: { $0 === outbox }) else { return }
        let frames = catchUpFrames()
        outbox.caughtUp(frames)
        catchUps += 1
        DaemonServer.log("session \(id): a window fell \(Outbox.budget >> 20) MB behind; caught it up "
            + "(\(frames.first?.1.count ?? 0) bytes, \(catchUps) so far)")
    }

    /// How many times a window was caught up, for the log.
    private var catchUps = 0

    /// Our state for a window catching up: a snapshot, its kitty images
    /// included (under `lock`).
    private func catchUpFrames() -> [(Wire.Kind, Data)] {
        guard let snapshot = Snapshots.encode(terminal) else { return [] }
        return [(.snapshot, snapshot)]
    }

    func detach(_ connection: Connection) {
        lock.lock()
        defer { lock.unlock() }
        if let i = clients.firstIndex(where: { $0.connection === connection }) { clients.remove(at: i).hangUp() }
        // Repaired either way: the window may have left the list already.
        if primary === connection { primary = clients.last?.connection }
        sizerLeft(connection)
    }

    /// A window's outbox stopped: it hung up, or was let go (its thread).
    func forget(_ outbox: Outbox) {
        lock.lock()
        defer { lock.unlock() }
        clients.removeAll { $0 === outbox }
        if primary === outbox.connection { primary = clients.last?.connection }
        sizerLeft(outbox.connection)
    }

    func write(_ data: Data, from connection: Connection?) {
        // A line submitted at the prompt: that prompt is about to go.
        let submits = data.contains(0x0D) || data.contains(0x0A)
        if connection != nil || submits {
            lock.lock()
            // Input still buffered from a window already let go must not
            // make it the one whose replies count.
            if let connection, clients.contains(where: { $0.connection === connection }) { primary = connection }
            if submits { submitted = true }
            lock.unlock()
        }
        pty.write(data)
    }

    /// ⌘K, asked for by a window. Computed from our copy (the authority:
    /// windows may lag behind the output) and applied between two complete
    /// escape sequences, then sent to every window as output, so all copies
    /// clear at the same point. Ghostty's semantics: at a prompt, screen and
    /// scrollback, then a form feed for the shell to redraw; while a program
    /// runs, the scrollback and the lines above the cursor.
    func requestClear(atPrompt: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pendingClear = atPrompt
        applyPendingClear()
    }

    /// Set when a clear waits for the parser to be between sequences (under `lock`).
    private var pendingClear: Bool?

    /// Under `lock`.
    private func applyPendingClear() {
        guard let atPrompt = pendingClear else { return }
        var ground = true
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground)
        guard ground else { return }  // after the next output
        pendingClear = nil
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        guard screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY else { return }  // full-screen programs keep theirs
        var x: UInt16 = 0, y: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        var sequence = "\u{1b}[3J"
        if atPrompt {
            // Erased first, the scrollback after: at a prompt, an erase of the
            // whole screen moves it into the scrollback (libghostty's ^L
            // heuristic), which would then keep the last screenful.
            sequence = "\u{1b}[H\u{1b}[2J\u{1b}[3J"
        } else if y > 0 {
            // Erase from the top through the row above the cursor, then put it back.
            sequence += "\u{1b}[\(y);\(size.cols)H\u{1b}[1J\u{1b}[\(y + 1);\(x + 1)H"
        }
        let bytes = Array(sequence.utf8)
        var lost = false
        bytes.withUnsafeBytes { raw in
            for c in clients where !c.output(raw) { lost = true }
        }
        if lost { forgetLost() }
        ghostty_terminal_vt_write(terminal, bytes, bytes.count)
        if atPrompt { pty.write(Data([0x0C])) }
    }

    func reply(_ data: Data, from connection: Connection) {
        lock.lock()
        let isPrimary = primary === connection
        lock.unlock()
        if isPrimary { pty.writeReply(data) }
    }

    func resize(_ newSize: GridSize, from connection: Connection) {
        lock.lock()
        let key = ObjectIdentifier(connection)
        clientSizes.removeAll { $0.connection == key }
        clientSizes.append((key, newSize))
        lock.unlock()
        apply(newSize)
    }

    /// Each window's last size, the latest last (under `lock`): when the
    /// window that sized the program goes, the one sized before it takes
    /// over (tmux does the same), so a pane still showing it fits again.
    private var clientSizes: [(connection: ObjectIdentifier, size: GridSize)] = []

    /// A window went (under `lock`): if it was the one whose size the
    /// program has, the program takes the size of the latest still here.
    private func sizerLeft(_ connection: Connection) {
        let key = ObjectIdentifier(connection)
        let wasLatest = clientSizes.last?.connection == key
        clientSizes.removeAll { $0.connection == key }
        guard wasLatest, let next = clientSizes.last?.size, next != size else { return }
        queue.async { [weak self] in self?.apply(next) }
    }

    private func apply(_ newSize: GridSize) {
        lock.lock()
        size = newSize
        // Every window hears the size the program has now: one whose pane is
        // another says so ("Sized by another window") and can take it back.
        let sized = (try? JSONSerialization.data(withJSONObject: ["cols": Int(newSize.cols), "rows": Int(newSize.rows)])) ?? Data()
        for c in clients { c.send(.ptySize, sized) }
        let cw = UInt32(newSize.widthPx) / UInt32(max(1, newSize.cols))
        let ch = UInt32(newSize.heightPx) / UInt32(max(1, newSize.rows))
        _ = ghostty_terminal_resize(terminal, max(1, newSize.cols), max(1, newSize.rows), cw, ch)
        // Once the size settles, put every window back in step with us
        // (see resyncScreen).
        resync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resyncScreen() }
        resync = work
        queue.asyncAfter(deadline: .now() + Self.resyncDelay, execute: work)
        lock.unlock()
        pty.resize(newSize)
    }

    /// How long after the last resize the screen is sent again (GoRex's
    /// value; long enough for a burst of resizes to coalesce).
    private static let resyncDelay: TimeInterval = 0.15

    /// Set under `lock`; fires on `queue` once a resize settles.
    private var resync: DispatchWorkItem?

    /// A window resized its own copy at its own moment, while the program's
    /// output — drawn for the old size — was on its way to it: what it
    /// painted can land in a screen of another size than we parsed it in,
    /// and the copies drift apart. Full-screen programs repaint only what
    /// they think changed, so the drift stays. Once a resize settles, send
    /// every window our screen, painted over theirs cleared. A shell
    /// reflows the same on both sides and needs nothing (GoRex's fix).
    private func resyncScreen() {
        lock.lock()
        defer { lock.unlock() }
        guard !clients.isEmpty else { return }
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        guard screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE else { return }
        // Painted as VT, which every window parses as output (a binary
        // snapshot here would be printed as text).
        var repaint = Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2J".utf8)
        repaint.append(Snapshots.screenVT(terminal))
        var lost = false
        repaint.withUnsafeBytes { raw in
            for c in clients where !c.output(raw) { lost = true }
        }
        if lost { forgetLost() }
    }

    func setScrollback(_ limit: Int) {
        lock.lock()
        scrollback = limit
        TerminalDefaults.setScrollback(terminal, limit)
        lock.unlock()
    }

    func terminate() { pty.terminate() }

    /// A window closed its pane: end the program, or with other windows still
    /// showing it (mirrors), just let this one go.
    func close(from connection: Connection) {
        lock.lock()
        let others = clients.contains { $0.connection !== connection }
        lock.unlock()
        if others {
            detach(connection)
            connection.close()
        } else {
            pty.terminate()
        }
    }

    // MARK: Inspection

    func info() -> SessionInfo {
        lock.lock()
        defer { lock.unlock() }
        var s = GhosttyString()
        let title = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS ? String(borrowed: s) : ""
        var p = GhosttyString()
        let pwd = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &p) == GHOSTTY_SUCCESS ? String(borrowed: p) : ""
        return SessionInfo(id: id, pid: pty.pid, title: title, workingDirectory: pwd,
                           cols: size.cols, rows: size.rows, clients: clients.count, created: created, command: command,
                           label: name.isEmpty ? nil : name)
    }

    // MARK: Keys (`libertty +send-key`)

    /// Press `keys`, each encoded for the terminal's modes at that moment (a
    /// program may change them in between: not here, they go at once). None
    /// go if one of them sends nothing to this program (`super+x` without the
    /// kitty keyboard protocol): its index, else nil.
    func press(_ keys: [KeySpec]) -> Int? {
        var encoder: GhosttyKeyEncoder?, event: GhosttyKeyEvent?
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS, let encoder else { return 0 }
        defer { ghostty_key_encoder_free(encoder) }
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else { return 0 }
        defer { ghostty_key_event_free(event) }
        lock.lock()
        let encoded = keys.map { $0.encode(for: terminal, with: encoder, event: event) }
        lock.unlock()
        if let silent = encoded.firstIndex(where: \.isEmpty) { return silent }
        write(Data(encoded.flatMap { $0 }), from: nil)
        return nil
    }

    // MARK: Its input mode

    /// As last seen (`PTY.onInputModeChange`); under `lock`.
    private var inputMode: InputMode?

    /// The windows hear (a program reading a password shows on its tab), and so does `+events`.
    private func inputModeChanged(_ mode: InputMode) {
        lock.lock()
        inputMode = mode
        let frame = (try? JSONSerialization.data(withJSONObject: ["echo": mode.echo, "canonical": mode.canonical])) ?? Data()
        for c in clients { c.send(.inputMode, frame) }
        lock.unlock()
        DaemonEvents.shared.publish("input-mode", session: id, ["echo": mode.echo, "canonical": mode.canonical])
    }

    // MARK: Its name

    /// What `+rename-session` named it ("" for nothing); under `lock`.
    private var name = ""

    var label: String {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    /// Name it: the windows showing it hear (they name its tab after it),
    /// and so does `+events`.
    func rename(_ label: String) {
        let clean = SessionInfo.cleanLabel(label)
        lock.lock()
        guard clean != name else { return lock.unlock() }
        name = clean
        let frame = (try? JSONSerialization.data(withJSONObject: ["label": clean])) ?? Data()
        for c in clients { c.send(.label, frame) }
        lock.unlock()
        DaemonEvents.shared.publish("label", session: id, ["label": clean])
    }

    func capture(scrollback: Bool, format: Snapshots.TextFormat = .plain) -> String {
        lock.lock()
        defer { lock.unlock() }
        return Snapshots.text(terminal, scrollback: scrollback, format: format)
    }

    // MARK: Takeover

    /// Stop, and give out what a new liberttyd needs to continue: the pty master,
    /// a header and a snapshot. Nil if the program already ended.
    func release() -> (Int32, [String: Any], Data)? {
        guard let fd = pty.release() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        clients.forEach { $0.hangUp() }  // they redial the new liberttyd
        clients = []
        primary = nil
        let snapshot = Snapshots.encode(terminal) ?? Data()
        let header: [String: Any] = [
            "id": id, "pid": Int(pty.pid), "created": created, "command": command, "scrollback": scrollback,
            "cols": Int(size.cols), "rows": Int(size.rows), "widthPx": Int(size.widthPx), "heightPx": Int(size.heightPx),
            "label": name,
        ]
        return (fd, header, snapshot)
    }
}

enum DaemonError: Error { case terminal }

private func daemonSession(_ userdata: UnsafeMutableRawPointer?) -> DaemonSession? {
    userdata.map { Unmanaged<DaemonSession>.fromOpaque($0).takeUnretainedValue() }
}

private let daemonSemanticPrompt: GhosttyTerminalSemanticPromptFn = { _, userdata, event in
    guard let event = event?.pointee else { return }
    daemonSession(userdata)?.semanticPrompt(event)
}
private let daemonTitleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in daemonSession(userdata)?.titleChanged() }
private let daemonPwdChanged: GhosttyTerminalPwdChangedFn = { _, userdata in daemonSession(userdata)?.pwdChanged() }
private let daemonBell: GhosttyTerminalBellFn = { _, userdata in daemonSession(userdata)?.rang() }

private let daemonProgramStatus: GhosttyTerminalProgramStatusFn = { _, userdata, report in
    guard let report = report?.pointee, let s = daemonSession(userdata) else { return }
    let state = switch report.state {
    case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR: "clear"
    case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: "working"
    case GHOSTTY_PROGRAM_STATUS_STATE_DONE: "done"
    case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: "blocked"
    case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: "error"
    default: "idle"
    }
    let kind = switch report.kind {
    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: "permission"
    case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: "question"
    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: "auth"
    default: ""
    }
    // Strings are only valid during this call: copied now.
    var fields: [String: Any] = ["state": state, "record": String(borrowed: report.id), "app": String(borrowed: report.app),
                                 "message": String(borrowed: report.message), "title": String(borrowed: report.title)]
    if !kind.isEmpty { fields["kind"] = kind }
    if report.progress >= 0 { fields["progress"] = Int(report.progress) }
    s.programStatus(fields)
}

/// OSC 9;4, as the agents' rules read it: "4;STATE[;PERCENT]" ("" once removed).
private let daemonProgressReport: GhosttyTerminalProgressReportFn = { _, userdata, report in
    guard let report = report?.pointee, let s = daemonSession(userdata) else { return }
    let state: Int? = switch report.state {
    case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: 1
    case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: 2
    case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: 3
    case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: 4
    default: nil
    }
    guard let state else { return s.progressReported("") }
    let percent = state == 1 ? max(0, Int(report.progress)) : (report.progress >= 0 && state != 3 ? Int(report.progress) : nil)
    s.progressReported(percent.map { "4;\(state);\(min(100, $0))" } ?? "4;\(state)")
}

private let daemonWritePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
    guard let userdata, let data, len > 0 else { return }
    Unmanaged<DaemonSession>.fromOpaque(userdata).takeUnretainedValue().terminalWantsToReply(data, len)
}

// MARK: - Shared terminal helpers

/// Options that change how output parses, so the app's replica and liberttyd's
/// copy must agree on them.
public enum TerminalDefaults {
    public static func apply(to terminal: GhosttyTerminal, scrollback: Int) {
        // Mode 2027 on by default (as Ghostty does): width comes from whole
        // grapheme clusters, so 👍🏽, 👨‍👩‍👧 and 🇨🇳 occupy one wide cell each
        // instead of one cell per codepoint.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes)
        setScrollback(terminal, scrollback)
    }

    /// `scrollback-limit`, as Ghostty means it: bytes. A byte cap prunes
    /// whole pages cheaply; libghostty's line cap scans and halves scrolling
    /// throughput (52 vs 105 MB/s measured), so small values (written as
    /// lines, Libertty's old meaning) become roughly as many bytes.
    /// libghostty-vt's own default is 10 000 bytes: about one page.
    public static func setScrollback(_ terminal: GhosttyTerminal, _ limit: Int) {
        var bytes = limit < 100_000 ? limit * 1_000 : limit
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, nil)
    }
}

public enum Snapshots {
    public static func encode(_ terminal: GhosttyTerminal) -> Data? {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_snapshot_encode_alloc(terminal, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return Data(bytes: ptr, count: len)
    }

    /// A terminal restored from `data`, or nil if it doesn't decode.
    public static func decode(_ data: Data, trackContinuation: Bool) -> GhosttyTerminal? {
        data.withUnsafeBytes { raw -> GhosttyTerminal? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var decoder: GhosttySnapshotDecoder?
            guard ghostty_snapshot_decoder_new_buf(nil, &decoder, base, raw.count) == GHOSTTY_SUCCESS, let decoder else { return nil }
            defer { ghostty_snapshot_decoder_free(decoder) }
            if trackContinuation {
                var retain = true
                _ = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain)
            }
            var compress = true
            _ = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress)
            // Its images: libghostty's default keeps only 10 MB of them.
            var limit = KittyGraphics.storageLimit
            _ = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit)
            var terminal: GhosttyTerminal?
            guard ghostty_snapshot_decoder_decode(decoder, &terminal) == GHOSTTY_SUCCESS else { return nil }
            return terminal
        }
    }

    /// The active screen as VT sequences that paint it — styles, links and
    /// where the cursor is — onto a cleared screen. Bytes any terminal
    /// parses, unlike `encode`'s binary snapshot, which only `decode` reads.
    public static func screenVT(_ terminal: GhosttyTerminal) -> Data {
        format(terminal, emit: GHOSTTY_FORMATTER_FORMAT_VT, unwrap: false, trim: false,
               extras: GHOSTTY_FORMATTER_EXTRA_CURSOR | GHOSTTY_FORMATTER_EXTRA_STYLE
                   | GHOSTTY_FORMATTER_EXTRA_HYPERLINK | GHOSTTY_FORMATTER_EXTRA_CHARSETS) ?? Data()
    }

    /// The screen (and optionally the scrollback) as plain text, wrapped lines joined.
    public static func plainText(_ terminal: GhosttyTerminal, scrollback: Bool) -> String {
        text(terminal, scrollback: scrollback, format: .plain)
    }

    /// How `+capture` gives a screen: plain text; with its colors and styles
    /// as VT sequences (what a terminal shows when it's printed); or as HTML.
    public enum TextFormat: String, Sendable {
        case plain, ansi, html
    }

    /// The screen (and optionally the scrollback) as text in `format`, wrapped lines joined.
    public static func text(_ terminal: GhosttyTerminal, scrollback: Bool, format: TextFormat, unwrap: Bool = true) -> String {
        let emit = switch format {
        case .plain: GHOSTTY_FORMATTER_FORMAT_PLAIN
        case .ansi: GHOSTTY_FORMATTER_FORMAT_VT
        case .html: GHOSTTY_FORMATTER_FORMAT_HTML
        }
        var extras = GHOSTTY_FORMATTER_EXTRAS_NONE
        if format != .plain { extras |= GHOSTTY_FORMATTER_EXTRA_STYLE | GHOSTTY_FORMATTER_EXTRA_HYPERLINK }
        // A page's palette colors are CSS variables (var(--vt-palette-1)): the
        // page must define them, or they're no color at all.
        if format == .html { extras |= GHOSTTY_FORMATTER_EXTRA_PALETTE }
        var all = GhosttySelection()
        let selection = scrollback && ghostty_terminal_select_all(terminal, &all) == GHOSTTY_SUCCESS ? all : nil
        guard let data = Self.format(terminal, emit: emit, unwrap: unwrap, trim: true, extras: extras, selection: selection)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What libghostty-vt's formatter makes of `terminal`, or of `selection`
    /// in it; `extras` nil keeps the formatter's own (palette, style and
    /// link: what `ghostty_terminal_selection_format_*` used before 1.0).
    /// Nil when there's nothing, or it failed.
    public static func format(_ terminal: GhosttyTerminal, emit: GhosttyFormatterFormat, unwrap: Bool, trim: Bool,
                              extras: GhosttyFormatterExtras? = nil, selection: GhosttySelection? = nil) -> Data? {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS, let formatter else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var emit = emit, unwrap = unwrap, trim = trim
        guard ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit) == GHOSTTY_SUCCESS,
              ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap) == GHOSTTY_SUCCESS,
              ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim) == GHOSTTY_SUCCESS
        else { return nil }
        if var extras, ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras) != GHOSTTY_SUCCESS {
            return nil
        }
        if var selection, ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection) != GHOSTTY_SUCCESS {
            return nil
        }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &ptr, &len) == GHOSTTY_SUCCESS else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        guard let ptr, len > 0 else { return nil }
        return Data(bytes: ptr, count: len)
    }
}

extension String {
    /// Copy a borrowed libghostty-vt string.
    public init(borrowed s: GhosttyString) {
        guard let ptr = s.ptr, s.len > 0 else {
            self = ""
            return
        }
        self = String(decoding: UnsafeBufferPointer(start: ptr, count: s.len), as: UTF8.self)
    }
}

/// Scrollback compression, as libghostty-vt asks: once a terminal has been
/// quiet for a tick, compress a little per tick until the pass completes.
/// A long scrollback then costs a fraction of its memory (liberttyd keeps one
/// per session on top of the window's).
public final class IdleCompressor {
    private let timer: DispatchSourceTimer
    private var lastActivity: UInt64 = .max
    private var complete = false

    /// `withTerminal` runs its body with the terminal locked against other use.
    public init(queue: DispatchQueue, withTerminal: @escaping ((GhosttyTerminal) -> Void) -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [unowned self] in
            withTerminal { terminal in
                var activity: UInt64 = 0
                _ = ghostty_terminal_compression_activity(terminal, &activity)
                guard activity == self.lastActivity else {
                    // Still changing: wait until it's quiet.
                    self.lastActivity = activity
                    self.complete = false
                    return
                }
                guard !self.complete else { return }
                for _ in 0..<32 {
                    var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE
                    guard ghostty_terminal_compress(terminal, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result) == GHOSTTY_SUCCESS,
                          result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING else {
                        self.complete = true
                        break
                    }
                }
            }
        }
        timer.resume()
    }

    deinit { timer.cancel() }

    public func stop() { timer.cancel() }
}
