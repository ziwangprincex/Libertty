import AppKit
import CPty
import LiberttyCore

/// `libertty +ACTION ...`: the command line side, in the app binary itself (as
/// Ghostty's `ghostty +list-themes`). It edits and inspects the config file,
/// and sends requests to the running Libertty. Shells started by Libertty have
/// `libertty` on their PATH.
enum CLI {
    /// What `libertty` exits with (`+help` lists them). `+wait` exits with
    /// the program's own status instead, whatever it is.
    enum ExitCode {
        static let ok: Int32 = 0
        static let failure: Int32 = 1
        static let usage: Int32 = 2
        /// No such session, pane or conversation (or more than one fits).
        static let notFound: Int32 = 3
        /// liberttyd, or the running Libertty, can't be reached.
        static let unreachable: Int32 = 4
        static let timeout: Int32 = 124
    }

    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        if Askpass.requested { Askpass.run(prompt: args.first ?? "") }  // ssh asking, while connecting to a host
        if args.first == "--validate-config" { exit(validate([])) }  // the original spelling
        guard let command = args.first, command.hasPrefix("+") else { return }
        var rest = Array(args.dropFirst())
        // `--host HOST`: the session commands talk to that machine's liberttyd (over ssh).
        if let i = rest.firstIndex(of: "--host") {
            guard i + 1 < rest.count, !rest[i + 1].hasPrefix("-") else { fail("--host needs an ssh destination"); exit(2) }
            host = RemoteHost.named(rest[i + 1])
            rest.removeSubrange(i...(i + 1))
        }
        guard CLISpec.command(named: command) != nil else {
            fail("unknown command \(command); see libertty +help")
            exit(ExitCode.usage)
        }
        if let refusal = RemoteControlPolicy.refusal(command, rest, config: store.config) {
            fail(refusal)
            exit(ExitCode.failure)
        }
        let status: Int32
        switch command {
        case "+help", "+h": status = help()
        case "+version": print(version); status = 0
        case "+show-config": status = showConfig(rest)
        case "+get": status = get(rest)
        case "+set": status = set(rest)
        case "+unset": status = unset(rest)
        case "+list-themes": status = listThemes(rest)
        case "+list-fonts":
            // `--styles`: each family's faces under it, as font-style names them.
            for family in FontSet.monospacedFamilies() {
                print(family)
                if rest.contains("--styles") { FontSet.faces(of: family).forEach { print("  " + $0.style) } }
            }
            status = 0
        case "+list-keybinds": status = listKeybinds(rest)
        case "+list-actions": status = listActions()
        case "+validate-config": status = validate(rest)
        case "+edit-config": status = editConfig()
        case "+import-ghostty": status = GhosttyImport.run(rest)
        case "+migrate-prompt": status = MigrationPrompt.run(rest)
        case "+action": status = action(rest)
        case "+new-window", "+new-tab": status = newWindow(rest, tab: command == "+new-tab")
        case "+open": status = openFiles(rest)
        case "+browser": status = browser(rest)
        case "+connect": status = connect(rest)
        case "+diff": status = diff(rest)
        case "+render-diff": status = renderDiff(rest)
        case "+render-markdown": status = renderMarkdown(rest)
        case "+list-sessions": status = listSessions(rest)
        case "+list-panes": status = listPanes()
        case "+new-session": status = newSession(rest)
        case "+capture": status = capture(rest)
        case "+send": status = send(rest)
        case "+send-key": status = sendKey(rest)
        case "+kill-session": status = killSession(rest)
        case "+attach": status = attach(rest)
        case "+update": status = update(rest)
        case "+wait": status = waitSession(rest)
        case "+events": status = events(rest)
        case "+prompt": status = prompt(rest)
        case "+focus": status = focusSession(rest)
        case "+rename-session": status = renameSession(rest)
        case "+history": status = history(rest)
        case "+resume": status = resume(rest)
        case "+split": status = split(rest)
        case "+move-pane": status = movePane(rest)
        case "+swap-pane": status = swapPane(rest)
        case "+resize-pane": status = resizePane(rest)
        case "+status": status = AgentCLI.status(rest)
        case "+agent-hook": status = AgentCLI.hook(rest)
        case "+agent-setup": status = AgentCLI.setup(rest)
        case "+completions": status = completions(rest)
        case "+complete": status = complete(rest)
        case "+daemon": status = daemonCommand(rest)
        case "+clients": status = clients(rest)
        default:
            fail("unknown command \(command); see libertty +help")
            status = 2
        }
        exit(status)
    }

    /// Set with `--host`; nil for this Mac's liberttyd.
    nonisolated(unsafe) static var host: RemoteHost?
    static var daemon: DaemonAddress { host?.address ?? .local }

    private static var version: String {
        "Libertty " + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev")
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(("libertty: " + message + "\n").data(using: .utf8)!)
    }

    static var store: ConfigStore { ConfigStore.shared }

    // MARK: Help

    private static func help() -> Int32 {
        print("""
        \(version)

        Settings live in \((store.url.path as NSString).abbreviatingWithTildeInPath) (Ghostty's `key = value` format).
        Every change below is written there; a running Libertty applies it as soon as the file is saved.

          libertty +set KEY=VALUE...        change settings, e.g. libertty +set theme="Tokyo Night" font-size=14
                                         keybind/palette add a line: libertty +set keybind=cmd+shift+k=clear_screen
          libertty +unset KEY[=VALUE]       back to the default (for keybind/palette, one line or all)
          libertty +get KEY                 print the effective value
          libertty +show-config             print every effective setting
                [--default] [--docs] [--changes]
          libertty +validate-config         check the file; exits 1 on problems
          libertty +edit-config             open the file in $EDITOR (or your text editor)
          libertty +import-ghostty [--from FILE] [--dry-run] [--yes]
                                         Ghostty's settings into this file: those Libertty knows and doesn't
                                         set itself; says what it adds and asks first
          libertty +migrate-prompt [--from ghostty|iterm2|tmux]…
                                         a prompt for a coding agent that brings your keybindings over
          libertty +update [--check]        install the newest version (signature-checked); --check only reports
          libertty +completions zsh|bash|fish
                                         the shell's completion for libertty (Libertty's shells load it themselves)

          libertty +list-themes [--path]    built-in themes, ~/.config/libertty/themes, and Rex's and Ghostty's if installed
          libertty +list-fonts [--styles]   monospaced font families (--styles: their faces, for font-style)
          libertty +list-keybinds [--default]
          libertty +list-actions            what keybinds (and +action) can do

          libertty +action ACTION           do it in the running Libertty, e.g. libertty +action new_split:right
          libertty +new-window [--cwd DIR] [-e COMMAND...]
          libertty +new-tab [--cwd DIR] [-e COMMAND...]
          libertty +open [--split] [--edit] [--wait] FILE[:LINE]...
                                         show Markdown (rendered) or source files in a tab, or with
                                         --split beside the focused terminal; --edit in the editor;
                                         --wait returns once it's closed (EDITOR="libertty +open --wait")
          libertty +browser open [--split] URL | go URL | back | forward | reload
                                         the browser block (a tab, or --split beside the terminal)
          libertty +browser url | text | html | eval JS | click SELECTOR | type SELECTOR TEXT | screenshot FILE
                                         read and act in the browser in front (browser-automation = true)
          libertty +render-markdown FILE    print the HTML Libertty renders for a Markdown file
          libertty +diff [--turn | --branch] [GIT DIFF ARGS]
                                         this repository's changes, rendered beside the terminal; --turn: what an
                                         agent changed in its last turn here; --branch: since the default branch

        Sessions (kept by liberttyd; they outlive the app — see session-persistence):
          libertty +list-sessions [--json]  every session: id, process, size, windows showing it, directory, name
          libertty +list-panes           every pane of the running Libertty: session, text size and font, cell, scale, grid
          libertty +new-session [--cwd DIR] [--worktree BRANCH [--base REF]] [-e COMMAND...]
                                         start one without a window (Libertty shows it at its next launch);
                                         --worktree: in a git worktree of its own, on a new branch
          libertty +capture ID [--scrollback] [--ansi | --html]
                                         print a session's screen (and history): text, with its colors
                                         as terminal escapes (--ansi), or as a web page (--html)
          libertty +send ID TEXT... [--enter]
                                         type TEXT into a session (\\n for Return); --enter: then press Return
          libertty +send-key ID KEY...      press keys in it, encoded as its program wants: ctrl+c, enter, shift+tab, up
          libertty +kill-session ID [--remove-worktree [--force]]
                                         end a session's program (and remove its worktree; --force: with
                                         uncommitted changes)
          libertty +wait ID [--until exit|prompt|idle=MS] [--timeout SECONDS]
                                         block until its program ends (exits with its status), its shell
                                         shows a prompt again, or its output has been quiet MS ms (0);
                                         124 when the time runs out
          libertty +events [ID] [--filter KIND,...] [--for STATE,...] [--once] [--timeout SECONDS]
                                         what happens in the sessions (or session ID), a JSON object a line,
                                         until ^C: session-started, session-ended, command-started,
                                         command-finished, prompt, title, directory, label, input-mode, bell,
                                         status (OSC 7501: --for working,waiting,done,error); --once: the first
          libertty +prompt ID TEXT... [--quiet MS] [--timeout SECONDS] [-n LINES]
                                         ask another agent: type TEXT and Return, wait until its screen has been
                                         quiet MS ms (3000), print its last LINES lines (40)
          libertty +focus ID                bring the pane showing it to the front
          libertty +rename-session [ID] NAME
                                         name a session (this pane's without ID); its tab shows the name
          libertty +split [ID] [--right|--left|--down|--up] [--ratio PERCENT] [--cwd DIR] [--no-focus] [--keep-open] [-e COMMAND...]
                                         a new pane beside the one showing session ID (this pane's without it),
                                         kept when its program ends with --keep-open;
                                         prints the new session's ID (a pane on a host: add --host HOST for --cwd)
          libertty +move-pane [ID] --new-tab | --tab N | --new-window | --beside OTHER [--right|--left|--down|--up]
                                         move the pane showing session ID (this pane's without it);
                                         tab N of its own window; beside OTHER's pane in the same split
          libertty +swap-pane [ID] OTHER    the two panes trade places in their split (each place keeps its size)
          libertty +resize-pane [ID] --right|--left|--down|--up POINTS | --equalize
                                         move the divider on that side of the pane by POINTS; even out the split
          libertty +attach ID [--window]    show a session in a tab (or window) of the running Libertty; a session
                                         shown twice mirrors: both follow it, closing one leaves the other
          libertty +history [QUERY] [-n N] [--json]
                                         coding agents' conversations that ran in panes (Claude Code, Codex;
                                         needs +agent-setup), the last to run first; QUERY matches names, folders, ids
          libertty +resume ID|NAME          pick one up again: the pane running it, or a new tab resuming it
                                         (claude --resume, codex resume); prints the pane's session ID
          libertty +daemon status [--json]  liberttyd: its pid, build, socket, log, uptime, sessions and clients
          libertty +daemon stop [--if-idle | --force]
                                         stop it; with sessions only --force (it ends them), --if-idle leaves it be
          libertty +daemon restart          a new liberttyd takes every session over (programs keep running)
          libertty +daemon logs [-f] [--lines N]
                                         its log's last N lines (50); -f: and what follows, until ^C
          libertty +clients [--json]        who is connected to liberttyd: windows, +events, +wait, Macs over ssh
        Inside Libertty, $LIBERTTY_SESSION is the current pane's ID.

        Programs and agents:
          libertty +status STATE [--app NAME] [--title TEXT] [--message TEXT] [--kind KIND] [--progress N] [--id ID]
                                         report to this terminal what a program is doing (OSC 7501): idle, working,
                                         blocked (waiting for you; KIND permission, question or auth), done, error;
                                         clear [--id ID] takes it back
          libertty +agent-setup [--agent claude|codex|all] [--claude-dir DIR] [--codex-dir DIR] [--remove] [--dry-run] [--yes]
                                         Claude Code hooks (its tab says when it works, waits for you or is done;
                                         it learns where it runs), Codex's notify (done, waiting for approval) and a
                                         skill for this command line for each; Codex when ~/.codex is there; asks first

        Other machines (over your own ssh; their sessions survive the link dropping):
          libertty +connect HOST            open a window on HOST (File ▸ Connect to Host…)
          --host HOST                    with +list-sessions, +new-session, +capture, +send, +send-key,
                                         +kill-session, +wait, +events, +split, +move-pane, +daemon or +clients:
                                         that machine's sessions

        With remote-control = false (Settings ▸ Integrations), commands may read but not drive Libertty:
        +split, +send, +focus, +action, +new-window, +new-session, +kill-session, +daemon stop… are refused.

        Exit status: 0 done, 1 failed, 2 usage, 3 no such session, pane or conversation, 4 liberttyd or
        Libertty unreachable, 124 out of time (+wait, +events); +wait exits with the program's own status.
        """)
        return 0
    }

    // MARK: Reading

    private static func showConfig(_ args: [String]) -> Int32 {
        let defaults = Config()
        let config = args.contains("--default") ? defaults : store.config
        let changesOnly = args.contains("--changes")
        for (key, doc) in Config.documentation where key != "config-file" {
            let values = config.values(of: key)
            if changesOnly, values == defaults.values(of: key) { continue }
            if args.contains("--docs") { print("\n# " + doc) }
            if values.isEmpty, Config.repeatable.contains(key) {
                if !changesOnly { print("# \(key) =") }
                continue
            }
            for v in values { print("\(key) = \(v)") }
        }
        if args.contains("--keybinds") { return listKeybinds([]) }
        return 0
    }

    private static func get(_ args: [String]) -> Int32 {
        guard let key = args.first else { fail("usage: libertty +get KEY"); return 2 }
        guard Config.documentation.contains(where: { $0.key == key }) else { fail("unknown key \(key)"); return 1 }
        store.config.values(of: key).forEach { print($0) }
        return 0
    }

    // MARK: Writing

    /// `KEY=VALUE`, or `KEY VALUE` as two arguments.
    private static func pairs(_ args: [String]) -> [(String, String)]? {
        var out: [(String, String)] = []
        var i = 0
        while i < args.count {
            if let eq = args[i].firstIndex(of: "=") {
                out.append((String(args[i][..<eq]), String(args[i][args[i].index(after: eq)...])))
                i += 1
            } else if i + 1 < args.count {
                out.append((args[i], args[i + 1]))
                i += 2
            } else {
                return nil
            }
        }
        return out
    }

    private static func set(_ args: [String]) -> Int32 {
        guard let pairs = pairs(args), !pairs.isEmpty else {
            fail("usage: libertty +set KEY=VALUE [KEY=VALUE...]")
            return 2
        }
        // Check everything first, so a typo writes nothing.
        var scratch = store.config
        for (key, value) in pairs {
            if key == "config-file" { continue }
            // What lets a terminal read your signed-in pages is yours to switch
            // on, in the config file: not something a program in a terminal does.
            // So is what lets programs drive Libertty.
            if key == "browser-automation" || key == "remote-control" {
                fail("\(key) is set in Settings or by editing the config file (\(store.url.path)), not with +set")
                return 1
            }
            if let problem = scratch.set(key, value) {
                fail("\(key): \(problem)")
                return 1
            }
        }
        for (key, value) in pairs {
            switch key {
            case "keybind":
                // One line per trigger (or sequence): replace an earlier binding of the same keys.
                if let (keys, _, isGlobal) = Keybinds.parse(value) {
                    store.unset("keybind") { v in
                        guard let (k, _, g) = Keybinds.parse(v) else { return false }
                        return k == keys && g == isGlobal
                    }
                }
                store.add(key, value)
            case "palette":
                let index = value.split(separator: "=").first.map(String.init)
                store.unset("palette") { $0.split(separator: "=").first.map(String.init) == index }
                store.add(key, value)
            case "config-file":
                store.add(key, value)
            default:
                store.set(key, value.isEmpty ? nil : quoteIfNeeded(value))
            }
        }
        return 0
    }

    /// Values are taken verbatim; quotes are only needed to keep edge spaces.
    private static func quoteIfNeeded(_ v: String) -> String {
        v != v.trimmingCharacters(in: .whitespaces) ? "\"\(v)\"" : v
    }

    private static func unset(_ args: [String]) -> Int32 {
        guard let arg = args.first else { fail("usage: libertty +unset KEY[=VALUE]"); return 2 }
        let (key, value): (String, String?) = arg.firstIndex(of: "=").map {
            (String(arg[..<$0]), String(arg[arg.index(after: $0)...]))
        } ?? (arg, args.count > 1 ? args[1] : nil)
        guard Config.documentation.contains(where: { $0.key == key }) else { fail("unknown key \(key)"); return 1 }
        // Back to its default would let commands drive Libertty again (see +set).
        if key == "remote-control" {
            fail("remote-control is set in Settings or by editing the config file (\(store.url.path)), not with +unset")
            return 1
        }
        if let value, Config.repeatable.contains(key) {
            store.unset(key) { $0 == value }
        } else {
            store.unset(key)
        }
        return 0
    }

    private static func validate(_ args: [String]) -> Int32 {
        var url = store.url
        if let i = args.firstIndex(where: { $0.hasPrefix("--config-file") }) {
            let a = args[i]
            let path = a.contains("=") ? String(a.split(separator: "=", maxSplits: 1)[1]) : (i + 1 < args.count ? args[i + 1] : "")
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let (_, warnings, _) = Config.load(url)
        for w in warnings { print("\(url.path): \(w)") }
        if warnings.isEmpty { print("\(url.path): ok") }
        return warnings.isEmpty ? 0 : 1
    }

    private static func editConfig() -> Int32 {
        store.ensureFile()
        let env = ProcessInfo.processInfo.environment
        if let editor = env["VISUAL"] ?? env["EDITOR"], !editor.isEmpty, isatty(STDIN_FILENO) != 0 {
            // Through the shell, so EDITOR="code --wait" works.
            let argv = ["/bin/sh", "-c", "\(editor) \"$0\"", store.url.path]
            let cargs = argv.map { strdup($0) } + [nil]
            execv("/bin/sh", cargs)
            fail("couldn't run \(editor)")
            return 1
        }
        NSWorkspace.shared.open(store.url)
        return 0
    }

    // MARK: Lists

    /// Help ▸ Libertty Help: every option with its docs and default, then the
    /// actions and default keybinds.
    static func reference() -> String {
        var out = """
        Libertty Reference
        ===============

        Settings live in \((store.url.path as NSString).abbreviatingWithTildeInPath), Ghostty's format: `key = value`.
        Libertty ▸ Settings… (⌘,) changes it a line at a time; Libertty ▸ Open Config File opens it. It applies as soon as it is saved.
        From a shell: libertty +set key=value, libertty +get key, libertty +show-config, libertty +help.

        Options
        -------

        """
        let defaults = Config()
        for (key, doc) in Config.documentation {
            out += "\n# \(doc)\n"
            let values = defaults.values(of: key)
            if values.isEmpty { out += "\(key) =\n" } else { values.forEach { out += "\(key) = \($0)\n" } }
        }
        out += "\n\nActions (for keybind = TRIGGER=ACTION, and libertty +action)\n-------\n\n"
        let width = Action.catalog.map(\.0.count).max() ?? 0
        for (name, doc) in Action.catalog { out += name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + doc + "\n" }
        out += "\n\nDefault keybinds\n----------------\n\n"
        for b in Keybinds(entries: []).local { out += "keybind = \(b.trigger.configString)=\(b.action.configString)\n" }
        return out
    }

    private static func listThemes(_ args: [String]) -> Int32 {
        let showPath = args.contains("--path")
        let color = isatty(STDOUT_FILENO) != 0 && !args.contains("--plain")
        var rows: [(String, String, Theme?)] = Theme.all.map { ($0.name, "built-in", $0) }
        let builtIn = Set(Theme.all.map { $0.name.lowercased() })
        for e in ThemeLibrary.shared.entries where !builtIn.contains(e.name.lowercased()) {
            rows.append((e.name, showPath ? e.url.path : e.source, color ? ThemeLibrary.shared.load(e.name) : nil))
        }
        let width = min(36, rows.map(\.0.count).max() ?? 0)
        for (name, source, theme) in rows {
            let padded = name.padding(toLength: max(width, name.count), withPad: " ", startingAt: 0)
            guard color, let t = theme else { print("\(name)\t\(source)"); continue }
            // A swatch: the theme's background with its six colors on top.
            var swatch = "\u{1b}[48;2;\(t.background.r);\(t.background.g);\(t.background.b)m "
            for i in 1...6 { swatch += "\u{1b}[38;2;\(t.ansi[i].r);\(t.ansi[i].g);\(t.ansi[i].b)m●" }
            swatch += " \u{1b}[0m"
            print("\(swatch) \(padded)  \u{1b}[2m\(source)\u{1b}[0m")
        }
        return 0
    }

    private static func listKeybinds(_ args: [String]) -> Int32 {
        let table = args.contains("--default") ? Keybinds(entries: []) : store.keybinds
        let width = ((table.local + table.global).map { $0.trigger.configString.count + 7 }
            + table.sequences.map(\.triggers.configString.count)).max() ?? 0
        for b in table.global {
            print(("global:" + b.trigger.configString).padding(toLength: width, withPad: " ", startingAt: 0)
                  + " = " + b.action.configString)
        }
        for b in table.local {
            print(b.trigger.configString.padding(toLength: width, withPad: " ", startingAt: 0) + " = " + b.action.configString)
        }
        for s in table.sequences {
            print(s.triggers.configString.padding(toLength: width, withPad: " ", startingAt: 0) + " = " + s.action.configString)
        }
        return 0
    }

    private static func listActions() -> Int32 {
        let width = Action.catalog.map(\.0.count).max() ?? 0
        for (name, doc) in Action.catalog {
            print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + doc)
        }
        return 0
    }

    // MARK: Talking to the running app

    static var liberttyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "dev.libertty.terminal"
                || ($0.executableURL?.lastPathComponent == "Libertty" && $0.processIdentifier != getpid())
        }
    }

    private static func action(_ args: [String]) -> Int32 {
        guard let text = args.first else { fail("usage: libertty +action ACTION (see libertty +list-actions)"); return 2 }
        guard let action = Action(text) else { fail("unknown action \(text); see libertty +list-actions"); return 1 }
        guard ActionDispatcher.allowedRemotely(action) else {
            fail("\(text) can't be sent from outside Libertty (it would type into a terminal); bind it to a key instead")
            return 1
        }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        RemoteControl.post(["action": action.configString])
        return 0
    }

    // MARK: Updates

    private static func update(_ args: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task {
            defer { semaphore.signal() }
            do {
                guard let release = try await Updater.check() else {
                    print("Libertty \(Updater.currentVersion) is the newest version.")
                    return
                }
                print("Libertty \(release.version) is available (you have \(Updater.currentVersion)).")
                if let notes = release.notes, !notes.isEmpty { print(notes) }
                if args.contains("--check") { status = 10; return }
                let app = Bundle.main.bundleURL
                guard app.pathExtension == "app" else { fail("not running from an app bundle"); status = 1; return }
                print("Downloading \(release.url)…")
                let zip = try await Updater.download(release) { _ in }
                print("Verified (SHA-256, Ed25519 signature). Installing over \(app.path)…")
                try Updater.install(zip, release: release, over: app)
                try? FileManager.default.removeItem(at: zip)
                print("Installed Libertty \(release.version). Restart Libertty to use it (your programs keep running).")
            } catch {
                fail(error.localizedDescription)
                status = 1
            }
        }
        semaphore.wait()
        return status
    }

    // MARK: Sessions (liberttyd)

    private static func sessionArgument(_ args: [String], usage: String) -> String? {
        guard let id = args.first(where: { !$0.hasPrefix("--") }) ?? ProcessInfo.processInfo.environment["LIBERTTY_SESSION"] else {
            fail("usage: libertty \(usage)")
            return nil
        }
        return id
    }

    /// A one-request answer as an exit status, having said what went wrong:
    /// no answer is liberttyd out of reach, a session it doesn't have is not found.
    static func status(_ frame: Connection.Frame?) -> Int32 {
        guard let frame else {
            fail(host.map { "can't reach liberttyd on \($0.destination)" } ?? "liberttyd isn't running (no sessions)")
            return ExitCode.unreachable
        }
        if frame.json["ok"] as? Bool == false {
            let error = frame.json["error"] as? String ?? "failed"
            fail(error)
            return isMissing(error) ? ExitCode.notFound : ExitCode.failure
        }
        return ExitCode.ok
    }

    /// liberttyd's word for a session it doesn't have.
    static func isMissing(_ error: String) -> Bool { error.hasPrefix("no such session") || error.hasPrefix("no session ") }

    /// `+split [ID] [--right|--left|--down|--up] [--ratio PERCENT] [--cwd DIR]
    /// [--no-focus] [-e COMMAND...]`: a new pane beside the one showing session
    /// ID (this pane's without it), in the running Libertty. Prints the new
    /// pane's session ID.
    private static func split(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +split [ID] [--right|--left|--down|--up] [--ratio PERCENT] [--cwd DIR] [--no-focus] [--keep-open] [-e COMMAND...]"
        var beside = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        var direction = "right", ratio = 50, cwd = "", command = "", focus = true, keepOpen = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--right", "--left", "--down", "--up": direction = String(a.dropFirst(2))
            case "--no-focus": focus = false
            case "--keep-open": keepOpen = true
            case "--ratio":
                guard i + 1 < args.count, let n = Int(args[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))),
                      (10...90).contains(n) else { fail("--ratio is the new pane's share, 10 to 90 (percent)"); return 2 }
                ratio = n
                i += 1
            case "--cwd":
                guard i + 1 < args.count else { fail(usage); return 2 }
                if host != nil {
                    // A host's directory is the host's: given whole, nothing here can expand it.
                    guard args[i + 1].hasPrefix("/") else { fail("--cwd on a host takes an absolute path"); return 2 }
                    cwd = args[i + 1]
                } else {
                    cwd = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath).standardizedFileURL.path
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                        fail("\(args[i + 1]): no such folder")
                        return 2
                    }
                }
                i += 1
            case "-e":
                guard i + 1 < args.count else { fail(usage); return 2 }
                command = args[(i + 1)...].joined(separator: " ")
                i = args.count
            default:
                guard !a.hasPrefix("-") else { fail(usage); return 2 }
                beside = a
            }
            i += 1
        }
        guard let beside else { fail(usage + " (outside a Libertty session, give the ID of the pane to split)"); return 2 }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        let answer = RemoteControl.request(["kind": "split", "beside": beside, "direction": direction,
                                            "share": String(Double(ratio) / 100), "cwd": cwd, "command": command,
                                            "focus": focus ? "1" : "0", "keepOpen": keepOpen ? "1" : "0"], timeout: 10)
        switch answer?["result"] {
        case "made":
            let id = answer?["session"] ?? ""
            guard !id.isEmpty else {
                fail("made, outside liberttyd (session-persistence = false?): it has no session ID")
                return 0
            }
            print(id)
            return 0
        case "no-pane":
            fail("no window shows session \(beside) (libertty +list-sessions; +attach \(beside) shows one)")
            return ExitCode.notFound
        case "refused":
            fail("can't split it: \(answer?["message"] ?? "")")
            return 1
        case "error":
            fail(answer?["message"] ?? "it couldn't be made")
            return 1
        default:
            fail("Libertty didn't answer (one older than this command?)")
            return ExitCode.unreachable
        }
    }

    /// `+move-pane [ID] --new-tab | --tab N | --new-window`: the pane showing
    /// session ID (this pane's without it) moves, in the running Libertty.
    /// Tab N is of the pane's own window and workspace.
    private static func movePane(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +move-pane [ID] --new-tab | --tab N | --new-window | --beside OTHER [--right|--left|--down|--up]"
        var id = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        var to: String?
        var side = "right"
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--new-tab": to = "new-tab"
            case "--new-window": to = "new-window"
            case "--tab":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { fail(usage); return 2 }
                to = "tab:\(n)"
                i += 1
            case "--beside":
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { fail(usage); return 2 }
                to = "beside:" + args[i + 1]
                i += 1
            case "--right", "--left", "--down", "--up": side = String(args[i].dropFirst(2))
            case let a where !a.hasPrefix("-"): id = a
            default: fail(usage); return 2
            }
            i += 1
        }
        guard let id, let to else { fail(usage); return 2 }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        let answer = RemoteControl.request(["kind": "move-pane", "id": id, "to": to, "side": side], timeout: 10)
        switch answer?["result"] {
        case "moved":
            return 0
        case "no-pane":
            fail("no window shows session \(answer?["missing"].flatMap { $0.isEmpty ? nil : $0 } ?? id) (libertty +list-sessions)")
            return ExitCode.notFound
        case "refused":
            fail("can't move it: \(answer?["message"] ?? "")")
            return 1
        default:
            fail("Libertty didn't answer (one older than this command?)")
            return ExitCode.unreachable
        }
    }

    /// `+swap-pane [ID] OTHER`: the panes showing the two sessions trade
    /// places (Rex's swap). Without ID, this pane.
    private static func swapPane(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +swap-pane [ID] OTHER"
        let mine = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        let ids = args.filter { !$0.hasPrefix("-") }
        guard args.count == ids.count, let (id, other) = ids.count == 2 ? (ids[0], ids[1]) : ids.count == 1 ? mine.map({ ($0, ids[0]) }) : nil
        else { fail(usage); return 2 }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        return arrangeAnswer(RemoteControl.request(["kind": "swap-pane", "id": id, "with": other], timeout: 10), id: id, done: "swapped")
    }

    /// `+resize-pane [ID] --right|--left|--down|--up POINTS | --equalize`:
    /// the divider on that side of the pane moves (Ghostty's resize_split).
    private static func resizePane(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +resize-pane [ID] --right|--left|--down|--up POINTS | --equalize"
        var id = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        var direction: String?, points = 0
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--right", "--left", "--down", "--up":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { fail(usage); return 2 }
                (direction, points) = (String(args[i].dropFirst(2)), n)
                i += 1
            case "--equalize": direction = "equalize"
            case let a where !a.hasPrefix("-"): id = a
            default: fail(usage); return 2
            }
            i += 1
        }
        guard let id, let direction else { fail(usage); return 2 }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        let answer = RemoteControl.request(["kind": "resize-pane", "id": id, "direction": direction, "points": String(points)], timeout: 10)
        return arrangeAnswer(answer, id: id, done: "resized")
    }

    private static func arrangeAnswer(_ answer: [String: String]?, id: String, done: String) -> Int32 {
        switch answer?["result"] {
        case done: return 0
        case "no-pane":
            fail("no window shows session \(answer?["missing"] ?? id) (libertty +list-sessions)")
            return ExitCode.notFound
        case "refused":
            fail("can't: \(answer?["message"] ?? "")")
            return 1
        default:
            fail("Libertty didn't answer (one older than this command?)")
            return ExitCode.unreachable
        }
    }

    /// `+rename-session [ID] NAME`: name a session (its tab goes by the
    /// name); "" takes the name away. Without ID, this pane's.
    private static func renameSession(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +rename-session [ID] NAME"
        let id: String, name: String
        switch args.count {
        case 1:
            guard let mine = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"], !mine.isEmpty else {
                fail(usage + " (outside a Libertty session, give its ID)")
                return 2
            }
            (id, name) = (mine, args[0])
        case 2:
            (id, name) = (args[0], args[1])
        default:
            fail(usage + " (quote a name with spaces)")
            return 2
        }
        switch DaemonClient.request(.rename, json: ["id": id, "label": name], needing: "label", address: daemon) {
        case .unanswered:
            fail("liberttyd isn't running")
            return ExitCode.unreachable
        case .unsupported:
            fail("this liberttyd can't name sessions; restart Libertty to update it")
            return 1
        case .answered(let frame):
            guard frame.json["ok"] as? Bool == true else {
                let error = frame.json["error"] as? String ?? "no session \(id)"
                fail(error)
                return isMissing(error) ? ExitCode.notFound : ExitCode.failure
            }
            return 0
        }
    }

    /// `+history [QUERY] [-n N] [--json]`: agents' conversations (Conversations).
    private static func history(_ args: [String]) -> Int32 {
        var query: [String] = [], limit = 20, json = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--json": json = true
            case "-n", "--limit":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { fail("usage: libertty +history [QUERY] [-n N] [--json]"); return 2 }
                limit = n
                i += 1
            default: query.append(args[i])
            }
            i += 1
        }
        let list = Array(Conversations.matching(query.joined(separator: " "), among: Conversations.load()).prefix(limit))
        if json {
            let data = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        guard !list.isEmpty else {
            print("no conversations (libertty +agent-setup records Claude Code's and Codex's)")
            return 0
        }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        for c in list {
            let when = format.string(from: Date(timeIntervalSince1970: c.active))
            let folder = (c.directory as NSString).abbreviatingWithTildeInPath
            print([String(c.id.prefix(8)), when, c.agentName, c.label, folder, c.ended ? "ended" : ""]
                .filter { !$0.isEmpty }.joined(separator: "  "))
        }
        return 0
    }

    /// `+resume ID|NAME`: the running Libertty picks the conversation up again.
    private static func resume(_ args: [String]) -> Int32 {
        guard args.count == 1 else { fail("usage: libertty +resume ID|NAME"); return 2 }
        guard let c = Conversations.find(args[0], among: Conversations.load()) else {
            fail("no conversation \(args[0]) (libertty +history lists them)")
            return ExitCode.notFound
        }
        guard Conversations.resumeCommand(c) != nil else { fail("\(c.agentName)'s conversations can't be resumed"); return 1 }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        let answer = RemoteControl.request(["kind": "resume", "agent": c.agent, "id": c.id], timeout: 10)
        switch answer?["result"] {
        case "made":
            if let id = answer?["session"], !id.isEmpty { print(id) }
            return 0
        case nil:
            fail("Libertty didn't answer")
            return ExitCode.unreachable
        default:
            fail(answer?["message"] ?? "Libertty couldn't resume it")
            return 1
        }
    }

    private static func listSessions(_ args: [String]) -> Int32 {
        guard let sessions = DaemonClient.sessions(address: daemon) else {
            let why = host.map { "can't reach \($0.destination)" + (($0.lastError as? LocalizedError)?.errorDescription.map { ": " + $0 } ?? "") }
            if !args.contains("--json") { print("no sessions (\(why ?? "liberttyd isn't running"))") } else { print("[]") }
            // This Mac's liberttyd not running is no sessions; a host out of reach is a failure.
            return host == nil ? 0 : ExitCode.unreachable
        }
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: (try? encoder.encode(sessions)) ?? Data(), as: UTF8.self))
            return 0
        }
        let mine = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"]
        for s in sessions {
            var name = ""
            if host == nil {
                var buf = [CChar](repeating: 0, count: 256)
                let fg = libertty_proc_tty_pgid(s.pid)
                libertty_proc_name(fg > 0 ? fg : s.pid, &buf, Int32(buf.count))
                name = String(cString: buf)
            } else {
                // Another machine's processes: what liberttyd says it runs.
                name = (s.command.split(separator: " ").first.map(String.init) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            }
            let dir = SessionInfo.directory(fromPwd: s.workingDirectory).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
            let shown = s.clients == 0 ? "detached" : (s.clients == 1 ? "shown" : "shown ×\(s.clients)")
            let marker = s.id == mine ? "*" : " "
            print("\(marker) \(s.id)  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.cols)×\(s.rows)  "
                  + "\(shown.padding(toLength: 9, withPad: " ", startingAt: 0)) \(dir)" + (s.label.map { "  “\($0)”" } ?? ""))
        }
        return 0
    }

    private static func newSession(_ args: [String]) -> Int32 {
        var directory = FileManager.default.currentDirectoryPath
        var command: String?
        var worktree: String?, base: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--cwd":
                guard i + 1 < args.count else { fail("--cwd needs a directory"); return 2 }
                directory = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath).standardizedFileURL.path
                i += 2
            case "--worktree", "--base":
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { fail("\(args[i]) needs a branch"); return 2 }
                if args[i] == "--worktree" { worktree = args[i + 1] } else { base = args[i + 1] }
                i += 2
            case "-e":
                command = args[(i + 1)...].joined(separator: " ")
                i = args.count
            default:
                fail("unknown option \(args[i])")
                return 2
            }
        }
        if base != nil, worktree == nil { fail("--base goes with --worktree"); return 2 }
        // In a git worktree of its own, on a new branch (New Tab in Worktree…).
        if let branch = worktree {
            guard host == nil else { fail("--worktree is for this Mac's repositories"); return 2 }
            guard let root = GitCLI.root(of: directory) else { fail("\(directory) isn't in a git repository"); return 1 }
            let from = base ?? (store.config.worktreeBase == "current" ? "HEAD" : nil)
            switch Worktrees.create(root: root, branch: branch, base: from, setting: store.config.worktreeDir) {
            case .failure(let why): fail(why.message); return 1
            case .success(let path): directory = path
            }
        }
        let id = Persistence.newSessionID()
        let config = store.config
        let size = GridSize(cols: UInt16(config.windowColumns), rows: UInt16(config.windowRows), widthPx: 0, heightPx: 0)
        let request: CreateRequest
        if let host {
            do { try host.prepare() } catch { fail("\(host.destination): \(error.localizedDescription)"); return ExitCode.unreachable }
            // There, the directory is the host's (its home unless --cwd).
            let cwd = args.contains("--cwd") ? directory : nil
            guard let r = host.createRequest(id: id, command: command, workingDirectory: cwd, size: size, config: config) else { return 1 }
            request = r
        } else {
            guard let exe = Persistence.daemonExecutable,
                  DaemonClient.ensureRunning(executable: exe, logPath: Persistence.logPath) else {
                fail("can't start liberttyd")
                return ExitCode.unreachable
            }
            var (executable, arguments, environment) = TerminalSession.launchSpec(command: command)
            environment["LIBERTTY_SESSION"] = id
            request = CreateRequest(id: id, executable: executable, arguments: arguments, environment: environment,
                                    workingDirectory: directory, size: size, scrollback: config.scrollbackLimit)
        }
        do {
            // Created attached to this connection; it detaches as we exit.
            let remote = try RemotePTY.create(request, address: daemon, queue: DispatchQueue(label: "libertty.cli"))
            remote.detach()
            print(id)
            return 0
        } catch {
            fail("\(error)")
            return 1
        }
    }

    private static func capture(_ args: [String]) -> Int32 {
        let usage = "+capture ID [--scrollback] [--ansi | --html]"
        guard let id = sessionArgument(args, usage: usage) else { return 2 }
        let format: Snapshots.TextFormat = args.contains("--html") ? .html : args.contains("--ansi") ? .ansi : .plain
        guard !(args.contains("--html") && args.contains("--ansi")) else { fail("usage: libertty \(usage)"); return 2 }
        let frame = DaemonClient.request(.capture, json: ["id": id, "scrollback": args.contains("--scrollback"),
                                                          "format": format.rawValue], address: daemon)
        let answered = status(frame)
        guard answered == ExitCode.ok, let text = frame?.json["text"] as? String else { return answered == 0 ? 1 : answered }
        // An older liberttyd knows plain text only (and says nothing of a format).
        if format != .plain, frame?.json["format"] as? String != format.rawValue {
            fail("this liberttyd captures plain text only; restart Libertty to update it")
            return 1
        }
        switch format {
        case .plain:
            print(text)
        case .ansi:
            // Ends with styles reset, so the shell's own prompt comes out plain.
            print(text + "\u{1b}[0m")
        case .html:
            // A page of its own around the formatter's rows (their colors and
            // styles inline), in a proper monospace face.
            print("""
            <!doctype html>
            <meta charset="utf-8">
            <title>\(htmlEscaped(id))</title>
            <style>body > div { font-family: ui-monospace, SFMono-Regular, Menlo, monospace !important; line-height: 1.25; }</style>
            \(text)
            """)
        }
        return 0
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `+send ID TEXT... [--enter]`: TEXT typed (`\n` Return, `\t` Tab);
    /// --enter then presses Return, encoded as the program wants it, apart
    /// from the text (as +prompt: an agent takes text typed at once as a paste).
    private static func send(_ args: [String]) -> Int32 {
        let enter = args.contains("--enter")
        let args = args.filter { $0 != "--enter" }
        guard args.count >= (enter ? 1 : 2) else { fail("usage: libertty +send ID TEXT... [--enter]"); return 2 }
        let text = args.dropFirst().joined(separator: " ")
            .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
        if !enter || !text.isEmpty {
            let sent = status(DaemonClient.request(.send, json: ["id": args[0], "text": text], address: daemon))
            guard sent == ExitCode.ok, enter else { return sent }
            usleep(300_000)
        }
        switch DaemonClient.request(.sendKey, json: ["id": args[0], "keys": ["enter"]], needing: "sendKey", address: daemon) {
        case .answered(let frame): return status(frame)
        case .unsupported: return status(DaemonClient.request(.send, json: ["id": args[0], "text": "\r"], address: daemon))
        case .unanswered: return status(nil)
        }
    }

    /// `+list-panes`: the running Libertty's panes as it draws them.
    private static func listPanes() -> Int32 {
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        guard let answer = RemoteControl.request(["kind": "list-panes"], timeout: 3) else {
            fail("Libertty didn't answer (an older version doesn't know +list-panes)")
            return ExitCode.unreachable
        }
        if let text = answer["text"], !text.isEmpty { print(text) }
        return 0
    }

    /// `+send-key ID KEY...`: press keys in a session — `ctrl+c`, `enter`,
    /// `shift+tab`, `up`, `alt+f` — encoded as its program wants them (cursor
    /// key mode, the kitty keyboard protocol), as typing them would.
    private static func sendKey(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { fail("usage: libertty +send-key ID KEY... (e.g. ctrl+c, enter, shift+tab, up)"); return 2 }
        if let bad = args.dropFirst().first(where: { KeySpec($0) == nil }) {
            fail("unknown key \(bad): a character or enter, tab, escape, backspace, delete, space, up, down, left, right, "
                 + "home, end, page_up, page_down, insert, f1–f12, comma, backslash, grave…, with ctrl+, alt+, shift+, super+")
            return 2
        }
        switch DaemonClient.request(.sendKey, json: ["id": args[0], "keys": Array(args.dropFirst())], needing: "sendKey",
                                    address: daemon) {
        case .unanswered: return status(nil)
        case .unsupported: fail("this liberttyd can't press keys; restart Libertty to update it"); return 1
        case .answered(let frame): return status(frame)
        }
    }

    private static func attach(_ args: [String]) -> Int32 {
        guard let id = args.first(where: { !$0.hasPrefix("--") }) else { fail("usage: libertty +attach ID [--window]"); return 2 }
        if host != nil { fail("+attach shows sessions of this Mac; for a host, use File ▸ Connect to Host…"); return 2 }
        guard let sessions = DaemonClient.sessions() else { fail("liberttyd isn't running (no sessions)"); return ExitCode.unreachable }
        guard sessions.contains(where: { $0.id == id }) else {
            fail("no session \(id) (see libertty +list-sessions)")
            return ExitCode.notFound
        }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        RemoteControl.post(["kind": "attach", "id": id, "tab": args.contains("--window") ? "0" : "1"])
        return 0
    }

    /// `+wait ID [--until exit|prompt|idle=MS] [--timeout SECONDS]`: the
    /// program's exit status; 0 once its shell shows a prompt or its output
    /// has been quiet for MS ms; 124 when the time runs out (as `timeout` does).
    private static func waitSession(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +wait ID [--until exit|prompt|idle=MS] [--timeout SECONDS]"
        var id: String?, until = "exit", idleMs = 0, timeout: Double?
        var i = 0
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            if a == "--until", let next {
                if next == "exit" || next == "prompt" {
                    until = next
                } else if next.hasPrefix("idle="), let ms = Int(next.dropFirst(5)), ms > 0 {
                    until = "idle"
                    idleMs = ms
                } else {
                    fail(usage)
                    return 2
                }
                i += 2
            } else if a == "--timeout", let next, let seconds = Double(next), seconds > 0 {
                timeout = seconds
                i += 2
            } else if !a.hasPrefix("--"), id == nil {
                id = a
                i += 1
            } else {
                fail(usage)
                return 2
            }
        }
        guard let id = id ?? ProcessInfo.processInfo.environment["LIBERTTY_SESSION"] else { fail(usage); return 2 }
        guard let c = daemon.connect() else { fail("liberttyd isn't running"); return ExitCode.unreachable }
        let start = Date()
        if let timeout { c.setReceiveTimeout(timeout) }
        // An older liberttyd would wait for the end whatever was asked.
        if until != "exit" {
            c.send(.hello, json: ["version": Wire.version, "client": "cli +wait"])
            guard let welcome = c.receive(), welcome.kind == .welcome else { return timedOut(start, timeout) ?? gone() }
            guard (welcome.json["features"] as? [String] ?? []).contains("waitUntil") else {
                fail("this liberttyd only waits for the end; restart Libertty to update it")
                return 1
            }
        }
        c.send(.wait, json: ["id": id, "until": until, "idleMs": idleMs])
        guard let frame = c.receive() else { return timedOut(start, timeout) ?? gone() }
        guard frame.json["ok"] as? Bool == true else {
            let error = frame.json["error"] as? String ?? "no such session"
            fail(error)
            return isMissing(error) ? ExitCode.notFound : ExitCode.failure
        }
        if frame.json["reached"] != nil { return 0 }
        return Int32(frame.json["status"] as? Int ?? 0)
    }

    /// 124 if the answer didn't come because the time ran out.
    private static func timedOut(_ start: Date, _ timeout: Double?) -> Int32? {
        guard let timeout, Date().timeIntervalSince(start) >= timeout - 0.05 else { return nil }
        return ExitCode.timeout
    }

    private static func gone() -> Int32 {
        fail("liberttyd went away")
        return ExitCode.unreachable
    }

    /// `+events [--filter KIND,...]`: what happens in the sessions, one JSON
    /// object a line, until interrupted.
    private static func events(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +events [ID] [--filter KIND,...] [--for STATE,...] [--once] [--timeout SECONDS]"
        var kinds: [String]?, states: Set<String>?, session: String?, once = false, timeout: Double?
        var i = 0
        func list(_ s: String) -> [String] {
            let parts: [String] = s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return parts.filter { !$0.isEmpty }
        }
        while i < args.count {
            let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--filter":
                guard let next else { fail(usage); return 2 }
                kinds = list(next)
                i += 2
            case "--for":
                // Programs' states (OSC 7501, an agent's hooks): status events in them.
                guard let next else { fail(usage); return 2 }
                var named: Set<String> = []
                for state in list(next) {
                    switch state {
                    case "waiting": named.insert("blocked")
                    case "failed": named.insert("error")
                    default: named.insert(state)
                    }
                }
                states = named
                i += 2
            case "--once":
                once = true
                i += 1
            case "--timeout":
                guard let next, let seconds = Double(next), seconds > 0 else { fail(usage); return 2 }
                timeout = seconds
                i += 2
            default:
                guard !a.hasPrefix("-"), session == nil else { fail(usage); return 2 }
                session = a
                i += 1
            }
        }
        if states != nil {
            var all: [String] = kinds ?? []
            if !all.contains("status") { all.append("status") }
            kinds = all
        }
        guard let c = daemon.connect() else { fail("liberttyd isn't running"); return ExitCode.unreachable }
        c.send(.hello, json: ["version": Wire.version, "client": "cli +events"])
        guard let welcome = c.receive(), welcome.kind == .welcome else { return gone() }
        guard (welcome.json["features"] as? [String] ?? []).contains("events") else {
            fail("this liberttyd has no events; restart Libertty to update it")
            return 1
        }
        var request: [String: Any] = [:]
        if let kinds { request["kinds"] = kinds }
        c.send(.events, json: request)
        guard let answer = c.receive(), answer.json["ok"] as? Bool == true else { return gone() }
        setvbuf(stdout, nil, _IOLBF, 0)
        let start = Date()
        while true {
            if let timeout {
                let left = timeout - Date().timeIntervalSince(start)
                guard left > 0 else { return ExitCode.timeout }
                c.setReceiveTimeout(left)
            }
            guard let frame = c.receive() else { return timedOut(start, timeout) ?? gone() }
            guard frame.kind == .event else { continue }
            if session != nil || states != nil {
                let event = frame.json
                if let session, (event["id"] as? String) != session { continue }
                if let states, event["event"] as? String == "status", !states.contains(event["state"] as? String ?? "") { continue }
                // A session ending is what a script waiting on it would want to know.
                if let session, event["event"] as? String == "session-ended", (event["id"] as? String) == session {
                    print(String(decoding: frame.payload, as: UTF8.self))
                    return once ? 1 : 0
                }
            }
            print(String(decoding: frame.payload, as: UTF8.self))
            if once { return 0 }
        }
    }

    /// `+prompt ID TEXT... [--quiet MS] [--timeout SECONDS] [-n LINES]`:
    /// another agent asked something (Kero's `prompt`): TEXT typed and
    /// Return pressed, then a wait until its screen has been quiet a while
    /// (an agent's spinner stops with its turn), then its screen's last lines.
    private static func prompt(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +prompt ID TEXT... [--quiet MS] [--timeout SECONDS] [-n LINES]"
        var words: [String] = [], quiet = 3000, timeout: Double?, lines = 40
        var i = 0
        while i < args.count {
            let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--quiet":
                guard let next, let ms = Int(next), ms > 0 else { fail(usage); return 2 }
                quiet = ms
                i += 2
            case "--timeout":
                guard let next, Double(next) != nil else { fail(usage); return 2 }
                timeout = Double(next)
                i += 2
            case "-n":
                guard let next, let n = Int(next), n > 0 else { fail(usage); return 2 }
                lines = n
                i += 2
            default:
                words.append(a)
                i += 1
            }
        }
        guard words.count >= 2 else { fail(usage); return 2 }
        let id = words[0], text = words.dropFirst().joined(separator: " ")
        let sent = status(DaemonClient.request(.send, json: ["id": id, "text": text], address: daemon))
        guard sent == ExitCode.ok else { return sent }
        // Return apart from the text: an agent's input takes text typed at once as a paste.
        usleep(300_000)
        switch DaemonClient.request(.sendKey, json: ["id": id, "keys": ["enter"]], needing: "sendKey", address: daemon) {
        case .answered: break
        case .unsupported: _ = DaemonClient.request(.send, json: ["id": id, "text": "\r"], address: daemon)
        case .unanswered: fail("liberttyd isn't running"); return ExitCode.unreachable
        }
        // Its answer starting: then quiet once it's over.
        usleep(800_000)
        var waitArgs: [String] = [id, "--until", "idle=" + String(quiet)]
        if let timeout { waitArgs += ["--timeout", String(timeout)] }
        let waited = waitSession(waitArgs)
        guard waited == 0 || waited == ExitCode.timeout else { return waited }
        let frame = DaemonClient.request(.capture, json: ["id": id, "scrollback": false, "format": "plain"], address: daemon)
        let captured = status(frame)
        guard captured == ExitCode.ok, let screen = frame?.json["text"] as? String else { return captured == 0 ? 1 : captured }
        var rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
        print(rows.suffix(lines).joined(separator: "\n"))
        return waited
    }

    private static func focusSession(_ args: [String]) -> Int32 {
        guard let id = args.first ?? ProcessInfo.processInfo.environment["LIBERTTY_SESSION"] else {
            fail("usage: libertty +focus ID")
            return 2
        }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        switch RemoteControl.request(["kind": "focus", "id": id], timeout: 5)?["result"] {
        case "focused": return 0
        case "no-pane":
            fail("no window shows session \(id) (libertty +list-sessions; +attach \(id) shows one)")
            return ExitCode.notFound
        case "refused":
            fail("remote-control = false: Libertty doesn't let commands drive it")
            return 1
        default:
            fail("Libertty didn't answer (one older than this command?)")
            return ExitCode.unreachable
        }
    }

    private static func killSession(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +kill-session ID [--remove-worktree [--force]]"
        let removing = args.contains("--remove-worktree"), force = args.contains("--force")
        let rest = args.filter { $0 != "--remove-worktree" && $0 != "--force" }
        guard rest.count == 1, let id = rest.first, force ? removing : true else { fail(usage); return 2 }
        // Its worktree, found before the session (and what it says of its folder) goes.
        var worktree: WorktreeInfo?
        if removing {
            guard host == nil else { fail("--remove-worktree is for this Mac's sessions"); return 2 }
            let info = DaemonClient.sessions(address: daemon)?.first { $0.id == id }
            guard let dir = info.flatMap({ SessionInfo.directory(fromPwd: $0.workingDirectory) }), let w = Worktrees.linked(at: dir) else {
                fail("session \(id) isn't in a git worktree of its own")
                return 1
            }
            if !force, Worktrees.uncommitted(w.path) > 0 {
                fail("\(w.path) has uncommitted changes; --force removes them too")
                return 1
            }
            worktree = w
        }
        let killed = status(DaemonClient.request(.kill, json: ["id": id], address: daemon))
        guard killed == ExitCode.ok else { return killed }
        guard let worktree else { return 0 }
        usleep(500_000)  // its programs let go of the folder
        if case .failure(let why) = Worktrees.remove(worktree, force: force) { fail(why.message); return 1 }
        print("removed \(worktree.path)")
        return 0
    }

    private static func renderDiff(_ args: [String]) -> Int32 {
        guard let path = args.first, let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        else { fail("usage: libertty +render-diff FILE"); return 2 }
        print(DiffRenderer.html(text), terminator: "")
        return 0
    }

    private static func renderMarkdown(_ args: [String]) -> Int32 {
        guard let path = args.first, let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        else { fail("usage: libertty +render-markdown FILE"); return 2 }
        var renderer = MarkdownRenderer { code, lang in Highlighter.html(code, language: lang) }
        print(renderer.render(text), terminator: "")
        return 0
    }

    /// `libertty +diff [GIT DIFF ARGS]`: this repository's changes, rendered
    /// beside the terminal (again: refreshed).
    private static func diff(_ args: [String]) -> Int32 {
        var args = args
        let here = FileManager.default.currentDirectoryPath
        // Since an agent's last turn began here, or since the branch left the
        // default one (Last Turn, Branch): to the working tree as it is, new files too.
        var name: String?
        if let flag = args.first(where: { $0 == "--turn" || $0 == "--branch" }) {
            args.removeAll { $0 == flag }
            guard let root = GitCLI.root(of: here) else { fail("not a git repository"); return 1 }
            let base: String
            if flag == "--turn" {
                guard let turn = Turns.last(root: root) else { fail("no agent has started a turn in \(root) yet"); return 1 }
                base = turn.tree
            } else {
                guard let (commit, _) = WorkTree.branchBase(root: root) else { fail("no default branch to compare with"); return 1 }
                base = commit
            }
            guard let now = WorkTree.snapshot(root: root) else { fail("couldn't read the working tree"); return 1 }
            args = ["-M", base, now] + args
            name = flag.dropFirst(2) + ""
        }
        switch GitDiff.write(directory: here, arguments: args, name: name) {
        case .failure(let why):
            fail(why.message)
            return 1
        case .success(let file):
            guard liberttyRunning else { fail("Libertty isn't running (the diff is in \(file.path))"); return 1 }
            let title = name.map { $0 == "turn" ? "Last turn" : "Since the default branch" } ?? (["git diff"] + args).joined(separator: " ")
            RemoteControl.post(["kind": "open", "path": file.path, "line": "", "split": "1", "name": title])
            return 0
        }
    }

    /// `libertty +connect HOST`: a window on HOST (File ▸ Connect to Host…).
    private static func connect(_ args: [String]) -> Int32 {
        guard let host = args.first, !host.hasPrefix("-") else { fail("usage: libertty +connect HOST"); return 2 }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        RemoteControl.post(["kind": "connect", "host": host])
        return 0
    }

    private static func openFiles(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +open [--split] [--edit] [--wait] FILE[:LINE]..."
        let beside = args.contains("--split")
        // --wait (as EDITOR): in the editor, and back only once it's closed.
        let wait = args.contains("--wait")
        let edit = wait || args.contains("--edit")
        let args = args.filter { !["--split", "--edit", "--wait"].contains($0) }
        guard !args.isEmpty, !args.contains(where: { $0.hasPrefix("--") }) else { fail(usage); return 2 }
        var status: Int32 = 0
        let running = liberttyRunning
        var launchArguments: [String] = []
        var waiting: Set<String> = []
        // Listening before asking: a refusal can come back at once.
        let waiter = wait ? EditorWaiter() : nil
        func request(_ path: String, line: Int?) {
            var info = ["kind": "open", "path": path, "line": line.map(String.init) ?? "", "split": beside ? "1" : "0"]
            var token = ""
            if wait {
                token = UUID().uuidString
                waiting.insert(token)
            }
            if edit {
                info["edit"] = "1"
                info["wait"] = token
            }
            if running {
                RemoteControl.post(info)
            } else {
                launchArguments += ["--open-document", path, info["line"]!, info["split"]!]
                if edit { launchArguments += ["edit=1", "wait=" + token] }
            }
        }
        for var arg in args {
            if arg.hasPrefix("http://") || arg.hasPrefix("https://") {
                // A web page (a dev server): in a tab, or beside the terminal.
                guard !edit else { fail("\(arg): a web page can't be edited"); status = 1; continue }
                guard URL(string: arg) != nil else { fail("\(arg): not a URL"); status = 1; continue }
                request(arg, line: nil)
                continue
            }
            // FILE:LINE (as compilers print it) opens at that line.
            var line: Int?
            if !FileManager.default.fileExists(atPath: (arg as NSString).expandingTildeInPath),
               let colon = arg.lastIndex(of: ":"), let n = Int(arg[arg.index(after: colon)...]) {
                line = n
                arg = String(arg[..<colon])
            }
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { fail("\(arg): no such file"); status = 1; continue }
            if edit {
                guard EditorAssets.canEdit(url) else { fail("\(arg): not a text file (or over 5 MB)"); status = 1; continue }
            } else {
                guard DocumentView.canShow(url) else { fail("\(arg): not a text file Libertty shows"); status = 1; continue }
            }
            request(url.path, line: line)
        }
        if !launchArguments.isEmpty {
            // Launch with the requests; the app handles them once its windows are up.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : "Libertty", "--args"] + launchArguments
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 { fail("couldn't start Libertty"); status = 1 }
            } catch {
                fail("couldn't start Libertty: \(error.localizedDescription)")
                status = 1
            }
        }
        // The files that did open are waited for, even if others didn't.
        guard let waiter, !waiting.isEmpty else { return status }
        let waited = waiter.wait(for: waiting, running: { liberttyRunning })
        return status != 0 ? status : waited
    }

    /// `libertty +browser OP …`: one request to the running app; its answer
    /// comes back in a private file, announced by a notification.
    private static func browser(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +browser open [--split] URL | go URL | back | forward | reload | url | text | html | eval JS | click SELECTOR | type SELECTOR TEXT | screenshot FILE"
        guard let op = args.first else { fail(usage); return 2 }
        var rest = Array(args.dropFirst())
        let split = rest.contains("--split")
        rest.removeAll { $0 == "--split" }
        var info = ["kind": "browser", "op": op, "split": split ? "1" : "0"]
        switch op {
        case "open": info["arg"] = rest.first ?? ""
        case "go", "eval", "click":
            guard let arg = rest.first, rest.count == 1 else { fail(usage); return 2 }
            info["arg"] = arg
        case "type":
            guard rest.count == 2 else { fail(usage); return 2 }
            info["arg"] = rest[0] + "\u{1f}" + rest[1]
        case "screenshot":
            guard let file = rest.first else { fail(usage); return 2 }
            info["file"] = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL.path
        case "back", "forward", "reload", "url", "text", "html":
            guard rest.isEmpty else { fail(usage); return 2 }
        default:
            fail(usage)
            return 2
        }
        guard liberttyRunning else { fail("Libertty isn't running"); return ExitCode.unreachable }
        let token = UUID().uuidString
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-browser-\(token)")
        info["token"] = token
        info["out"] = out.path
        var answer: Bool?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: BrowserAutomation.replied, object: nil, queue: .main) { note in
            guard note.userInfo?["token"] as? String == token else { return }
            answer = note.userInfo?["ok"] as? String == "1"
        }
        defer {
            center.removeObserver(observer)
            try? FileManager.default.removeItem(at: out)
        }
        RemoteControl.post(info)
        let deadline = Date().addingTimeInterval(30)
        while answer == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let ok = answer else { fail("no answer from Libertty"); return ExitCode.unreachable }
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        if ok {
            if !text.isEmpty { print(text) }
            return 0
        }
        fail(text.isEmpty ? "\(op) failed" : text)
        return 1
    }

    private static func newWindow(_ args: [String], tab: Bool) -> Int32 {
        var info = ["kind": "new-window", "tab": tab ? "1" : "0"]
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--cwd", "--working-directory":
                guard i + 1 < args.count else { fail("--cwd needs a directory"); return 2 }
                info["cwd"] = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath).standardizedFileURL.path
                i += 2
            case "-e":
                info["command"] = args[(i + 1)...].joined(separator: " ")
                i = args.count
            default:
                fail("unknown option \(args[i])")
                return 2
            }
        }
        if info["cwd"] == nil { info["cwd"] = FileManager.default.currentDirectoryPath }
        guard liberttyRunning else {
            // Not running: start it; the first window then runs the command.
            var launch = ["-a", Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : "Libertty"]
            if let command = info["command"] { launch += ["--args", "-e", command] }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = launch
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        RemoteControl.post(info)
        return 0
    }
}

/// `+open --wait`: hears the editors it asked for close (EditorWait).
private final class EditorWaiter {
    private var closed: Set<String> = []
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: EditorWait.closed, object: nil, queue: .main) { [weak self] note in
            if let token = note.userInfo?["token"] as? String { self?.closed.insert(token) }
        }
    }

    deinit { observer.map(DistributedNotificationCenter.default().removeObserver) }

    /// Until every one of `tokens` has closed (0), or Libertty is gone (1).
    /// A launch takes a moment to show up as running; after that, its going
    /// away (a crash, a force quit) ends the wait too.
    func wait(for tokens: Set<String>, running: () -> Bool) -> Int32 {
        let start = Date()
        var seen = false
        while !tokens.isSubset(of: closed) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if running() { seen = true } else if seen || Date().timeIntervalSince(start) > 20 {
                FileHandle.standardError.write(Data("libertty: Libertty quit before the editor closed\n".utf8))
                return 1
            }
        }
        return 0
    }
}
