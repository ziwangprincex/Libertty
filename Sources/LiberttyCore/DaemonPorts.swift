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

/// One TCP socket a session's programs listen on.
public struct SessionPort: Codable, Sendable, Equatable {
    public var port: UInt16
    /// Where it listens: "127.0.0.1" (this machine only), "0.0.0.0" or "::"
    /// (anyone who can reach the machine).
    public var address: String
    public var pid: Int32
    /// What to call the program: the script or package a runtime runs (a
    /// Vite dev server reads "vite", not "node"), else the process's name.
    public var label: String
    /// When a scan first saw it (seconds since 1970).
    public var since: Double

    public init(port: UInt16, address: String, pid: Int32, label: String, since: Double) {
        self.port = port
        self.address = address
        self.pid = pid
        self.label = label
        self.since = since
    }

    var json: [String: Any] {
        ["port": Int(port), "address": address, "pid": Int(pid), "label": label, "since": since]
    }

    /// The same socket as before, whatever its first-seen time says.
    func isSame(as other: SessionPort) -> Bool {
        port == other.port && address == other.address && pid == other.pid && label == other.label
    }
}

/// What one session listens on: in a `ports` frame to its windows, in a
/// `ports` event, and in `libertty +ports`.
public struct SessionPorts: Codable, Sendable {
    public var id: String
    public var ports: [SessionPort]
    /// Some of the session's processes wouldn't say what they listen on
    /// (another user's, or /proc out of reach), so the list may be short.
    /// What this can't show: a program reparented away from the shell
    /// (tmux's), or one listening in a network of its own (a container).
    public var partial: Bool

    public init(id: String, ports: [SessionPort], partial: Bool) {
        self.id = id
        self.ports = ports
        self.partial = partial
    }
}

extension DaemonServer {
    /// The `listPorts` answer.
    struct Ports: Codable {
        var ok: Bool
        var sessions: [SessionPorts]
    }
}

/// The listening TCP sockets of a session's process tree: libproc on macOS,
/// /proc/net/tcp and each process's descriptors on Linux. A scan asks the
/// kernel about every process under the shell, so it belongs on a slow
/// cadence (PortWatch), never on the output path.
enum PortScan {
    /// The most sockets one scan reports (a frame stays small) and the most
    /// processes it looks under; both full mean the answer is short.
    static let maxPorts = 64
    static let maxProcesses = 256

    /// One socket before it's labelled.
    struct Socket: Equatable {
        var port: UInt16
        var address: String
    }

    /// Every port the shell and its descendants listen on, right now.
    static func look(shell: pid_t, at now: Double) -> (ports: [SessionPort], partial: Bool) {
        guard shell > 0, let prober = Prober() else { return ([], true) }
        var pids = [pid_t](repeating: 0, count: maxProcesses)
        let found = Int(libertty_proc_descendants(shell, &pids, Int32(pids.count)))
        var ports: [SessionPort] = []
        // A tree too big to list, or more sockets than fit: what's left out
        // is unknown, not absent.
        var partial = found >= maxProcesses
        for pid in [shell] + pids.prefix(found) {
            guard ports.count < maxPorts else {
                partial = true
                break
            }
            let (sockets, readable) = prober.sockets(of: pid)
            if !readable { partial = true }
            guard !sockets.isEmpty else { continue }
            let label = label(of: pid)
            if sockets.count > maxPorts - ports.count { partial = true }
            for socket in sockets.prefix(maxPorts - ports.count) {
                let port = SessionPort(port: socket.port, address: socket.address, pid: pid, label: label, since: now)
                if !ports.contains(where: { $0.isSame(as: port) }) { ports.append(port) }
            }
        }
        ports.sort { ($0.port, $0.address, $0.pid) < ($1.port, $1.address, $1.pid) }
        return (ports, partial)
    }

