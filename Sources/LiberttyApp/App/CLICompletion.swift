import AppKit
import LiberttyCore

/// The command line's shape: every `+command`, what it says it does, its
/// flags and what its arguments are. `+complete` reads it to complete a
/// command line for the shells (`+completions`), and an unknown command is
/// one that isn't here.
enum CLISpec {
    /// What an argument (or a flag's value) is, for completing it.
    indirect enum Kind: Equatable {
        case session, action, theme, configKey, configAssignment, conversation, host, key, shell
        case file, directory, number, text
        /// One of these words.
        case choice([String])
        /// Comma-separated words from the list (`--for working,waiting`).
        case list([String])
        /// A command and its arguments (`-e COMMAND...`): the rest of the line.
        case command
    }

    struct Flag {
        var name: String
        var value: Kind?
        var doc: String
        var repeatable = false
        init(_ name: String, _ value: Kind? = nil, _ doc: String = "", repeatable: Bool = false) {
            self.name = name
            self.value = value
            self.doc = doc
            self.repeatable = repeatable
        }
    }

    struct Command {
        var name: String
        var aliases: [String] = []
        var summary: String
        var flags: [Flag] = []
        /// The positional arguments in order; the last one repeats when `repeats`.
        var arguments: [Kind] = []
        var repeats = false
        /// Not offered for completion (an internal command, an old spelling).
        var hidden = false
        /// Takes `--host HOST` (another machine's liberttyd).
        var hostable = false
    }

    static let states = ["idle", "working", "blocked", "waiting", "done", "error", "failed"]
    static let eventKinds = ["session-started", "session-ended", "command-started", "command-finished", "prompt", "title",
                             "directory", "label", "input-mode", "bell", "status"]
    static let browserOps = ["list", "open", "go", "back", "forward", "reload", "url", "title", "text", "html", "snapshot",
                             "eval", "click", "hover", "check", "uncheck", "type", "press", "select", "scroll", "wait",
                             "cookies", "screenshot"]
    static let daemonCommands = ["status", "stop", "restart", "logs"]
    static let directions: [Flag] = ["--right", "--left", "--down", "--up"].map { Flag($0) }

