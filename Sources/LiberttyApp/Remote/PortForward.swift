import Darwin
import Foundation
import LiberttyCore

/// A port carried between this Mac and a host Libertty is connected to
/// (File ▸ Connect to Host…), over that host's own shared ssh connection:
/// `ssh -O forward` asks the ControlMaster that is already up for it, and
/// `-O cancel` takes it back. Nothing logs in again, so a forward costs one
/// round trip to a connection that exists anyway.
///
/// Two directions, as ssh spells them:
///   `open`  `-L 127.0.0.1:local:remoteHost:remote` — a port there, reachable here
///   `share` `-R 127.0.0.1:remote:localhost:local`  — a port here, reachable there
struct PortForward: Sendable, Equatable {
    enum Direction: String, Sendable, Equatable {
        /// A port on the host, listened for on this Mac (`ssh -L`).
        case open
        /// A port on this Mac, listened for on the host (`ssh -R`).
        case share
    }

    /// The host's ssh destination (`RemoteHost.destination`).
    var destination: String
    var direction: Direction
    /// The port on this Mac.
    var local: Int
    /// The port on the host's side.
    var remote: Int
    /// What the host resolves `remote` on: `localhost` for its own dev
    /// server, another name for a machine only the host can reach.
    var remoteHost: String = "localhost"

    /// Short, stable and typed by hand (`libertty +forward close`): the
    /// host, which way it goes, and the port on the host's side.
    var id: String {
        let letter = direction == .open ? "L" : "R"
        let there = direction == .open && remoteHost != "localhost" ? remoteHost + ":" : ""
        return "\(destination):\(letter)\(there)\(remote)"
    }

    /// What it does, for a list: the two ends, the arrow the way it carries.
    var summary: String {
        switch direction {
        case .open: "127.0.0.1:\(local) → \(remoteHost):\(remote) on \(destination)"
        case .share: "\(remote) on \(destination) → 127.0.0.1:\(local)"
        }
    }

    // MARK: ssh's words

    /// ssh's own spelling of the forward — what follows `-L` or `-R`.
    /// `-L bind:port:host:hostport` listens here and connects there;
    /// `-R bind:port:host:hostport` listens there and connects here. The
    /// bind address is 127.0.0.1 both ways: a forward is for this machine
    /// (or that one), not for its network.
    var specification: String {
        switch direction {
        case .open: "127.0.0.1:\(local):\(remoteHost):\(remote)"
        case .share: "127.0.0.1:\(remote):localhost:\(local)"
        }
    }

    var flag: String { direction == .open ? "-L" : "-R" }

    /// The whole ssh command line that asks the host's ControlMaster to add
    /// this forward or drop it, after the options its own connection uses.
    static func controlArguments(for forward: PortForward, cancel: Bool, options: [String]) -> [String] {
        options + ["-O", cancel ? "cancel" : "forward", forward.flag, forward.specification, forward.destination]
    }

    // MARK: Links to this machine

    /// What a link to the machine it was printed on means on each side: the
    /// name the host connects to, and the name to open here. Libertty always
    /// listens on 127.0.0.1, so a link to `[::1]` is opened as `localhost`;
    /// `0.0.0.0` and `::` are what a server binds to rather than addresses
    /// to reach it at, and still mean "the machine this came from".
    /// Anything else is a name the network knows: not ours to forward.
    static func loopback(_ host: String) -> (there: String, here: String)? {
        let name = host.lowercased()
        if name == "localhost" { return ("localhost", "localhost") }
        if name == "::1" { return ("::1", "localhost") }
        if name == "0.0.0.0" || name == "::" { return ("localhost", "localhost") }
        // 127.0.0.0/8 is all loopback: keep the literal for the host's side.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127", parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
           parts.dropFirst().allSatisfy({ (Int($0) ?? 256) <= 255 }) {
            return (name, "127.0.0.1")
        }
        return nil
    }