    /// What a process listening on a port is called: the script or package a
    /// runtime was handed (`node …/vite/bin/vite.js` is vite,
    /// `python3 -m http.server` is http.server), else its own name. Its
    /// arguments are only read for a runtime, and only when it listens:
    /// reading them can fault a big process's pages back in.
    static func label(of pid: pid_t) -> String {
        let name = AgentNames.baseName(ForegroundProgram.processName(pid))
        guard AgentNames.runsAnotherProgram(name), !AgentNames.shells.contains(name.lowercased()) else { return name }
        let scripted = script(in: ForegroundProgram.arguments(pid))
        return scripted.isEmpty ? name : scripted
    }

    /// Options whose value comes as the next argument: that value is not
    /// the program (`node -r ts-node/register app.ts` runs app.ts).
    static let optionsWithValues: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
        "--env-file", "--inspect-port", "--title", "-W", "-X",
    ]
    /// A runtime's own commands before the program it runs (`deno run
    /// server.ts`, `bun run dev`): not the program either.
    static let runtimeCommands: Set<String> = ["run", "exec", "x"]

    /// The program in a runtime's arguments (argv[0] left out): the first
    /// one that isn't an option, an option's value or the runtime's own
    /// command, by its own name or the package it's in
    /// (`…/node_modules/vite/bin/vite.js` and `…/node_modules/.bin/vite`
    /// are both vite). "" when they say nothing.
    static func script(in arguments: String) -> String {
        var skipNext = false, commandSeen = false
        var found: Substring?
        for word in arguments.split(separator: " ") {
            if skipNext {
                skipNext = false
                continue
            }
            if word.hasPrefix("-") {
                skipNext = optionsWithValues.contains(String(word))
                continue
            }
            // A bare number is an option's value too (`--max-old-space-size 4096`).
            if word.allSatisfy(\.isNumber) { continue }
            // The first word that isn't an option may be the runtime's command.
            if !commandSeen, runtimeCommands.contains(String(word)) {
                commandSeen = true
                continue
            }
            found = word
            break
        }
        guard let path = found else { return "" }
        let parts = path.split(separator: "/").map(String.init)
        guard var name = parts.last, !name.isEmpty else { return "" }
        // cli.js, index.mjs: the extension is noise. A script in another
        // language keeps its own (manage.py reads better than manage).
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".mts", ".cts"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        // Those names say nothing by themselves: the package's does.
        let vague: Set<String> = ["cli", "index", "main", "bin", "run", "start", "server", "serve", "app", "dist"]
        if vague.contains(name.lowercased()), let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count {
            let package = parts[i + 1].hasPrefix("@") && i + 2 < parts.count ? parts[i + 2] : parts[i + 1]
            if !package.hasPrefix(".") { return package }
        }
        return name
    }

    /// Reads one process's listening sockets. Made once per scan: on Linux
    /// it holds /proc/net's rows, which say which socket listens and where.
    private struct Prober {
        #if os(Linux)
        private let rows: [UInt64: Socket]

        init?() {
            var rows: [UInt64: Socket] = [:]
            var read = false
            for (path, ipv6) in [("/proc/net/tcp", false), ("/proc/net/tcp6", true)] {
                guard let text = PortScan.readFile(path) else { continue }
                read = true
                rows.merge(PortScan.listeningRows(text, ipv6: ipv6)) { first, _ in first }
            }
            // No table at all: what the session listens on is unknown.
            guard read else { return nil }
            self.rows = rows
        }

        func sockets(of pid: pid_t) -> (sockets: [Socket], readable: Bool) {
            var inodes = [UInt64](repeating: 0, count: 256)
            let count = Int(libertty_proc_socket_inodes(pid, &inodes, Int32(inodes.count)))
            guard count >= 0 else { return ([], false) }
            // More sockets than fit: the rest stays unknown.
            return (inodes.prefix(count).compactMap { rows[$0] }, count < inodes.count)
        }
        #else
        init?() {}

        func sockets(of pid: pid_t) -> (sockets: [Socket], readable: Bool) {
            var listeners = [libertty_listener](repeating: libertty_listener(), count: 64)
            let count = Int(libertty_proc_listeners(pid, &listeners, Int32(listeners.count)))
            guard count >= 0 else { return ([], false) }
            let sockets = listeners.prefix(count).map { listener in
                Socket(port: listener.port, address: withUnsafeBytes(of: listener.address) {
                    String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                })
            }
            // More listening sockets than fit: the rest stays unknown.
            return (sockets, count < listeners.count)
        }
        #endif
    }

    /// A whole /proc file, which has no size to ask for: read until it ends.
    /// Nil when it can't be read.
    static func readFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { sysClose(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        // /proc/net/tcp on a busy machine is tens of kilobytes; past a
        // megabyte the rows that matter are long gone.
        while bytes.count < 1 << 20 {
            let n = chunk.withUnsafeMutableBytes { sysRead(fd, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            bytes.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The listening rows of /proc/net/tcp or /proc/net/tcp6, by socket
    /// inode. The columns are
    /// `sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode …`,
    /// st 0A is LISTEN, and an address is `HEX:PORT` — the port in plain
    /// hex, the host part in 32-bit words as the machine writes them.
    static func listeningRows(_ text: String, ipv6: Bool) -> [UInt64: Socket] {
        var rows: [UInt64: Socket] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            // The header line ("sl local_address …") has no state column of its own.
            guard columns.count >= 10, columns[3] == "0A" else { continue }
            guard let inode = UInt64(columns[9]), inode > 0 else { continue }
            let local = columns[1].split(separator: ":")
            guard local.count == 2, let port = UInt16(local[1], radix: 16),
                  let address = address(hex: String(local[0]), ipv6: ipv6) else { continue }
            rows[inode] = Socket(port: port, address: address)
        }
        return rows
    }

    /// A /proc/net address: 8 hex digits for IPv4, 32 for IPv6, each 32-bit
    /// word written as this machine holds it (little-endian in practice).
    /// Nil when it's neither.
    static func address(hex: String, ipv6: Bool) -> String? {
        let digits = Array(hex.utf8)
        guard digits.count == (ipv6 ? 32 : 8) else { return nil }
        var bytes = [UInt8](repeating: 0, count: digits.count / 2)
        for i in 0..<bytes.count {
            guard let high = value(ofHex: digits[i * 2]), let low = value(ofHex: digits[i * 2 + 1]) else { return nil }
            bytes[i] = high << 4 | low
        }
        // Each word back from the machine's order to the wire's.
        for word in stride(from: 0, to: bytes.count, by: 4) {
            bytes[word..<(word + 4)].reverse()
        }
        var out = [CChar](repeating: 0, count: 46)
        let family = ipv6 ? AF_INET6 : AF_INET
        guard inet_ntop(family, &bytes, &out, socklen_t(out.count)) != nil else { return nil }
        return String(cString: out)
    }

    private static func value(ofHex c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x41...0x46: c - 0x41 + 10
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }
}

/// liberttyd's watch over the ports a session's programs listen on: a scan
/// of its process tree now and then, told as a `ports` event and in `ports`
/// frames to the windows showing it, so a dev server's address shows up
/// without anyone asking (Rex watches its terminals the same way).
///
/// The cost is the point. A scan walks the session's processes and their
/// descriptors, so one happens every `floor` seconds while the ports change
/// and only every `ceiling` while they don't; a session with nothing in
/// front of its shell, nothing listening and no output since the last scan
/// is dropped from the clock until output comes back — an idle shell costs
/// nothing at all. One event a second per session at most.
///
/// Scans are serialized by `scanning` and the state kept under `lock`,
/// which is never held during a scan (the session's output thread sets a
/// flag here) nor while telling anyone. Nothing here holds `lock` while it
/// talks to the clock, and the clock holds its own lock only to pick what's
/// due.
final class PortWatch {
    /// Seconds between scans: this long while the ports change, doubling up
    /// to `ceiling` while they don't (Rex's 10 seconds to 5 minutes).
    static let floor = 10.0
    static let ceiling = 300.0
    /// A scan this soon after a command starts or ends (the shell says so,
    /// OSC 133): a server binds its port as it starts.
    static let afterCommand = 1.5
    /// The first scan of a new session, and one after a window attaches.
    static let firstLook = 2.0
    /// At most one event a second per session.
    static let minimumGap = 1.0

    private let id: String
    private let shell: pid_t
    /// Whether a program is in front of the shell (one kernel call).
    private let busy: () -> Bool
    private let tell: (SessionPorts) -> Void

    private let lock = NSLock()
    private let scanning = NSLock()
    /// What the last scan found, and what was last told (nil: nothing yet).
    private var found: [SessionPort] = []
    private var told: [SessionPort]?
    private var partial = false
    private var toldPartial = false
    private var interval = PortWatch.floor
    /// When the next scan is due and when the last event went out (the
    /// monotonic clock, in seconds).
    private var due: Double
    private var lastEvent: Double
    /// Output came since the last scan: a program may have started one.
    private var stirred = true
    private var asleep = false
    private var ended = false

    init(id: String, shell: pid_t, busy: @escaping () -> Bool, tell: @escaping (SessionPorts) -> Void) {
        self.id = id
        self.shell = shell
        self.busy = busy
        self.tell = tell
        let now = PortWatch.seconds()
        due = now + PortWatch.firstLook
        lastEvent = now - PortWatch.minimumGap
        Clock.shared.add(self)
    }

    /// Output came (the session's output thread): only a flag, unless the
    /// watch had gone to sleep — then it's back on the clock.
    func noteOutput() {
        lock.lock()
        stirred = true
        let wake = asleep && !ended
        if wake {
            asleep = false
            due = Self.seconds() + Self.floor
        }
        lock.unlock()
        if wake { Clock.shared.add(self) }
    }

    /// A command started or ended: scan soon, and at the short cadence
    /// again — this is when servers come and go.
    func commandBoundary() { lookIn(Self.afterCommand, restartCadence: true) }

    /// A window attached: it wants what the session listens on now.
    func lookSoon() { lookIn(Self.firstLook, restartCadence: false) }

    private func lookIn(_ seconds: Double, restartCadence: Bool) {
        lock.lock()
        guard !ended else { return lock.unlock() }
        let soon = Self.seconds() + seconds
        if restartCadence { interval = Self.floor }
        let wake = asleep
        if wake { asleep = false }
        if wake || due > soon { due = soon }
        lock.unlock()
        if wake { Clock.shared.add(self) } else { Clock.shared.reschedule() }
    }

    /// The session ended, or liberttyd is handing it over. Returns once no
    /// scan is under way: a scan asks the session's pty what's in front, so
    /// the pty may be let go of only after this.
    func stop() {
        lock.lock()
        ended = true
        lock.unlock()
        scanning.lock()
        scanning.unlock()
        Clock.shared.remove(self)
    }

    /// When the next scan is due; never for one asleep or ended.
    var dueAt: Double {
        lock.lock()
        defer { lock.unlock() }
        return asleep || ended ? .infinity : due
    }

    /// Scan now and tell everyone if it's news: the clock's pass, and a
    /// `ports` request (`+ports` always answers from a fresh scan).
    /// `fromClock`: the clock's own pass, which sets its timer once after.
    @discardableResult
    func look(fromClock: Bool = false) -> SessionPorts {
        let (answer, news) = scan()
        // Told with no lock of ours held: a listener or a window that
        // doesn't read holds up only itself.
        if news { tell(answer) }
        // The timer takes the scan this one asked for (a change held back by
        // the event's second). One asleep stays on the clock, due never:
        // taken off here, it could miss output waking it meanwhile and stay
        // off for good.
        if !fromClock { Clock.shared.reschedule() }
        return answer
    }

    /// The scan itself, one at a time: what it found and whether that's news.
    private func scan() -> (SessionPorts, news: Bool) {
        scanning.lock()
        defer { scanning.unlock() }
        lock.lock()
        let before = found, over = ended, lastPartial = partial
        lock.unlock()
        // Ended (or handed to a newer liberttyd): its processes are gone or
        // another's to look at; the last scan's answer stands.
        guard !over else { return (SessionPorts(id: id, ports: before, partial: lastPartial), false) }
        let seen = PortScan.look(shell: shell, at: Date().timeIntervalSince1970)
        let inFront = busy()
        // Each socket keeps the time the first scan that saw it gave it.
        let ports = seen.ports.map { port -> SessionPort in
            var port = port
            if let earlier = before.first(where: { $0.isSame(as: port) }) { port.since = earlier.since }
            return port
        }
        lock.lock()
        let unchanged = ports == found && seen.partial == partial
        found = ports
        partial = seen.partial
        interval = unchanged ? min(Self.ceiling, interval * 2) : Self.floor
        let now = Self.seconds()
        var news = ports != (told ?? []) || seen.partial != toldPartial
        if news, now - lastEvent < Self.minimumGap {
            // One event a second: the next pass tells it.
            news = false
            due = lastEvent + Self.minimumGap
        } else {
            if news {
                told = ports
                toldPartial = seen.partial
                lastEvent = now
            }
            due = now + interval
            // Nothing in front of the shell, nothing listening and nothing
            // printed since the last scan: there is nothing to find here
            // until the session stirs again (it never wakes a program).
            if ports.isEmpty, !seen.partial, !stirred, !inFront, !ended { asleep = true }
        }
        stirred = false
        lock.unlock()
        return (SessionPorts(id: id, ports: ports, partial: seen.partial), news)
    }

    @inline(__always)
    static func seconds() -> Double { Double(monotonicNanos()) / 1e9 }

    /// One timer for every watch, as the sleeping compressors have
    /// (IdleCompressor.Sleepers): it wakes when the earliest scan is due,
    /// scans what's due one after another (no thread per session), and stops
    /// once nothing is watched.
    final class Clock: @unchecked Sendable {
        static let shared = Clock()

        private let queue = DispatchQueue(label: "liberttyd.ports", qos: .utility)
        private let lock = NSLock()
        private final class Weak {
            weak var value: PortWatch?
            init(_ v: PortWatch) { value = v }
        }
        private var watches: [ObjectIdentifier: Weak] = [:]
        private var timer: DispatchSourceTimer?

        func add(_ watch: PortWatch) {
            lock.withLock { watches[ObjectIdentifier(watch)] = Weak(watch) }
            reschedule()
        }

        func remove(_ watch: PortWatch) {
            lock.withLock { watches[ObjectIdentifier(watch)] = nil }
            reschedule()
        }

        /// The timer to the earliest scan due; stopped while every watch is
        /// asleep or gone. The due times are read under the clock's lock,
        /// and the timer set under the same hold: a reschedule that looked
        /// before a watch came due can't cancel the one that came after it.
        /// (A watch takes its own lock inside the clock's, never the other
        /// way: none calls the clock holding its own.)
        func reschedule() {
            lock.lock()
            defer { lock.unlock() }
            let soonest = watches.values.compactMap(\.value).map(\.dueAt).min()
            guard let soonest, soonest.isFinite else {
                timer?.cancel()
                timer = nil
                return
            }
            let wait = max(0, soonest - PortWatch.seconds())
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.setEventHandler { [weak self] in self?.pass() }
                timer = t
                t.schedule(deadline: .now() + wait, leeway: .milliseconds(500))
                t.resume()
            } else {
                timer?.schedule(deadline: .now() + wait, leeway: .milliseconds(500))
            }
        }

        /// Scan every watch whose time has come, then wait for the next.
        private func pass() {
            let now = PortWatch.seconds()
            let waiting = lock.withLock { watches.values.compactMap(\.value) }
            for watch in waiting where watch.dueAt <= now + 0.1 { watch.look(fromClock: true) }
            reschedule()
        }
    }
}