    static let commands: [Command] = [
        // Settings
        Command(name: "+help", aliases: ["+h"], summary: "what libertty can do"),
        Command(name: "+version", summary: "Libertty's version"),
        Command(name: "+set", summary: "change settings (KEY=VALUE...)", arguments: [.configAssignment], repeats: true),
        Command(name: "+unset", summary: "a setting back to its default", arguments: [.configKey]),
        Command(name: "+get", summary: "a setting's effective value", arguments: [.configKey]),
        Command(name: "+show-config", summary: "every effective setting",
                flags: [Flag("--default", nil, "the defaults"), Flag("--docs", nil, "with each one's help"),
                        Flag("--changes", nil, "only what differs from the defaults"), Flag("--keybinds", nil, "and the keybinds")]),
        Command(name: "+validate-config", summary: "check the config file", flags: [Flag("--config-file", .file, "another file")]),
        Command(name: "+edit-config", summary: "open the config file in $EDITOR"),
        Command(name: "+import-ghostty", summary: "Ghostty's settings into Libertty's config",
                flags: [Flag("--from", .file, "Ghostty's config file"), Flag("--dry-run", nil, "only say what it would add"),
                        Flag("--yes", nil, "don't ask")]),
        Command(name: "+migrate-prompt", summary: "a prompt for an agent to bring your keybindings over",
                flags: [Flag("--from", .choice(["ghostty", "iterm2", "tmux"]), "where from", repeatable: true)]),
        Command(name: "+update", summary: "install the newest version", flags: [Flag("--check", nil, "only report")]),
        Command(name: "+completions", summary: "the completion script for a shell", arguments: [.shell]),
        Command(name: "+complete", summary: "complete a command line (for the shells)", hidden: true),
        Command(name: "+list-themes", summary: "the themes",
                flags: [Flag("--path", nil, "where each one is"), Flag("--plain", nil, "without swatches")]),
        Command(name: "+list-fonts", summary: "monospaced font families", flags: [Flag("--styles", nil, "with their faces")]),
        Command(name: "+list-keybinds", summary: "the keybinds", flags: [Flag("--default", nil, "the defaults")]),
        Command(name: "+list-actions", summary: "what keybinds and +action can do"),
        // The running app
        Command(name: "+action", summary: "do an action in the running Libertty", arguments: [.action]),
        Command(name: "+new-window", summary: "a new window",
                flags: [Flag("--cwd", .directory, "start there"), Flag("-e", .command, "run a command")]),
        Command(name: "+new-tab", summary: "a new tab",
                flags: [Flag("--cwd", .directory, "start there"), Flag("-e", .command, "run a command")]),
        Command(name: "+open", summary: "show or edit files (FILE[:LINE]) or a web page",
                flags: [Flag("--split", nil, "beside the focused terminal"), Flag("--edit", nil, "in the editor"),
                        Flag("--wait", nil, "until it's closed (EDITOR)")],
                arguments: [.file], repeats: true),
        Command(name: "+browser", summary: "the browser block",
                flags: [Flag("--split", nil, "beside the terminal"), Flag("--tab", nil, "in a tab of its own"),
                        Flag("--pane", .text), Flag("--beside", .session), Flag("--no-focus", nil, "the keyboard stays"),
                        Flag("--ref", .text), Flag("--enter", nil, "then Return"), Flag("--timeout", .number),
                        Flag("--interactive", nil, "only what can be acted on"), Flag("--json")],
                arguments: [.choice(browserOps), .text], repeats: true),
        Command(name: "+render-markdown", summary: "the HTML Libertty renders for a Markdown file", arguments: [.file]),
        Command(name: "+render-diff", summary: "the HTML Libertty renders for a diff", arguments: [.file], hidden: true),
        Command(name: "+diff", summary: "this repository's changes beside the terminal",
                flags: [Flag("--turn", nil, "what an agent changed in its last turn"), Flag("--branch", nil, "since the default branch")]),
        Command(name: "+connect", summary: "a window on another machine", arguments: [.host]),
        // Sessions
        Command(name: "+list-sessions", summary: "every session", flags: [Flag("--json")], hostable: true),
        Command(name: "+list-panes", summary: "the running Libertty's panes"),
        Command(name: "+new-session", summary: "a session without a window",
                flags: [Flag("--cwd", .directory, "start there"), Flag("--worktree", .text, "in a git worktree on this new branch"),
                        Flag("--base", .text, "the worktree's branch starts here"), Flag("-e", .command, "run a command")],
                hostable: true),
        Command(name: "+capture", summary: "print a session's screen",
                flags: [Flag("--scrollback", nil, "and its history"), Flag("--ansi", nil, "with colors as escapes"),
                        Flag("--html", nil, "as a web page")],
                arguments: [.session], hostable: true),
        Command(name: "+send", summary: "type into a session (\\n for Return)",
                flags: [Flag("--enter", nil, "then press Return")], arguments: [.session, .text], repeats: true, hostable: true),
        Command(name: "+send-key", summary: "press keys in a session", arguments: [.session, .key], repeats: true, hostable: true),
        Command(name: "+kill-session", summary: "end a session's program",
                flags: [Flag("--remove-worktree", nil, "and remove its worktree"), Flag("--force", nil, "even with uncommitted changes")],
                arguments: [.session], hostable: true),
        Command(name: "+attach", summary: "show a session in a tab", flags: [Flag("--window", nil, "in a window")],
                arguments: [.session]),
        Command(name: "+wait", summary: "until a session's program ends, it's at a prompt, or quiet",
                flags: [Flag("--until", .choice(["exit", "prompt", "idle="]), "what to wait for"),
                        Flag("--timeout", .number, "seconds, then 124")],
                arguments: [.session], hostable: true),
        Command(name: "+events", summary: "what happens in the sessions, a JSON object a line",
                flags: [Flag("--filter", .list(eventKinds), "these kinds"), Flag("--for", .list(states), "status events in these states"),
                        Flag("--once", nil, "the first, then exit"), Flag("--timeout", .number, "seconds, then 124")],
                arguments: [.session], hostable: true),
        Command(name: "+prompt", summary: "ask another agent and print its answer",
                flags: [Flag("--quiet", .number, "ms of quiet that end the answer"), Flag("--timeout", .number, "seconds"),
                        Flag("-n", .number, "lines to print")],
                arguments: [.session, .text], repeats: true),
        Command(name: "+focus", summary: "bring the pane showing a session to the front", arguments: [.session]),
        Command(name: "+rename-session", summary: "name a session", arguments: [.session, .text]),
        Command(name: "+history", summary: "coding agents' conversations",
                flags: [Flag("-n", .number, "how many"), Flag("--json")], arguments: [.text]),
        Command(name: "+resume", summary: "pick a conversation up again", arguments: [.conversation]),
        Command(name: "+split", summary: "a new pane beside a session's",
                flags: directions + [Flag("--ratio", .number, "the new pane's share, percent"), Flag("--cwd", .directory, "start there"),
                                     Flag("--no-focus", nil, "keep the keyboard where it is"),
                                     Flag("--keep-open", nil, "keep it when its program ends"), Flag("-e", .command, "run a command")],
                arguments: [.session], hostable: true),
        Command(name: "+move-pane", summary: "move a session's pane",
                flags: directions + [Flag("--new-tab"), Flag("--tab", .number, "tab N of its window"), Flag("--new-window"),
                                     Flag("--beside", .session, "beside that session's pane")],
                arguments: [.session], hostable: true),
        Command(name: "+swap-pane", summary: "two panes trade places", arguments: [.session, .session]),
        Command(name: "+resize-pane", summary: "move a pane's divider",
                flags: directions.map { Flag($0.name, .number, "points") } + [Flag("--equalize", nil, "even out its split")],
                arguments: [.session]),
        Command(name: "+daemon", summary: "liberttyd: status, stop, restart, logs",
                flags: [Flag("--json", nil, "status as JSON"), Flag("--if-idle", nil, "stop only without sessions"),
                        Flag("--force", nil, "stop even with sessions (ends them)"), Flag("-f", nil, "logs: follow"),
                        Flag("--lines", .number, "logs: how many lines")],
                arguments: [.choice(daemonCommands)], hostable: true),
        Command(name: "+clients", summary: "who is connected to liberttyd", flags: [Flag("--json")], hostable: true),
        // Programs and agents
        Command(name: "+status", summary: "report what a program is doing (OSC 7501)",
                flags: [Flag("--app", .text), Flag("--title", .text), Flag("--message", .text),
                        Flag("--kind", .choice(["permission", "question", "auth"])), Flag("--progress", .number), Flag("--id", .text)],
                arguments: [.choice(["idle", "working", "blocked", "done", "error", "clear"])]),
        Command(name: "+agent-hook", summary: "a coding agent's hook", hidden: true),
        Command(name: "+agents", summary: "the coding agents whose screens Libertty reads, yours too",
                flags: [Flag("--check", nil, "what of yours can't be read")]),
        Command(name: "+agent-setup", summary: "hooks and skills for coding agents",
                flags: [Flag("--agent", .choice(["claude", "codex", "pi", "omp", "opencode", "all"])),
                        Flag("--claude-dir", .directory), Flag("--codex-dir", .directory), Flag("--remove", nil, "take them out"),
                        Flag("--dry-run", nil, "only say what it would change"), Flag("--yes", nil, "don't ask")]),
    ]