    /// Whether this URL names the machine it was printed on: a dev server's
    /// `http://localhost:5173/`. In a pane running on a host such a link
    /// means that machine's port, so Libertty forwards it rather than
    /// opening it here, where it is some other program or nothing at all.
    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return (url.host).flatMap { loopback($0) } != nil
    }

    /// The port a web link asks for: its own, or the scheme's default.
    static func port(of url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    /// The same page on this Mac, through a forward: the path, query and
    /// fragment as they were, the port changed only when the forward
    /// couldn't take the host's own number. The name stays `localhost`
    /// whenever it can — a dev server that checks the Host header (Vite,
    /// webpack) turns away a name it doesn't know.
    static func rewrite(_ url: URL, to local: Int, here name: String) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = name
        // 80 and 443 are the scheme's own: a URL that left them out keeps them out.
        parts.port = local == port(of: url) && url.port == nil ? nil : local
        return parts.url
    }

    // MARK: Ports on this Mac

    /// Whether this Mac could listen on a port: whether ssh's own forward
    /// listener could, that is, so SO_REUSEADDR is set as ssh sets it — a
    /// port whose last connections are still in TIME_WAIT can be listened
    /// on again, while one a program is listening on cannot.
    static func canBind(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 }
        }
    }

    /// Whether something on this Mac answers on a port. A forward's
    /// listener belongs to the ssh master that holds it, so one that stopped
    /// answering is one to ask for again.
    static func isListening(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        // Loopback answers or refuses at once; no timeout to wait for.
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) == 0 }
        }
    }

    /// A port on this Mac to listen on: the host's own number when it's
    /// free, so `http://localhost:5173/` stays that; else one the system
    /// picks, and the link's port is rewritten.
    static func freePort(preferring wanted: Int) -> Int? {
        if canBind(wanted) { return wanted }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { return nil }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port == 0 ? nil : port
    }

    // MARK: What the user typed

    /// `Forward Port…` and `libertty +forward open` take a port, a
    /// `host:port` the host can reach, or a URL printed in one of its panes.
    /// Returns which port on the host to forward, the name it is on there,
    /// and the page it leads to, once the port is one of this Mac's. A bare
    /// port is taken for a web address, as a dev server's almost always is;
    /// a `host:port` names no page, so nothing is opened for it.
    static func target(_ typed: String) -> (remote: Int, remoteHost: String, url: URL?)? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            // A URL to the host's own loopback names the port there; any
            // other name is one the host resolves itself.
            let there = loopback(host)?.there ?? host
            return (port(of: url), there, url)
        }
        if let colon = text.lastIndex(of: ":") {
            let name = String(text[text.startIndex..<colon]), rest = String(text[text.index(after: colon)...])
            guard let port = Int(rest), (1...65535).contains(port), !name.isEmpty, !name.contains(" ") else { return nil }
            return (port, loopback(name)?.there ?? name, nil)
        }
        guard let port = Int(text), (1...65535).contains(port) else { return nil }
        return (port, "localhost", URL(string: "http://localhost:\(port)/"))
    }
}

/// Every forward Libertty holds, by host. They belong to the app: a forward
/// is closed when the host's last window goes and when Libertty quits, so
/// no listener on this Mac outlives the window that asked for it (ssh's own
/// master lingers for ControlPersist seconds after that, forward-free). A
/// forward made by `libertty +forward` with no window open stays until it's
/// closed or Libertty quits.
///
/// Asking for a forward runs ssh, so every call that changes one blocks and
/// belongs off the main thread; reading the list doesn't.
final class PortForwarder: @unchecked Sendable {
    static let shared = PortForwarder()

    /// A forward was added, dropped, or came back after a reconnect (posted
    /// on the main thread): Settings ▸ Remote Hosts follows it.
    static let changed = Notification.Name("LiberttyPortForwardsChanged")

    enum Failure: LocalizedError {
        case notConnected(String)
        case notATarget(String)
        case noLocalPort
        case ssh(PortForward, String)

