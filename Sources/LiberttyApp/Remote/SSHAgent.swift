import CPty
import Foundation

/// Where ssh finds the keys for a host. By default that is ssh's own
/// business: its `IdentityAgent`, or the agent `SSH_AUTH_SOCK` names — on a
/// Mac usually the one launchd keeps. People who hold their keys somewhere
/// else (1Password, Secretive, a YubiKey) can say so here, and Libertty
/// passes it to ssh as `-o IdentityAgent=…` when it connects to a host.
///
/// One thing always wins over the setting: an `IdentityAgent` the user wrote
/// in ~/.ssh/config for that host. That is their own word on it, and ssh
/// takes the first value it is given, so Libertty asks ssh what the host
/// resolves to (`ssh -G`) before it adds anything of its own.
enum SSHAgent: Equatable, Sendable {
    /// ssh decides, as it does without Libertty.
    case system
    case onePassword
    case secretive
    case bitwarden
    case yubikey
    case gpg
    /// A socket the user named.
    case custom(String)

    /// The ones offered by name, in the order Settings shows them.
    static let known: [SSHAgent] = [.system, .onePassword, .secretive, .bitwarden, .yubikey, .gpg]

    /// What the config file holds (`remote-hosts-ssh-agent`).
    var token: String {
        switch self {
        case .system: "system"
        case .onePassword: "1password"
        case .secretive: "secretive"
        case .bitwarden: "bitwarden"
        case .yubikey: "yubikey"
        case .gpg: "gpg"
        case .custom(let path): path
        }
    }

