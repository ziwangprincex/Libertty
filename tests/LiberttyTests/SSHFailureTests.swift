import Darwin
import Foundation
import Testing
@testable import LiberttyApp

/// What ssh's own words mean, and which agent a host's keys come from: all
/// pure functions, so real OpenSSH 9.x output is the test. The samples are
/// what ssh writes to its stderr, whitespace and all.
struct SSHFailureTests {
    /// An agent in a given state, as the diagnosis sees one.
    static func agent(_ answer: SSHAgentStanding.Answer, name: String = "The macOS agent",
                      socket: String? = nil, isDefault: Bool = true, fromConfig: Bool = false) -> SSHAgentStanding {
        SSHAgentStanding(name: name, socket: socket, isDefault: isDefault, fromConfig: fromConfig, answer: answer)
    }

    // MARK: The table of real ssh failures

    struct Sample: Sendable {
        let what: String
        let errors: String
        let problem: SSHRecovery.Problem
    }

    static let samples: [Sample] = [
        Sample(what: "no key exchange method in common",
               errors: "Unable to negotiate with 10.0.0.5 port 22: no matching key exchange method found. "
                     + "Their offer: diffie-hellman-group1-sha1,diffie-hellman-group14-sha1",
               problem: .noCommonAlgorithm(.keyExchange,
                                           offered: "diffie-hellman-group1-sha1,diffie-hellman-group14-sha1")),
        Sample(what: "no host key type in common",
               errors: "Unable to negotiate with 192.168.1.9 port 22: no matching host key type found. Their offer: ssh-rsa",
               problem: .noCommonAlgorithm(.hostKey, offered: "ssh-rsa")),
        Sample(what: "no cipher in common",
               errors: "Unable to negotiate with 10.0.0.5 port 2222: no matching cipher found. "
                     + "Their offer: aes128-cbc,3des-cbc,blowfish-cbc",
               problem: .noCommonAlgorithm(.cipher, offered: "aes128-cbc,3des-cbc,blowfish-cbc")),
        Sample(what: "no MAC in common",
               errors: "Unable to negotiate with 10.0.0.5 port 22: no matching MAC found. Their offer: hmac-md5,hmac-sha1",
               problem: .noCommonAlgorithm(.mac, offered: "hmac-md5,hmac-sha1")),
        Sample(what: "the host closed the connection without a greeting (MaxStartups)",
               errors: """
               kex_exchange_identification: Connection closed by remote host
               Connection closed by 10.0.0.5 port 22
               """,
               problem: .closedWithoutAnswer(host: "10.0.0.5", port: 22)),
        Sample(what: "the host reset the connection without a greeting",
               errors: """
               kex_exchange_identification: read: Connection reset by peer
               Connection reset by 203.0.113.7 port 2022
               """,
               problem: .closedWithoutAnswer(host: "203.0.113.7", port: 2022)),
        Sample(what: "nothing listens for SSH",
               errors: "ssh: connect to host devbox port 22: Connection refused",
               problem: .unreachable(.refused, host: "devbox", port: 22)),
        Sample(what: "no answer at all",
               errors: "ssh: connect to host devbox.example port 22: Operation timed out",
               problem: .unreachable(.timedOut, host: "devbox.example", port: 22)),
        Sample(what: "no route",
               errors: "ssh: connect to host 10.1.1.1 port 22: No route to host",
               problem: .unreachable(.noRoute, host: "10.1.1.1", port: 22)),
        Sample(what: "no network on this Mac",
               errors: "ssh: connect to host devbox port 22: Network is unreachable",
               problem: .unreachable(.networkDown, host: "devbox", port: 22)),
        Sample(what: "the name has no address",
               errors: "ssh: Could not resolve hostname nosuchbox: nodename nor servname provided, or not known",
               problem: .unreachable(.unknownName, host: "nosuchbox", port: nil)),
        Sample(what: "too many keys offered",
               errors: """
               Received disconnect from 10.0.0.5 port 22:2: Too many authentication failures
               Disconnected from 10.0.0.5 port 22
               """,
               problem: .tooManyAuthFailures),
        Sample(what: "an SSH 1 server",
               errors: "Protocol major versions differ: 2 vs. 1",
               problem: .notSSH(nil)),
        Sample(what: "something that isn't SSH on the port",
               errors: "kex_exchange_identification: Bad protocol version identification 'HTTP/1.1 400 Bad Request' "
                     + "from 10.0.0.5 port 8080",
               problem: .notSSH("HTTP/1.1 400 Bad Request")),
    ]