        var errorDescription: String? {
            switch self {
            case .notConnected(let destination):
                "Libertty isn't connected to \(destination) yet."
            case .notATarget(let text):
                "not a port, host:port or URL: \(text)"
            case .noLocalPort:
                "This Mac has no free port to listen on."
            case .ssh(let forward, let why):
                forward.direction == .open
                    ? "ssh couldn't forward \(forward.remoteHost):\(forward.remote) on \(forward.destination): \(why)"
                    : "ssh couldn't share port \(forward.local) with \(forward.destination): \(why)"
            }
        }
    }

    private let lock = NSLock()
    /// The forwards each host holds, in the order they were made.
    private var held: [String: [PortForward]] = [:]
    /// One change at a time, so two panes asking for the same port don't
    /// both pick the same local one (as `prepareLock` serializes logins).
    private let workLock = NSLock()
    /// Where forwards are made and re-made: never the main thread.
    private let queue = DispatchQueue(label: "dev.libertty.forwards")

    private init() {
        // A host that reconnects gets its forwards again: the master that
        // held them is gone, and a new one has none.
        NotificationCenter.default.addObserver(forName: RemoteHost.statusChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let host = note.object as? RemoteHost, !self.forwards(on: host.destination).isEmpty else { return }
            self.queue.async { self.reestablish(on: host) }
        }
    }

    // MARK: Reading

    /// What this host holds now (any thread).
    func forwards(on destination: String) -> [PortForward] {
        lock.withLock { held[destination] ?? [] }
    }

    /// Every forward, by host name, each host's in the order they were made.
    var all: [PortForward] {
        lock.withLock { held.keys.sorted().flatMap { held[$0] ?? [] } }
    }

    // MARK: Making one

    /// A port on `host` reachable on this Mac: the forward it already has
    /// for that port, or a new one. Blocking.
    @discardableResult
    func open(remote: Int, on host: RemoteHost, remoteHost: String = "localhost") throws -> PortForward {
        workLock.lock()
        defer { workLock.unlock() }
        if let known = forwards(on: host.destination).first(where: {
            $0.direction == .open && $0.remote == remote && $0.remoteHost == remoteHost
        }) {
            // Still answering: the same forward serves, so the link keeps
            // the address it had. Gone with its master: ask again, keeping
            // its local port while it's free. (Something else could have
            // taken that port since the master went; a reconnect asks for
            // the forwards again, and Close makes a fresh one.)
            if PortForward.isListening(known.local) { return known }
            remember(known, host: host.destination, keeping: false)
            return try establish(known, on: host, retrying: true)
        }
        guard let local = PortForward.freePort(preferring: remote) else { throw Failure.noLocalPort }
        let forward = PortForward(destination: host.destination, direction: .open, local: local,
                                  remote: remote, remoteHost: remoteHost)
        return try establish(forward, on: host, retrying: true)
    }

    /// A port on this Mac that programs on `host` can reach, on the same
    /// port number there. Blocking. The host's port is its own to give: if
    /// something there holds it, ssh says so and nothing is kept.
    @discardableResult
    func share(local: Int, on host: RemoteHost) throws -> PortForward {
        workLock.lock()
        defer { workLock.unlock() }
        guard (1...65535).contains(local) else { throw Failure.notATarget("\(local)") }
        if let known = forwards(on: host.destination).first(where: { $0.direction == .share && $0.local == local }) {
            return known
        }
        let forward = PortForward(destination: host.destination, direction: .share, local: local, remote: local)
        return try establish(forward, on: host, retrying: false)
    }

    /// A target typed into the Forward Port page or given to `libertty
    /// +forward open` — a port, a `host:port` the host can reach, or a URL:
    /// the forward for it, and the page it leads to here when it was a URL.
    /// Blocking.
    func open(target typed: String, on host: RemoteHost) throws -> (forward: PortForward, url: URL?) {
        guard let target = PortForward.target(typed) else { throw Failure.notATarget(typed) }
        let forward = try open(remote: target.remote, on: host, remoteHost: target.remoteHost)
        let url = target.url.flatMap { url in
            // The name to ask for here: a link to the host's loopback keeps
            // its own spelling, anything else is reached through ours.
            PortForward.rewrite(url, to: forward.local, here: PortForward.loopback(url.host ?? "")?.here ?? "localhost")
        }
        return (forward, url)
    }