    static func command(named name: String) -> Command? {
        commands.first { $0.name == name || $0.aliases.contains(name) }
    }

    // MARK: Completing

    /// A word the shell may put in, and what it says.
    struct Candidate: Equatable {
        var value: String
        var doc = ""
    }

    /// What the shell should do besides offering the candidates.
    enum Directive: String {
        /// Complete file names (as the shell does).
        case files
        /// Directories only.
        case dirs
        /// A command name (the shell's own completion for commands).
        case commands
        /// No space after the word (`key=` waits for a value).
        case nospace
    }

    struct Completion: Equatable {
        var candidates: [Candidate] = []
        var directives: [Directive] = []
    }

    /// Where the dynamic candidates come from: the running liberttyd, the
    /// config, the themes… (a test hands in its own).
    struct Sources {
        var sessions: () -> [Candidate]
        var actions: () -> [Candidate]
        var themes: () -> [Candidate]
        var configKeys: () -> [Candidate]
        var configValues: (String) -> [Candidate]
        var conversations: () -> [Candidate]
        var hosts: () -> [Candidate]
        var keys: () -> [Candidate]
    }

    /// The completions for `words` — what follows `libertty` on the line,
    /// the last one being the word under the cursor ("" for a new one).
    static func complete(_ words: [String], sources: Sources) -> Completion {
        guard let current = words.last else { return Completion() }
        if words.count == 1 {
            let list = commands.filter { !$0.hidden }.map { Candidate(value: $0.name, doc: $0.summary) }
            return Completion(candidates: list.filter { $0.value.hasPrefix(current) || !current.hasPrefix("+") })
        }
        guard let spec = command(named: words[0]) else { return Completion() }
        var flags = spec.flags
        if spec.hostable { flags.append(Flag("--host", .host, "that machine's liberttyd")) }
        // Read what comes before the current word.
        var used: Set<String> = []
        var position = 0
        var pending: Kind?
        var hasHost = false
        for word in words.dropFirst().dropLast() {
            // `-e COMMAND ARGS...`: past the command, its own arguments (files, as a shell would have it).
            if pending == .command { return Completion(directives: [.files]) }
            if pending != nil { pending = nil; continue }
            if let flag = flags.first(where: { $0.name == word }) {
                used.insert(flag.name)
                if flag.name == "--host" { hasHost = true }
                pending = flag.value
                continue
            }
            if word.hasPrefix("-"), word.count > 1 { continue }
            position += 1
        }
        if let pending { return values(of: pending, current, sources: sources, remote: hasHost) }
        if current.hasPrefix("-") {
            let open = flags.filter { $0.repeatable || !used.contains($0.name) }
            return Completion(candidates: open.filter { $0.name.hasPrefix(current) }.map { Candidate(value: $0.name, doc: $0.doc) })
        }
        let kind: Kind? = position < spec.arguments.count ? spec.arguments[position] : (spec.repeats ? spec.arguments.last : nil)
        guard let kind else {
            // No more arguments: what flags are left.
            let open = flags.filter { $0.repeatable || !used.contains($0.name) }
            return Completion(candidates: open.map { Candidate(value: $0.name, doc: $0.doc) })
        }
        return values(of: kind, current, sources: sources, remote: hasHost)
    }