    @Test(arguments: samples) func readsWhatSSHSaid(_ sample: Sample) {
        let problem = SSHRecovery.diagnose(sample.errors, agent: Self.agent(.keys(1)), keysOnDisk: [])
        #expect(problem == sample.problem, "\(sample.what)")
    }

    /// Every one of them says what it is and what fixes it, in words with no
    /// ssh jargon left bare.
    @Test(arguments: samples) func explainsEachOne(_ sample: Sample) {
        let (title, body) = SSHRecovery.explain(sample.problem, destination: "devbox")
        #expect(!title.isEmpty && title.count < 70, "\(sample.what): the title")
        #expect(body.count > 80, "\(sample.what): the body is too short to explain anything")
        #expect(!body.contains("%@"), "\(sample.what): a placeholder was left in")
    }

    /// The fix names the keyword that holds the list, so it can be acted on.
    @Test func negotiationNamesTheKeyword() {
        let offered = "only-this-one"
        for (problem, keyword) in [(SSHRecovery.Problem.noCommonAlgorithm(.keyExchange, offered: offered), "KexAlgorithms"),
                                   (.noCommonAlgorithm(.cipher, offered: offered), "Ciphers"),
                                   (.noCommonAlgorithm(.mac, offered: offered), "MACs"),
                                   (.noCommonAlgorithm(.hostKey, offered: offered), "HostKeyAlgorithms")] {
            let body = SSHRecovery.explain(problem, destination: "devbox").body
            #expect(body.contains(keyword))
            #expect(body.contains(offered), "it repeats what the host offered")
        }
        // A host with only old host keys is told how to make a current one.
        #expect(SSHRecovery.explain(.noCommonAlgorithm(.hostKey, offered: "ssh-rsa"), destination: "devbox")
            .body.contains("ssh-keygen -A"))
    }

    /// A host that closes connections is named with its port, and MaxStartups
    /// is pointed at: that is the setting that does it.
    @Test func closedWithoutAnswerPointsAtMaxStartups() {
        let body = SSHRecovery.explain(.closedWithoutAnswer(host: "devbox", port: 2222), destination: "devbox").body
        #expect(body.contains("2222") && body.contains("MaxStartups"))
    }

    /// Nothing ssh wrote is thrown away: the details keep its own last words.
    @Test func keepsWhatSSHWrote() {
        let raw = """
        Warning: Permanently added 'devbox' (ED25519) to the list of known hosts.
        kex_exchange_identification: Connection closed by remote host
        Connection closed by 10.0.0.5 port 22
        """
        let details = SSHRecovery.details(raw)
        #expect(details.contains("kex_exchange_identification") && details.contains("Connection closed by 10.0.0.5 port 22"))
        #expect(!details.contains("Permanently added"), "ssh's chatter isn't part of the failure")
    }

    /// Text ssh never wrote isn't made to mean something.
    @Test func saysNothingAboutWhatItDoesntKnow() {
        #expect(SSHRecovery.diagnose("", agent: Self.agent(.noKeys), keysOnDisk: []) == nil)
        #expect(SSHRecovery.diagnose("ssh: connect to host devbox port 22: Undocumented thing",
                                     agent: Self.agent(.noKeys), keysOnDisk: []) == nil)
        #expect(SSHRecovery.diagnose("Unable to negotiate with 10.0.0.5 port 22: no matching nonsense found.",
                                     agent: Self.agent(.noKeys), keysOnDisk: []) == nil)
    }

    // MARK: Which agent the advice is about (bug B1)

    /// The keys ssh offered were refused: with the agent ssh would use by
    /// itself, Libertty can load them; with any other agent it must say which
    /// one, because `ssh-add` wouldn't reach it.
    @Test func refusedKeysNameTheAgentThatHasNone() {
        let refused = "me@devbox: Permission denied (publickey,gssapi-keyex,gssapi-with-mic)."
        let keys = ["/Users/me/.ssh/id_ed25519"]

        // The macOS agent, empty: Libertty offers to put the keys in it.
        #expect(SSHRecovery.diagnose(refused, agent: Self.agent(.noKeys), keysOnDisk: keys) == .keysNotLoaded(keys))

        // 1Password's agent, empty: adding to the macOS agent would change
        // nothing, so the advice names 1Password instead.
        let onePassword = Self.agent(.noKeys, name: "1Password's agent", socket: "/tmp/op.sock", isDefault: false)
        #expect(SSHRecovery.diagnose(refused, agent: onePassword, keysOnDisk: keys)
                == .agentWithoutKeys(agent: "1Password's agent", socket: "/tmp/op.sock", answer: .noKeys, fromConfig: false))
        let body = SSHRecovery.explain(SSHRecovery.diagnose(refused, agent: onePassword, keysOnDisk: keys)!,
                                       destination: "devbox").body
        #expect(body.contains("1Password's agent"))
        #expect(!body.lowercased().contains("ssh-add"), "it must not tell them to fill an agent ssh won't ask")

        // One ~/.ssh/config picked for this host: said so, so they know why.
        let fromConfig = Self.agent(.notRunning, name: "Secretive's agent", socket: "/tmp/s.ssh",
                                    isDefault: false, fromConfig: true)
        let problem = SSHRecovery.diagnose(refused, agent: fromConfig, keysOnDisk: keys)
        #expect(problem == .agentWithoutKeys(agent: "Secretive's agent", socket: "/tmp/s.ssh",
                                             answer: .notRunning, fromConfig: true))
        #expect(SSHRecovery.explain(problem!, destination: "devbox").body.contains("IdentityAgent"))

        // A host set up to use no agent at all.
        #expect(SSHRecovery.diagnose(refused, agent: Self.agent(.noAgent, name: "No agent", isDefault: false),
                                     keysOnDisk: keys)
                == .agentWithoutKeys(agent: "No agent", socket: nil, answer: .noAgent, fromConfig: false))

        // An agent with keys: the host simply refused them, nothing to fix here.
        #expect(SSHRecovery.diagnose(refused, agent: Self.agent(.keys(3)), keysOnDisk: keys) == nil)
        // The macOS agent is empty but there is nothing in ~/.ssh to load.
        #expect(SSHRecovery.diagnose(refused, agent: Self.agent(.noKeys), keysOnDisk: [])
                == .agentWithoutKeys(agent: "The macOS agent", socket: nil, answer: .noKeys, fromConfig: false))
    }
}

