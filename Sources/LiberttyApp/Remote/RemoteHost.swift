import CPty
import CryptoKit
import Foundation
import LiberttyCore

/// A machine Libertty reaches over ssh (File ▸ Connect to Host…, `libertty
/// +connect`), where a liberttyd of its own keeps the sessions: closing the
/// laptop, losing Wi-Fi or quitting Libertty leaves programs running there, and
/// the windows reattach when the link is back (like mosh or tmux, in
/// Libertty's own windows, tabs and splits).
///
/// Everything goes through the user's own ssh: their ~/.ssh/config, keys,
/// agent and jump hosts. One ControlMaster connection carries it all, so a
/// password is asked once; each connection to liberttyd is an ssh channel
/// running `liberttyd --bridge` there. The first time, and after an update,
/// Libertty installs what it needs under ~/.libertty on the host: liberttyd, the
/// shell integration and Ghostty's terminfo (compiled with the host's tic).
final class RemoteHost: @unchecked Sendable {
    let destination: String

    /// What the host told us when Libertty set it up.
    struct Info: Sendable {
        var os: String
        var arch: String
        var home: String
        var shell: String
        var liberttyHome: String
        var lang: String
        /// xterm-ghostty's terminfo is installed there.
        var terminfo: Bool
        var terminfoDir: String
        var liberttyd: String { liberttyHome + "/bin/liberttyd" }
    }

    enum Failure: LocalizedError {
        case ssh(String), unsupported(String), install(String)
        var errorDescription: String? {
            switch self {
            case .ssh(let why): why
            case .unsupported(let what): "Libertty can't run its helper on \(what) yet."
            case .install(let why): "Couldn't set up Libertty on the host: \(why)"
            }
        }
    }