    private static func values(of kind: Kind, _ current: String, sources: Sources, remote: Bool) -> Completion {
        switch kind {
        case .session:
            // Another machine's sessions would mean a link per keystroke.
            return Completion(candidates: remote ? [] : sources.sessions())
        case .action: return Completion(candidates: sources.actions())
        case .theme: return Completion(candidates: sources.themes())
        case .configKey: return Completion(candidates: sources.configKeys())
        case .configAssignment:
            if let eq = current.firstIndex(of: "=") {
                let key = String(current[..<eq])
                return Completion(candidates: sources.configValues(key).map { Candidate(value: key + "=" + $0.value, doc: $0.doc) })
            }
            return Completion(candidates: sources.configKeys().map { Candidate(value: $0.value + "=", doc: $0.doc) },
                              directives: [.nospace])
        case .conversation: return Completion(candidates: sources.conversations())
        case .host: return Completion(candidates: sources.hosts())
        case .key: return Completion(candidates: sources.keys())
        case .shell: return Completion(candidates: ["zsh", "bash", "fish"].map { Candidate(value: $0) })
        case .file: return Completion(directives: [.files])
        case .directory: return Completion(directives: [.dirs])
        case .number, .text: return Completion()
        case .command: return Completion(directives: [.commands])
        case .choice(let words):
            let list = words.sorted().map { Candidate(value: $0) }
            // `idle=` waits for its number.
            return Completion(candidates: list, directives: list.contains { $0.value.hasSuffix("=") } ? [.nospace] : [])
        case .list(let words):
            // After the last comma: the words not given yet, behind what's there.
            let parts = current.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let head = parts.dropLast().joined(separator: ",")
            let given = Set(parts.dropLast())
            let prefix = head.isEmpty ? "" : head + ","
            return Completion(candidates: words.filter { !given.contains($0) }.map { Candidate(value: prefix + $0) })
        }
    }

    /// The shell's lines: `value<TAB>doc`, then `:directive` lines.
    static func lines(_ completion: Completion, shell: String, current: String) -> [String] {
        var out: [String] = []
        for c in completion.candidates {
            // bash filters nothing itself: only what fits what's typed.
            if shell == "bash", !c.value.hasPrefix(current) { continue }
            let doc = c.doc.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            out.append(doc.isEmpty || shell == "bash" ? c.value : c.value + "\t" + doc)
        }
        out += completion.directives.map { ":" + $0.rawValue }
        return out
    }

