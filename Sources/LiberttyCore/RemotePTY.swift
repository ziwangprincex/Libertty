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

/// A session that lives in liberttyd, seen through one connection: the same
/// interface as a local `PTY`. If liberttyd goes away without the session ending
/// (a newer liberttyd took over, or the network to its host dropped), it
/// redials and re-attaches, handing the fresh snapshot to `onReattach` so the
/// window's replica can catch up.
public final class RemotePTY: TerminalBackend {
    public let id: String
    public let address: DaemonAddress
    public private(set) var pid: pid_t
    public var onOutput: ((UnsafeBufferPointer<UInt8>) -> Void)?
    public var onExit: ((Int32) -> Void)?
    /// After a redial: the session's state as liberttyd has it now (on `queue`).
    public var onReattach: ((Data) -> Void)?
    /// Mid-stream: the session's state, sent in place of output this window
    /// fell too far behind to be sent (on `queue`, in order with output).
    public var onCatchUp: ((Data) -> Void)?
    /// On another machine: the link went down (false) or is back (true), on `queue`.
    public var onLinkChange: ((Bool) -> Void)?

    private var connection: Connection?
    private let queue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "libertty.remote.write", qos: .userInteractive)
    private let stateLock = NSLock()
    private var detached = false
    /// We asked for the end (closing the pane): a hang-up is final.
    private var ended = false
    private var exitStatus: Int32?
    private var reading = false
    /// Until the first attach succeeds: if liberttyd no longer has the session
    /// (the host rebooted), start this instead.
    private var fallback: (@Sendable () -> CreateRequest?)?

    private init(id: String, pid: pid_t, connection: Connection?, address: DaemonAddress, queue: DispatchQueue) {
        self.id = id
        self.pid = pid
        self.connection = connection
        self.address = address
        self.queue = queue
    }

    deinit { detach() }

    /// Start a new session in liberttyd.
    public static func create(_ request: CreateRequest, address: DaemonAddress = .local, queue: DispatchQueue) throws -> RemotePTY {
        guard let c = address.connect() else { throw DaemonClientError.unavailable }
        let pid = try create(c, request)
        return RemotePTY(id: request.id, pid: pid, connection: c, address: address, queue: queue)
    }

    private static func create(_ c: Connection, _ request: CreateRequest) throws -> pid_t {
        c.setBufferSizes(1 << 21)
        c.setReceiveTimeout(15)
        var request = request
        request.catchUp = true  // see readLoop's `.snapshot`
        c.send(.create, encoding: request)
        guard let reply = c.receive() else { throw DaemonClientError.unavailable }
        guard reply.kind == .attached, let (header, _) = reply.headerAndBody else {
            throw DaemonClientError.refused(reply.json["error"] as? String ?? "unexpected reply")
        }
        c.setReceiveTimeout(0)
        return pid_t(header["pid"] as? Int ?? 0)
    }

    /// Attach to a running session. Returns its snapshot too (empty if liberttyd
    /// couldn't encode one).
    public static func attach(id: String, address: DaemonAddress = .local, queue: DispatchQueue) throws -> (RemotePTY, Data) {
        guard let c = address.connect() else { throw DaemonClientError.unavailable }
        c.setBufferSizes(1 << 21)
        let (pid, snapshot) = try attach(c, id: id)
        return (RemotePTY(id: id, pid: pid, connection: c, address: address, queue: queue), snapshot)
    }

    /// A session on a machine that may not be reachable yet (a window
    /// restored at launch): it connects in the background, and its state
    /// arrives through `onReattach`.
    /// `fallback` is asked for once connected (it may need what the host told us).
    public static func reattaching(id: String, address: DaemonAddress, fallback: (@Sendable () -> CreateRequest?)?,
                                   queue: DispatchQueue) -> RemotePTY {
        let pty = RemotePTY(id: id, pid: 0, connection: nil, address: address, queue: queue)
        pty.fallback = fallback
        return pty
    }

    private static func attach(_ c: Connection, id: String) throws -> (pid_t, Data) {
        c.setReceiveTimeout(20)
        c.send(.attach, json: ["id": id, "catchUp": true])
        guard let reply = c.receive() else { throw DaemonClientError.unavailable }
        guard reply.kind == .attached, let (header, body) = reply.headerAndBody else {
            throw DaemonClientError.refused(reply.json["error"] as? String ?? "unexpected reply")
        }
        c.setReceiveTimeout(0)
        return (pid_t(header["pid"] as? Int ?? 0), body)
    }

    /// Begin delivering output; set the handlers first.
    public func startReading() {
        guard !reading else { return }
        reading = true
        let bytes = ByteQueue()
        let thread = Thread { [weak self] in self?.readLoop(bytes) }
        thread.name = "libertty.remote.reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func readLoop(_ bytes: ByteQueue) {
        func wake() {
            queue.async { [weak self] in self?.drain(bytes) ?? bytes.discardAll() }
        }
        while true {
            if let c = currentConnection {
                let alive = c.receiveFrames { kind, payload in
                    switch kind {
                    case .output:
                        if bytes.push(payload.bindMemory(to: UInt8.self)) { wake() }
                    case .snapshot:
                        // We fell behind, and liberttyd skipped us ahead. In
                        // order: `queue` applies what was pushed before it
                        // first, and nothing after is pushed until it's done.
                        let snapshot = Data(payload)
                        queue.sync { onCatchUp?(snapshot) }
                    case .exited:
                        let status = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any]
                        stateLock.lock()
                        exitStatus = Int32(status?["status"] as? Int ?? 0)
                        stateLock.unlock()
                    default:
                        break
                    }
                }
                if alive { continue }
            }
            // Hung up (or not connected yet). Ended, or let go of: done.
            // Otherwise liberttyd was replaced, or its host is out of reach.
            stateLock.lock()
            let finished = detached || ended || exitStatus != nil
            stateLock.unlock()
            if finished || !redial(bytes, wake: wake) { break }
        }
        if bytes.close() { wake() }
    }

    private var currentConnection: Connection? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connection
    }

    /// Reconnect and re-attach: to this Mac's liberttyd for up to ~10 s (a
    /// takeover is quick); to a host's for as long as the window wants it.
    /// Either way the window hears the link went down — a liberttyd that
    /// died is news too, not just a host out of reach — and, if it comes
    /// back, that it did.
    private func redial(_ bytes: ByteQueue, wake: () -> Void) -> Bool {
        let remote = address.isRemote
        let wasConnected = currentConnection != nil
        if wasConnected { queue.async { [weak self] in self?.onLinkChange?(false) } }
        var attempt = 0
        while remote || attempt < 100 {
            if attempt > 0 || wasConnected {
                // A host: back off to a few seconds between tries.
                usleep(remote ? useconds_t(min(3_000_000, 250_000 * (1 << min(attempt, 4)))) : 100_000)
            }
            attempt += 1
            stateLock.lock()
            let gone = detached || ended
            let pendingFallback = fallback
            stateLock.unlock()
            if gone { return false }
            guard let c = address.connect() else { continue }
            c.setBufferSizes(1 << 21)
            let snapshot: Data
            do {
                let (pid, data) = try Self.attach(c, id: id)
                self.pid = pid
                snapshot = data
            } catch DaemonClientError.refused {
                // The session is gone. Restoring: start a fresh one in its place.
                guard let request = pendingFallback?(), let fresh = address.connect(),
                      let pid = try? Self.create(fresh, request) else { return false }
                self.pid = pid
                stateLock.lock()
                connection = fresh
                fallback = nil
                stateLock.unlock()
                if settled(fresh) { return false }
                queue.async { [weak self] in self?.onLinkChange?(true) }
                return true
            } catch {
                continue  // the link broke halfway: try again
            }
            stateLock.lock()
            connection = c
            fallback = nil
            stateLock.unlock()
            if settled(c) { return false }
            // Before reading on: output from the old connection still queued
            // applies first, and nothing from the new one can land in a
            // drain that runs before the snapshot (and be thrown away by it).
            queue.sync { onReattach?(snapshot) }
            queue.async { [weak self] in self?.onLinkChange?(true) }
            return true
        }
        return false
    }

    private func drain(_ bytes: ByteQueue) {
        while true {
            switch bytes.take() {
            case .bytes(let chunk):
                chunk.withUnsafeBufferPointer { onOutput?($0) }
            case .closed:
                stateLock.lock()
                let status = exitStatus
                let wasDetached = detached
                stateLock.unlock()
                if !wasDetached { onExit?(status ?? 0) }
                return
            case .idle:
                return
            }
        }
    }

    // MARK: TerminalBackend

    public func write(_ data: Data) { send(.input, data) }

    public func writeReply(_ data: Data) { send(.reply, data) }

    public func clear(atPrompt: Bool) -> Bool {
        let payload = (try? JSONSerialization.data(withJSONObject: ["atPrompt": atPrompt])) ?? Data()
        send(.clear, payload)
        return true
    }

    /// Dropped while not connected: typing into a link that's down must not
    /// replay later.
    private func send(_ kind: Wire.Kind, _ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.currentConnection?.send(kind, data)
        }
    }

    public func resize(_ size: GridSize) {
        var payload = Data(capacity: 8)
        for v in [size.cols, size.rows, size.widthPx, size.heightPx] {
            withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) }
        }
        let c = currentConnection
        writeQueue.async { c?.send(.resize, payload) }
    }

    /// Another machine's process table can't be asked from here.
    public var hasForegroundProgram: Bool {
        guard !address.isRemote else { return false }
        let pgid = libertty_proc_tty_pgid(pid)
        return pgid > 0 && pgid != pid
    }

    public func terminate() {
        stateLock.lock()
        ended = true
        stateLock.unlock()
        let c = currentConnection
        let id = id, address = address
        if address.isRemote {
            // Never hold up quitting on the network; while the link is down,
            // a separate connection ends it by name.
            writeQueue.async {
                if c?.send(.kill, json: [:]) != true { _ = DaemonClient.request(.kill, json: ["id": id], address: address) }
            }
            return
        }
        // Synchronous: the app may be quitting right after.
        writeQueue.sync { _ = c?.send(.kill, json: [:]) }
    }

    public func detach() {
        stateLock.lock()
        guard !detached else { return stateLock.unlock() }
        detached = true
        let c = connection
        stateLock.unlock()
        // After queued input and resizes have gone out.
        writeQueue.async { c?.close() }
    }

    /// Ended or let go of while the link was being made: a kill by name
    /// finds nothing until the session exists, and a hang-up had no
    /// connection to close. Done now over `c`; true if so.
    private func settled(_ c: Connection) -> Bool {
        stateLock.lock()
        let (wasEnded, wasDetached) = (ended, detached)
        stateLock.unlock()
        guard wasEnded || wasDetached else { return false }
        writeQueue.async {
            if wasEnded { _ = c.send(.kill, json: [:]) }
            c.close()
        }
        return true
    }
}

