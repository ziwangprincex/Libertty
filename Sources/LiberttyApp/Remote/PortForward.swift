import AppKit
import Darwin
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
    /// The pid of the host's ssh master that took it (0: it didn't say). A
    /// master with another pid is a new connection, which holds none of it.
    var master: Int32 = 0

    /// Short, stable and typed by hand (`libertty +forward close`): the
    /// host, which way it goes, and the port on the host's side.
    var id: String {
        let letter = direction == .open ? "L" : "R"
        let there = direction == .open && remoteHost != "localhost" ? remoteHost + ":" : ""
        return "\(destination):\(letter)\(there)\(remote)"
    }

    /// What it is, for a person: the port it carries and where it opens
    /// ("5173 → 5173 on this Mac"). `id` is for typing; `summary` says
    /// both ends exactly.
    var title: String {
        switch direction {
        case .open:
            let there = remoteHost == "localhost" ? "\(remote)" : "\(remoteHost):\(remote)"
            return String(format: L10n.t("%@ → %@ on this Mac"), there, "\(local)")
        case .share:
            return String(format: L10n.t("%@ on this Mac → %@ on the host"), "\(local)", "\(remote)")
        }
    }

    /// What it does, for a list: the two ends, the arrow the way it carries.
    var summary: String {
        switch direction {
        case .open: "127.0.0.1:\(local) → \(remoteHost):\(remote) on \(destination)"
        case .share: "\(remote) on \(destination) → 127.0.0.1:\(local)"
        }
    }

    /// `summary` in the interface's language, for Settings and the palette
    /// (`libertty +forward ls` says it in English, as the command line does).
    var localizedSummary: String {
        switch direction {
        case .open: "127.0.0.1:\(local) → " + Self.on("\(remoteHost):\(remote)", destination)
        case .share: Self.on("\(remote)", destination) + " → 127.0.0.1:\(local)"
        }
    }

    /// "5173 on devbox", in the interface's language.
    static func on(_ what: String, _ host: String) -> String {
        String(format: L10n.t("%@ on %@"), what, host)
    }

    // MARK: ssh's words

    /// ssh's own spelling of the forward — what follows `-L` or `-R`.
    /// `-L bind:port:host:hostport` listens here and connects there;
    /// `-R bind:port:host:hostport` listens there and connects here. The
    /// bind address is 127.0.0.1 both ways: a forward is for this machine
    /// (or that one), not for its network.
    var specification: String {
        // An IPv6 address goes in brackets: ssh splits the rest on colons.
        let there = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
        switch direction {
        case .open: return "127.0.0.1:\(local):\(there):\(remote)"
        case .share: return "127.0.0.1:\(remote):localhost:\(local)"
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

    /// The four places a program on this Mac may listen on a port and be
    /// what `localhost` reaches: IPv4's loopback and any-address, IPv6's
    /// too. A browser tries ::1 first for `localhost`.
    private enum Place: CaseIterable { case v4Loopback, v4Any, v6Loopback, v6Any }

    /// A socket of `place`'s family and its address with `port`, handed to
    /// `body`; the socket is closed after. False when no socket could be made.
    private static func socket(at place: Place, port: Int, _ body: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Bool) -> Bool {
        let v6 = place == .v6Loopback || place == .v6Any
        let fd = Darwin.socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if v6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_addr = place == .v6Loopback ? in6addr_loopback : in6addr_any
            addr.sin6_port = UInt16(port).bigEndian
            // Only IPv6: the IPv4 places are asked on their own.
            var only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = place == .v4Loopback ? inet_addr("127.0.0.1") : INADDR_ANY
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    /// Whether a forward could take a port here and be what `localhost`
    /// reaches on it: ssh listens on 127.0.0.1 (with SO_REUSEADDR, so a
    /// port still in TIME_WAIT can be listened on again), but a program
    /// listening on `::`, `::1` or `0.0.0.0` would answer `localhost`
    /// first, or as well — the page opened would be this Mac's own.
    static func canBind(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return Place.allCases.allSatisfy { place in
            socket(at: place, port: port) { fd, addr, size in
                var reuse: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                return bind(fd, addr, size) == 0
            }
        }
    }

    /// Whether something on this Mac answers on 127.0.0.1:`port` (a real
    /// connection: the probe's and the tests' look at a forward, never the
    /// forwarder's own — through a forward it would reach the host's side).
    static func isListening(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        // Loopback answers or refuses at once; no timeout to wait for.
        return socket(at: .v4Loopback, port: port) { fd, addr, size in connect(fd, addr, size) == 0 }
    }

    /// A port on this Mac to listen on: the host's own number when it's
    /// free, so `http://localhost:5173/` stays that; else one the system
    /// picks (free in every place `localhost` might reach), and the link's
    /// port is rewritten.
    static func freePort(preferring wanted: Int) -> Int? {
        if canBind(wanted) { return wanted }
        for _ in 0..<8 {
            var port = 0
            let picked = socket(at: .v4Loopback, port: 0) { fd, addr, size in
                var named = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard bind(fd, addr, size) == 0, withUnsafeMutablePointer(to: &named, {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
                }) else { return false }
                port = Int(UInt16(bigEndian: named.sin_port))
                return true
            }
            if picked, port != 0, canBind(port) { return port }
        }
        return nil
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
            var name = String(text[text.startIndex..<colon]), rest = String(text[text.index(after: colon)...])
            // `[::1]:5173`: the brackets set the address off from its port,
            // and aren't its name (`specification` puts them back for ssh).
            if name.count > 2, name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
            guard let port = Int(rest), (1...65535).contains(port), !name.isEmpty, !name.contains(" "),
                  !name.contains("["), !name.contains("]") else { return nil }
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
/// closed or Libertty quits: while a host has any, its connection is held
/// up (`RemoteHost.keepConnection`), which ssh would otherwise close a
/// minute after the last window's session went, the forwards with it.
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
    /// One change at a time per host, so two panes asking for the same port
    /// don't both pick the same local one (as `prepareLock` serializes
    /// logins). Nothing is held across hosts while ssh runs: one that stalls
    /// (a `-R` waits for the host's answer) holds up only its own forwards.
    /// Two hosts' forwards that pick the same free port at once: the master
    /// that listens on it second can't, and `establish` tries another.
    private var workLocks: [String: NSLock] = [:]

    private func work<T>(on destination: String, _ body: () throws -> T) rethrows -> T {
        let hostLock = lock.withLock { () -> NSLock in
            if let existing = workLocks[destination] { return existing }
            let made = NSLock()
            workLocks[destination] = made
            return made
        }
        hostLock.lock()
        defer { hostLock.unlock() }
        return try body()
    }

    /// Whether `forward` is still up: the master that took it is the one
    /// running now (`RemoteHost.master`). A master that doesn't say its
    /// pid leaves only the port to go by: held by someone, taken for ours.
    /// Neither connects to the port (through a forward that reaches the
    /// host's own server, once a look).
    private static func isHeld(_ forward: PortForward, by master: Int32) -> Bool {
        if master != 0, forward.master != 0 { return forward.master == master }
        return forward.direction == .open ? !PortForward.canBind(forward.local) : true
    }
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
        try work(on: host.destination) {
            guard let master = host.master else { throw Failure.notConnected(host.destination) }
            if let known = forwards(on: host.destination).first(where: {
                $0.direction == .open && $0.remote == remote && $0.remoteHost == remoteHost
            }) {
                // Still held by the master running now: the same forward
                // serves, so the link keeps the address it had. Gone with
                // its master: asked again, on its old port while that's
                // free here (something else may have taken it since). The
                // entry stays until a new one is up: a failure now leaves
                // it for the next reconnect.
                if Self.isHeld(known, by: master) { return known }
                var again = known
                again.local = PortForward.canBind(known.local) ? known.local : 0
                if again.local == 0, let other = PortForward.freePort(preferring: 0) { again.local = other }
                return try establish(again, on: host, master: master, retrying: true)
            }
            guard let local = PortForward.freePort(preferring: remote) else { throw Failure.noLocalPort }
            let forward = PortForward(destination: host.destination, direction: .open, local: local,
                                      remote: remote, remoteHost: remoteHost)
            return try establish(forward, on: host, master: master, retrying: true)
        }
    }

    /// A port on this Mac that programs on `host` can reach, on the same
    /// port number there. Blocking. The host's port is its own to give: if
    /// something there holds it, ssh says so and nothing is kept.
    @discardableResult
    func share(local: Int, on host: RemoteHost) throws -> PortForward {
        guard (1...65535).contains(local) else { throw Failure.notATarget("\(local)") }
        return try work(on: host.destination) {
            guard let master = host.master else { throw Failure.notConnected(host.destination) }
            let known = forwards(on: host.destination).first { $0.direction == .share && $0.local == local }
            if let known, Self.isHeld(known, by: master) { return known }
            let forward = known ?? PortForward(destination: host.destination, direction: .share, local: local, remote: local)
            return try establish(forward, on: host, master: master, retrying: false)
        }
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
    /// taken since (by another host's forward made at the same moment, or
    /// a master that still holds an old forward of ours), so try once more
    /// on a port the system picks.
    private func establish(_ forward: PortForward, on host: RemoteHost, master: Int32, retrying: Bool) throws -> PortForward {
        var first = forward
        first.master = master
        let result = host.control(first, cancel: false)
        if result.ok {
            remember(first, host: host.destination, keeping: true)
            host.keepConnection(on: master)
            return first
        }
        guard retrying, let other = PortForward.freePort(preferring: 0), other != forward.local else {
            throw Failure.ssh(first, result.why)
        }
        var again = first
        again.local = other
        let second = host.control(again, cancel: false)
        guard second.ok else { throw Failure.ssh(again, second.why) }
        remember(again, host: host.destination, keeping: true)
        host.keepConnection(on: master)
        return again
    }

    /// A forward closed a moment ago, asked for again as it was — on its
    /// old port here while that's free (Undo after Close). Blocking.
    @discardableResult
    func reopen(_ forward: PortForward) throws -> PortForward {
        let host = RemoteHost.named(forward.destination)
        guard forward.direction == .open else { return try share(local: forward.local, on: host) }
        return try work(on: host.destination) {
            guard let master = host.master else { throw Failure.notConnected(host.destination) }
            // Made again meanwhile (a link clicked): that one serves.
            if let known = forwards(on: host.destination).first(where: { $0.id == forward.id }),
               Self.isHeld(known, by: master) { return known }
            var again = forward
            again.local = PortForward.canBind(forward.local) ? forward.local : 0
            if again.local == 0 {
                guard let other = PortForward.freePort(preferring: 0) else { throw Failure.noLocalPort }
                again.local = other
            }
            return try establish(again, on: host, master: master, retrying: true)
        }
    }

    // MARK: Closing

    /// Close one forward by its `id`. Blocking; true when it was there.
    @discardableResult
    func close(id: String) -> Bool {
        guard let found = all.first(where: { $0.id == id }) else { return false }
        return work(on: found.destination) {
            // Looked for again under the host's lock: another close may have won.
            guard let forward = forwards(on: found.destination).first(where: { $0.id == id }) else { return false }
            drop(forward)
            return true
        }
    }

    /// Close every forward, or every one of a host's. Blocking.
    func closeAll(on destination: String? = nil) {
        let hosts = destination.map { [$0] } ?? lock.withLock { Array(held.keys) }
        for host in hosts {
            work(on: host) { for forward in forwards(on: host) { drop(forward) } }
        }
    }

    /// Take a forward back from the master and forget it. The entry goes
    /// whatever ssh says: a master that is down took the forward with it,
    /// and an entry nobody can close would be there for good.
    private func drop(_ forward: PortForward) {
        let host = RemoteHost.named(forward.destination)
        _ = host.control(forward, cancel: true)
        remember(forward, host: forward.destination, keeping: false)
        // The last one: the connection goes once nothing else uses it.
        if forwards(on: forward.destination).isEmpty { host.keepConnection(on: nil) }
    }

    /// The host's last window closed: its forwards were for those panes.
    /// Called on the main thread; the ssh calls go to the background.
    func closeSoon(on destination: String) {
        // Even with none held now: one being asked for again (Undo) is made
        // under the host's lock, and this waits for it.
        queue.async { [weak self] in self?.closeAll(on: destination) }
    }

    // MARK: After a reconnect

    /// Ask for the forwards this host should hold again: those the master
    /// running now didn't take (it's a new connection). One that can't be
    /// had now stays listed, for the next reconnect or a click to ask again.
    private func reestablish(on host: RemoteHost) {
        work(on: host.destination) {
            guard let master = host.master else { return }
            for forward in forwards(on: host.destination) where !Self.isHeld(forward, by: master) {
                var again = forward
                if forward.direction == .open, !PortForward.canBind(forward.local) {
                    // Its port was taken here meanwhile: another one, and the
                    // next click on its link opens that.
                    guard let other = PortForward.freePort(preferring: 0) else { continue }
                    again.local = other
                }
                _ = try? establish(again, on: host, master: master, retrying: forward.direction == .open)
            }
            // And the connection held up: this new master, or the same one
            // if the session holding it ended (`keepConnection` keeps one that's still there).
            if !forwards(on: host.destination).isEmpty { host.keepConnection(on: master) }
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

extension PortForwarder {
    /// A link to `host`'s own machine, opened here through a forward: ssh is
    /// asked off the main thread, then `show` opens the page at the address
    /// this Mac reaches; what went wrong is a sheet on `window` (a dialog
    /// without one). A pane's link and the Inspector's ports go this way.
    @MainActor
    static func open(_ url: URL, on host: RemoteHost, window: NSWindow?, show: @escaping @MainActor (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak window] in
            do {
                let here = try shared.rewrite(url, on: host)
                DispatchQueue.main.async { MainActor.assumeIsolated { show(here) } }
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let alert = NSAlert()
                        alert.messageText = L10n.t("Couldn't open this link from %@").replacingOccurrences(of: "%@", with: host.destination)
                        alert.informativeText = url.absoluteString + "\n\n" + why
                        // Its own OK button, which AppKit words in the system's language.
                        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
                    }
                }
            }
        }
    }
}
