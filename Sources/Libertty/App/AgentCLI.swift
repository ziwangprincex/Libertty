import Foundation
import LiberttyCore

/// Coding agents in Libertty (after Rex). `+status` reports what a program
/// is doing to the terminal it runs in (OSC 7501); `+agent-hook` is what
/// Claude Code's hooks run, so its tab says whether it's working, waiting
/// for you or done; `+agent-setup` installs those hooks and a skill that
/// tells it about Libertty's command line.
enum AgentCLI {
    private static func fail(_ message: String) {
        fflush(stdout)  // after what was printed before it
        FileHandle.standardError.write(Data("libertty: \(message)\n".utf8))
    }

    // MARK: +status

    /// `+status STATE [--app NAME] [--title TEXT] [--message TEXT] [--kind KIND]
    /// [--progress N] [--id ID]`, or `+status clear [--id ID]`: an OSC 7501
    /// report, written to this process's terminal.
    static func status(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +status idle|working|blocked|done|error|clear [--app NAME] [--title TEXT] "
            + "[--message TEXT] [--kind permission|question|auth] [--progress 0-100] [--id ID]"
        guard let first = args.first, !first.hasPrefix("-") else { fail(usage); return 2 }
        var report = Report(state: first)
        var i = 1
        while i < args.count {
            guard i + 1 < args.count else { fail(usage); return 2 }
            let value = args[i + 1]
            switch args[i] {
            case "--app": report.app = value
            case "--title": report.title = value
            case "--message": report.message = value
            case "--kind": report.kind = value
            case "--progress": report.progress = value
            case "--id": report.id = value
            default: fail(usage); return 2
            }
            i += 2
        }
        switch report.sequence() {
        case .failure(let why): fail(why.message); return 2
        case .success(let sequence): return write(sequence) ? 0 : 1
        }
    }

    struct Problem: Error { var message: String }

    /// One OSC 7501 report, checked against the specification's rules so the
    /// terminal doesn't throw it away (vendor/ghostty/src/terminal/osc/parsers/program_status.zig).
    struct Report {
        var state: String
        var app = ""
        var title = ""
        var message = ""
        var kind = ""
        var progress = ""
        var id = ""

        private static let nameBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-")

        private static func isName(_ s: String, max: Int) -> Bool {
            !s.isEmpty && s.utf8.count <= max && s.allSatisfy(nameBytes.contains)
        }