public enum DaemonClientError: Error, CustomStringConvertible {
    case unavailable
    case refused(String)

    public var description: String {
        switch self {
        case .unavailable: "liberttyd isn't reachable"
        case .refused(let why): why
        }
    }
}

/// Finding, starting and asking liberttyd.
public enum DaemonClient {
    public struct Welcome {
        public var version: Int
        public var build: String
        public var pid: pid_t
        /// What it can do beyond the protocol's beginnings (`layout`,
        /// `catchUp`); empty for a liberttyd from before features were named.
        public var features: [String]
    }

    /// Who answers on the socket, if anyone.
    public static func hello(timeout: Double = 2, address: DaemonAddress = .local) -> Welcome? {
        guard let c = address.connect() else { return nil }
        c.setReceiveTimeout(timeout)
        c.send(.hello, json: ["version": Wire.version])
        guard let reply = c.receive(), reply.kind == .welcome else { return nil }
        let json = reply.json
        return Welcome(version: json["version"] as? Int ?? 0, build: json["build"] as? String ?? "",
                       pid: pid_t(json["pid"] as? Int ?? 0), features: json["features"] as? [String] ?? [])
    }

    /// One request, one result (list, capture, send, kill by id, shutdown).
    public static func request(_ kind: Wire.Kind, json: [String: Any] = [:], timeout: Double = 5,
                               address: DaemonAddress = .local) -> Connection.Frame? {
        guard let c = address.connect() else { return nil }
        c.setReceiveTimeout(timeout)
        c.send(kind, json: json)
        return c.receive()
    }

