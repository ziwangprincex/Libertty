import AppKit

/// What to do when ssh can't connect for a reason the user can fix, as
/// Rex walks them through it: a host whose key changed (reinstalled, or
/// someone in between — Libertty can't tell which, so it says so and lets
/// them decide), or keys on disk that ssh-agent hasn't got.
enum SSHRecovery {
    enum Problem: Equatable {
        /// "REMOTE HOST IDENTIFICATION HAS CHANGED": the host as known_hosts
        /// names it (`[host]:2222` for another port), the new key's
        /// fingerprint, and the known_hosts file and line with the old one.
        case changedHostKey(host: String, fingerprint: String?, file: String?, line: Int?)
        /// "Permission denied (publickey…)" while ssh-agent has no keys and
        /// these are on disk.
        case keysNotLoaded([String])
    }

    /// What `errors` (all ssh said) is, if it's one of those.
    static func diagnose(_ errors: String, agentHasKeys: () -> Bool = agentHasKeys,
                         keysOnDisk: () -> [String] = keysOnDisk) -> Problem? {
        if errors.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
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
        if errors.contains("Permission denied (publickey"), !agentHasKeys() {
            let keys = keysOnDisk()
            if !keys.isEmpty { return .keysNotLoaded(keys) }
        }
        return nil
    }

    // MARK: Asking

    /// Ask what to do about `problem` in a sheet on `window` (or a dialog),
    /// do it, and call `retry` if the connection should be tried again.
    @MainActor
    static func offer(_ problem: Problem, destination: String, in window: NSWindow?, retry: @escaping () -> Void) {
        let alert = NSAlert()
        switch problem {
        case .changedHostKey(let host, let fingerprint, let file, let line):
            alert.alertStyle = .critical
            alert.messageText = L10n.t("The host's identification has changed")
            var text = L10n.t("%@ answered with another key than the one you've connected to before. If it was set up again, remove the old key and connect: you'll be asked to trust the new one. If you don't know why it changed, don't: someone may be between you and the host.")
                .replacingOccurrences(of: "%@", with: host)
            if let fingerprint { text += "\n\n" + L10n.t("New key:") + " " + fingerprint }
            if let file { text += "\n" + L10n.t("Old key:") + " " + (file as NSString).abbreviatingWithTildeInPath + (line.map { ":\($0)" } ?? "") }
            alert.informativeText = text
            alert.addButton(withTitle: L10n.t("Remove the Old Key"))
            if fingerprint != nil { alert.addButton(withTitle: L10n.t("Copy Fingerprint")) }
            alert.addButton(withTitle: L10n.t("Cancel"))
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fingerprint ?? "", forType: .string)
                default: break
                }
            }
        case .keysNotLoaded(let keys):
            alert.messageText = L10n.t("Add your keys to ssh-agent?")
            alert.informativeText = L10n.t("%@ refused the keys ssh offered, and ssh-agent has none. These are in ~/.ssh:")
                .replacingOccurrences(of: "%@", with: destination)
                + "\n" + keys.map { "  " + ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
                + "\n\n" + L10n.t("A key's passphrase is asked once and kept in your keychain.")
            alert.addButton(withTitle: L10n.t("Add Keys to ssh-agent"))
            alert.addButton(withTitle: L10n.t("Cancel"))
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
        }
    }

    @MainActor
    private static func present(_ alert: NSAlert, in window: NSWindow?, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: then)
        } else {
            then(alert.runModal())
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

    /// Whether ssh-agent holds any key (`ssh-add -l`: 1 means none).
    static func agentHasKeys() -> Bool { run("/usr/bin/ssh-add", ["-l"]).status == 0 }

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
