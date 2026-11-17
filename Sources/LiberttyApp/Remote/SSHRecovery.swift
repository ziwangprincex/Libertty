import AppKit

/// What to do when ssh can't connect, as Rex walks the user through it: a
/// host whose key changed (reinstalled, or someone in between — Libertty
/// can't tell which, so it says so and lets them decide), keys on disk that
/// ssh-agent hasn't got, an agent that holds nothing for this host, and the
/// failures ssh explains only to someone who already knows SSH — no common
/// key exchange method, a host that closes the connection at once.
///
/// Reading ssh's words and putting them plainly is in SSHFailure, as pure
/// functions of the text. This file asks the user and does what they say.
enum SSHRecovery {
    enum Problem: Equatable, Sendable {
        /// "REMOTE HOST IDENTIFICATION HAS CHANGED": the host as known_hosts
        /// names it (`[host]:2222` for another port), the new key's
        /// fingerprint, and the known_hosts file and line with the old one.
        case changedHostKey(host: String, fingerprint: String?, file: String?, line: Int?)
        /// "Permission denied (publickey…)" while the agent ssh would use by
        /// itself has no keys and these are on disk: `ssh-add` can fix it.
        case keysNotLoaded([String])
        /// The same, but the keys live in another agent (1Password, a
        /// YubiKey, one ~/.ssh/config names for this host): only the user can
        /// put a key in it, so Libertty says which agent it is.
        case agentWithoutKeys(agent: String, socket: String?, answer: SSHAgentStanding.Answer, fromConfig: Bool)
        /// ssh and the host found no key exchange method, host key type,
        /// cipher or message check in common.
        case noCommonAlgorithm(Negotiation, offered: String)
        /// The host took the connection and closed it without a greeting.
        case closedWithoutAnswer(host: String?, port: Int?)
        /// ssh never reached the host at all.
        case unreachable(Unreachable, host: String?, port: Int?)
        /// The host counted too many keys as failed logins and gave up.
        case tooManyAuthFailures
        /// Whatever answered doesn't speak SSH (the greeting, if ssh quoted it).
        case notSSH(String?)

        /// Trying again won't help until someone changes something. A host
        /// out of reach, or one that closed the connection at once, may
        /// answer the next time: Retry just tries.
        var needsUser: Bool {
            switch self {
            case .unreachable, .closedWithoutAnswer: false
            default: true
            }
        }

        /// Trying again as things are fails the same way: ssh's config (or
        /// the host's) has to change first — no algorithm in common, no SSH
        /// server there, a name nothing resolves, too many keys offered.
        /// Its sheet's first button closes it; Try Again waits for after.
        var retryAloneFails: Bool {
            switch self {
            case .noCommonAlgorithm, .notSSH, .tooManyAuthFailures, .unreachable(.unknownName, _, _): true
            default: false
            }
        }
    }

    // MARK: Asking the Mac first

    /// What ssh uses for `destination` and what it holds, with the keys in
    /// ~/.ssh. Runs ssh and ssh-add: not on the main thread.
    static func facts(for destination: String) -> (agent: SSHAgentStanding, keys: [String]) {
        // (Not the config itself: this runs off the main thread.)
        let setting = SSHAgent.current
        return (SSHAgent.standing(for: destination, setting: setting), keysOnDisk())
    }

    /// The same as `diagnose`, for the command line: blocking. ssh and the
    /// agent are asked only when the keys were refused: for anything else
    /// what the agent holds says nothing, and a hung agent would hold up
    /// the answer.
    static func diagnose(_ errors: String, destination: String) -> Problem? {
        guard !errors.isEmpty else { return nil }
        guard errors.contains("Permission denied (publickey") else {
            return diagnose(errors, agent: .unasked, keysOnDisk: [])
        }
        let facts = facts(for: destination)
        return diagnose(errors, agent: facts.agent, keysOnDisk: facts.keys)
    }