    /// The candidates from this Mac: its liberttyd, config, themes, hosts.
    static var liveSources: Sources {
        Sources(
            sessions: {
                (DaemonClient.sessions() ?? []).map { s in
                    let dir = SessionInfo.directory(fromPwd: s.workingDirectory).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
                    let what = [s.label ?? "", (s.command.split(separator: " ").first.map(String.init) ?? ""), dir]
                        .filter { !$0.isEmpty }.joined(separator: "  ")
                    return Candidate(value: s.id, doc: what)
                }
            },
            actions: {
                var out: [Candidate] = []
                for (name, doc) in Action.catalog {
                    for spelled in Self.spellings(of: name) {
                        // `text:` and the like read with something after the colon.
                        let probe = spelled.hasSuffix(":") ? spelled + "1" : spelled
                        if let action = Action(probe), !ActionDispatcher.allowedRemotely(action) { continue }
                        out.append(Candidate(value: spelled, doc: doc))
                    }
                }
                return out
            },
            themes: {
                var names = Theme.all.map(\.name)
                let have = Set(names.map { $0.lowercased() })
                names += ThemeLibrary.shared.entries.map(\.name).filter { !have.contains($0.lowercased()) }
                return names.map { Candidate(value: $0) }
            },
            configKeys: {
                Config.documentation.filter { $0.key != "config-file" }.map { Candidate(value: $0.key, doc: firstSentence($0.doc)) }
            },
            configValues: { key in
                if key == "theme" {
                    return Theme.all.map { Candidate(value: $0.name) }
                        + ThemeLibrary.shared.entries.map { Candidate(value: $0.name) }
                }
                guard let item = SettingsRegistry.items.first(where: { $0.key == key && $0.keys.count == 1 }) else { return [] }
                if case .toggle(let on, let off) = item.kind { return [Candidate(value: on), Candidate(value: off)] }
                return item.options.map { Candidate(value: $0.value, doc: $0.label) }
            },
            conversations: {
                Conversations.load().prefix(50).map { Candidate(value: String($0.id.prefix(8)), doc: $0.agentName + "  " + $0.label) }
            },
            hosts: {
                let recent = MainActor.assumeIsolated { ConnectPanel.recentHosts }
                return (recent + SSHConfig.hosts().filter { !recent.contains($0) }).map { Candidate(value: $0) }
            },
            keys: {
                KeySpec.namedKeys.map { Candidate(value: $0) }
                    + ["ctrl+", "alt+", "shift+", "super+"].map { Candidate(value: $0, doc: "with a key") }
            })
    }

    /// `new_split:right|down` is new_split:right and new_split:down;
    /// `goto_tab:N` is goto_tab: (the number is yours).
    static func spellings(of name: String) -> [String] {
        guard let colon = name.firstIndex(of: ":") else { return [name] }
        let base = String(name[...colon]), parameter = name[name.index(after: colon)...]
        if parameter.contains("|") { return parameter.split(separator: "|").map { base + $0 } }
        return [base]
    }

    private static func firstSentence(_ doc: String) -> String {
        let end = doc.range(of: ". ").map { doc[..<$0.lowerBound] } ?? Substring(doc)
        return end.count > 90 ? String(end.prefix(87)) + "…" : String(end)
    }
}

extension CLI {
    /// `+complete SHELL -- WORD...`: what the shell may complete the last
    /// word to (the completion scripts call it at each Tab).
    static func complete(_ args: [String]) -> Int32 {
        guard let shell = args.first, let dashes = args.firstIndex(of: "--") else {
            fail("usage: libertty +complete zsh|bash|fish -- WORD...")
            return ExitCode.usage
        }
        let words = Array(args[(dashes + 1)...])
        let completion = CLISpec.complete(words.isEmpty ? [""] : words, sources: CLISpec.liveSources)
        for line in CLISpec.lines(completion, shell: shell, current: words.last ?? "") { print(line) }
        return ExitCode.ok
    }

    /// `+completions zsh|bash|fish`: the script that has the shell complete
    /// `libertty` (Libertty's shell integration loads it by itself).
    static func completions(_ args: [String]) -> Int32 {
        let files = ["zsh": "shell-integration/zsh/completions/_libertty",
                     "bash": "shell-integration/bash/libertty-completion.bash",
                     "fish": "shell-integration/fish/fish/vendor_completions.d/libertty.fish"]
        guard args.count == 1, let path = files[args[0]] else {
            fail("usage: libertty +completions zsh|bash|fish")
            return ExitCode.usage
        }
        guard let url = AppResources.url(path), let text = try? String(contentsOf: url, encoding: .utf8) else {
            fail("no \(args[0]) completion in this build of Libertty")
            return ExitCode.failure
        }
        print(text, terminator: "")
        return ExitCode.ok
    }
}
