import Foundation
import Testing
@testable import LiberttyApp

/// Forwarded ports: which links mean the machine they were printed on, what
/// the rewritten link looks like, what the user may type, and the ssh
/// command line that asks a host's shared connection for the forward.
// One at a time: two tests asking for a free port at once may both be
// handed the same one, and each holds it against the other.
@Suite(.serialized) struct PortForwardTests {
    // MARK: Links to the machine they came from

    @Test func loopbackNames() {
        // Both sides: what the host connects to, what opens here.
        #expect(PortForward.loopback("localhost")! == ("localhost", "localhost"))
        #expect(PortForward.loopback("LocalHost")! == ("localhost", "localhost"))
        #expect(PortForward.loopback("127.0.0.1")! == ("127.0.0.1", "127.0.0.1"))
        #expect(PortForward.loopback("127.1.2.3")! == ("127.1.2.3", "127.0.0.1"))
        // Libertty listens on 127.0.0.1, so an IPv6 link opens by name.
        #expect(PortForward.loopback("::1")! == ("::1", "localhost"))
        // What a server binds to, not an address to reach it at.
        #expect(PortForward.loopback("0.0.0.0")! == ("localhost", "localhost"))
        #expect(PortForward.loopback("::")! == ("localhost", "localhost"))
        // Names the network knows: not ours to forward.
        #expect(PortForward.loopback("example.com") == nil)
        #expect(PortForward.loopback("127.0.0.256") == nil)
        #expect(PortForward.loopback("1270.0.0.1") == nil)
        #expect(PortForward.loopback("127.0.0") == nil)
        #expect(PortForward.loopback("localhost.example.com") == nil)
        #expect(PortForward.loopback("") == nil)
    }

    @Test func whichLinksAreForwarded() throws {
        func loopback(_ text: String) -> Bool {
            guard let url = URL(string: text) else { return false }
            return PortForward.isLoopback(url)
        }
        #expect(loopback("http://localhost:5173/"))
        #expect(loopback("https://localhost:8443/app?x=1#top"))
        #expect(loopback("http://127.0.0.1:3000"))
        #expect(loopback("http://[::1]:3000/"))
        #expect(loopback("http://0.0.0.0:8080/"))
        // Only the web: a file or an ssh link is not a port to carry.
        #expect(!loopback("file:///tmp/x"))
        #expect(!loopback("ssh://localhost:22"))
        #expect(!loopback("http://devbox:5173/"))
        #expect(!loopback("http://example.com/"))
    }

    @Test func theSchemesOwnPort() {
        #expect(PortForward.port(of: URL(string: "http://localhost/")!) == 80)
        #expect(PortForward.port(of: URL(string: "https://localhost/")!) == 443)
        #expect(PortForward.port(of: URL(string: "http://localhost:5173/")!) == 5173)
    }

    // MARK: The link that opens here

    @Test func rewritingKeepsThePage() throws {
        let url = try #require(URL(string: "http://localhost:5173/app/index.html?tab=2&q=a%20b#top"))
        // The same port: the link is untouched, Host header and all.
        let same = try #require(PortForward.rewrite(url, to: 5173, here: "localhost"))
        #expect(same.absoluteString == "http://localhost:5173/app/index.html?tab=2&q=a%20b#top")
        // Another port: only the port changes.
        let moved = try #require(PortForward.rewrite(url, to: 49231, here: "localhost"))
        #expect(moved.absoluteString == "http://localhost:49231/app/index.html?tab=2&q=a%20b#top")
    }

    @Test func rewritingNamesTheHostItCanReach() throws {
        // An IPv6 loopback link opens by name: the listener is on 127.0.0.1.
        let six = try #require(URL(string: "http://[::1]:3000/x"))
        let sixHost = try #require(six.host)
        let names = try #require(PortForward.loopback(sixHost))
        #expect(PortForward.rewrite(six, to: 3000, here: names.here)?.absoluteString == "http://localhost:3000/x")
        // 127.0.0.1 keeps its literal.
        let four = try #require(URL(string: "http://127.0.0.1:3000/x"))
        #expect(PortForward.rewrite(four, to: 3000, here: "127.0.0.1")?.absoluteString == "http://127.0.0.1:3000/x")
        // A link without a port keeps it out while the forward took 80.
        let bare = try #require(URL(string: "http://localhost/x"))
        #expect(PortForward.rewrite(bare, to: 80, here: "localhost")?.absoluteString == "http://localhost/x")
        #expect(PortForward.rewrite(bare, to: 8080, here: "localhost")?.absoluteString == "http://localhost:8080/x")
    }