    /// The same with raw bytes as the request (storeLayout).
    public static func request(_ kind: Wire.Kind, payload: Data, timeout: Double = 5,
                               address: DaemonAddress = .local) -> Connection.Frame? {
        guard let c = address.connect() else { return nil }
        c.setReceiveTimeout(timeout)
        c.setSendTimeout(Int(timeout.rounded(.up)))
        c.send(kind, payload)
        return c.receive()
    }

    /// How a request to a liberttyd that must do `feature` went.
    public enum Reply {
        case answered(Connection.Frame)
        /// It doesn't do that (an older liberttyd drops requests it doesn't
        /// know without a word, so it's asked first).
        case unsupported
        /// No connection, or no answer in time.
        case unanswered
    }

    /// One request, `json` or raw `payload`, to a liberttyd that does
    /// `feature` — asked on the same connection, so a host costs one link.
    public static func request(_ kind: Wire.Kind, json: [String: Any] = [:], payload: Data? = nil, needing feature: String,
                               timeout: Double = 5, address: DaemonAddress = .local) -> Reply {
        guard let c = address.connect() else { return .unanswered }
        c.setReceiveTimeout(timeout)
        c.setSendTimeout(Int(timeout.rounded(.up)))
        c.send(.hello, json: ["version": Wire.version])
        guard let welcome = c.receive(), welcome.kind == .welcome else { return .unanswered }
        guard (welcome.json["features"] as? [String] ?? []).contains(feature) else { return .unsupported }
        if let payload { c.send(kind, payload) } else { c.send(kind, json: json) }
        return c.receive().map(Reply.answered) ?? .unanswered
    }