    /// The URL from a pane on `host` as one that opens on this Mac: the
    /// forward for its port, made if it isn't there. Blocking.
    func rewrite(_ url: URL, on host: RemoteHost) throws -> URL {
        guard let name = url.host, let names = PortForward.loopback(name) else {
            throw Failure.notATarget(url.absoluteString)
        }
        let forward = try open(remote: PortForward.port(of: url), on: host, remoteHost: names.there)
        guard let rewritten = PortForward.rewrite(url, to: forward.local, here: names.here) else {
            throw Failure.notATarget(url.absoluteString)
        }
        return rewritten
    }

    /// Ask the host's ControlMaster for a forward, and keep it if it took.
    /// `retrying`: a local port that was free a moment ago may have been
    /// taken since (or by a master that still holds an old forward of
    /// ours), so try once more on a port the system picks.
    private func establish(_ forward: PortForward, on host: RemoteHost, retrying: Bool) throws -> PortForward {
        guard host.isConnected else { throw Failure.notConnected(host.destination) }
        let result = host.control(forward, cancel: false)
        if result.ok {
            remember(forward, host: host.destination, keeping: true)
            return forward
        }
        guard retrying, let other = PortForward.freePort(preferring: 0), other != forward.local else {
            throw Failure.ssh(forward, result.why)
        }
        var again = forward
        again.local = other
        let second = host.control(again, cancel: false)
        guard second.ok else { throw Failure.ssh(again, second.why) }
        remember(again, host: host.destination, keeping: true)
        return again
    }

    // MARK: Closing

    /// Close one forward by its `id`. Blocking; true when it was there.
    @discardableResult
    func close(id: String) -> Bool {
        workLock.lock()
        defer { workLock.unlock() }
        guard let forward = all.first(where: { $0.id == id }) else { return false }
        drop(forward)
        return true
    }

    /// Close every forward, or every one of a host's. Blocking.
    func closeAll(on destination: String? = nil) {
        workLock.lock()
        defer { workLock.unlock() }
        for forward in all where destination == nil || forward.destination == destination { drop(forward) }
    }

    /// Take a forward back from the master and forget it. The entry goes
    /// whatever ssh says: a master that is down took the forward with it,
    /// and an entry nobody can close would be there for good.
    private func drop(_ forward: PortForward) {
        _ = RemoteHost.named(forward.destination).control(forward, cancel: true)
        remember(forward, host: forward.destination, keeping: false)
    }

    /// The host's last window closed: its forwards were for those panes.
    /// Called on the main thread; the ssh calls go to the background.
    func closeSoon(on destination: String) {
        guard !forwards(on: destination).isEmpty else { return }
        queue.async { [weak self] in self?.closeAll(on: destination) }
    }

    // MARK: After a reconnect

    /// Ask for the forwards this host should hold again. A forward the new
    /// master already has refuses to bind a second time, which is harmless:
    /// the entry stays, since something is answering on its port.
    private func reestablish(on host: RemoteHost) {
        workLock.lock()
        defer { workLock.unlock() }
        guard host.isConnected else { return }
        for forward in forwards(on: host.destination) {
            // An `open` forward that still answers is up; a `share` one
            // listens on the host, where we can't look, so ask again.
            if forward.direction == .open, PortForward.isListening(forward.local) { continue }
            if host.control(forward, cancel: false).ok { announce() }
        }
    }

    // MARK: The list

    private func remember(_ forward: PortForward, host destination: String, keeping: Bool) {
        lock.withLock {
            var list = held[destination] ?? []
            list.removeAll { $0.id == forward.id }
            if keeping { list.append(forward) }
            held[destination] = list.isEmpty ? nil : list
        }
        announce()
    }

    private func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}