    // MARK: What the user types

    @Test func targets() throws {
        // A bare port is taken for a web address, as a dev server's is.
        let port = try #require(PortForward.target(" 5173 "))
        #expect(port.remote == 5173 && port.remoteHost == "localhost")
        #expect(port.url?.absoluteString == "http://localhost:5173/")
        // host:port names a machine only the host can reach: no page to open.
        let pair = try #require(PortForward.target("db:5432"))
        #expect(pair.remote == 5432 && pair.remoteHost == "db" && pair.url == nil)
        // The host's own loopback, however it was spelled.
        #expect(PortForward.target("127.0.0.1:9000")?.remoteHost == "127.0.0.1")
        #expect(PortForward.target("0.0.0.0:9000")?.remoteHost == "localhost")
        // A URL keeps its path, and its port is the one to carry.
        let url = try #require(PortForward.target("http://localhost:5173/app?x=1"))
        #expect(url.remote == 5173 && url.remoteHost == "localhost")
        #expect(url.url?.absoluteString == "http://localhost:5173/app?x=1")
        #expect(PortForward.target("https://localhost/app")?.remote == 443)
        // Not a target.
        #expect(PortForward.target("") == nil)
        #expect(PortForward.target("  ") == nil)
        #expect(PortForward.target("0") == nil)
        #expect(PortForward.target("65536") == nil)
        #expect(PortForward.target("-1") == nil)
        #expect(PortForward.target("nope") == nil)
        #expect(PortForward.target("db:") == nil)
        #expect(PortForward.target(":5432") == nil)
        #expect(PortForward.target("a b:80") == nil)
        #expect(PortForward.target("ftp://localhost:21/") == nil)
    }

    // MARK: ssh's command line

    @Test func sshSpellsTheForward() {
        let open = PortForward(destination: "devbox", direction: .open, local: 5173, remote: 5173)
        #expect(open.flag == "-L")
        #expect(open.specification == "127.0.0.1:5173:localhost:5173")
        // A port of this Mac's, listened for on the host.
        let share = PortForward(destination: "devbox", direction: .share, local: 3000, remote: 3000)
        #expect(share.flag == "-R")
        #expect(share.specification == "127.0.0.1:3000:localhost:3000")
        // Another machine, reached from the host.
        let far = PortForward(destination: "devbox", direction: .open, local: 49231, remote: 5432, remoteHost: "db")
        #expect(far.specification == "127.0.0.1:49231:db:5432")
        // An IPv6 address in brackets: ssh splits the rest on colons.
        let six = PortForward(destination: "devbox", direction: .open, local: 3000, remote: 3000, remoteHost: "::1")
        #expect(six.specification == "127.0.0.1:3000:[::1]:3000")
    }