    public static func sessions(address: DaemonAddress = .local) -> [SessionInfo]? {
        guard let frame = request(.list, address: address), frame.kind == .result else { return nil }
        struct List: Decodable { var sessions: [SessionInfo] }
        return frame.decode(List.self)?.sessions
    }

    /// Make sure the liberttyd at `executable` (the one this app ships) serves
    /// the socket: start it, or have it take over from another build.
    /// Returns whether a compatible liberttyd answers.
    @discardableResult
    public static func ensureRunning(executable: String, logPath: String?) -> Bool {
        let mine = DaemonServer.buildID(ofExecutable: executable)
        if let w = hello() {
            if w.version == Wire.version, w.build == mine { return true }
            log("liberttyd[\(w.pid)] is build \(w.build) (protocol \(w.version)); replacing it with \(mine)")
            guard let pid = spawn(executable, ["--takeover"], logPath: logPath) else { return w.version == Wire.version }
            if waitFor({ $0.build == mine }, seconds: 10, child: pid) { return true }
            return hello()?.version == Wire.version
        }
        guard let pid = spawn(executable, [], logPath: logPath) else { return false }
        // The first run of a freshly built liberttyd can take seconds (the
        // system checks a new binary): wait as long as it's alive.
        return waitFor({ $0.version == Wire.version }, seconds: 10, child: pid)
    }

    private static func waitFor(_ condition: (Welcome) -> Bool, seconds: Double, child: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let w = hello(timeout: 0.5), condition(w) { return true }
            // It exited (another liberttyd may have won the lock): one last look.
            if kill(child, 0) != 0 { return hello(timeout: 0.5).map(condition) ?? false }
            usleep(20_000)
        }
        return false
    }

    private static func spawn(_ executable: String, _ arguments: [String], logPath: String?) -> pid_t? {
        if let logPath {
            try? FileManager.default.createDirectory(atPath: logPath.parentPath,
                                                     withIntermediateDirectories: true)
        }
        var argv = (["liberttyd"] + arguments).map { strdup($0) } + [nil]
        var env = ProcessInfo.processInfo.environment
        env["LIBERTTY_DAEMON_SOCKET"] = Wire.socketPath
        var envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let pid = libertty_spawn_detached(executable, &argv, &envp, logPath)
        guard pid > 0 else {
            log("couldn't start \(executable): \(String(cString: strerror(errno)))")
            return nil
        }
        // Reap it when it exits while we're still running (it's our child).
        reapWhenDone(pid)
        return pid
    }

    private static func log(_ message: String) {
        writeError("libertty: \(message)\n")
    }
}
