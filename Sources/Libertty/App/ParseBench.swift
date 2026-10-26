import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

/// `Libertty --parse-bench FILE [--cols N] [--rows N] [--seconds S]`
///
/// Feeds FILE into a libghostty-vt terminal in a loop, with no pty, lock or
/// renderer, and prints parse throughput. Comparing it with vtebench numbers
/// separates the parser's cost from everything Libertty adds around it.
enum ParseBench {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // A probe missing its arguments must stop here: run on, it would be
        // an ordinary launch, a real window that takes the focus.
        let arguments = ["--session-bench": 1, "--link-probe": 1, "--command-probe": 1, "--responsible-probe": 1,
                         "--ui-probe": 2, "--document-probe": 2, "--remote-probe": 1, "--output-probe": 1,
                         "--shell-probe": 2, "--parse-bench": 1, "--screen-probe": 1, "--screen-cover-probe": 1]
        // Not what follows -e: that's a command to run, its words its own.
        let own = args.firstIndex(of: "-e").map { Array(args[..<$0]) } ?? args
        for (flag, count) in arguments {
            guard let i = own.firstIndex(of: flag), i + count >= own.count else { continue }
            FileHandle.standardError.write(Data("\(flag) needs \(count == 1 ? "an argument" : "\(count) arguments")\n".utf8))
            exit(2)
        }
        // A probe or bench run by hand never reaches your liberttyd: without
        // a socket of its own (tests/run.sh gives one) it gets a private one,
        // so it can't take over, stop or fill the daemon your sessions live in.
        if args.dropFirst().contains(where: { $0.hasPrefix("--") && ($0.hasSuffix("-probe") || $0.hasSuffix("-bench")) }),
           (ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_SOCKET"] ?? "").isEmpty {
            let dir = NSTemporaryDirectory() + "libertty-probe-\(getpid())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            setenv("LIBERTTY_DAEMON_SOCKET", dir + "/liberttyd.sock", 1)
            setenv("LIBERTTY_DAEMON_LOG", dir + "/liberttyd.log", 1)
            setenv("LIBERTTY_STATE_FILE", dir + "/windows.json", 0)
            FileHandle.standardError.write(Data("(no LIBERTTY_DAEMON_SOCKET: a private liberttyd in \(dir))\n".utf8))
        }
        // A probe's blocks keep what they make (drawings, profiles) in a
        // folder of the run's, never Application Support.
        if args.dropFirst().contains(where: { $0.hasPrefix("--") && ($0.hasSuffix("-probe") || $0.hasSuffix("-bench")) }),
           (ProcessInfo.processInfo.environment["LIBERTTY_DATA_DIR"] ?? "").isEmpty {
            let socket = ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_SOCKET"] ?? ""
            let dir = socket.isEmpty ? NSTemporaryDirectory() + "libertty-probe-\(getpid())" : (socket as NSString).deletingLastPathComponent
            setenv("LIBERTTY_DATA_DIR", dir, 1)
        }
        if args.contains("--resize-bench") { resizeBench() }
        if let i = args.firstIndex(of: "--session-bench"), i + 1 < args.count { sessionBench(file: args[i + 1]) }
        if let i = args.firstIndex(of: "--link-probe"), i + 1 < args.count { linkProbe(command: args[i + 1]) }
        if let i = args.firstIndex(of: "--command-probe"), i + 1 < args.count { commandProbe(shell: args[i + 1]) }
        if args.contains("--selection-probe") { selectionProbe() }
        if args.contains("--paste-probe") { pasteProbe() }
        if args.contains("--clear-probe") { clearProbe() }
        if args.contains("--scrollbar-probe") { scrollbarProbe() }
        if args.contains("--column-fit-probe") { columnFitProbe() }
        if args.contains("--git-probe") { gitProbe() }
        if let i = args.firstIndex(of: "--responsible-probe"), i + 1 < args.count {
            responsibleProbe(pid_t(args[i + 1]) ?? -1)
        }
        if args.contains("--ligature-config-probe") { ligatureConfigProbe() }
        if args.contains("--web-probe") { MainActor.assumeIsolated { webProbe() } }
        if args.contains("--kitty-reattach-probe") { kittyReattachProbe() }
        if args.contains("--kitty-key-probe") { kittyKeyProbe() }
        if let i = args.firstIndex(of: "--ui-probe"), i + 2 < args.count {
            MainActor.assumeIsolated { UIProbe.run(script: args[i + 1], output: args[i + 2]) }
        }
        if let i = args.firstIndex(of: "--screen-cover-probe"), i + 1 < args.count {
            MainActor.assumeIsolated { ScreenProbe.cover(seconds: Double(args[i + 1]) ?? 1.5) }
        }
        if let i = args.firstIndex(of: "--screen-probe"), i + 1 < args.count {
            MainActor.assumeIsolated { ScreenProbe.run(output: args[i + 1]) }
        }
        if args.contains("--resize-resync-probe") { resizeResyncProbe() }
        if args.contains("--slow-client-probe") { SlowClientProbe.run() }
        if args.contains("--layout-store-probe") { LayoutStoreProbe.run() }
        if let i = args.firstIndex(of: "--document-probe"), i + 2 < args.count {
            MainActor.assumeIsolated { documentProbe(args[i + 1], to: args[i + 2]) }
        }
        if args.contains("--web-serve-probe") { MainActor.assumeIsolated { webServeProbe() } }
        if let i = args.firstIndex(of: "--update-notes-probe"), i + 2 < args.count {
            MainActor.assumeIsolated { updateNotesProbe(feed: args[i + 1], to: args[i + 2]) }
        }
        if let i = args.firstIndex(of: "--remote-probe"), i + 1 < args.count { remoteProbe(host: args[i + 1]) }
        if let i = args.firstIndex(of: "--output-probe"), i + 1 < args.count { outputProbe(shell: args[i + 1]) }
        if let i = args.firstIndex(of: "--shell-probe"), i + 2 < args.count { shellProbe(shell: args[i + 1], input: args[i + 2]) }
        guard let flag = args.firstIndex(of: "--parse-bench"), flag + 1 < args.count else { return }
        func value(_ name: String, _ fallback: Double) -> Double {
            guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return fallback }
            return v
        }
        let cols = UInt16(value("--cols", 120)), rows = UInt16(value("--rows", 40))
        let seconds = value("--seconds", 3)
        guard let data = FileManager.default.contents(atPath: args[flag + 1]), !data.isEmpty else {
            FileHandle.standardError.write("parse-bench: cannot read \(args[flag + 1])\n".data(using: .utf8)!)
            exit(1)
        }

        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS, let terminal else { exit(1) }
        var lines = 10_000
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // `--scrollback-bytes N`: also cap history in bytes (libghostty's own default is 10000).
        if let i = args.firstIndex(of: "--scrollback-bytes"), i + 1 < args.count, var bytes = Int(args[i + 1]) {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        }

        // Same chunking as the pty reader: 64 KiB writes.
        let chunk = 1 << 16
        var bytes = 0
        let start = Date()
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while Date().timeIntervalSince(start) < seconds {
                var offset = 0
                while offset < raw.count {
                    let n = min(chunk, raw.count - offset)
                    ghostty_terminal_vt_write(terminal, base + offset, n)
                    offset += n
                }
                bytes += raw.count
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "%.0f MB/s  (%d MB in %.2fs, %dx%d)", Double(bytes) / 1e6 / elapsed,
                     bytes / 1_000_000, elapsed, cols, rows))
        ghostty_terminal_free(terminal)
        exit(0)
    }

    /// `Libertty --session-bench FILE [--mb N] [--persist]`: a program writes FILE
    /// over and over (N MB in all) and a windowless session parses it, as a
    /// window would but without drawing. With --persist the bytes go through
    /// liberttyd (pty → liberttyd → socket → this replica), else straight from the pty.
    private static func sessionBench(file: String) -> Never {
        let args = CommandLine.arguments
        let mb = args.firstIndex(of: "--mb").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 200
        Persistence.setUp(wanted: args.contains("--persist"))
        final class Waiter: TerminalSessionDelegate {
            var exited = false
            func sessionNeedsRender(_ session: TerminalSession) {}
            func sessionTitleChanged(_ session: TerminalSession, title: String) {}
            func sessionBell(_ session: TerminalSession) {}
            func sessionProgramStatusChanged(_ session: TerminalSession) {}
            func sessionExited(_ session: TerminalSession, status: Int32) { exited = true }
        }
        do {
            let session = try TerminalSession(size: GridSize(cols: 120, rows: 40, widthPx: 1920, heightPx: 1240))
            let waiter = Waiter()
            session.delegate = waiter
            // One ~20 MB file, so the writer isn't a thousand `cat` launches.
            guard let one = FileManager.default.contents(atPath: file), !one.isEmpty else { throw TerminalError.libghostty("can't read \(file)") }
            var chunk = Data()
            while chunk.count < 20_000_000 { chunk.append(one) }
            let big = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-bench-\(getpid()).bin")
            try chunk.write(to: big)
            defer { try? FileManager.default.removeItem(at: big) }
            let size = chunk.count
            let repeats = mb * 1_000_000 / size + 1
            let command = "for i in $(seq \(repeats)); do cat \(ShellQuote.quote(big.path)); done"
            let start = Date()
            try session.start(command: command)
            while !waiter.exited { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            let elapsed = Date().timeIntervalSince(start)
            let bytes = repeats * size
            print(String(format: "%@: %.0f MB/s (%d MB in %.2fs)", Persistence.enabled ? "via liberttyd" : "local pty",
                         Double(bytes) / 1e6 / elapsed, bytes / 1_000_000, elapsed))
            try? FileManager.default.removeItem(at: big)
            exit(0)
        } catch {
            print("session-bench: \(error)")
            exit(1)
        }
    }

    /// `Libertty --link-probe COMMAND`: run COMMAND in a 40-column session and
    /// print every distinct link found at any cell (link detection test).
    private static func linkProbe(command: String) -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 0, heightPx: 0))
            try session.start(workingDirectory: FileManager.default.currentDirectoryPath, command: command + "; sleep 1")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            var seen: [String] = []
            for row in 0..<10 {
                for col in 0..<40 {
                    guard let link = session.link(atCol: col, row: row) else { continue }
                    let key = "\(link.explicit ? "osc8" : "text") \(link.url)\(link.line.map { " line \($0)" } ?? "")\(link.column.map { " col \($0)" } ?? "") " + link.spans.map { "\($0.row):\($0.columns.lowerBound)-\($0.columns.upperBound)" }.joined(separator: ",")
                    if !seen.contains(key) { seen.append(key) }
                }
            }
            seen.forEach { print($0) }
            exit(0)
        } catch {
            print("link-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --command-probe zsh|bash`: run two commands in that shell with
    /// Libertty's integration and print the command-finished events it reports.
    private static func commandProbe(shell: String) -> Never {
        final class Events: TerminalSessionDelegate {
            func sessionNeedsRender(_ session: TerminalSession) {}
            func sessionTitleChanged(_ session: TerminalSession, title: String) {}
            func sessionBell(_ session: TerminalSession) {}
            func sessionProgramStatusChanged(_ session: TerminalSession) {}
            func sessionExited(_ session: TerminalSession, status: Int32) {}
            func sessionCommandFinished(_ session: TerminalSession, command: String, exitCode: Int32?, duration: TimeInterval) {
                print(String(format: "finished: %@ exit=%@ after %.1fs", command, exitCode.map { String($0) } ?? "?", duration))
            }
            func sessionDesktopNotification(_ session: TerminalSession, title: String, body: String) {
                print("notification: \(title) / \(body)")
            }
            func sessionProgressChanged(_ session: TerminalSession) {
                print("progress: \(String(describing: session.progress))")
            }
        }
        do {
            setenv("SHELL", "/bin/\(shell)", 1)
            let session = try TerminalSession(size: GridSize(cols: 100, rows: 30, widthPx: 0, heightPx: 0))
            let events = Events()
            session.delegate = events
            try session.start(shellPath: "/bin/\(shell)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            session.sendText("sleep 0.3; echo 'a;b' >/dev/null\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            session.sendText("printf '\\e]9;4;1;42\\a\\e]777;notify;Build;done\\a'; false\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            if CommandLine.arguments.contains("--screen") {
                session.selectAll()
                print(session.selectedText() ?? "")
            }
            exit(0)
        } catch {
            print("command-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --selection-probe`: drag-select past the top edge (autoscroll),
    /// shift-click to extend, ⌥-drag a block; prints what got selected.
    private static func selectionProbe() -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 20, rows: 5, widthPx: 200, heightPx: 100))
            try session.start(command: "for i in $(seq 1 30); do echo line$i; done; sleep 2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func at(_ col: Int, _ row: Int, y: Double? = nil) -> TerminalSession.Pointer {
                .init(col: col, row: row, positionPx: CGPoint(x: Double(col * 10 + 5), y: y ?? Double(row * 20 + 10)),
                      cellWidthPx: 10, paddingLeftPx: 0, surfaceHeightPx: 100)
            }
            func show(_ label: String) {
                print(label + ": " + (session.selectedText() ?? "(none)").replacingOccurrences(of: "\n", with: " | "))
            }
            // Screen now: line27..line30 and an empty last row. Drag from line29 up past the top.
            session.selectionGesture(.press, at(6, 2))
            let direction = session.selectionGesture(.drag, at(0, -1, y: -15))
            print("autoscroll: \(direction)")
            for _ in 0..<3 { session.selectionAutoscroll(direction, rows: 1, at(0, -1, y: -15), rectangle: false) }
            session.selectionGesture(.release, at(0, 0))
            show("drag up + 3 ticks")
            session.scrollToBottom()
            session.selectionGesture(.press, at(0, 1))
            session.selectionGesture(.drag, at(5, 1))
            session.selectionGesture(.release, at(5, 1))
            _ = session.extendSelection(to: at(3, 3))
            show("shift-click extend")
            session.selectionGesture(.press, at(4, 0))
            session.selectionGesture(.drag, at(5, 2), rectangle: true)
            session.selectionGesture(.release, at(5, 2))
            show("rectangle cols 4-5")
            exit(0)
        } catch {
            print("selection-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --paste-probe [--persist]`: paste 2 MB into a program reading the
    /// pty raw; it must receive every byte (the pty fills up and the writer
    /// waits on EAGAIN, many times over).
    private static func pasteProbe() -> Never {
        Persistence.setUp(wanted: CommandLine.arguments.contains("--persist"))
        do {
            let session = try TerminalSession(size: GridSize(cols: 60, rows: 5, widthPx: 600, heightPx: 100))
            try session.start(command: "stty raw -echo; head -c 2000000 | wc -c; sleep 2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let started = Date()
            _ = session.paste(String(repeating: "a", count: 2_000_000), allowUnsafe: true)
            var text = ""
            while Date().timeIntervalSince(started) < 10 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                session.selectAll()
                text = session.selectedText() ?? ""
                if text.contains("2000000") { break }
            }
            let count = text.split(whereSeparator: \.isWhitespace).first { Int($0) != nil } ?? "nothing"
            print(String(format: "pasted 2000000 bytes, program read %@ (%.2fs, %@)", String(count),
                         Date().timeIntervalSince(started), Persistence.enabled ? "via liberttyd" : "local pty"))
            exit(0)
        } catch {
            print("paste-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --shell-probe zsh|bash|fish LINE`: type LINE into that shell
    /// (with Libertty's integration and environment) and print the screen.
    private static func shellProbe(shell: String, input: String) -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 100, rows: 20, widthPx: 0, heightPx: 0))
            try session.start(shellPath: shell.hasPrefix("/") ? shell : "/bin/\(shell)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            session.sendText(input + "\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            session.selectAll()
            print(session.selectedText() ?? "")
            exit(0)
        } catch {
            print("shell-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --remote-probe HOST` (with tests/fixtures/fake-ssh as LIBERTTY_SSH):
    /// set the host up, run a session there, drop the link and bring it
    /// back, then reattach as a relaunched Libertty would.
    private static func remoteProbe(host destination: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let host = RemoteHost.named(destination)
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return done()
        }
        var failed: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("\(name): \(ok)")
            if !ok { failed.append(name) }
        }
        do {
            let info = try host.prepare { print("progress: \($0)") }
            print("host: \(info.os) \(info.arch) terminfo=\(info.terminfo) shell=\((info.shell as NSString).lastPathComponent)")
            let size = GridSize(cols: 60, rows: 12, widthPx: 600, heightPx: 240)
            let session = try TerminalSession(size: size)
            session.start(on: host, workingDirectory: "/tmp", command: "echo remote-ok TERM=$TERM; pwd; sleep 60")
            check("link up", wait(15) { session.linkUp && session.scrollbackText().contains("remote-ok") })
            print("output: \(session.scrollbackText().split(separator: "\n").prefix(2).joined(separator: " | "))")
            let listed = DaemonClient.sessions(address: host.address)?.contains { $0.id == session.persistentID } ?? false
            check("listed on host", listed)

            // The windows this Mac shows the host's sessions in, kept there:
            // handed over as a save does (over the link that's up, in batch
            // mode, never logging in), read back as Connect to Host does.
            setenv("LIBERTTY_CLIENT_ID", "remote-probe", 1)
            let layout = SavedState(windows: [SavedWindow(frame: "", sidebar: true, inspector: false, fontSize: nil, selected: 0,
                                                          tabs: [SavedTab(panes: SavedPane(session: session.persistentID))],
                                                          host: destination)], savedAt: 1)
            let body = try JSONEncoder().encode(layout).withUnsafeBytes {
                Connection.headed(["client": Restoration.clientID, "local": false], body: $0)
            }
            var stored = false
            if case .answered(let reply) = DaemonClient.request(.storeLayout, payload: body, needing: "layout", timeout: 5,
                                                                address: host.quietAddress) {
                stored = reply.json["ok"] as? Bool == true
            }
            check("layout kept there", stored)
            var readBack = false
            if case .layout(let back, mine: true) = Restoration.held(at: host.address, local: false, timeout: 5) {
                readBack = back.windows.first?.tabs.first?.panes?.session == session.persistentID
            }
            check("layout read back", readBack)

            // The network goes away (bridges die, new ones fail), then comes back.
            let down = ProcessInfo.processInfo.environment["FAKE_SSH_DOWN"] ?? "/tmp/libertty-test/fake-ssh-down"
            FileManager.default.createFile(atPath: down, contents: nil)
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", info.liberttyd + " --bridge"]
            try kill.run()
            kill.waitUntilExit()
            check("link down", wait(5) { !session.linkUp })
            try? FileManager.default.removeItem(atPath: down)
            check("link back", wait(15) { session.linkUp })
            check("kept", session.scrollbackText().contains("remote-ok"))

            // Libertty quits (the session lives on there) and comes back.
            let id = session.persistentID ?? ""
            session.detachForProbe()
            let again = try TerminalSession.reattach(id, host: host, size: size, workingDirectory: nil)
            check("reattached", wait(15) { again.linkUp && again.scrollbackText().contains("remote-ok") })
            again.terminate()
            check("ended there", wait(5) { !(DaemonClient.sessions(address: host.address)?.contains { $0.id == id } ?? true) })

            // The login shell there, with Libertty's integration from ~/.libertty.
            let shell = try TerminalSession(size: size)
            shell.start(on: host, workingDirectory: nil, command: nil)
            _ = wait(15) { shell.linkUp }
            _ = wait(8) { shell.scrollbackText().contains("%") || shell.scrollbackText().contains("$") }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            shell.sendText("sleep 2\n")
            check("busy while running", wait(3) { shell.hasForegroundProgram })
            check("idle at the prompt", wait(5) { !shell.hasForegroundProgram })
            shell.sendText("echo session=$LIBERTTY_SESSION\n")
            check("shell", wait(5) { shell.scrollbackText().contains("session=" + (shell.persistentID ?? "?")) })
            // Where that shell is, as the host has it: the pane's name and its
            // new splits go by it.
            check("folder there", wait(5) { shell.workingDirectory != nil })
            shell.terminate()
            print(failed.isEmpty ? "remote-probe: all passed" : "remote-probe failed: \(failed)")
            exit(failed.isEmpty ? 0 : 1)
        } catch {
            print("remote-probe: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// `Libertty --web-serve-probe`: serve one pane (a colored line, then `cat`)
    /// for a minute, for a browser to load the page (LIBERTTY_WEB_PORT, LIBERTTY_WEB_TOKEN).
    @MainActor
    private static func webServeProbe() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let session = try? TerminalSession(size: GridSize(cols: 60, rows: 10, widthPx: 0, heightPx: 0)),
              (try? session.start(command: "printf '\\033[1;32mgreen\\033[0m on the \\033[44mweb\\033[0m <b>&\\n'; exec cat")) != nil
        else { exit(1) }
        let web = WebAccess.shared
        web.panes = { [WebPane(id: "p1", title: "probe", place: "probe window", host: nil, session: session)] }
        var config = Config()
        config.webAccess = "local"
        config.webAccessPort = Int(ProcessInfo.processInfo.environment["LIBERTTY_WEB_PORT"] ?? "") ?? 17682
        web.apply(config)
        print("serving on \(config.webAccessPort)")
        RunLoop.main.run(until: Date().addingTimeInterval(60))
        print("screen at the end:\n" + session.scrollbackText())
        exit(0)
    }

    /// `Libertty --web-probe`: Web Access on a private port with one pane; a
    /// WebSocket client checks the page, the secret, the screen and typing.
    @MainActor
    private static func webProbe() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        var failed: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("\(name): \(ok)")
            if !ok { failed.append(name) }
        }
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return done()
        }
        do {
            let session = try TerminalSession(size: GridSize(cols: 50, rows: 8, widthPx: 0, heightPx: 0))
            try session.start(command: "printf 'web-ok\\n'; exec cat")
            let web = WebAccess.shared
            web.panes = { [WebPane(id: "p1", title: "probe", place: "probe window", host: nil, session: session)] }
            var config = Config()
            config.webAccess = "local"
            config.webAccessPort = Int(ProcessInfo.processInfo.environment["LIBERTTY_WEB_PORT"] ?? "") ?? 17682
            web.apply(config)
            check("listening", wait(5) { web.listening })
            let base = "http://127.0.0.1:\(web.port)"

            // The page, with its nonce policy.
            var page: (Int, String, String)?
            URLSession.shared.dataTask(with: URL(string: base + "/")!) { data, response, _ in
                let http = response as? HTTPURLResponse
                page = (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "",
                        String(decoding: data ?? Data(), as: UTF8.self))
            }.resume()
            _ = wait(5) { page != nil }
            check("page", page?.0 == 200 && page?.2.contains("<title>Libertty</title>") == true)
            check("script needs the nonce", page?.1.contains("script-src 'nonce-") == true && page?.1.contains("script-src 'unsafe") == false)

            final class Inbox: @unchecked Sendable {
                let lock = NSLock()
                var messages: [[String: Any]] = []
                var closed = false
                func add(_ m: [String: Any]) { lock.withLock { messages.append(m) } }
                func all() -> [[String: Any]] { lock.withLock { messages } }
            }
            func open(_ token: String, origin: String? = nil) -> (URLSessionWebSocketTask, Inbox) {
                var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(web.port)/ws?t=\(token)")!)
                if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
                let task = URLSession.shared.webSocketTask(with: request)
                let inbox = Inbox()
                // On URLSession's queue, not the main actor: it only fills the inbox.
                @Sendable func next() {
                    task.receive { result in
                        switch result {
                        case .success(.string(let text)):
                            if let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { inbox.add(m) }
                            next()
                        case .success: next()
                        case .failure: inbox.lock.withLock { inbox.closed = true }
                        }
                    }
                }
                task.resume()
                next()
                return (task, inbox)
            }
            func send(_ task: URLSessionWebSocketTask, _ message: [String: Any]) {
                let data = try! JSONSerialization.data(withJSONObject: message)
                task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
            }

            let (bad, badInbox) = open("not-the-secret")
            check("wrong secret refused", wait(5) { badInbox.lock.withLock { badInbox.closed } } && badInbox.all().isEmpty)
            bad.cancel()
            let (foreign, foreignInbox) = open(web.token, origin: "https://evil.example")
            check("other sites refused", wait(5) { foreignInbox.lock.withLock { foreignInbox.closed } } && foreignInbox.all().isEmpty)
            foreign.cancel()

            let (task, inbox) = open(web.token)
            check("hello", wait(5) { inbox.all().contains { $0["t"] as? String == "hello" } })
            check("panes listed", wait(5) { inbox.all().contains { ($0["panes"] as? [[String: Any]])?.first?["id"] as? String == "p1" } })
            send(task, ["t": "watch", "id": "p1"])
            func screen() -> String { inbox.all().last { $0["t"] as? String == "screen" }?["html"] as? String ?? "" }
            check("screen", wait(5) { screen().contains("web-ok") })
            check("palette sent once", inbox.all().filter { $0["t"] as? String == "style" }.count == 1)
            send(task, ["t": "text", "text": "typed-in"])
            send(task, ["t": "key", "code": "Enter", "key": "Enter"])
            check("typing", wait(5) { screen().components(separatedBy: "typed-in").count >= 3 })  // echoed, then printed by cat
            send(task, ["t": "key", "code": "KeyC", "key": "c", "ctrl": true])
            check("ctrl-c through the encoder", wait(5) { session.hasExited })
            task.cancel()

            // My tailnet (a stand-in Tailscale, LIBERTTY_TAILSCALE): tailscale
            // serve takes the port, the link is the Mac's tailnet name over
            // HTTPS, and a page from there may connect (served as 127.0.0.1).
            if let log = ProcessInfo.processInfo.environment["FAKE_TAILSCALE_LOG"] {
                config.webAccess = "tailscale"
                web.apply(config)
                let name = "probe-mac.tail1234.ts.net"
                check("tailscale: listening, named", wait(5) { web.listening && web.tailnetName == name })
                if !web.listening { print("  (not listening: \(web.lastError ?? "no error"))") }
                check("tailscale: the link", web.links == ["https://\(name):\(web.port)/#\(web.token)"])
                let asked = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
                check("tailscale: serve took the port", asked().contains("serve --bg --https=\(web.port) http://127.0.0.1:\(web.port)"))
                let (tailnet, tailnetInbox) = open(web.token, origin: "https://\(name):\(web.port)")
                check("tailscale: a page from the tailnet name connects", wait(5) { tailnetInbox.all().contains { $0["t"] as? String == "hello" } })
                tailnet.cancel()
                let (other, otherInbox) = open(web.token, origin: "https://evil.example")
                check("tailscale: other sites still refused", wait(5) { otherInbox.lock.withLock { otherInbox.closed } } && otherInbox.all().isEmpty)
                other.cancel()
                web.stop()
                check("tailscale: serve let go of the port", wait(5) { asked().contains("serve --https=\(web.port) off") })
            }
            web.stop()
            print(failed.isEmpty ? "web-probe: all passed" : "web-probe failed: \(failed)")
            exit(failed.isEmpty ? 0 : 1)
        } catch {
            print("web-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --kitty-reattach-probe FIXTURE`: images shown in a liberttyd
    /// session are there again after detaching and attaching.
    private static func kittyReattachProbe() -> Never {
        Persistence.setUp(wanted: true)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--kitty-reattach-probe"), i + 1 < args.count else { exit(2) }
        func placements(_ s: TerminalSession) -> [String] {
            let found = s.kittyImages(cellWidth: 16, cellHeight: 32) { _, _ in false }
            return found.draws.map { "\($0.imageID)@\(Int($0.rect.x)),\(Int($0.rect.y)) \(Int($0.rect.z))x\(Int($0.rect.w))" }
                + found.virtuals.map { "virtual \($0.imageID) \($0.columns)x\($0.rows) \($0.width)x\($0.height)px" }
        }
        do {
            let size = GridSize(cols: 60, rows: 14, widthPx: 960, heightPx: 448)
            let session = try TerminalSession(size: size)
            session.setCellSize(widthPx: 16, heightPx: 32)
            try session.start(command: "python3 \(args[i + 1]); sleep 30")
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let before = placements(session)
            guard let id = session.persistentID else { print("kitty-reattach: not in liberttyd"); exit(1) }
            session.detachForProbe()
            let again = try TerminalSession.attach(id)
            again.setCellSize(widthPx: 16, heightPx: 32)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let after = placements(again)
            print("before: \(before)")
            print("after:  \(after)")
            print(!before.isEmpty && before.sorted() == after.sorted() ? "kitty-reattach: images kept" : "kitty-reattach: lost")
            again.terminate()
            exit(0)
        } catch {
            print("kitty-reattach: \(error)")
            exit(1)
        }
    }

    /// `Libertty --resize-resync-probe`: resizing a session in liberttyd that
    /// runs on the alternate screen must be followed, once the size settles,
    /// by the daemon re-sending its screen to every window (painted over
    /// theirs cleared). A window resizes its own copy at its own moment
    /// while the program's output — drawn for the old size — is in flight,
    /// so the copies can drift apart, and a full-screen program repaints
    /// only what it thinks changed (GoRex's race and its fix). A plain
    /// shell reflows the same on both sides and gets nothing.
    private static func resizeResyncProbe() -> Never {
        Persistence.setUp(wanted: true)
        var failures = 0
        let prefix = Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2J".utf8)
        /// What a resize brought back: no repaint, or one that does or
        /// doesn't paint exactly the session's screen on a cleared terminal
        /// of the new size — what a window does with it.
        enum Outcome { case none, right, wrong, failed }
        // A second client attached by id, which asks for the resize and
        // watches what arrives back.
        func watchResize(of command: String) -> Outcome {
            do {
                let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 640, heightPx: 200))
                try session.start(command: command + "; sleep 20")
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                guard let id = session.persistentID,
                      let c = DaemonAddress.local.connect() else { return .failed }
                defer {
                    c.close()
                    session.terminate()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                c.setBufferSizes(1 << 18)
                c.send(.attach, json: ["id": id])
                c.setReceiveTimeout(5)
                guard c.receive()?.kind == .attached else { return .failed }
                c.setReceiveTimeout(0.3)
                var payload = Data(capacity: 8)
                for v in [UInt16(20), UInt16(5), UInt16(320), UInt16(100)] {
                    withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) }
                }
                c.send(.resize, payload)
                // The repaint goes out 150 ms after the resize settles.
                let deadline = Date().addingTimeInterval(1.0)
                var repaint: Data?
                while repaint == nil, Date() < deadline {
                    guard let frame = c.receive() else { continue }
                    if frame.kind == .output, frame.payload.starts(with: prefix) { repaint = frame.payload }
                }
                guard let repaint else { return .none }
                guard repaint.range(of: Data("GHOSTSNP".utf8)) == nil else { return .wrong }  // a binary snapshot
                var fresh: GhosttyTerminal?
                guard ghostty_terminal_new(nil, &fresh, 20, 5) == GHOSTTY_SUCCESS, let fresh else { return .failed }
                defer { ghostty_terminal_free(fresh) }
                repaint.withUnsafeBytes { ghostty_terminal_vt_write(fresh, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                let painted = Snapshots.plainText(fresh, scrollback: false)
                let theirs = DaemonClient.request(.capture, json: ["id": id, "scrollback": false])?.json["text"] as? String
                if painted != theirs { print("      painted: \(painted.debugDescription)\n      session: \((theirs ?? "").debugDescription)") }
                return painted == theirs && painted.contains("ALT") ? .right : .wrong
            } catch {
                print("resize-resync: \(error)")
                return .failed
            }
        }
        switch watchResize(of: "printf 'MARK\\033[?1049h\\033[2;3HALT\\033[1mBOLD\\033[0m\\033[4;1Hrow4'") {
        case .right: print("ok    resize-resync alternate screen repainted as the session has it")
        case .wrong: print("FAIL  resize-resync alternate screen: the repaint doesn't paint the session's screen"); failures += 1
        case .none, .failed: print("FAIL  resize-resync alternate screen: no repaint"); failures += 1
        }
        if watchResize(of: "printf 'MARK'") == .none {
            print("ok    resize-resync plain shell")
        } else {
            print("FAIL  resize-resync plain shell")
            failures += 1
        }
        print(failures == 0 ? "resize-resync: all passed" : "resize-resync: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `Libertty --document-probe FILE|URL OUT.png`: show it as a document pane
    /// in a window off screen (never in front, never focused) and save
    /// what it shows.
    @MainActor
    private static func documentProbe(_ target: String, to output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let url = target.hasPrefix("http") ? URL(string: target)! : URL(fileURLWithPath: target)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let doc = DocumentView(url: url, theme: Config().resolvedTheme, renderMarkdown: true)
        doc.frame = window.contentView!.bounds
        doc.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(doc)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        var saved = false
        doc.snapshot { image in
            if let image, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                saved = CGImageDestinationFinalize(dest)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !saved, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(saved ? "document: \(doc.title) → \(output)" : "document: no snapshot")
        exit(saved ? 0 : 1)
    }

    /// `Libertty --kitty-key-probe`: a program enables the kitty keyboard
    /// protocol at each level and echoes what it receives (`cat -v`), then
    /// the probe presses Shift+2 the way the view does. Legacy and
    /// disambiguate modes must deliver plain "@" (the kitty spec keeps
    /// shift+key out of CSI u, and programs like tclaude mis-decode it);
    /// report-all keeps CSI u, which is what the program asked for.
    private static func kittyKeyProbe() -> Never {
        Persistence.setUp(wanted: true)
        var failures = 0
        func press(_ name: String, enable: String, expect: String, absent: String) {
            do {
                let session = try TerminalSession(size: GridSize(cols: 60, rows: 6, widthPx: 600, heightPx: 120))
                try session.start(command: "printf '\(enable)'; sleep 0.4; cat -v")
                RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                session.send(TerminalSession.Key(
                    action: GHOSTTY_KEY_ACTION_PRESS, key: GHOSTTY_KEY_DIGIT_2,
                    mods: GhosttyMods(GHOSTTY_MODS_SHIFT), consumedMods: 0,
                    text: "@", unshiftedCodepoint: 0x32, composing: false))
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let text = session.scrollbackText()
                if text.contains(expect), !text.contains(absent) {
                    print("ok    kitty-key \(name)")
                } else {
                    print("FAIL  kitty-key \(name): wanted \(expect), screen has \(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(50))")
                    failures += 1
                }
                session.terminate()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            } catch {
                print("FAIL  kitty-key \(name): \(error)")
                failures += 1
            }
        }
        // AZERTY's Ctrl+A: the physical key is US Q, the text the layout's "a"
        // (TerminalView passes it): ^A goes out, not ^Q.
        do {
            let session = try TerminalSession(size: GridSize(cols: 60, rows: 6, widthPx: 600, heightPx: 120))
            try session.start(command: "sleep 0.4; od -An -c")
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            session.send(TerminalSession.Key(
                action: GHOSTTY_KEY_ACTION_PRESS, key: GHOSTTY_KEY_Q, mods: GhosttyMods(GHOSTTY_MODS_CTRL), consumedMods: 0,
                text: "a", unshiftedCodepoint: 0x61, composing: false))
            session.sendText("\n\u{04}")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let text = session.scrollbackText()
            if text.contains("001"), !text.contains("021") { print("ok    kitty-key layout ctrl: ^A") } else {
                print("FAIL  kitty-key layout ctrl: wanted 001 (^A), screen has \(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(50))")
                failures += 1
            }
            session.terminate()
        } catch {
            print("FAIL  kitty-key layout ctrl: \(error)")
            failures += 1
        }
        press("legacy: @", enable: "", expect: "@", absent: "[50")
        press("disambiguate: @", enable: "\\033[>1u", expect: "@", absent: "[50")
        press("report-all: CSI u", enable: "\\033[>8u", expect: "[50;2u", absent: "@")
        print(failures == 0 ? "kitty-key: all passed" : "kitty-key: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `Libertty --ligature-config-probe`: font-feature lines → whether ligatures stay on.
    private static func ligatureConfigProbe() -> Never {
        let cases: [(String, Bool)] = [
            ("", true), ("font-feature = -calt", false), ("font-feature = -calt, -liga, -dlig", false),
            ("font-feature = calt off", false), ("font-feature = liga=0", false), ("font-feature = +calt", true),
            ("font-feature = -calt\nfont-feature = +calt", true), ("font-feature = ss01", true),
        ]
        let wrong = cases.filter { Config.parse($0.0).0.ligatures != $0.1 }
        print(wrong.isEmpty ? "ligature config: all \(cases.count) right" : "ligature config wrong: \(wrong.map(\.0))")
        exit(0)
    }

    /// `Libertty --clear-probe`: ⌘K in a liberttyd session must clear liberttyd's copy
    /// too; prints how many lines liberttyd still has before and after.
    private static func clearProbe() -> Never {
        Persistence.setUp(wanted: true)
        do {
            let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 400, heightPx: 200))
            try session.start(command: "seq 1 50; sleep 5")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func liberttydLines() -> Int {
                guard let id = session.persistentID,
                      let text = DaemonClient.request(.capture, json: ["id": id, "scrollback": true])?.json["text"] as? String
                else { return -1 }
                return text.split(separator: "\n").count
            }
            let before = liberttydLines()
            session.clearScreen()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let window = session.scrollbackText().split(separator: "\n").count
            print("liberttyd lines before ⌘K: \(before), after: \(liberttydLines()), window: \(window)")
            session.terminate()

            // ⌘K while the output stops inside an escape sequence: the clear
            // waits for its end instead of cutting it into literal text.
            let split = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 400, heightPx: 200))
            try split.start(command: "printf 'x\\033[38;5;'; sleep 0.8; printf '196mRED\\n'; sleep 0.4; printf 'AFTER\\n'; sleep 5")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            split.clearScreen()
            RunLoop.main.run(until: Date().addingTimeInterval(1.4))
            let text = split.persistentID.flatMap {
                DaemonClient.request(.capture, json: ["id": $0, "scrollback": true])?.json["text"] as? String
            } ?? ""
            let windowText = split.scrollbackText()
            func intact(_ t: String) -> Bool { t.contains("AFTER") && !t.contains("196m") }
            print("mid-sequence: liberttyd \(intact(text) ? "intact" : "broken: \(text.debugDescription)"), window \(intact(windowText) ? "intact" : "broken")")
            split.terminate()
            exit(0)
        } catch {
            print("clear-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --output-probe zsh|bash`: run two commands, then select the
    /// last one's output (OSC 133 marks) and print it.
    private static func outputProbe(shell: String) -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 80, rows: 30, widthPx: 0, heightPx: 0))
            try session.start(shellPath: "/bin/\(shell)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            session.sendText("echo first-command\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            session.sendText("printf 'out one\\nout two\\nout three\\n'\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let ok = session.selectLastCommandOutput()
            print("selected: \(ok)")
            print("[" + (session.selectedText() ?? "") + "]")
            // A command that prints nothing: there's no output of it to take
            // (not the one before's).
            session.sendText("cd .\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            print("after a silent command: \(session.selectLastCommandOutput() ? "selected [\(session.selectedText() ?? "")]" : "nothing")")
            exit(0)
        } catch {
            print("output-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --scrollbar-probe`: the scrollbar model through output and scrolling.
    /// `Libertty --column-fit-probe`: where a window goes when a side column
    /// comes or goes on a screen (the UI probe's windows have none).
    private static func columnFitProbe() -> Never {
        let visible = NSRect(x: 0, y: 25, width: 1920, height: 1030)
        var failed = 0
        func show(_ label: String, _ grown: NSRect, from old: NSRect, _ want: NSRect) {
            let got = TerminalWindowController.onScreen(grown, from: old, visible: visible)
            if got != want { failed += 1 }
            print("\(got == want ? "ok  " : "FAIL") \(label): \(NSStringFromRect(got))" + (got == want ? "" : ", not \(NSStringFromRect(want))"))
        }
        let old = NSRect(x: 500, y: 200, width: 900, height: 600)
        // The sidebar comes in on the left (the window grows by 250 there).
        show("room on the left", NSRect(x: 250, y: 200, width: 1150, height: 600), from: old,
             NSRect(x: 250, y: 200, width: 1150, height: 600))
        show("at the left edge: moved right", NSRect(x: -150, y: 200, width: 1150, height: 600),
             from: NSRect(x: 100, y: 200, width: 900, height: 600), NSRect(x: 0, y: 200, width: 1150, height: 600))
        // The inspector comes in on the right.
        show("at the right edge: moved left", NSRect(x: 1000, y: 200, width: 1150, height: 600),
             from: NSRect(x: 1000, y: 200, width: 900, height: 600), NSRect(x: 770, y: 200, width: 1150, height: 600))
        show("wider than the screen: as wide as it", NSRect(x: 0, y: 200, width: 2100, height: 600),
             from: NSRect(x: 0, y: 200, width: 1850, height: 600), NSRect(x: 0, y: 200, width: 1920, height: 600))
        show("partly off the screen: left as asked", NSRect(x: -400, y: 200, width: 1150, height: 600),
             from: NSRect(x: -150, y: 200, width: 900, height: 600), NSRect(x: -400, y: 200, width: 1150, height: 600))
        let fills = TerminalWindowController.fills(NSRect(x: 0, y: 25, width: 1920, height: 1030), visible: visible)
        let not = TerminalWindowController.fills(old, visible: visible)
        if !(fills && !not) { failed += 1 }
        print("\(fills && !not ? "ok  " : "FAIL") filling the screen: \(fills), a smaller window: \(not)")
        if failed == 0 { print("column-fit: all passed") }
        exit(failed == 0 ? 0 : 1)
    }

    private static func scrollbarProbe() -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 400, heightPx: 200))
            try session.start(command: "seq 1 400; sleep 2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func show(_ label: String) {
                let s = session.scrollbar
                print("\(label): total \(s.total) offset \(s.offset) length \(s.length) scrollable \(s.scrollable)")
            }
            show("after output")
            session.scroll(toRow: 0)
            show("scrolled to top")
            session.scroll(toRow: 200)
            show("scrolled to 200")
            session.scrollToBottom()
            show("bottom")
            exit(0)
        } catch {
            print("scrollbar-probe: \(error)")
            exit(1)
        }
    }

    /// `Libertty --update-notes-probe FEED.json OUT.png`: what Check for
    /// Updates would show of FEED's notes (the box under the dialog's text),
    /// as a PNG in light and dark, and the box's size.
    @MainActor
    private static func updateNotesProbe(feed: String, to output: String) -> Never {
        guard let data = FileManager.default.contents(atPath: feed),
              let release = try? JSONDecoder().decode(Updater.Release.self, from: data) else {
            print("update-notes-probe: \(feed) isn't an update feed")
            exit(1)
        }
        guard let view = UpdateController.notesView(for: release) else {
            print("update-notes-probe: no notes")
            exit(0)
        }
        print("notes box: \(Int(view.frame.width))x\(Int(view.frame.height))")
        // On a dialog's background, as it shows.
        let backdrop = Backdrop(frame: view.frame.insetBy(dx: -12, dy: -12))
        view.setFrameOrigin(NSPoint(x: 12, y: 12))
        backdrop.addSubview(view)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let path = (output as NSString).deletingPathExtension + "-\(name).png"
            backdrop.appearance = NSAppearance(named: appearance)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
                backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
                guard (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
                else { return print("update-notes-probe: couldn't write \(path)") }
                print(path)
            }
        }
        exit(0)
    }

    private final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    /// `Libertty --git-probe`: which git Libertty runs for the current folder,
    /// and what it gets from it — on a Mac without developer tools (try
    /// `DEVELOPER_DIR=/nonexistent`) never /usr/bin/git, Apple's stub.
    private static func gitProbe() -> Never {
        let directory = FileManager.default.currentDirectoryPath
        print("git: \(GitCLI.executable ?? "none")")
        print("root: \(GitCLI.root(of: directory) ?? "none")")
        switch GitCLI.execute(["status", "--porcelain"], in: directory) {
        case .success: print("status: ok")
        case .failure(let why): print("status: \(why.message)")
        }
        switch GitDiff.write(directory: directory) {
        case .success: print("diff: ok")
        case .failure(let why): print("diff: \(why.message)")
        }
        exit(0)
    }

    /// `Libertty --responsible-probe PID`: the process macOS holds responsible
    /// for PID — the one its camera, microphone, … requests are asked in the
    /// name of. For a session's program that should be liberttyd itself.
    private static func responsibleProbe(_ pid: pid_t) -> Never {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            print("responsible: unknown (no responsibility_get_pid_responsible_for_pid)")
            exit(1)
        }
        let responsible = unsafeBitCast(symbol, to: Responsible.self)(pid)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard responsible > 0, proc_pidpath(responsible, &buffer, UInt32(buffer.count)) > 0 else {
            print("responsible: pid \(responsible), not running")
            exit(1)
        }
        print("responsible: \(String(cString: buffer))")
        exit(0)
    }

    /// `Libertty --resize-bench`: cost of one grid resize (reflow) with a full
    /// scrollback, as a live window resize or split drag pays every frame.
    private static func resizeBench() {
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, 120, 40) == GHOSTTY_SUCCESS, let terminal else { exit(1) }
        var lines = 10_000
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        // Fill the scrollback with wrapped, styled lines like real output.
        var text = ""
        for i in 0..<12_000 {
            text += "\u{1b}[3\(i % 8)m\(i) " + String(repeating: "lorem ipsum dolor sit amet ", count: 3 + i % 5) + "\u{1b}[0m\r\n"
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }

        var times: [Double] = []
        for i in 0..<200 {
            let cols = UInt16(80 + (i % 2 == 0 ? i % 60 : 60 - i % 60))
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            _ = ghostty_terminal_resize(terminal, cols, 40, 16, 31)
            times.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
        }
        times.sort()
        print(String(format: "resize with full scrollback: median %.2f ms, p95 %.2f ms, max %.2f ms",
                     times[times.count / 2], times[times.count * 95 / 100], times.last!))
        ghostty_terminal_free(terminal)
        exit(0)
    }
}