    @Test func sshIsAskedOverTheSharedConnection() {
        let forward = PortForward(destination: "me@devbox", direction: .open, local: 49231, remote: 5173)
        let options = ["-T", "-o", "ControlPath=/tmp/ssh-abc"]
        #expect(PortForward.controlArguments(for: forward, cancel: false, options: options)
                == options + ["-O", "forward", "-L", "127.0.0.1:49231:localhost:5173", "me@devbox"])
        #expect(PortForward.controlArguments(for: forward, cancel: true, options: options)
                == options + ["-O", "cancel", "-L", "127.0.0.1:49231:localhost:5173", "me@devbox"])
    }

    // MARK: How one is named and described

    @Test func namesAndSummaries() {
        let open = PortForward(destination: "devbox", direction: .open, local: 49231, remote: 5173)
        #expect(open.id == "devbox:L5173")
        #expect(open.summary == "127.0.0.1:49231 → localhost:5173 on devbox")
        let share = PortForward(destination: "devbox", direction: .share, local: 3000, remote: 3000)
        #expect(share.id == "devbox:R3000")
        #expect(share.summary == "3000 on devbox → 127.0.0.1:3000")
        // Two machines behind one host stay apart.
        let far = PortForward(destination: "devbox", direction: .open, local: 1, remote: 5432, remoteHost: "db")
        #expect(far.id == "devbox:Ldb:5432")
        #expect(far.id != PortForward(destination: "devbox", direction: .open, local: 2, remote: 5432).id)
    }

    /// What a person reads: the port and where it opens, both ends' numbers
    /// (the id is for typing, the summary for the exact ends).
    @Test func titlesSayWhereItOpens() {
        #expect(PortForward(destination: "devbox", direction: .open, local: 49231, remote: 5173).title
                == "5173 → 49231 on this Mac")
        #expect(PortForward(destination: "devbox", direction: .open, local: 5432, remote: 5432, remoteHost: "db").title
                == "db:5432 → 5432 on this Mac")
        #expect(PortForward(destination: "devbox", direction: .share, local: 3000, remote: 3000).title
                == "3000 on this Mac → 3000 on the host")
    }

    // MARK: Ports on this Mac

    /// The host's own number when it's free, another when something holds it.
    @Test func picksALocalPort() throws {
        let taken = try #require(PortForward.freePort(preferring: 0))
        #expect(PortForward.canBind(taken))
        // Hold it, as a program on this Mac would.
        let held = socket(AF_INET, SOCK_STREAM, 0)
        try #require(held >= 0)
        defer { close(held) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(taken).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(held, $0, size) == 0 }
        }
        try #require(bound)
        try #require(listen(held, 1) == 0)
        #expect(!PortForward.canBind(taken))
        #expect(PortForward.isListening(taken))
        let other = try #require(PortForward.freePort(preferring: taken))
        #expect(other != taken)
        // Out of range is no port at all.
        #expect(!PortForward.canBind(0) && !PortForward.canBind(70000))
        #expect(!PortForward.isListening(0))
    }

    /// A program here listening on IPv6 (a local dev server on `::` or ::1)
    /// is what `localhost` reaches first in a browser: its port isn't free
    /// for a forward, though 127.0.0.1 alone could still be bound.
    @Test func aPortHeldOnIPv6IsNotFree() throws {
        let port = try #require(PortForward.freePort(preferring: 0))
        let held = socket(AF_INET6, SOCK_STREAM, 0)
        try #require(held >= 0)
        defer { close(held) }
        var only: Int32 = 1
        setsockopt(held, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_addr = in6addr_loopback
        addr.sin6_port = UInt16(port).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(held, $0, size) == 0 }
        }
        try #require(bound)
        try #require(listen(held, 1) == 0)
        #expect(!PortForward.canBind(port))
        #expect(try #require(PortForward.freePort(preferring: port)) != port)
    }

    // MARK: What the running Libertty is asked

    /// `libertty +forward` reaches the app as a request of its own kind, and
    /// one naming no host (no `--host`, and the pane it ran in is this
    /// Mac's) is answered rather than acted on. Nothing here runs ssh.
    @Test func requestsAreRouted() {
        #expect(!ForwardRequests.handle(["kind": "split"], in: []))
        #expect(ForwardRequests.handle(["kind": "forward", "op": "ls"], in: []))
        #expect(ForwardRequests.handle(["kind": "forward", "op": "open", "target": "5173"], in: []))
        #expect(ForwardRequests.handle(["kind": "forward", "op": "close", "target": "nowhere:L1"], in: []))
        // A host with no forwards has none to list or close.
        #expect(PortForwarder.shared.forwards(on: "no-such-host.invalid").isEmpty)
        #expect(!PortForwarder.shared.close(id: "no-such-host.invalid:L1"))
    }

    // MARK: remote-control = false

    /// Listing what's forwarded reads; making or closing one drives Libertty.
    @Test func remoteControlPolicy() {
        var config = Config()
        _ = config.set("remote-control", "false")
        #expect(RemoteControlPolicy.refusal("+forward", ["ls"], config: config) == nil)
        #expect(RemoteControlPolicy.refusal("+forward", ["open", "5173"], config: config) != nil)
        #expect(RemoteControlPolicy.refusal("+forward", ["share", "3000"], config: config) != nil)
        #expect(RemoteControlPolicy.refusal("+forward", ["close", "--all"], config: config) != nil)
        #expect(!RemoteControlPolicy.refuses(["kind": "forward", "op": "ls"], config: config))
        #expect(RemoteControlPolicy.refuses(["kind": "forward", "op": "open"], config: config))
        // With it on, nothing is refused.
        var on = Config()
        _ = on.set("remote-control", "true")
        #expect(RemoteControlPolicy.refusal("+forward", ["open", "5173"], config: on) == nil)
    }
}