        /// Text for people: one line without control characters, cut to
        /// `limit` bytes of UTF-8 (on a character boundary).
        private static func text(_ s: String, limit: Int) -> String {
            let visible = String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == "\n" || $0 == "\t" ? " " : $0 }
                .filter { !$0.properties.generalCategory.isControlOrFormat }))
            var line = "", bytes = 0
            for character in visible {
                bytes += character.utf8.count
                if bytes > limit { break }
                line.append(character)
            }
            return line
        }

        func sequence() -> Result<String, Problem> {
            let names = ["idle", "working", "blocked", "done", "error", "clear"]
            let state = ProgramStatusStore.State(name: self.state)?.name ?? self.state.lowercased()
            guard names.contains(state) else { return .failure(Problem(message: "unknown state \(self.state) (\(names.joined(separator: ", ")))")) }
            var pairs = ["state=\(state)"]
            if !id.isEmpty {
                let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard id.utf8.count <= 128, parts.count <= 8, parts.allSatisfy({ Self.isName($0, max: 32) }) else {
                    return .failure(Problem(message: "an id is up to 8 names joined by /, each of letters, digits and _.+-"))
                }
                pairs.append("id=\(id)")
            }
            guard state != "clear" else { return .success(Self.osc(pairs)) }
            if !app.isEmpty {
                guard Self.isName(app, max: 32) else { return .failure(Problem(message: "--app is up to 32 letters, digits and _.+-")) }
                pairs.append("app=\(app)")
            }
            if !kind.isEmpty {
                guard ["permission", "question", "auth"].contains(kind) else { return .failure(Problem(message: "--kind is permission, question or auth")) }
                pairs.append("kind=\(kind)")
            }
            if !progress.isEmpty {
                guard let n = Int(progress), (0...100).contains(n) else { return .failure(Problem(message: "--progress is 0 to 100")) }
                pairs.append("progress=\(n)")
            }
            let title = Self.text(title, limit: 192), message = Self.text(message, limit: 2048)
            if !title.isEmpty { pairs.append("title=" + Data(title.utf8).base64EncodedString()) }
            if !message.isEmpty { pairs.append("msg=" + Data(message.utf8).base64EncodedString()) }
            return .success(Self.osc(pairs))
        }

        private static func osc(_ pairs: [String]) -> String { "\u{1b}]7501;" + pairs.joined(separator: ":") + "\u{1b}\\" }
    }

    /// To the terminal this runs in: /dev/tty, so a program whose output is
    /// captured (an agent's hook) still reaches it.
    private static func write(_ sequence: String) -> Bool {
        let fd = open("/dev/tty", O_WRONLY | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { fail("no terminal to report to"); return false }
        defer { close(fd) }
        let bytes = Array(sequence.utf8)
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    // MARK: +agent-hook

    /// The app name agents' reports carry (OSC 7501 `app`).
    private static let claudeApp = "claude-code"

    /// The record of a turn in progress (working, or waiting for you), apart
    /// from the agent's own (idle, done): a turn that ends without Stop — you
    /// pressed Esc, or said no to a tool — is cleared when the agent sits
    /// idle, without taking a `done` you haven't seen.
    private static let turn = "turn"

    /// `+agent-hook claude EVENT`, run by a Claude Code hook (`+agent-setup`)
    /// with the hook's JSON on stdin: what the agent does, as its pane's
    /// program status. Inside Libertty only; elsewhere it does nothing.
    static func hook(_ args: [String]) -> Int32 {
        guard args.count == 2, args[0] == "claude" else { fail("usage: libertty +agent-hook claude EVENT"); return 2 }
        guard ProcessInfo.processInfo.environment["TERM_PROGRAM"] == "Libertty" else { return 0 }
        func report(_ state: String, id: String = "", kind: String = "", message: String = "") -> String {
            var r = Report(state: state)
            r.app = claudeApp
            r.id = id
            r.kind = kind
            r.message = message
            guard case .success(let sequence) = r.sequence() else { return "" }
            return sequence
        }
        var reports: [String] = []
        switch args[1] {
        case "SessionStart":
            // What it hears at its start (a SessionStart hook's output is context).
            print(context())
            reports = [report("clear"), report("idle")]
        case "UserPromptSubmit", "PostToolUse":
            // At work: after your prompt, and again after a tool ran (once you
            // allowed it, when it had to ask).
            reports = [report("working", id: turn)]
        case "Notification":
            // Only this one reads its input: a tool's whole output comes with PostToolUse.
            let input = readInput()
            let message = input["message"] as? String ?? ""
            let type = input["notification_type"] as? String ?? ""
            if type == "permission_prompt" || (type.isEmpty && message.localizedCaseInsensitiveContains("permission")) {
                reports = [report("blocked", id: turn, kind: "permission", message: message)]
            } else if type == "elicitation_dialog" {
                reports = [report("blocked", id: turn, kind: "question", message: message)]
            } else if type == "idle_prompt" || (type.isEmpty && message.localizedCaseInsensitiveContains("waiting for your input")) {
                reports = [report("clear", id: turn)]  // the turn is over, however it ended
            } else if type != "auth_success", !message.isEmpty {
                reports = [report("blocked", id: turn, message: message)]
            }
        case "Stop":
            reports = [report("clear", id: turn), report("done")]
        case "SessionEnd":
            reports = [report("clear")]
        default:
            break
        }
        let sequence = reports.joined()
        if !sequence.isEmpty { _ = write(sequence) }
        return 0
    }

    /// The hook's JSON, at most a megabyte of it.
    private static func readInput() -> [String: Any] {
        guard isatty(STDIN_FILENO) == 0,
              let data = try? FileHandle.standardInput.read(upToCount: 1 << 20) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// What an agent starting in a pane is told.
    static func context() -> String {
        let session = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        var lines = [
            "You are running in Libertty, a macOS terminal"
                + (session.map { ", in the pane of session \($0) ($LIBERTTY_SESSION)" } ?? "") + ".",
            "The user may be looking at another pane, tab or window, not at this one.",
            "Libertty's command line (`libertty +help`) can list other terminal sessions, read their screens,"
                + " type into them, wait for them and start new ones, and show files, diffs and pages beside the terminal;"
                + " the libertty skill has the details.",
        ]
        if session != nil, ConfigStore.shared.config.agentSessionNames {
            lines.append("Once the task is clear, name this session after it with "
                + "`libertty +rename-session NAME`: two or three lowercase words joined by hyphens, like fix-login-redirect."
                + " Rename it only if the task changes.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: +agent-setup

    /// The Claude Code events Libertty's hook follows.
    static let hookedEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// What a hook runs: nothing outside Libertty, nothing that can fail the agent.
    static func hookCommand(_ event: String) -> String {
        "[ \"$TERM_PROGRAM\" = Libertty ] && command -v libertty >/dev/null && libertty +agent-hook claude \(event) || true"
    }

    private static func isOurs(_ entry: Any) -> Bool {
        guard let hooks = (entry as? [String: Any])?["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains("libertty +agent-hook") == true }
    }

    /// `settings` with Libertty's hooks (again, replacing any earlier ones),
    /// or without them; everything else as it was.
    static func settings(_ settings: [String: Any], installing: Bool) -> [String: Any] {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var touched = false
        for (event, value) in hooks {
            guard let entries = value as? [Any], entries.contains(where: isOurs) else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
            touched = true
        }
        if installing {
            for event in hookedEvents {
                let entry: [String: Any] = ["hooks": [["type": "command", "command": hookCommand(event), "timeout": 10]]]
                hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
            }
        }
        // Left as found when nothing of ours was there (even an empty "hooks").
        if installing || touched { result["hooks"] = hooks.isEmpty ? nil : hooks }
        return result
    }

    /// `+agent-setup [--claude-dir DIR] [--remove] [--dry-run] [--yes]`:
    /// Libertty's hooks in Claude Code's settings.json and its skill, after
    /// saying what changes (and asking, unless --yes).
    static func setup(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +agent-setup [--claude-dir DIR] [--remove] [--dry-run] [--yes]"
        var dir: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--claude-dir":
                guard i + 1 < args.count, !args[i + 1].isEmpty else { fail(usage); return 2 }
                dir = args[i + 1]
                i += 1
            case "--remove", "--dry-run", "--yes": break
            default: fail(usage); return 2
            }
            i += 1
        }
        let removing = args.contains("--remove"), dryRun = args.contains("--dry-run")
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: ((dir ?? env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "~/.claude") as NSString).expandingTildeInPath).standardizedFileURL
        // Through symbolic links (dotfiles managers keep the files elsewhere):
        // what's written replaces the file, never the link.
        let settingsURL = root.appendingPathComponent("settings.json").resolvingSymlinksInPath()
        let skillURL = root.appendingPathComponent("skills/libertty/SKILL.md").resolvingSymlinksInPath()
        let skillDir = skillURL.deletingLastPathComponent()
        let fm = FileManager.default

        // What's there now; a file Libertty can't read as JSON stays untouched.
        var current: [String: Any] = [:]
        let exists = fm.fileExists(atPath: settingsURL.path)
        if exists {
            guard let data = fm.contents(atPath: settingsURL.path),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                fail("\(settingsURL.path) isn't a JSON object; fix it (or move it away) and try again")
                return 1
            }
            current = json
        }
        let updated = settings(current, installing: !removing)
        let settingsChange = !NSDictionary(dictionary: updated).isEqual(to: current)
        let skillText = skill()
        let installedSkill = try? String(contentsOf: skillURL, encoding: .utf8)
        let skillChange = removing ? installedSkill != nil : installedSkill != skillText
        // A skill someone changed is kept aside, not lost.
        let skillEdited = installedSkill != nil && installedSkill != skillText

        let shown = { (url: URL) in (url.path as NSString).abbreviatingWithTildeInPath }
        print("Claude Code's settings: \(shown(root))" + (dir == nil && env["CLAUDE_CONFIG_DIR"] == nil
            ? " (another with --claude-dir, or CLAUDE_CONFIG_DIR)" : ""))
        guard settingsChange || skillChange else {
            print(removing ? "Libertty's hooks and skill aren't there; nothing to do." : "Already set up; nothing to do.")
            return 0
        }
        // Names no earlier backup has (two runs in one second get two).
        let stamp = Int(Date().timeIntervalSince1970)
        func backupName(_ url: URL) -> URL {
            (0...).lazy.map { n in
                url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).libertty-backup-\(stamp)" + (n == 0 ? "" : "-\(n)"))
            }.first { !fm.fileExists(atPath: $0.path) }!
        }
        let backup = backupName(settingsURL), skillBackup = backupName(skillURL)
        if settingsChange {
            if removing {
                print("  \(shown(settingsURL)): remove Libertty's hooks")
            } else {
                print("  \(shown(settingsURL)): \(exists ? "add" : "create it with") hooks for \(hookedEvents.joined(separator: ", "))")
                print("      each runs: \(hookCommand("EVENT"))")
                print("      (in Libertty: the tab says when Claude works, waits for you, or is done; it hears where it runs)")
            }
            if exists { print("      the file as it was goes to \(backup.lastPathComponent) (it's rewritten with its keys sorted)") }
        }
        if skillChange {
            print(removing ? "  \(shown(skillURL)): remove the skill"
                  : "  \(shown(skillURL)): the libertty skill (how to use Libertty's command line)")
            if skillEdited { print("      it was changed: it goes to \(skillBackup.lastPathComponent)") }
        }
        if dryRun { print("(--dry-run: nothing written)"); return 0 }
        if !args.contains("--yes") {
            guard isatty(STDIN_FILENO) != 0 else { fail("not asked on a terminal: run again with --yes to go ahead"); return 1 }
            print("Go ahead? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print("Nothing changed."); return 1 }
        }
        do {
            if settingsChange {
                try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // It may hold secrets: the new file keeps the old one's permissions.
                let mode = (try? fm.attributesOfItem(atPath: settingsURL.path))?[.posixPermissions] as? NSNumber
                if exists { try fm.copyItem(at: settingsURL, to: backup) }
                try Data((JSON.text(updated) + "\n").utf8).write(to: settingsURL, options: .atomic)
                if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: settingsURL.path) }
            }
            if skillChange {
                if skillEdited {
                    try fm.moveItem(at: skillURL, to: skillBackup)
                } else if removing {
                    try fm.removeItem(at: skillURL)
                }
                if removing {
                    // Its folder too, if nothing else is in it.
                    if (try? fm.contentsOfDirectory(atPath: skillDir.path))?.isEmpty == true { try? fm.removeItem(at: skillDir) }
                } else {
                    try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
                    try skillText.write(to: skillURL, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            fail(error.localizedDescription)
            return 1
        }
        print(removing ? "Removed." : "Done. Claude Code sessions started in Libertty from now on use it.")
        return 0
    }

    /// The skill: what Libertty's command line does for an agent.
    static func skill() -> String {
        """
        ---
        name: libertty
        description: Use Libertty, the macOS terminal this session runs in ($TERM_PROGRAM is Libertty) — other terminal sessions (list them, read their screens, type into them, wait for a command or a prompt, start new ones), files, diffs and web pages shown to the user beside the terminal, and this session's name. Use when a task involves another terminal, a long-running command, a server or watcher in its own session, or showing the user something.
        ---

        # Libertty

        You're in a pane of Libertty. `$LIBERTTY_SESSION` is this pane's session ID; sessions live in
        `liberttyd` and keep running when windows close. The user may be looking at another pane.

        ## Other sessions

        - `libertty +list-sessions [--json]` — every session: ID, program, size, folder, name.
        - `libertty +split [--down] [--ratio PERCENT] [--no-focus] -e COMMAND` — a pane beside this one
          running COMMAND (a dev server, a watcher, tests), with PERCENT of the space; prints its session
          ID. `--no-focus` leaves the keyboard here. Without -e it's a shell.
        - `libertty +new-session [--cwd DIR] -e COMMAND` — start COMMAND in a session of its own, in no
          window; prints its ID. It shows as a tab the next time Libertty opens windows.
        - `libertty +move-pane ID --new-tab | --tab N | --new-window` — move a pane elsewhere.
        - `libertty +capture ID [--scrollback]` — print its screen (with --scrollback, its history too).
        - `libertty +send ID TEXT` — type TEXT into it; `\\n` is Return.
        - `libertty +wait ID --until prompt|exit|idle=MS [--timeout S]` — block until its shell shows a prompt
          again, its program ends (the exit status is returned), or its output has been quiet for MS ms;
          exit status 124 when the time runs out.
        - `libertty +events [--filter KIND,...]` — what happens in sessions, one JSON object a line, until
          interrupted: session-started, session-ended, command-started, command-finished, prompt, title,
          directory, label, bell.
        - `libertty +kill-session ID` — end its program. Only end sessions you started.

        ## Showing the user something

        - `libertty +open [--split] FILE[:LINE]` — a file in a tab, or with --split beside this terminal.
        - `libertty +diff [GIT DIFF ARGS]` — this repository's changes, rendered beside the terminal.
        - `libertty +browser open --split URL` — a page beside the terminal (e.g. the dev server).
        - `libertty +focus ID` — bring the pane showing a session to the front. Don't move the user around
          unless they asked.

        ## This session

        - `libertty +rename-session NAME` — name this session (its tab shows the name); two or three
          lowercase words joined by hyphens. `libertty +rename-session ""` takes the name away.
        - `libertty +status working|blocked|done|error|clear [--message TEXT]` — say what you're doing on
          this pane's tab. Libertty's hooks already report Claude Code's own states; use it for a long
          piece of work of your own, e.g. a script that runs a while.

        `libertty +help` lists every command.
        """
    }
}

/// JSON text for what JSONSerialization read, pretty and with sorted keys,
/// numbers as short as they round-trip (JSONSerialization writes 0.1 as
/// 0.10000000000000001) and slashes left alone.
enum JSON {
    static func text(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { return "{}" }
            let members = dictionary.keys.sorted().map { key in
                inner + string(key) + ": " + text(dictionary[key]!, indent: inner)
            }
            return "{\n" + members.joined(separator: ",\n") + "\n" + indent + "}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            return "[\n" + array.map { inner + text($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case let string as String:
            return Self.string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            switch String(cString: number.objCType) {
            case "f", "d":
                let d = number.doubleValue
                return d.isFinite ? "\(d)" : "null"
            case "Q": return "\(number.uint64Value)"
            default: return "\(number.int64Value)"
            }
        default:
            return "null"
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

private extension Unicode.GeneralCategory {
    var isControlOrFormat: Bool {
        switch self {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
