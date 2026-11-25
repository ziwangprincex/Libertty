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

/// liberttyd going away mustn't end every program in it: when it crashes (a
/// Swift trap ends the whole process), is killed or is let go by the system,
/// its ptys would close and every shell get a hang-up. So a second liberttyd
/// (`--guardian`), which does nothing else, holds a copy of each session's pty
/// master: the ptys stay open, the programs never notice. Once liberttyd is
/// gone without standing it down, the guardian starts a new one (`--recover`)
/// and hands it every session the way an older liberttyd hands its sessions to
/// a newer one (`takeover`), less the screens, which went with the crash: the
/// windows give theirs back (`restore`). The windows redial meanwhile.
///
/// liberttyd stands it down before it exits on purpose (`+daemon stop`, a
/// takeover, SIGTERM): then the sessions end with it, or a newer one has them.
///
/// It shares liberttyd's lock (`--locked`, descriptor 3), so the lock is
/// never free when liberttyd crashes: a liberttyd started before the new one
/// (a host's windows reconnecting, a new tab) can't take it and serve
/// without the sessions, leaving the new one to give up and end them all.
enum DaemonGuardian {
    /// What it holds of a session: the takeover header (DaemonSession's
    /// `guardianCopy`), kept up to date, and its pty master.
    private struct Held {
        var header: [String: Any]
        let fd: Int32
        var created: Double { header["created"] as? Double ?? 0 }
    }

    /// Given up when liberttyd went away this many times in `crashWindow`
    /// seconds: something brings it down again and again (the sessions, say).
    static let maxRecoveries = 3
    static let crashWindow: Double = 60