/// The agent ssh asks for a host's keys: what `ssh -G` says, which sockets
/// are really there, and which of the two wins.
struct SSHAgentTests {
    // MARK: ssh -G

    @Test func readsIdentityAgentFromSSHConfig() {
        // ssh -G prints every setting, lower-cased, one per line.
        let plain = """
        user me
        hostname devbox.example
        port 22
        identityagent SSH_AUTH_SOCK
        identityfile ~/.ssh/id_rsa
        """
        #expect(SSHAgent.identityAgent(fromConfig: plain) == "SSH_AUTH_SOCK")
        #expect(SSHAgent.identityAgent(fromConfig: "hostname devbox\nport 22") == nil)
        #expect(SSHAgent.identityAgent(fromConfig: "identityagent none") == "none")
        // A path, with the quotes ssh keeps and a ~ for the home folder.
        #expect(SSHAgent.identityAgent(fromConfig: "identityagent \"~/.1password/agent.sock\"")
                == NSHomeDirectory() + "/.1password/agent.sock")
        #expect(SSHAgent.identityAgent(fromConfig: "identityagent /tmp/custom.sock") == "/tmp/custom.sock")
        // Settings whose names merely begin the same aren't it.
        #expect(SSHAgent.identityAgent(fromConfig: "identityfile ~/.ssh/id_ed25519\nidentitiesonly yes") == nil)
    }

    // MARK: Sockets on this Mac

    /// A real bound Unix socket, a plain file and nothing at all are three
    /// different answers — "that file isn't a socket" is worth saying.
    @Test func tellsASocketFromAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socket = dir.appendingPathComponent("agent.sock").path
        let fd = try bind(socket)
        defer { close(fd) }
        let file = dir.appendingPathComponent("notes.txt").path
        try "not a socket".write(toFile: file, atomically: true, encoding: .utf8)
        let missing = dir.appendingPathComponent("gone.sock").path

        #expect(SSHAgent.kind(ofPath: socket) == .socket)
        #expect(SSHAgent.kind(ofPath: file) == .otherFile)
        #expect(SSHAgent.kind(ofPath: missing) == .missing)
        // The first candidate that is really a socket is the one used.
        #expect(SSHAgent.firstSocket(among: [missing, file, socket]) == socket)
        #expect(SSHAgent.firstSocket(among: [missing, file]) == nil)
    }

    /// Binding a Unix socket and listening, as every agent does.
    private func bind(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            path.withCString { strncpy(UnsafeMutableRawPointer(field).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            Darwin.bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), size)
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        return fd
    }

    // MARK: What ssh-add answered

    @Test func readsWhatSSHAddSaid() {
        let two = """
        256 SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa me@mac (ED25519)
        3072 SHA256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb me@work (RSA)
        """
        #expect(SSHAgent.answer(status: 0, output: two) == .keys(2))
        #expect(SSHAgent.answer(status: 1, output: "The agent has no identities.") == .noKeys)
        #expect(SSHAgent.answer(status: 2, output: "Error connecting to agent: No such file or directory") == .notRunning)
        // Whatever the status, an agent that can't be reached isn't empty.
        #expect(SSHAgent.answer(status: 1, output: "Error connecting to agent: Connection refused") == .notRunning)
    }

    // MARK: Which one wins

    /// ~/.ssh/config comes before the setting: that is the user's own word on
    /// the host, and ssh would take it over anything Libertty added anyway.
    @Test func sshConfigComesFirst() {
        func standing(setting: SSHAgent, configured: String?, defaultSocket: String? = "/tmp/launchd.sock")
            -> SSHAgentStanding {
            SSHAgent.standing(setting: setting, configured: configured, defaultSocket: defaultSocket) { _ in .keys(1) }
        }

        // The host names an agent: used, and marked as coming from the config.
        let fromConfig = standing(setting: .onePassword, configured: "/tmp/secretive.ssh")
        #expect(fromConfig.socket == "/tmp/secretive.ssh")
        #expect(fromConfig.fromConfig)
        #expect(!fromConfig.isDefault)

        // The host wants no agent: no socket is asked, and it says so.
        let none = standing(setting: .onePassword, configured: "none")
        #expect(none.answer == .noAgent && none.fromConfig)

        // The config leaves it at the default: the setting decides.
        #expect(standing(setting: .system, configured: "SSH_AUTH_SOCK").isDefault)
        #expect(!standing(setting: .system, configured: "SSH_AUTH_SOCK").fromConfig)

        // ssh said nothing about the host (an unknown alias): the setting again.
        #expect(standing(setting: .system, configured: nil).isDefault)

        // The agent the environment names is the one plain ssh-add reaches,
        // so keys can still be offered to it even when the config names it.
        let same = standing(setting: .system, configured: "/tmp/launchd.sock")
        #expect(same.isDefault && same.fromConfig)
    }

    /// A named agent whose socket isn't on this Mac isn't running — Libertty
    /// says that rather than asking a path that doesn't exist.
    @Test func anAgentThatIsntInstalledIsntRunning() {
        var asked = false
        let standing = SSHAgent.standing(setting: .custom("/nowhere/at/all.sock"), configured: nil,
                                         defaultSocket: nil) { _ in
            asked = true
            return .keys(1)
        }
        #expect(standing.answer == .notRunning)
        #expect(!asked, "nothing to ask: there is no socket there")
    }

    /// The config's two settings come to one agent.
    @Test func readsTheSetting() {
        #expect(SSHAgent.chosen(setting: "system", socket: "") == .system)
        #expect(SSHAgent.chosen(setting: "1password", socket: "") == .onePassword)
        #expect(SSHAgent.chosen(setting: "custom", socket: "/tmp/a.sock") == .custom("/tmp/a.sock"))
        // Custom with no socket named yet is ssh's own choice again.
        #expect(SSHAgent.chosen(setting: "custom", socket: "") == .system)
        // A path straight in `ssh-agent`, and a value that means nothing.
        #expect(SSHAgent.chosen(setting: "/tmp/b.sock", socket: "") == .custom("/tmp/b.sock"))
        #expect(SSHAgent.chosen(setting: "nonsense", socket: "") == .system)
        #expect(SSHAgent(token: "nonsense") == nil)
        // Every agent Libertty knows has somewhere to look.
        for agent in SSHAgent.known where agent != .system {
            #expect(!agent.socketCandidates.isEmpty, "\(agent.token) has no socket to look for")
            #expect(agent.socketCandidates.allSatisfy { $0.hasPrefix("/") }, "\(agent.token): ~ must be expanded")
        }
    }

    /// Libertty adds `-o IdentityAgent` only when it has something to add and
    /// the host's own configuration hasn't already settled it.
    @Test func addsTheOptionOnlyWhenItShould() {
        // Nothing to add for ssh's own choice, whatever the config says.
        #expect(SSHAgent.options(for: "devbox", setting: .system).isEmpty)
        // An agent that isn't on this Mac: no option, so ssh keeps its own way.
        #expect(SSHAgent.options(for: "devbox", setting: .custom("/nowhere/at/all.sock")).isEmpty)
    }
}
