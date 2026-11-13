import Foundation
import LiberttyCore

/// `libertty +terminfo`: Libertty's terminfo (Ghostty's xterm-ghostty) on the
/// hosts you ssh to yourself, as Rex's `rex terminfo` does. Connect to Host
/// installs it there by itself; a plain `ssh` in a pane otherwise says
/// TERM=xterm-256color (`ssh-env`), which every host knows but which says
/// less (no undercurl, no synchronized output). Once a host has it, the
/// shell integration's `ssh` keeps TERM=xterm-ghostty there.
///
///   +terminfo setup [SSH ARGS…]   install it on that host (~/.terminfo, by its own tic) and remember it
///   +terminfo status              the hosts that have it, as ssh resolved them
///   +terminfo show                the source, for `libertty +terminfo show | ssh HOST tic -x -`
///   +terminfo forget HOST | --all
///   +terminfo ssh-term -- ARGS    (the ssh wrapper's) the TERM for that ssh; with ssh-terminfo, installs first
enum TerminfoCLI {
    static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        switch sub {
        case "setup":
            let ssh = rest.first == "--" ? Array(rest.dropFirst()) : rest
            guard !ssh.isEmpty else { return usage() }
            guard let key = target(ssh) else { return fail("ssh can't resolve \(ssh.joined(separator: " "))") }
            print("Installing xterm-ghostty's terminfo on \(key)…")
            switch install(ssh, quiet: false) {
            case true:
                remember(key)
                print("Done: ssh in Libertty keeps TERM=xterm-ghostty there.")
                return 0
            case false:
                return fail("couldn't install it there (does the host have tic?)")
            }
        case "status":
            let hosts = known()
            if hosts.isEmpty { print("No hosts have it yet: libertty +terminfo setup HOST") }
            hosts.sorted().forEach { print($0) }
            return 0
        case "show":
            guard let source = source() else { return fail("this copy of Libertty is missing its terminfo") }
            print(source, terminator: "")
            return 0
        case "forget":
            if rest == ["--all"] { save([]); return 0 }
            guard rest.count == 1 else { return usage() }
            // As typed, or as ssh resolves it.
            let gone = Set([rest[0]] + (target([rest[0]]).map { [$0] } ?? []))
            save(known().filter { !gone.contains($0) })
            return 0
        case "ssh-term":
            let ssh = rest.first == "--" ? Array(rest.dropFirst()) : rest
            print(sshTerm(ssh))
            return 0
        default:
            return usage()
        }
    }

    /// The TERM an ssh with these arguments gets: xterm-ghostty for a host
    /// that has it (or, with `ssh-terminfo`, gets it now: an interactive
    /// login only, never one that runs a command), else `ssh-env`'s.
    static func sshTerm(_ ssh: [String]) -> String {
        // Without ssh-env, whatever TERM the pane has.
        let env = ProcessInfo.processInfo.environment
        let fallback = env["LIBERTTY_SSH_TERM"].flatMap { $0.isEmpty ? nil : $0 } ?? env["TERM"] ?? "xterm-256color"
        guard let key = target(ssh) else { return fallback }
        if known().contains(key) { return "xterm-ghostty" }
        guard ConfigStore.shared.config.sshTerminfo, interactive(ssh) else { return fallback }
        FileHandle.standardError.write(Data("Libertty: installing xterm-ghostty's terminfo on \(key)…\n".utf8))
        guard install(ssh, quiet: true) else { return fallback }
        remember(key)
        return "xterm-ghostty"
    }

    // MARK: ssh

    /// `user@hostname:port` as ssh resolves these arguments (aliases, its
    /// config): what's remembered, so `ssh box` and `ssh me@box.local` are one host.
    static func target(_ ssh: [String]) -> String? {
        guard let out = runSSH(["-G"] + ssh, input: nil, timeout: 10), out.status == 0 else { return nil }
        return target(fromConfig: out.output)
    }

    static func target(fromConfig text: String) -> String? {
        var user = "", host = "", port = "22"
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "user": user = parts[1]
            case "hostname": host = parts[1]
            case "port": port = parts[1]
            default: break
            }
        }
        guard !host.isEmpty else { return nil }
        return (user.isEmpty ? "" : user + "@") + host + ":" + port
    }

    /// An ssh that logs in, rather than running a command, forwarding only
    /// (-N, -W) or asking for no terminal (-T): its first word that isn't an
    /// option or an option's value is the host, and nothing comes after.
    static func interactive(_ ssh: [String]) -> Bool {
        let takesValue = Set("BbcDEeFIiJLlmOopQRSWw")
        var i = 0, host: Int?
        while i < ssh.count {
            let word = ssh[i]
            i += 1
            guard host == nil else { return false }
            guard word.hasPrefix("-"), word.count >= 2 else { host = i - 1; continue }
            if word == "--" { continue }
            // Flags run together (`-vt`) up to one that takes a value, which
            // is the rest of the word or the next one (`-p22`, `-p 22`).
            for (n, c) in word.dropFirst().enumerated() {
                if "NTWf".contains(c) { return false }
                if takesValue.contains(c) {
                    if n == word.count - 2 { i += 1 }
                    break
                }
            }
        }
        return host != nil
    }

    /// The install, on the host: nothing if it knows xterm-ghostty already.
    private static let installScript = """
    infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
    command -v tic >/dev/null 2>&1 || exit 1
    mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
    exit 1
    """

    private static func install(_ ssh: [String], quiet: Bool) -> Bool {
        guard let source = source() else { return false }
        // The arguments as given, then our command (the host comes before it).
        let out = runSSH(ssh + ["sh -c " + RemoteHost.quote(installScript)], input: Data(source.utf8), timeout: 60,
                         passErrors: !quiet)
        return out?.status == 0
    }

    private static func runSSH(_ arguments: [String], input: Data?, timeout: TimeInterval,
                               passErrors: Bool = false) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIBERTTY_SSH"] ?? "/usr/bin/ssh")
        p.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = passErrors ? FileHandle.standardError : FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: What's remembered

    static var listURL: URL { Blocks.dataDirectory.appendingPathComponent("terminfo-hosts") }

    static func known() -> [String] {
        guard let text = try? String(contentsOf: listURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func remember(_ key: String) {
        save(Array(Set(known() + [key])).sorted())
    }

    private static func save(_ hosts: [String]) {
        try? FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(hosts.map { $0 + "\n" }.joined().utf8).write(to: listURL, options: .atomic)
    }

    static func source() -> String? {
        AppResources.url("terminfo-src/ghostty.terminfo").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("libertty: \(message)\n".utf8))
        return 1
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
        usage: libertty +terminfo setup [SSH ARGS…] | status | show | forget HOST | --all

        """.utf8))
        return 2
    }
}