    /// `liberttyd --guardian`: liberttyd is on stdin; `locked`, its lock on 3.
    static func main(locked: Bool) -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let lock: Int32 = locked && fcntl(3, F_SETFD, FD_CLOEXEC) == 0 ? 3 : -1
        let link = Connection(fd: STDIN_FILENO)
        var held: [String: Held] = [:]
        var socket = Wire.socketPath
        var liberttyd: pid_t = 0
        var standingDown = false
        loop: while let frame = link.receive() {
            switch frame.kind {
            case .hello:
                if let path = frame.json["socket"] as? String, !path.isEmpty { socket = path }
                liberttyd = pid_t(clamping: frame.json["pid"] as? Int ?? 0)
                link.send(.welcome, json: ["version": Wire.version, "pid": Int(getpid())])
            case .keep:
                let header = frame.json
                // Lockstep, as a takeover's: the descriptor comes after the ack.
                guard let id = header["id"] as? String, !link.hasBufferedBytes, link.send(.ack),
                      let fd = link.receiveDescriptor() else { break loop }
                if let old = held[id] { sysClose(old.fd) }
                held[id] = Held(header: header, fd: fd)
            case .update:
                guard let id = frame.json["id"] as? String, held[id] != nil else { continue }
                for (key, value) in frame.json where key != "id" { held[id]?.header[key] = value }
            case .forget:
                if let id = frame.json["id"] as? String, let gone = held.removeValue(forKey: id) { sysClose(gone.fd) }
            case .standDown:
                standingDown = true
                break loop
            default:
                continue
            }
        }
        guard !standingDown, !held.isEmpty else {
            // Our share of the lock first: liberttyd waits for us to go
            // before it does, and the lock must be free once it has.
            if lock >= 0 { sysClose(lock) }
            exit(0)
        }
        recover(held.values.sorted { $0.created < $1.created }, socket: socket, lock: lock, liberttyd: liberttyd)
    }

    /// liberttyd (`pid`) hung up without standing down: start another for its
    /// sessions. `shared`: its lock, held with it, or -1.
    private static func recover(_ sessions: [Held], socket: String, lock shared: Int32, liberttyd: pid_t) -> Never {
        // Gone, or did it only hang up on us? Its process says (it may linger
        // while the system writes its crash report). We keep the lock we've
        // held with it all along for the liberttyd we start (`--locked`).
        var lockFD: Int32 = -1
        var locked = false
        if shared >= 0, liberttyd > 0, DaemonServer.holdsLock(shared, of: socket) {
            var gone = false
            for _ in 0..<1000 {
                if libertty_proc_running(liberttyd) == 0 { gone = true; break }
                usleep(10_000)
            }
            guard gone else {
                log("liberttyd hung up but still runs: it keeps its \(sessions.count) sessions")
                exit(0)
            }
            lockFD = shared
            locked = true
        } else {
            // (Started by a liberttyd from before it shared its lock.) Its lock
            // says: it lets go of it as it goes. Once we have it we keep it.
            if shared >= 0 { sysClose(shared) }
            lockFD = open(socket + ".lock", O_RDWR | O_CLOEXEC)
            if lockFD >= 0 {
                for _ in 0..<1000 {
                    if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                    usleep(10_000)
                }
                guard locked else {
                    log("liberttyd hung up but still runs: it keeps its \(sessions.count) sessions")
                    exit(0)
                }
            }
        }
        var env = ProcessInfo.processInfo.environment
        let now = Date().timeIntervalSince1970
        let recent = (env["LIBERTTY_RECOVERIES"] ?? "").split(separator: ",")
            .compactMap { Double(String($0)) }.filter { now - $0 < crashWindow }
        guard recent.count < maxRecoveries else {
            log("liberttyd went away \(recent.count + 1) times in \(Int(crashWindow)) s; giving up: "
                + "its \(sessions.count) sessions end")
            sessions.forEach { sysClose($0.fd) }
            exit(0)
        }
        log("liberttyd went away without standing down (a crash?); a new one takes its \(sessions.count) sessions")
        env["LIBERTTY_RECOVERIES"] = (recent + [now]).map { String(Int($0)) }.joined(separator: ",")
        env["LIBERTTY_DAEMON_SOCKET"] = socket
        var left = sessions
        for _ in 0..<maxRecoveries where !left.isEmpty {
            // The lock as its descriptor 3: it shares our hold of it, which
            // outlasts us once it has it.
            guard let (c, _) = spawn(["liberttyd", "--recover"] + (locked ? ["--locked"] : []), env: env,
                                     passing: locked ? lockFD : -1) else { break }
            // The first run of a binary the system hasn't checked yet can take long.
            c.setReceiveTimeout(60)
            left = handOver(left, on: c)
            c.close()
        }
        if !left.isEmpty { log("couldn't give \(left.count) sessions to a new liberttyd; they end") }
        left.forEach { sysClose($0.fd) }
        exit(0)
    }

    /// The takeover's old side (as DaemonServer.handOver) to the new
    /// liberttyd on `c`: what it didn't take.
    private static func handOver(_ sessions: [Held], on c: Connection) -> [Held] {
        guard let hello = c.receive(), hello.kind == .hello else { return sessions }
        c.send(.welcome, json: ["version": Wire.version, "pid": Int(getpid())])
        guard let ask = c.receive(), ask.kind == .takeover else { return sessions }
        var left = sessions
        while let s = left.first {
            var header = s.header
            header["recovered"] = true
            let sent = c.send(.handoff, header: header, body: UnsafeRawBufferPointer(start: nil, count: 0))
            guard sent, let ack = c.receive(), ack.kind == .ack, c.sendDescriptor(s.fd) else { return left }
            sysClose(s.fd)
            left.removeFirst()
        }
        c.send(.result, json: ["ok": true, "sessions": sessions.count, "layouts": [Any]()])
        return []
    }

    /// Start this program with `arguments`, a socket to it on its stdin
    /// (and `passing` as its descriptor 3), logging where we do: the socket, and its pid.
    static func spawn(_ arguments: [String], env: [String: String], responsible: Bool? = nil,
                      passing descriptor: Int32 = -1) -> (Connection, pid_t)? {
        guard let executable = currentExecutablePath() else { return nil }
        var pair: [Int32] = [-1, -1]
        guard libertty_socketpair(&pair) == 0 else { return nil }
        // As liberttyd was started: answering for itself to macOS's privacy
        // checks, or (reached over ssh) under sshd's (see DaemonClient.spawn).
        let answers = responsible ?? (env["LIBERTTY_DAEMON_RESPONSIBLE"] != "0")
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let pid = libertty_spawn_detached_stdin(executable, &argv, &envp, DaemonServer.logPath(), answers ? 1 : 0,
                                                pair[1], descriptor)
        let failure = errno
        sysClose(pair[1])
        let c = Connection(fd: pair[0])
        guard pid > 0 else {
            log("couldn't start \(executable): \(String(cString: strerror(failure)))")
            return nil
        }
        c.setSendTimeout(10)
        return (c, pid)
    }

    static func log(_ message: String) { DaemonServer.log("guardian: \(message)") }
}

/// liberttyd's side of its guardian: each session as it starts, changes and
/// ends. On a queue of its own: nothing here holds up a session, or waits on
/// the guardian, but `standDown`.
final class GuardianLink: @unchecked Sendable {
    static let shared = GuardianLink()

    /// Every session now (DaemonServer's), for a guardian started late or again.
    var sessions: () -> [DaemonSession] = { [] }

    private let queue = DispatchQueue(label: "liberttyd.guardian", qos: .utility)
    // On `queue`:
    private var connection: Connection?
    /// The guardian's process while `connection` is its, until it's reaped.
    private var guardianPID: pid_t = 0
    /// Guardians started and not reaped yet. Each is reaped here, its pid
    /// forgotten in the same step: nothing on `queue` signals a pid reaped
    /// already, which the system may have given another process since.
    private var unreaped: Set<pid_t> = []
    /// liberttyd's lock (its descriptor), which each guardian shares.
    private var lock: Int32 = -1
    private var stoodDown = false
    private var lastStart: Double?
    /// A guardian that's gone is started again after this long at the soonest.
    private static let restartAfter: Double = 10