    // MARK: Hosts by name

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: RemoteHost] = [:]

    static func named(_ destination: String) -> RemoteHost {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let host = registry[destination] { return host }
        let host = RemoteHost(destination: destination)
        registry[destination] = host
        return host
    }

    private init(destination: String) {
        self.destination = destination
    }

    /// How sessions reach this host's liberttyd.
    private(set) lazy var address = DaemonAddress(host: destination) { [unowned self] in self.dial() }
    /// The same for a connection that must never log in (a background save
    /// of the layout): over the shared ssh connection while it's up, else none.
    var quietAddress: DaemonAddress { DaemonAddress(host: destination) { [unowned self] in self.dial(login: false) } }

    private let stateLock = NSLock()
    private var prepared: Info?
    /// What `prepared` says may be out of date (the user tried again, or a
    /// connection found no liberttyd where it said): the next connection
    /// sets the host up again first. Until then `info` still answers.
    private var setUpAgain = false
    /// Each setup counted: a connection knows the one it was made with.
    private var setUps = 0
    /// The next setup is made because a connection's liberttyd failed there
    /// or the user tried again (`checking`), and the last such setup, with
    /// when (`checked`): a connection made with it failing the same way
    /// soon after is said, not set up again for good.
    private var checking = false
    private var checked: (setUp: Int, at: Date)?
    private var lastFailure: (time: Date, error: Error)?
    /// The last try failed in a way only the user can fix (a refused
    /// password, a changed host key): no automatic retries until `retry()`.
    private var waitingForUser = false
    /// Waiting for the user to fix something and try again.
    var needsUser: Bool { stateLock.withLock { waitingForUser } }
    /// One setup at a time (and so one password prompt).
    private let prepareLock = NSLock()

    var info: Info? { stateLock.withLock { prepared } }
    var lastError: Error? { stateLock.withLock { lastFailure?.error } }
    /// All ssh said when it last failed (the error keeps its last lines):
    /// what SSHRecovery reads a changed host key's fingerprint from.
    var lastSSHErrors: String { stateLock.withLock { fullErrors } }
    private var fullErrors = ""
    /// Setting up or logging in right now.
    var isConnecting: Bool { stateLock.withLock { connecting } }
    private var connecting = false

    /// A host connected, failed or is trying again (on the main thread): the
    /// Remote Hosts list follows.
    static let statusChanged = Notification.Name("LiberttyRemoteHostStatusChanged")

    private func statusChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.statusChanged, object: self) }
    }

    /// What ssh said, kept whole, as the failure it makes.
    private func sshFailure(_ errors: String, status: Int32) -> Failure {
        stateLock.withLock { fullErrors = errors }
        return Failure.ssh(Self.sshError(errors, status: status))
    }

    // MARK: ssh

    private var ssh: String { ProcessInfo.processInfo.environment["LIBERTTY_SSH"] ?? "/usr/bin/ssh" }

    /// Short and per host: Unix socket paths are limited to 104 bytes.
    private var controlPath: String {
        let digest = SHA256.hash(data: Data(destination.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        Wire.prepareDirectory(for: Wire.socketPath)
        return ((Wire.socketPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ssh-" + digest)
    }

    private var options: [String] {
        var o = ["-T", "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=60",
                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=20"]
        o += hostOptions
        // Tests point ssh at their own configuration.
        if let config = ProcessInfo.processInfo.environment["LIBERTTY_SSH_CONFIG"], !config.isEmpty { o = ["-F", config] + o }
        return o
    }

    /// What this host alone adds (`ssh-agent`): worked out once, since it asks
    /// ssh what the host resolves to. Empty until `resolveHostOptions` has run,
    /// so reading `options` never waits on a subprocess — and `-o IdentityAgent`
    /// only ever matters to a login, which `resolveHostOptions` comes before.
    private var hostOptions: [String] { stateLock.withLock { resolvedOptions?.options ?? [] } }
    private var resolvedOptions: (setting: String, options: [String])?

    /// Work the host's own ssh options out, if the setting changed since last
    /// time. Blocking (it runs `ssh -G`): under `prepareLock`, never on the
    /// main thread.
    private func resolveHostOptions() {
        // (Not the config itself: this runs off the main thread.)
        let chosen = SSHAgent.setting
        let setting = chosen.agent + "\u{0}" + chosen.socket
        if stateLock.withLock({ resolvedOptions?.setting }) == setting { return }
        let options = SSHAgent.options(for: destination, setting: SSHAgent.chosen(setting: chosen.agent, socket: chosen.socket))
        stateLock.withLock { resolvedOptions = (setting, options) }
    }

    /// Passwords and new host keys are asked in a Libertty dialog
    /// (`libertty +askpass`): there is no terminal to ask in.
    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let exe = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = exe
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["LIBERTTY_ASKPASS"] = "1"
            if env["DISPLAY"] == nil { env["DISPLAY"] = ":0" }  // older ssh asks only with one set
        }
        return env
    }

    /// Run `command` there (blocking), with `input` on its stdin. Output
    /// goes through files, not pipes: the ssh that becomes the shared
    /// master stays in the background and may keep its descriptors.
    func run(_ command: String, input: Data? = nil, arguments: [String]? = nil) -> (status: Int32, output: String, errors: String) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("libertty-ssh-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
            return (-1, "", "can't make a temporary file")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ssh)
        p.arguments = arguments ?? (options + [destination, command])
        p.environment = environment
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        try? out.close()
        try? err.close()
        // An ssh that ends mid-upload (the link dropped, the host's disk is
        // full) mustn't take Libertty down with SIGPIPE: the write fails instead.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        let output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let errors = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (p.terminationStatus, output, errors)
    }

    /// Whether the shared ssh connection is up (`ssh -O check`, local and quick).
    private var masterIsUp: Bool { masterProcess != nil }

    /// The shared ssh connection's process, from `ssh -O check` ("Master
    /// running (pid=4242)"): nil when it's down, 0 when it's up and didn't
    /// say. A forward belongs to the master that took it: one with another
    /// pid is a new connection, which holds none of the old one's.
    private var masterProcess: Int32? {
        let check = run("", arguments: options + ["-O", "check", destination])
        guard check.status == 0 else { return nil }
        let said = check.errors + check.output
        guard let at = said.range(of: "pid=") else { return 0 }
        return Int32(said[at.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    /// Whether a connection there would work without logging in again:
    /// set up, and its shared ssh connection up. Never prompts.
    var isConnected: Bool { info != nil && masterIsUp }

    /// The shared connection's process while the host is connected (see
    /// `masterProcess`); nil when it isn't. Blocking, never prompts.
    var master: Int32? { info == nil ? nil : masterProcess }

    /// Ask the shared ssh connection to carry a port, or to stop carrying
    /// it (`ssh -O forward` / `-O cancel`, for `PortForwarder`). It talks to
    /// the master that is already up, so there is no login and no process
    /// of our own to keep alive. Blocking, like everything else here.
    func control(_ forward: PortForward, cancel: Bool) -> (ok: Bool, why: String) {
        let result = run("", arguments: PortForward.controlArguments(for: forward, cancel: cancel, options: options))
        // A listen the host refuses (`-R` onto a port something there
        // already holds) is a warning on stderr, and ssh still exits 0.
        let said = result.errors.lowercased()
        let refused = said.contains("forwarding failed") || said.contains("cannot listen to port")
        guard result.status == 0, !refused else {
            return (false, Self.sshError(result.errors.isEmpty ? result.output : result.errors, status: result.status))
        }
        return (true, "")
    }

    /// Bring the shared connection up if it's down: one login (one password
    /// prompt) for every pane that wants to reconnect.
    private func ensureMaster() -> Bool {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        resolveHostOptions()
        if masterIsUp { return true }
        if stateLock.withLock({ waitingForUser }) { return false }
        let login = run("true")
        if login.status == 0 {
            // Up again after it dropped: a new connection, with none of the
            // old one's forwards (PortForwarder asks for them again).
            statusChanged()
            return true
        }
        fail(sshFailure(login.errors, status: login.status))
        return false
    }

    /// A new connection to the host's liberttyd, over an ssh channel.
    /// `login`: set the host up and log in if needed; without it, only
    /// over a link already up.
    private func dial(login: Bool = true) -> Connection? {
        let ready = login ? ensurePrepared().flatMap { ensureMaster() ? $0 : nil } : info.flatMap { masterIsUp ? $0 : nil }
        guard let info = ready else { return nil }
        let made = stateLock.withLock { setUps }
        var fds: [Int32] = [-1, -1]
        guard libertty_socketpair(&fds) == 0 else { return nil }
        // (Batch mode: should the shared link go down meanwhile, ssh fails
        // rather than ask for a password.)
        let argv = ["ssh"] + options + (login ? [] : ["-o", "BatchMode=yes"]) + [destination, Self.quote(info.liberttyd) + " --bridge"]
        var cargv = argv.map { strdup($0) } + [nil]
        var cenv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cargv.forEach { free($0) }
            cenv.forEach { free($0) }
        }
        let pid = libertty_spawn_io(ssh, &cargv, &cenv, fds[1], fds[1], -1)
        close(fds[1])
        guard pid > 0 else {
            close(fds[0])
            return nil
        }
        // ssh ends when we hang up (its stdin closes); reap it then.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            source.cancel()
            self?.forget(source)
            // ssh ends with the status of the command there, or 255 for its
            // own failure (the link down). 127 and 126 are the host's shell
            // finding no liberttyd to run there, or one it can't run; any
            // other is liberttyd's own, which tries again (1: it couldn't
            // start one, a moment while another takes over or recovers).
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 0
            if code == 126 || code == 127 { self?.helperFailed(status: code, setUp: made) }
        }
        stateLock.withLock { reapers.append(source) }
        source.resume()
        return Connection(fd: fds[0])
    }

    private var reapers: [DispatchSourceProcess] = []
    private func forget(_ source: DispatchSourceProcess) { stateLock.withLock { reapers.removeAll { $0 === source } } }

    // MARK: Holding the shared connection up

    /// A session over the shared connection that does nothing (`cat`, reading
    /// our end of a socket until we close it), held while the host has port
    /// forwards: ssh's master counts sessions, not forwards, as what it's
    /// there for, and with no window's session on it, it would exit
    /// ControlPersist seconds after the last forward was made, every
    /// forward with it. `master`: the master it holds (`masterProcess`).
    private var keeper: (pid: pid_t, input: Int32, master: Int32)?
    /// The session holding the connection up, if any (for the probes).
    var keeperProcess: pid_t? { stateLock.withLock { keeper?.pid } }

    /// Hold the shared connection up — the master whose process is `master`
    /// (`RemoteHost.master`) — or, nil, let it go. One already held is left
    /// as it is; a new master (the link came back) is held instead. Never
    /// logs in: it's asked of a master that's up. Blocking, briefly.
    func keepConnection(on master: Int32?) {
        let (held, stale): (Bool, Int32?) = stateLock.withLock {
            if let master, let keeper, keeper.master == master { return (true, nil) }
            defer { keeper = nil }
            return (false, keeper?.input)
        }
        guard !held else { return }
        // Its end of the socket closed: `cat` there reads the end, and the
        // session ends (its reaper finds it isn't the keeper any more).
        if let stale { close(stale) }
        guard let master else { return }
        var fds: [Int32] = [-1, -1]
        guard libertty_socketpair(&fds) == 0 else { return }
        let argv = ["ssh"] + options + ["-o", "BatchMode=yes", destination, "cat > /dev/null"]
        var cargv = argv.map { strdup($0) } + [nil]
        var cenv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cargv.forEach { free($0) }
            cenv.forEach { free($0) }
        }
        let pid = libertty_spawn_io(ssh, &cargv, &cenv, fds[1], -1, -1)
        close(fds[1])
        guard pid > 0 else {
            close(fds[0])
            return
        }
        stateLock.withLock { keeper = (pid, fds[0], master) }
        // Ended by us, or with its master (the link dropped): held again
        // once the link is back and its forwards are (PortForwarder).
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            source.cancel()
            guard let self else { return }
            self.forget(source)
            let input: Int32? = self.stateLock.withLock {
                guard let keeper = self.keeper, keeper.pid == pid else { return nil }
                self.keeper = nil
                return keeper.input
            }
            if let input { close(input) }
        }
        stateLock.withLock { reapers.append(source) }
        source.resume()
    }

    /// For a single remote shell word (remote shells all take single quotes).
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Setting up

    private func ensurePrepared() -> Info? {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        if let info = stateLock.withLock({ setUpAgain ? nil : prepared }) { return info }
        let (last, waiting) = stateLock.withLock { (lastFailure, waitingForUser) }
        if waiting { return nil }
        // While the host is down, don't try every quarter second.
        if let last, Date().timeIntervalSince(last.time) < 3 { return nil }
        return try? prepareHeld()
    }

    /// The user asked to try again (after fixing what was wrong).
    func retry() {
        stateLock.withLock {
            waitingForUser = false
            lastFailure = nil
            // Whatever they fixed may be the agent (opening 1Password, say):
            // its socket is looked for again.
            resolvedOptions = nil
            // Or the host itself (rebuilt under the same name: a new host
            // key, and nothing of what Libertty installed there): it's set
            // up again from the start.
            setUpAgain = true
            checking = true
        }
        statusChanged()
    }

    /// A connection found no liberttyd it could run there (`status` 127 or
    /// 126: ~/.libertty deleted, say): the next connection sets the host up
    /// again first, which installs what's missing. Failing so again within
    /// a minute of that, it's said, and the windows wait for Retry instead
    /// of redialing a liberttyd that isn't there for good.
    private func helperFailed(status: Int32, setUp: Int) {
        let stuck: Bool = stateLock.withLock {
            // Made with a setup since replaced, or being made again: nothing new.
            guard setUp == setUps, !setUpAgain else { return false }
            setUpAgain = true
            if let checked, checked.setUp == setUp, Date().timeIntervalSince(checked.at) < 60 { return true }
            checking = true
            return false
        }
        if stuck { fail(Failure.install("liberttyd there ended before it answered (status \(status))")) }
    }

    private func fail(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let needsUser = ["Permission denied", "Host key verification failed", "Too many authentication failures",
                         "IDENTIFICATION HAS CHANGED", "can't run its helper", "Couldn't set up"].contains { text.contains($0) }
        stateLock.withLock {
            lastFailure = (Date(), error)
            waitingForUser = needsUser
        }
        statusChanged()
    }

    /// Reach the host, install or update Libertty's helper there if needed, and
    /// make sure its liberttyd runs (blocking; not on the main thread).
    /// After a setup already under way (a window reconnecting meanwhile),
    /// never beside it: one password prompt at a time, one install.
    @discardableResult
    func prepare(progress: (String) -> Void = { _ in }) throws -> Info {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        return try prepareHeld(progress: progress)
    }

    /// `prepare`, under `prepareLock`.
    private func prepareHeld(progress: (String) -> Void = { _ in }) throws -> Info {
        resolveHostOptions()
        stateLock.withLock { connecting = true }
        statusChanged()
        defer {
            stateLock.withLock { connecting = false }
            statusChanged()
        }
        do {
            let info = try setUp(progress: progress)
            stateLock.withLock {
                prepared = info
                setUpAgain = false
                setUps += 1
                checked = checking ? (setUps, Date()) : nil
                checking = false
                lastFailure = nil
                fullErrors = ""
            }
            return info
        } catch {
            fail(error)
            throw error
        }
    }

    private func setUp(progress: (String) -> Void) throws -> Info {
        progress("Connecting to \(destination)…")
        let probe = run("sh -s", input: Data(Self.probeScript.utf8))
        guard probe.status == 0 else { throw sshFailure(probe.errors, status: probe.status) }
        var fields: [String: String] = [:]
        for line in probe.output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let os = fields["os"], let arch = fields["arch"], let home = fields["home"], let liberttyHome = fields["libertty_home"] else {
            throw Failure.ssh("The host's shell didn't answer as expected:\n" + probe.output.prefix(300))
        }
        var info = Info(os: os, arch: arch, home: home, shell: fields["shell"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh",
                        liberttyHome: liberttyHome, lang: fields["lang"] ?? "", terminfo: fields["terminfo"] == "yes",
                        terminfoDir: fields["terminfo_dir"] ?? home + "/.terminfo")

        let payload = try Self.payload(os: os, arch: arch)
        if fields["stamp"] != payload.stamp {
            progress("Installing Libertty's helper on \(destination)…")
            let install = run("sh -c " + Self.quote(Self.installScript), input: payload.tar)
            guard install.status == 0, install.output.contains("installed") else {
                throw Failure.install(Self.sshError(install.errors.isEmpty ? install.output : install.errors, status: install.status))
            }
            info.terminfo = install.output.contains("terminfo=yes")
        }

        progress("Starting liberttyd on \(destination)…")
        let ensure = run(Self.quote(info.liberttyd) + " --ensure")
        guard ensure.status == 0, ensure.output.contains("socket=") else {
            throw Failure.install(Self.sshError(ensure.errors.isEmpty ? ensure.output : ensure.errors, status: ensure.status))
        }
        return info
    }

    /// ssh's own message, without its chatter.
    private static func sshError(_ text: String, status: Int32) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        if lines.isEmpty { return status == 255 ? "ssh couldn't connect." : "It ended with status \(status)." }
        return lines.suffix(3).joined(separator: "\n")
    }

    /// Facts about the host, as key=value lines (any POSIX sh).
    private static let probeScript = """
    LH="${LIBERTTY_HOME:-$HOME/.libertty}"
    TI="${LIBERTTY_TERMINFO_DIR:-$HOME/.terminfo}"
    echo "os=$(uname -s)"
    echo "arch=$(uname -m)"
    echo "home=$HOME"
    echo "shell=${SHELL:-}"
    echo "libertty_home=$LH"
    echo "lang=${LANG:-}"
    echo "stamp=$(cat "$LH/VERSION" 2>/dev/null)"
    echo "terminfo_dir=$TI"
    if TERMINFO="$TI" infocmp xterm-ghostty >/dev/null 2>&1 || infocmp xterm-ghostty >/dev/null 2>&1; then echo terminfo=yes; else echo terminfo=no; fi

    """

    /// Unpack the payload (stdin) into ~/.libertty beside what's running: a
    /// running liberttyd keeps its old file until it hands over.
    private static let installScript = """
    LH="${LIBERTTY_HOME:-$HOME/.libertty}"; TI="${LIBERTTY_TERMINFO_DIR:-$HOME/.terminfo}"; \
    S="$LH/.stage.$$"; rm -rf "$S"; mkdir -p "$S" || exit 1; cd "$S" || exit 1; \
    tar xzf - || exit 1; \
    for d in bin shell-integration terminfo; do rm -rf "$LH/$d.old"; if [ -e "$LH/$d" ]; then mv "$LH/$d" "$LH/$d.old"; fi; mv "$d" "$LH/$d" || exit 1; rm -rf "$LH/$d.old"; done; \
    mv VERSION "$LH/VERSION"; cd "$LH"; rm -rf "$S"; \
    if command -v tic >/dev/null 2>&1 && mkdir -p "$TI" && tic -x -o "$TI" "$LH/terminfo/ghostty.terminfo" >/dev/null 2>&1; then echo terminfo=yes; else echo terminfo=no; fi; \
    echo installed
    """

    // MARK: What gets installed

    nonisolated(unsafe) private static var payloads: [String: (tar: Data, stamp: String)] = [:]
    private static let payloadLock = NSLock()

    /// liberttyd for the host's system, Libertty's shell integration and the
    /// terminfo source, as a tar.gz; `stamp` names its exact contents.
    private static func payload(os: String, arch: String) throws -> (tar: Data, stamp: String) {
        let key = os + "-" + arch
        payloadLock.lock()
        defer { payloadLock.unlock() }
        if let cached = payloads[key] { return cached }
        guard let binary = liberttydBinary(os: os, arch: arch) else { throw Failure.unsupported("\(os) \(arch)") }
        guard let integration = AppResources.url("shell-integration"),
              let terminfo = AppResources.url("terminfo-src/ghostty.terminfo") else {
            throw Failure.install("this copy of Libertty is missing its shell integration")
        }
        let fm = FileManager.default
        var hash = SHA256()
        func add(_ url: URL) { if let data = fm.contents(atPath: url.path) { hash.update(data: data) } }
        add(binary)
        add(terminfo)
        let files = (fm.enumerator(at: integration, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
        for file in files {
            hash.update(data: Data(file.path.dropFirst(integration.path.count).utf8))
            add(file)
        }
        let stamp = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        let stage = fm.temporaryDirectory.appendingPathComponent("libertty-payload-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        do {
            try fm.createDirectory(at: stage.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fm.createDirectory(at: stage.appendingPathComponent("terminfo"), withIntermediateDirectories: true)
            try fm.copyItem(at: binary, to: stage.appendingPathComponent("bin/liberttyd"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.appendingPathComponent("bin/liberttyd").path)
            try fm.copyItem(at: integration, to: stage.appendingPathComponent("shell-integration"))
            try fm.copyItem(at: terminfo, to: stage.appendingPathComponent("terminfo/ghostty.terminfo"))
            try Data((stamp + "\n").utf8).write(to: stage.appendingPathComponent("VERSION"))
        } catch {
            throw Failure.install(error.localizedDescription)
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", "-", "--format", "ustar", "-C", stage.path, "VERSION", "bin", "shell-integration", "terminfo"]
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"  // no ._ AppleDouble files
        tar.environment = env
        let out = Pipe()
        tar.standardOutput = out
        tar.standardError = FileHandle.nullDevice
        do { try tar.run() } catch { throw Failure.install(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, !data.isEmpty else { throw Failure.install("couldn't pack the helper") }
        payloads[key] = (data, stamp)
        return (data, stamp)
    }

    /// The liberttyd that runs there: this Mac's own for an Apple silicon Mac,
    /// a static Linux build from the bundle for Linux.
    private static func liberttydBinary(os: String, arch: String) -> URL? {
        let normalized = ["amd64": "x86_64", "arm64": "aarch64"][arch.lowercased()] ?? arch.lowercased()
        switch os {
        case "Darwin":
            if normalized == "aarch64", let own = Persistence.daemonExecutable { return URL(fileURLWithPath: own) }
            return AppResources.url("remote/liberttyd-darwin-\(normalized)")
        case "Linux":
            return AppResources.url("remote/liberttyd-linux-\(normalized)")
        default:
            return nil
        }
    }

    // MARK: Sessions there

    /// What a new session on the host runs: the user's login shell there
    /// with Libertty's integration (from ~/.libertty), or `command` through sh.
    func createRequest(id: String, command: String?, workingDirectory: String?, size: GridSize, config: Config) -> CreateRequest? {
        guard let info else { return nil }
        var env: [String: String] = [
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Libertty",
            "TERM_PROGRAM_VERSION": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "LIBERTTY_SESSION": id,
        ]
        if config.term == "xterm-ghostty" {
            env["TERM"] = info.terminfo ? "xterm-ghostty" : "xterm-256color"
            if info.terminfo, info.terminfoDir != info.home + "/.terminfo" { env["TERMINFO"] = info.terminfoDir }
        } else {
            env["TERM"] = config.term
        }
        if info.lang.isEmpty { env["LANG"] = info.os == "Darwin" ? "en_US.UTF-8" : "C.UTF-8" }

        let executable: String
        var arguments: [String]
        if let command {
            executable = "/bin/sh"
            arguments = ["sh", "-c", command]
        } else {
            executable = info.shell
            let name = (info.shell as NSString).lastPathComponent
            arguments = ["-" + name]
            let integration = info.liberttyHome + "/shell-integration"
            switch name {
            case "zsh":
                env["ZDOTDIR"] = integration + "/zsh"
            case "bash":
                arguments = ["bash", "--rcfile", integration + "/bash/libertty.bash", "-i"]
                env["LIBERTTY_BASH_LOGIN"] = "1"
            case "fish":
                env["XDG_DATA_DIRS"] = integration + "/fish:/usr/local/share:/usr/share"
            default:
                break
            }
        }
        return CreateRequest(id: id, executable: executable, arguments: arguments, environment: env,
                             workingDirectory: workingDirectory ?? info.home, size: size,
                             scrollback: config.scrollbackLimit, inheritEnvironment: true)
    }
}