    /// What `errors` is, with the facts gathered in the background: which
    /// agent a host uses can only be had by asking ssh, and no window waits
    /// on a subprocess.
    @MainActor
    static func diagnose(_ errors: String, destination: String, then: @escaping (Problem?) -> Void) {
        guard !errors.isEmpty else { return then(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = diagnose(errors, destination: destination)
            DispatchQueue.main.async { then(problem) }
        }
    }

    // MARK: Asking the user

    /// Ask what to do about `problem` in a sheet on `window` (or a dialog),
    /// do it, and call `retry` if the connection should be tried again.
    /// `errors` is all ssh said, for the details button.
    @MainActor
    static func offer(_ problem: Problem, destination: String, errors: String = "",
                      in window: NSWindow?, retry: @escaping () -> Void) {
        let (title, body) = explain(problem, destination: destination)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        switch problem {
        case .changedHostKey(let host, let fingerprint, let file, _):
            alert.alertStyle = .critical
            alert.addButton(withTitle: L10n.t("Remove the Old Key"))
            if fingerprint != nil { alert.addButton(withTitle: L10n.t("Copy Fingerprint")) }
            alert.addCancelButton()
            present(alert, in: window) { response in
                switch response {
                case .alertFirstButtonReturn:
                    if let failure = removeOldKey(host: host, file: file) {
                        let oops = NSAlert()
                        oops.messageText = L10n.t("Couldn't remove the old key")
                        oops.informativeText = failure
                        present(oops, in: window) { _ in }
                    } else {
                        retry()
                    }
                case .alertSecondButtonReturn where fingerprint != nil:
                    copy(fingerprint ?? "")
                default: break
                }
            }

        case .keysNotLoaded(let keys):
            alert.addButton(withTitle: L10n.t("Add Keys to ssh-agent"))
            alert.addCancelButton()
            present(alert, in: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = addToAgent(keys)
                    DispatchQueue.main.async {
                        if ok { retry() } else {
                            let oops = NSAlert()
                            oops.messageText = L10n.t("ssh-agent didn't take the keys")
                            present(oops, in: window) { _ in }
                        }
                    }
                }
            }

        // Nothing Libertty can do for the user: what it is, what fixes it,
        // and ssh's own words for whoever wants them.
        default:
            let details = details(errors)
            if !details.isEmpty { alert.informativeText += "\n\n" + L10n.t("ssh said:") + "\n" + details }
            // Return tries again only where trying might help.
            var actions: [() -> Void] = []
            func button(_ title: String, _ action: @escaping () -> Void) {
                alert.addButton(withTitle: L10n.t(title))
                actions.append(action)
            }
            if problem.retryAloneFails { button("OK") {} }
            button("Try Again", retry)
            if !details.isEmpty { button("Copy Details") { copy(details) } }
            if !problem.retryAloneFails {
                alert.addCancelButton()
                actions.append {}
            }
            // With no Cancel, Esc is OK's: it closes the sheet as Return does.
            present(alert, in: window, escapes: problem.retryAloneFails ? 0 : nil) { response in
                let i = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if actions.indices.contains(i) { actions[i]() }
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// `escapes`: the button Esc presses, for an alert without Cancel
    /// (AppKit gives Esc to Cancel alone).
    @MainActor
    private static func present(_ alert: NSAlert, in window: NSWindow?, escapes: Int? = nil,
                                then: @escaping (NSApplication.ModalResponse) -> Void) {
        var monitor: Any?
        if let escapes, alert.buttons.indices.contains(escapes) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
                guard event.keyCode == 53, let alert, event.window === alert.window else { return event }
                alert.buttons[escapes].performClick(nil)
                return nil
            }
        }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if let monitor { NSEvent.removeMonitor(monitor) }
            then(response)
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    // MARK: Doing

    /// `ssh-keygen -R HOST` on the file that has it (ssh-keygen keeps the
    /// file as it was beside it, as known_hosts.old). nil when done, else why not.
    static func removeOldKey(host: String, file: String?) -> String? {
        var args = ["-R", host]
        if let file { args += ["-f", file] }
        let (status, output) = run("/usr/bin/ssh-keygen", args)
        return status == 0 ? nil : (output.isEmpty ? "ssh-keygen ended with status \(status)" : output)
    }

    /// Private keys in ~/.ssh: id_* files with their .pub beside them.
    static func keysOnDisk() -> [String] {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("id_") && !$0.hasSuffix(".pub") && names.contains($0 + ".pub") }
            .sorted().map { (dir as NSString).appendingPathComponent($0) }
    }

    /// `ssh-add --apple-use-keychain KEYS`: a passphrase is asked in
    /// Libertty's dialog (SSH_ASKPASS, as Connect to Host does).
    static func addToAgent(_ keys: [String]) -> Bool {
        var env = ProcessInfo.processInfo.environment
        if let exe = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = exe
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["LIBERTTY_ASKPASS"] = "1"
            if env["DISPLAY"] == nil { env["DISPLAY"] = ":0" }
        }
        return run("/usr/bin/ssh-add", ["--apple-use-keychain"] + keys, environment: env).status == 0
    }

    private static func run(_ tool: String, _ args: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