    /// A session started (or came from another liberttyd).
    func keep(_ session: DaemonSession) {
        guard let (header, fd) = session.guardianCopy() else { return }
        queue.async { [self] in
            defer { sysClose(fd) }
            guard !stoodDown else { return }
            // A new guardian is given every session, this one too.
            guard connection != nil else { return start() }
            send(header, fd)
        }
    }

    /// Its size or name changed: `fields` as in its takeover header.
    func update(_ id: String, _ fields: [String: Any]) {
        queue.async { [self] in
            guard let connection, !stoodDown else { return }
            var json = fields
            json["id"] = id
            if !connection.send(.update, json: json) { lost(connection) }
        }
    }

    /// It ended.
    func forget(_ id: String) {
        queue.async { [self] in
            guard let connection, !stoodDown else { return }
            if !connection.send(.forget, json: ["id": id]) { lost(connection) }
        }
    }

    /// liberttyd holds its lock through `fd` (before any session is
    /// guarded): each guardian holds it too.
    func share(lock fd: Int32) {
        queue.sync { lock = fd }
    }

    /// liberttyd exits on purpose: the guardian lets every session go (they end
    /// with liberttyd, or a newer one has them). Before the exit; it waits,
    /// for the guardian to be gone too: with its share of the lock, which a
    /// liberttyd started the moment we exit must find free.
    func standDown() {
        queue.sync {
            stoodDown = true
            guard let connection else { return }
            connection.send(.standDown)
            connection.setReceiveTimeout(2)
            _ = connection.receive()
            connection.close()
            self.connection = nil
            // One that didn't go (wedged) is ended, and reaped either way:
            // its share of the lock must be let go before we exit, or the
            // next liberttyd finds it held and leaves, every new tab waiting.
            end(guardianPID)
        }
    }

    /// Start a guardian and give it every session (on `queue`).
    private func start() {
        let all = sessions()
        guard !all.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if let lastStart, now - lastStart < Self.restartAfter { return }
        lastStart = now
        // It needn't answer for anything to macOS: it runs no programs.
        guard let (c, pid) = DaemonGuardian.spawn(["liberttyd", "--guardian"] + (lock >= 0 ? ["--locked"] : []),
                                                  env: ProcessInfo.processInfo.environment,
                                                  responsible: false, passing: lock) else { return retryLater() }
        unreaped.insert(pid)
        // Its going noticed (it says nothing on its own), and it reaped on `queue`.
        let thread = Thread { [weak self] in
            libertty_wait_exited(pid)
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.reap(pid)
                if self.connection === c { self.lost(c) }
            }
        }
        thread.name = "liberttyd.guardian.reaper"
        thread.start()
        c.setReceiveTimeout(30)
        c.send(.hello, json: ["version": Wire.version, "socket": Wire.socketPath, "pid": Int(getpid())])
        guard let welcome = c.receive(), welcome.kind == .welcome else {
            DaemonServer.log("its guardian liberttyd[\(pid)] didn't answer; sessions go unguarded for now")
            c.close()
            // Left running, it would hold its share of our lock for nothing.
            end(pid)
            retryLater()
            return
        }
        c.setReceiveTimeout(10)
        connection = c
        guardianPID = pid
        var kept = 0
        for s in all {
            guard let (header, fd) = s.guardianCopy() else { continue }
            send(header, fd)
            sysClose(fd)
            guard connection != nil else { return }
            kept += 1
        }
        DaemonServer.log("guardian liberttyd[\(pid)] holds its \(kept) sessions' ptys")
    }

    /// One session, in the takeover's lockstep (on `queue`).
    private func send(_ header: [String: Any], _ fd: Int32) {
        guard let c = connection else { return }
        guard c.send(.keep, json: header), let ack = c.receive(), ack.kind == .ack, c.sendDescriptor(fd) else {
            return lost(c)
        }
    }

    /// The guardian went (or stopped answering): another starts in a while (on `queue`).
    private func lost(_ c: Connection) {
        c.close()
        guard connection === c else { return }
        connection = nil
        // One that stopped answering is ended: holding our lock with us, it
        // would recover the sessions beside the next one should we crash.
        end(guardianPID)
        guardianPID = 0
        DaemonServer.log("lost its guardian; sessions go unguarded until another starts")
        retryLater()
    }

    /// A guardian ended at once, if it's still ours to end, and reaped (on
    /// `queue`): gone for sure, its share of the lock let go.
    private func end(_ pid: pid_t) {
        guard unreaped.contains(pid) else { return }
        kill(pid, SIGKILL)
        reap(pid)
    }

    /// A guardian that has ended (or is ending: this waits) reaped, its pid
    /// forgotten in the same step (on `queue`).
    private func reap(_ pid: pid_t) {
        guard unreaped.remove(pid) != nil else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if guardianPID == pid { guardianPID = 0 }
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + Self.restartAfter + 0.1) { [weak self] in
            guard let self, self.connection == nil, !self.stoodDown else { return }
            self.start()
        }
    }
}
