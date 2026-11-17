import Foundation

/// Reading ssh's own words and saying them plainly, with the fix: ssh tells
/// the truth, but it tells it to someone who already knows SSH ("no matching
/// key exchange method found. Their offer: …"). Everything here is a pure
/// function of the text ssh wrote, so a sample of real ssh output is a test.
extension SSHRecovery {
    /// Which part of the handshake found nothing in common.
    enum Negotiation: Equatable, Sendable {
        case keyExchange, hostKey, cipher, mac

        /// What it is, in a sentence.
        var what: String {
            switch self {
            case .keyExchange: L10n.t("key exchange method")
            case .hostKey: L10n.t("host key type")
            case .cipher: L10n.t("cipher")
            case .mac: L10n.t("way to check each message")
            }
        }

        /// The sshd_config keyword that lists them on the host.
        var keyword: String {
            switch self {
            case .keyExchange: "KexAlgorithms"
            case .hostKey: "HostKeyAlgorithms"
            case .cipher: "Ciphers"
            case .mac: "MACs"
            }
        }
    }

    /// Why ssh never reached the host at all.
    enum Unreachable: Equatable, Sendable {
        case refused, timedOut, noRoute, networkDown, unknownName
    }

    // MARK: Reading what ssh said

    /// What `errors` (all ssh said) is, if Libertty can put it in plain
    /// words: pure, so the table of samples in the tests is the whole story.
    /// `agent` is the agent ssh uses for this host and what it answered;
    /// `keysOnDisk` the private keys in ~/.ssh.
    static func diagnose(_ errors: String, agent: SSHAgentStanding, keysOnDisk: [String]) -> Problem? {
        if errors.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return changedKey(errors) }
        if let problem = negotiation(errors) { return problem }
        if errors.contains("Protocol major versions differ") || errors.contains("Bad protocol version identification") {
            return .notSSH(greeting(errors))
        }
        if errors.contains("kex_exchange_identification:") {
            let (host, port) = endpoint(errors)
            return .closedWithoutAnswer(host: host, port: port)
        }
        if errors.contains("Too many authentication failures") { return .tooManyAuthFailures }
        if errors.contains("Permission denied (publickey") { return keysRefused(agent: agent, keysOnDisk: keysOnDisk) }
        if let problem = unreachable(errors) { return problem }
        return nil
    }

    /// The keys were refused and the agent is why: either it holds nothing
    /// and plain `ssh-add` can fill it (the agent ssh would use by itself),
    /// or it is some other agent, and only the user can put a key in it.
    private static func keysRefused(agent: SSHAgentStanding, keysOnDisk: [String]) -> Problem? {
        switch agent.answer {
        case .keys:
            // It offered keys and the host turned them down: nothing here to fix.
            return nil
        case .noKeys, .notRunning, .notASocket, .noAgent:
            if agent.isDefault, agent.answer == .noKeys || agent.answer == .notRunning, !keysOnDisk.isEmpty {
                return .keysNotLoaded(keysOnDisk)
            }
            return .agentWithoutKeys(agent: agent.name, socket: agent.socket, answer: agent.answer,
                                     fromConfig: agent.fromConfig)
        }
    }

    /// "REMOTE HOST IDENTIFICATION HAS CHANGED": the host as known_hosts
    /// names it (`[host]:2222` for another port), the new key's fingerprint,
    /// and the known_hosts file and line with the old one.
    private static func changedKey(_ errors: String) -> Problem? {
        var host: String?, fingerprint: String?, file: String?, line: Int?
        for raw in errors.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SHA256:") || l.hasPrefix("MD5:") { fingerprint = l }
            // "Host key for [example.com]:2222 has changed and you have requested strict checking."
            if l.hasPrefix("Host key for "), let end = l.range(of: " has changed") {
                host = String(l[l.index(l.startIndex, offsetBy: 13)..<end.lowerBound])
            }
            // "Offending ED25519 key in /Users/me/.ssh/known_hosts:12"
            if l.hasPrefix("Offending "), let at = l.range(of: " key in ") {
                let place = l[at.upperBound...]
                if let colon = place.lastIndex(of: ":"), let n = Int(place[place.index(after: colon)...]) {
                    file = String(place[..<colon])
                    line = n
                } else {
                    file = String(place)
                }
            }
        }
        guard let host else { return nil }
        return .changedHostKey(host: host, fingerprint: fingerprint, file: file, line: line)
    }

    /// "Unable to negotiate with 10.0.0.5 port 22: no matching cipher found.
    /// Their offer: aes128-cbc,3des-cbc"
    private static func negotiation(_ errors: String) -> Problem? {
        for raw in errors.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard let start = l.range(of: "no matching "), let end = l.range(of: " found", range: start.upperBound..<l.endIndex)
            else { continue }
            let kind: Negotiation
            switch l[start.upperBound..<end.lowerBound].lowercased() {
            case "key exchange method": kind = .keyExchange
            case "host key type": kind = .hostKey
            case "cipher": kind = .cipher
            case "mac": kind = .mac
            default: continue
            }
            var offered = ""
            if let their = l.range(of: "Their offer: ") {
                offered = String(l[their.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            }
            return .noCommonAlgorithm(kind, offered: offered)
        }
        return nil
    }

    /// "ssh: connect to host devbox port 22: Connection refused", and the
    /// name that never resolved.
    private static func unreachable(_ errors: String) -> Problem? {
        for raw in errors.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let name = l.range(of: "Could not resolve hostname ") {
                let rest = l[name.upperBound...]
                let host = String(rest[..<(rest.firstIndex(of: ":") ?? rest.endIndex)])
                return .unreachable(.unknownName, host: host.isEmpty ? nil : host, port: nil)
            }
            guard l.contains("connect to host "), let colon = l.lastIndex(of: ":") else { continue }
            let why: Unreachable
            switch l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces) {
            case "Connection refused": why = .refused
            case "Operation timed out", "Connection timed out": why = .timedOut
            case "No route to host": why = .noRoute
            case "Network is unreachable", "Network is down": why = .networkDown
            default: continue
            }
            let (host, port) = endpoint(l)
            return .unreachable(why, host: host, port: port)
        }
        return nil
    }

    /// The host and port in whichever line names them: "connect to host H
    /// port N:", "Connection closed by H port N", "Unable to negotiate with
    /// H port N:".
    static func endpoint(_ errors: String) -> (host: String?, port: Int?) {
        for raw in errors.split(separator: "\n") {
            let words = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let at = words.firstIndex(of: "port"), at > 0, at + 1 < words.count else { continue }
            let host = words[at - 1]
            // Through a jump host or a proxy command, ssh doesn't know who it
            // talks to ("Connection closed by UNKNOWN port 65535"): neither
            // the name nor the port says anything then.
            guard host != "UNKNOWN" else { return (nil, nil) }
            let port = Int(words[at + 1].trimmingCharacters(in: CharacterSet(charactersIn: ":.,")))
            guard port != nil || !host.isEmpty else { continue }
            return (host.isEmpty ? nil : host, port)
        }
        return (nil, nil)
    }

    /// What the other end sent instead of an SSH greeting, if ssh quoted it:
    /// "Bad protocol version identification 'HTTP/1.1 400' from …".
    private static func greeting(_ errors: String) -> String? {
        guard let line = errors.split(separator: "\n").first(where: { $0.contains("Bad protocol version identification") }),
              let open = line.firstIndex(of: "'"), let close = line.lastIndex(of: "'"), open < close
        else { return nil }
        let text = String(line[line.index(after: open)..<close])
        return text.isEmpty ? nil : text
    }

    // MARK: Saying it plainly

    /// What to tell the user about `problem`, in Libertty's words: a title
    /// and the body, with the fix in it. Pure.
    static func explain(_ problem: Problem, destination: String) -> (title: String, body: String) {
        switch problem {
        case .changedHostKey(let host, let fingerprint, let file, let line):
            var body = fill(L10n.t("%@ answered with another key than the one you've connected to before. If it was set up again, remove the old key and connect: you'll be asked to trust the new one. If you don't know why it changed, don't: someone may be between you and the host."), host)
            if let fingerprint { body += "\n\n" + L10n.t("New key:") + " " + fingerprint }
            if let file {
                body += "\n" + L10n.t("Old key:") + " " + (file as NSString).abbreviatingWithTildeInPath
                    + (line.map { ":\($0)" } ?? "")
            }
            return (L10n.t("The host's identification has changed"), body)

        case .keysNotLoaded(let keys):
            let body = fill(L10n.t("%@ refused the keys ssh offered, and ssh-agent has none. These are in ~/.ssh:"), destination)
                + "\n" + keys.map { "  " + ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
                + "\n\n" + L10n.t("A key's passphrase is asked once and kept in your keychain.")
            return (L10n.t("Add your keys to ssh-agent?"), body)

        case .agentWithoutKeys(let agent, let socket, let answer, let fromConfig):
            var body: String
            switch answer {
            case .noAgent:
                body = fill(L10n.t("%@ is set up to use no SSH agent, so ssh offered only the key files in your ssh configuration, and %@ refused them."), destination, destination)
            case .notRunning:
                body = fill(L10n.t("%@ refused the keys ssh offered, and %@ isn't answering. Open the app that keeps your keys, then try again."), destination, agent)
            case .notASocket:
                body = fill(L10n.t("%@ refused the keys ssh offered, and %@ isn't an agent's socket. Check the path of the agent Libertty should use."), destination, agent)
            case .noKeys, .keys:
                body = fill(L10n.t("%@ refused the keys ssh offered, and %@ holds no key for it. Add a key there (or unlock it), then try again."), destination, agent)
            }
            if let socket { body += "\n\n" + L10n.t("Agent:") + " " + (socket as NSString).abbreviatingWithTildeInPath }
            if fromConfig {
                body += "\n" + fill(L10n.t("Your ~/.ssh/config picks that agent for %@ with IdentityAgent."), destination)
            }
            return (L10n.t("The agent has no key for this host"), body)

        case .noCommonAlgorithm(let kind, let offered):
            var body = fill(L10n.t("%@ and the ssh on this Mac share no %@, so they can't even start a connection. ssh dropped it before any login."),
                            destination, kind.what)
            if !offered.isEmpty { body += "\n\n" + fill(L10n.t("The host offers only: %@"), offered) }
            body += "\n\n" + fill(L10n.t("The lasting fix is on the host: let its SSH server offer a current one, by adding it to %@ in sshd_config and restarting the server. To connect right now instead, name one of the host's in %@ under a Host entry for %@ in ~/.ssh/config — that weakens this one connection only."),
                                  kind.keyword, kind.keyword, destination)
            if kind == .hostKey {
                body += "\n\n" + L10n.t("A host with no current host key can make one with ssh-keygen -A.")
            }
            return (L10n.t("ssh and the host have nothing in common"), body)

        case .closedWithoutAnswer(let host, let port):
            let named = host ?? destination
            var body = fill(L10n.t("%@ took the connection and then closed it without saying a word, so ssh never got as far as a login."), named)
            if let port { body += " " + fill(L10n.t("The port that answered was %@."), String(port)) }
            body += "\n\n" + L10n.t("A host under load refuses new connections like this when too many are half-open at once (MaxStartups in its sshd_config). Something in between — a firewall, or the host's own blocklist after failed logins — closes them the same way. Waiting and trying again tells the two apart.")
            return (L10n.t("The host closed the connection at once"), body)

        case .unreachable(let why, let host, let port):
            let named = host ?? destination
            switch why {
            case .refused:
                var body = fill(L10n.t("Nothing is listening for SSH on %@."), named)
                if let port { body += " " + fill(L10n.t("It refused port %@."), String(port)) }
                body += "\n\n" + L10n.t("The host is up — something answered to say no. Its SSH server may be off, or listening on another port: a host that uses one writes it in ~/.ssh/config, or you can name it as host:port.")
                return (L10n.t("The host refused the connection"), body)
            case .timedOut:
                let body = fill(L10n.t("%@ never answered. Nothing came back at all, which is what a firewall in the way looks like, and also what a host that is asleep or off looks like."), named)
                    + "\n\n" + L10n.t("Being on the same network as the host (or on its VPN) is the usual fix.")
                return (L10n.t("The host didn't answer"), body)
            case .noRoute:
                let body = fill(L10n.t("This Mac has no way to reach %@: the network it is on has no route there."), named)
                    + "\n\n" + L10n.t("A VPN that is down, or Wi-Fi that changed, is the usual reason.")
                return (L10n.t("There's no route to the host"), body)
            case .networkDown:
                let body = fill(L10n.t("This Mac has no network to reach %@ over."), named)
                    + "\n\n" + L10n.t("Libertty keeps the sessions on the host as they are and reconnects by itself once the network is back.")
                return (L10n.t("This Mac has no network"), body)
            case .unknownName:
                let body = fill(L10n.t("No address could be found for “%@”, so ssh had nowhere to connect."), named)
                    + "\n\n" + L10n.t("A typo, a name that only resolves on a VPN or a Tailscale network, or a Host entry in ~/.ssh/config whose HostName is wrong: those are the usual reasons.")
                return (L10n.t("That name has no address"), body)
            }

        case .tooManyAuthFailures:
            let body = fill(L10n.t("%@ ended the login after too many tries. ssh offers every key it has one after another, and the host counts each as a failed attempt (MaxAuthTries in its sshd_config)."), destination)
                + "\n\n" + fill(L10n.t("Naming the one key that host wants settles it: an IdentityFile with IdentitiesOnly yes, under a Host entry for %@ in ~/.ssh/config."), destination)
            return (L10n.t("The host stopped the login after too many tries"), body)

        case .notSSH(let greeting):
            var body = fill(L10n.t("Whatever answered on %@ doesn't speak SSH as ssh does, so there was nothing to log in to."), destination)
            if let greeting { body += "\n\n" + L10n.t("It answered with:") + " " + greeting }
            body += "\n\n" + L10n.t("A web server or another service on that port, or an SSH server far too old for a current ssh, both look like this.")
            return (L10n.t("That isn't an SSH server"), body)
        }
    }

    /// `%@` by `%@`, in order (L10n keeps the English text as the key, and a
    /// translation may move them, so one pass per value, leftmost first).
    static func fill(_ format: String, _ values: String...) -> String {
        var text = format
        for value in values {
            guard let at = text.range(of: "%@") else { break }
            text.replaceSubrange(at, with: value)
        }
        return text
    }

    /// ssh's own last words, for the details under an explanation.
    static func details(_ errors: String) -> String {
        let lines = errors.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.suffix(4).joined(separator: "\n")
    }
}