    /// From the config file: a name, or a path for an agent Libertty doesn't
    /// know by name. nil for anything else, so the config can say so —
    /// `custom` among them, since its socket is a setting of its own and only
    /// `chosen(setting:socket:)` can put the two together.
    init?(token: String) {
        let text = token.trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "", "system", "ssh", "default": self = .system
        case "1password", "onepassword": self = .onePassword
        case "secretive": self = .secretive
        case "bitwarden": self = .bitwarden
        case "yubikey", "yubikey-agent": self = .yubikey
        case "gpg", "gnupg", "gpg-agent": self = .gpg
        default:
            guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
            self = .custom(Self.expand(text))
        }
    }

    /// What the two settings come to: `ssh-agent = custom` takes its path from
    /// `ssh-agent-socket`, and with none named it is ssh's own choice again.
    static func chosen(setting: String, socket: String) -> SSHAgent {
        let path = socket.trimmingCharacters(in: .whitespaces)
        if setting.trimmingCharacters(in: .whitespaces).lowercased() == "custom" {
            return path.isEmpty ? .system : .custom(expand(path))
        }
        return SSHAgent(token: setting) ?? .system
    }

    /// The agent the config names (Settings and every connection read this).
    static func chosen(_ config: Config) -> SSHAgent {
        chosen(setting: config.sshAgent, socket: config.sshAgentSocket)
    }

    /// The two settings as they stand, for any thread: the config itself is
    /// the main thread's (copying it while a reload replaces it isn't safe),
    /// so ConfigStore keeps this copy current as it changes.
    static var setting: (agent: String, socket: String) { settingLock.withLock { kept } }

    /// The agent the settings name, from any thread.
    static var current: SSHAgent { let s = setting; return chosen(setting: s.agent, socket: s.socket) }

    /// The config changed (ConfigStore, as it changes it).
    static func keep(_ config: Config) {
        settingLock.withLock { kept = (config.sshAgent, config.sshAgentSocket) }
    }

    private static let settingLock = NSLock()
    nonisolated(unsafe) private static var kept = (agent: Config().sshAgent, socket: Config().sshAgentSocket)

    /// In the picker.
    var label: String {
        switch self {
        case .system: L10n.t("Whatever ssh chooses")
        case .onePassword: "1Password"
        case .secretive: "Secretive"
        case .bitwarden: "Bitwarden"
        case .yubikey: "YubiKey"
        case .gpg: "GnuPG"
        case .custom: L10n.t("Custom…")
        }
    }

    /// How the agent is named in a sentence about it.
    var agentName: String {
        switch self {
        case .system: L10n.t("The agent ssh chooses")
        case .onePassword: L10n.t("1Password's agent")
        case .secretive: L10n.t("Secretive's agent")
        case .bitwarden: L10n.t("Bitwarden's agent")
        case .yubikey: L10n.t("The YubiKey agent")
        case .gpg: L10n.t("The GnuPG agent")
        case .custom(let path): (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Where each agent is known to listen. More than one when an agent ships
    /// in several shapes (1Password's own build and the sandboxed one, a
    /// Homebrew prefix per architecture); the first that is really a socket wins.
    var socketCandidates: [String] {
        switch self {
        case .system:
            []
        case .onePassword:
            [expand("~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"),
             expand("~/.1password/agent.sock")]
        case .secretive:
            [expand("~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh")]
        case .bitwarden:
            [expand("~/.bitwarden-ssh-agent.sock"),
             expand("~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock")]
        case .yubikey:
            ["/opt/homebrew/var/run/yubikey-agent.sock", "/usr/local/var/run/yubikey-agent.sock"]
        case .gpg:
            [expand("~/.gnupg/S.gpg-agent.ssh")]
        case .custom(let path):
            [expand(path)]
        }
    }

    private func expand(_ path: String) -> String { Self.expand(path) }

    /// A leading ~ as the running user's home (NSString's own expansion also
    /// takes ~other, which an agent's path never means).
    static func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst(1)
    }

    // MARK: Sockets

    /// What is at a path, as far as an agent is concerned.
    enum PathKind: Equatable, Sendable {
        /// A socket: something may be listening (only connecting tells).
        case socket
        /// There, but not a socket — a path typed by hand, most likely.
        case otherFile
        case missing
    }

    static func kind(ofPath path: String) -> PathKind {
        var st = stat()
        guard stat(path, &st) == 0 else { return .missing }
        return (st.st_mode & S_IFMT) == S_IFSOCK ? .socket : .otherFile
    }

    /// The first of `candidates` that is a socket.
    static func firstSocket(among candidates: [String]) -> String? {
        candidates.first { kind(ofPath: $0) == .socket }
    }

    /// Where this agent listens, if it does. nil for `.system`, which is
    /// ssh's own choice and has no path of ours.
    var resolvedSocket: String? { Self.firstSocket(among: socketCandidates) }

    /// Whether this agent is installed and listening: what Settings offers.
    var isAvailable: Bool {
        switch self {
        case .system, .custom: true
        default: resolvedSocket != nil
        }
    }
}

// MARK: - What the agent for a host says

/// Which agent ssh asks for keys when it connects to one host, and what it
/// answered: the Settings status line, and the advice when a login is refused.
struct SSHAgentStanding: Equatable, Sendable {
    /// Not asked (the failure had nothing to do with keys).
    static let unasked = SSHAgentStanding(name: "", socket: nil, isDefault: true, fromConfig: false, answer: .keys(0))

    /// Named for a sentence: "1Password's agent", "The macOS agent".
    var name: String
    /// Where it listens; nil when it is whatever `SSH_AUTH_SOCK` names, and
    /// so the one plain `ssh-add` talks to.
    var socket: String?
    /// Whether `ssh-add` without a socket of its own reaches this agent —
    /// then Libertty can offer to load the keys into it.
    var isDefault: Bool
    /// ~/.ssh/config picked this agent for the host, not the setting.
    var fromConfig: Bool
    var answer: Answer

    enum Answer: Equatable, Sendable {
        case keys(Int)
        /// Listening, with nothing in it.
        case noKeys
        /// Nothing listening there (the app that keeps the keys isn't open).
        case notRunning
        /// A path that is there but isn't a socket.
        case notASocket
        /// The host is set up to use no agent at all (`IdentityAgent none`).
        case noAgent
    }
}

extension SSHAgent {
    /// `identityagent` for a host, as ssh resolves it (`ssh -G HOST`): the
    /// value with its quotes off and a leading ~ expanded. "none" and
    /// "SSH_AUTH_SOCK" come back as they are — they mean no agent and the
    /// default one. nil when ssh named no agent at all.
    static func identityAgent(fromConfig text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "identityagent" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !value.isEmpty else { return nil }
            return value == "none" || value == "SSH_AUTH_SOCK" ? value : expand(value)
        }
        return nil
    }

    /// Which agent a host ends up with, and how it answered, from facts
    /// gathered elsewhere: the setting, what `ssh -G` said for the host
    /// (`configured`), the agent `SSH_AUTH_SOCK` names, and `ask`, which
    /// asks one socket (nil: the default one) what it holds.
    static func standing(setting: SSHAgent, configured: String?, defaultSocket: String?,
                         ask: (String?) -> SSHAgentStanding.Answer) -> SSHAgentStanding {
        // The user's own ~/.ssh/config comes first: ssh would take its value
        // over anything Libertty added, so Libertty doesn't add one. (`ssh -G`
        // says IdentityAgent only when the config sets it: SSH_AUTH_SOCK
        // there is the user asking for the default agent for this host.)
        if configured == "SSH_AUTH_SOCK" {
            let named = defaultSocket.map { name(ofSocket: $0) } ?? L10n.t("The macOS agent")
            return SSHAgentStanding(name: named, socket: nil, isDefault: true, fromConfig: true, answer: ask(nil))
        }
        if let configured {
            if configured == "none" {
                return SSHAgentStanding(name: L10n.t("No agent"), socket: nil, isDefault: false,
                                        fromConfig: true, answer: .noAgent)
            }
            return look(at: configured, named: name(ofSocket: configured), fromConfig: true,
                        defaultSocket: defaultSocket, ask: ask)
        }
        switch setting {
        case .system:
            // Whatever ssh would use by itself, which is SSH_AUTH_SOCK's agent.
            let named = defaultSocket.map { name(ofSocket: $0) } ?? L10n.t("The macOS agent")
            return SSHAgentStanding(name: named, socket: nil, isDefault: true, fromConfig: false, answer: ask(nil))
        default:
            // A named agent with no socket on this Mac isn't running at all;
            // say that rather than asking a path that isn't there.
            guard let socket = setting.resolvedSocket ?? setting.socketCandidates.first else {
                return SSHAgentStanding(name: setting.agentName, socket: nil, isDefault: false,
                                        fromConfig: false, answer: .notRunning)
            }
            return look(at: socket, named: setting.agentName, fromConfig: false,
                        defaultSocket: defaultSocket, ask: ask)
        }
    }

    private static func look(at socket: String, named: String, fromConfig: Bool, defaultSocket: String?,
                             ask: (String?) -> SSHAgentStanding.Answer) -> SSHAgentStanding {
        // The same socket the environment names: plain `ssh-add` reaches it,
        // so keys can be offered to it.
        let isDefault = socket == defaultSocket
        var standing = SSHAgentStanding(name: named, socket: socket, isDefault: isDefault,
                                        fromConfig: fromConfig, answer: .notRunning)
        switch kind(ofPath: socket) {
        case .socket: standing.answer = ask(isDefault ? nil : socket)
        case .otherFile: standing.answer = .notASocket
        case .missing: standing.answer = .notRunning
        }
        return standing
    }

    /// An agent named by its socket: the one Libertty knows with that path,
    /// else the path itself.
    static func name(ofSocket socket: String) -> String {
        for agent in known where agent.socketCandidates.contains(socket) { return agent.agentName }
        // The one launchd starts for each login (`SSH_AUTH_SOCK` on a Mac):
        // /private/tmp/com.apple.launchd.XXXX/Listeners, or under /var/run.
        if isLaunchdAgent(socket) { return L10n.t("The macOS agent") }
        return (socket as NSString).abbreviatingWithTildeInPath
    }

    static func isLaunchdAgent(_ socket: String) -> Bool {
        let path = socket.hasPrefix("/private/") ? String(socket.dropFirst("/private".count)) : socket
        return (path.hasPrefix("/tmp/com.apple.launchd.") || path.hasPrefix("/var/run/com.apple.launchd."))
            && path.hasSuffix("/Listeners")
    }

    /// What `ssh-add -l` said: its keys, or why there are none. (It ends with
    /// 1 for an agent that holds nothing, 2 when it couldn't reach one.)
    static func answer(status: Int32, output: String) -> SSHAgentStanding.Answer {
        if output.contains("Error connecting to agent") || output.contains("Could not open a connection") {
            return .notRunning
        }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("The agent has no identities") }
        if status == 0, !lines.isEmpty { return .keys(lines.count) }
        return status == 1 || status == 0 ? .noKeys : .notRunning
    }

    // MARK: Asking (blocking)

    /// Which agent `destination` uses and what it holds. Runs ssh and
    /// ssh-add, so never on the main thread.
    static func standing(for destination: String, setting: SSHAgent) -> SSHAgentStanding {
        standing(setting: setting, configured: configuredAgent(for: destination),
                 defaultSocket: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]) { socket in
            ask(socket)
        }
    }

    /// `ssh-add -l` on one socket (nil: the agent the environment names).
    static func ask(_ socket: String?) -> SSHAgentStanding.Answer {
        var env = ProcessInfo.processInfo.environment
        if let socket { env["SSH_AUTH_SOCK"] = socket }
        // Nothing may ask for a passphrase here: this only counts keys.
        env["SSH_ASKPASS_REQUIRE"] = "never"
        env.removeValue(forKey: "SSH_ASKPASS")
        env.removeValue(forKey: "LIBERTTY_ASKPASS")
        let run = runTool("/usr/bin/ssh-add", ["-l"], environment: env, timeout: 5)
        return answer(status: run.status, output: run.output)
    }

    /// `IdentityAgent` as ssh resolves it for `destination`, or nil when ssh
    /// couldn't say (an unknown host alias, no ssh at all).
    static func configuredAgent(for destination: String) -> String? {
        let ssh = ProcessInfo.processInfo.environment["LIBERTTY_SSH"] ?? "/usr/bin/ssh"
        var arguments: [String] = []
        // Tests point ssh at their own configuration, as RemoteHost does.
        if let config = ProcessInfo.processInfo.environment["LIBERTTY_SSH_CONFIG"], !config.isEmpty {
            arguments += ["-F", config]
        }
        arguments += ["-G", destination]
        let run = runTool(ssh, arguments, environment: nil, timeout: 10)
        guard run.status == 0 else { return nil }
        return identityAgent(fromConfig: run.output)
    }

    /// The `-o` options Libertty adds when it runs ssh for a host: the agent
    /// the setting names, unless ~/.ssh/config already names one for that
    /// host (then ssh's own value stands). Blocking; not on the main thread.
    static func options(for destination: String, setting: SSHAgent) -> [String] {
        // What is on this Mac first: with nothing to add, ssh is left to its
        // own way and no `ssh -G` is run at all.
        guard setting != .system, let socket = setting.resolvedSocket else { return [] }
        // Any IdentityAgent the config sets for the host stands, SSH_AUTH_SOCK
        // too (ssh -G says it only when the config does).
        if configuredAgent(for: destination) != nil { return [] }
        return ["-o", identityAgentOption(socket)]
    }

    /// `IdentityAgent="PATH"`: ssh splits an option's value into words, so
    /// a path with a space in it (1Password's, under Group Containers) is
    /// quoted, a quote or backslash in it escaped.
    static func identityAgentOption(_ socket: String) -> String {
        let escaped = socket.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "IdentityAgent=\"" + escaped + "\""
    }

    /// Run a tool and read all it said, with a deadline so a hung agent
    /// can't hold a connection up.
    ///
    /// What it says goes to a file, not a pipe: ssh hands its own stderr to
    /// what it runs (`Match exec`), and something of that left running
    /// would keep a pipe open — reading it would wait for that too. The
    /// tool runs in a process group of its own, ended whole when the time
    /// is up: SIGTERM, then SIGKILL a moment later.
    static func runTool(_ tool: String, _ arguments: [String], environment: [String: String]?,
                                timeout: TimeInterval) -> (status: Int32, output: String) {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("libertty-tool-\(UUID().uuidString)")
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return (-1, "") }
        defer {
            close(fd)
            unlink(path)
        }
        var argv = ([tool] + arguments).map { strdup($0) } + [nil]
        var envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let pid = libertty_spawn_io(tool, &argv, &envp, -1, fd, fd)
        guard pid > 0 else { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var ended = false
        while !ended, Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r < 0 && errno != EINTR) { ended = true } else { usleep(10_000) }
        }
        if !ended {
            // Its whole group: what it started goes with it.
            kill(-pid, SIGTERM)
            for _ in 0..<50 where !ended {
                if waitpid(pid, &status, WNOHANG) == pid { ended = true } else { usleep(10_000) }
            }
            if !ended {
                kill(-pid, SIGKILL)
                for _ in 0..<100 where !ended {
                    if waitpid(pid, &status, WNOHANG) == pid { ended = true } else { usleep(10_000) }
                }
            }
            // (Not reaped after all that: the system has it; nobody waits on it.)
            return (-1, "")
        }
        let code: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : -1
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return (code, "") }
        var bytes = [UInt8](repeating: 0, count: Int(min(size, 1 << 20)))
        let n = pread(fd, &bytes, bytes.count, 0)
        return (code, String(decoding: bytes.prefix(max(0, n)), as: UTF8.self))
    }
}
