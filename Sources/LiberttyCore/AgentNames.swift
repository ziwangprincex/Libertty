import CPty
#if os(Linux)
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif

/// Which coding agent a process is, by its name or the script a runtime
/// runs: what the app's tab icons and liberttyd's screen-watching both go
/// by. Libertty's own list (Kero's), and the agents your rules name
/// (AgentScreen.user: a manifest's id, aliases and `processes`).
public enum AgentNames {
    /// Coding agents, by process name, as their logos and rules know them.
    public static let builtIn: Set<String> = [
        "claude", "codex", "gemini", "opencode", "amp", "cursor-agent", "droid", "qwen", "copilot", "kiro-cli", "cline",
        "kimi", "pi", "omp", "aider", "goose", "crush", "auggie", "codebuddy", "iflow", "qodercli", "kilocode", "jules",
        "junie", "letta", "vibe", "cn", "trae", "openhands", "plandex",
    ]
    /// Other names of the same programs.
    static let aliases = ["pdx": "plandex"]

    /// Your agents: name → the manifest's id.
    public static func user() -> [String: String] {
        var names: [String: String] = [:]
        for (name, manifest) in AgentScreen.current() where !manifest.source.isEmpty && !builtIn.contains(manifest.id) {
            names[name] = manifest.id
        }
        return names
    }

    /// The agent a name is, as Kero tells it: the name, or the name with a
    /// suffix ("claude-code", "gemini-cli"; not Pi's: "pi-hole" isn't Pi).
    /// Yours by their names exactly.
    public static func key(_ name: String) -> String? {
        let name = name.lowercased()
        if builtIn.contains(name) { return name }
        if let alias = aliases[name] { return alias }
        if let yours = user()[name] { return yours }
        return builtIn.sorted { $0.count > $1.count }.first { $0 != "pi" && name.hasPrefix($0 + "-") }
    }

    public static let shells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "nu", "pwsh", "elvish", "xonsh", "tcsh", "csh", "ksh", "cmd", "powershell",
    ]

    /// A program that runs something else lives inside it: a language
    /// runtime, a shell. Only for these is the argument list worth reading.
    public static func runsAnotherProgram(_ name: String) -> Bool {
        let runtime: Set<String> = ["node", "deno", "bun", "python", "python3", "ipython", "ruby", "perl", "php", "lua",
                                    "java", "dotnet", "cargo", "go"]
        let base = baseName(name).lowercased()
        return shells.contains(base) || runtime.contains(base)
    }

    /// The agent a runtime runs, by the script it was given: the script's
    /// own name (`node /opt/homebrew/bin/claude`, through its shebang) or
    /// the package it's in (`…/node_modules/@openai/codex/bin/codex.js`).
    /// Names only, never a substring of the command line:
    /// /Users/claude/server.js isn't Claude Code.
    public static func scripted(_ arguments: String) -> String? {
        // The script is the first argument that isn't an option.
        guard let script = arguments.split(separator: " ").first(where: { !$0.hasPrefix("-") }) else { return nil }
        let parts = script.split(separator: "/").map(String.init)
        var names: [String] = []
        if let last = parts.last {
            let dot = last.lastIndex(of: ".").map { last[..<$0] }.map(String.init)
            names.append(dot.flatMap { $0.isEmpty ? nil : $0 } ?? last)
        }
        if let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count {
            let package = parts[i + 1].hasPrefix("@") && i + 2 < parts.count ? parts[i + 2] : parts[i + 1]
            names.append(package)
        }
        for name in names {
            if let key = key(name) { return key }
        }
        return nil
    }

    /// A path's last part, without a login shell's leading "-".
    public static func baseName(_ path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }
}

/// The program in front of a terminal, from the process table: the
/// foreground process group's leader, and what it runs when that's a
/// wrapper or a runtime. For the app's panes on this Mac and for
/// liberttyd's sessions (on a remote host, the only one that can look).
public enum ForegroundProgram {
    /// The leader of the process group in front of the pty, unless that's
    /// the shell itself: its pid and name. Two kernel calls.
    public static func process(master: Int32, shell: pid_t) -> (pgid: pid_t, name: String)? {
        let pgid = libertty_pty_foreground_pgid(master)
        guard pgid > 0, pgid != shell else { return nil }
        let name = processName(pgid)
        return name.isEmpty ? nil : (pgid, name)
    }

    /// What a foreground process runs, when its own name doesn't say: a
    /// language runtime or a shell is in front, and the program is either
    /// one it started — `tclaude` is node starting `claude` — or the script
    /// it was handed (`node …/node_modules/@anthropic-ai/claude-code/cli.js`).
    /// Costlier than `process`: it walks the leader's children and reads its
    /// arguments (which can fault the process's pages back in).
    public static func identify(_ process: (pgid: pid_t, name: String)) -> (name: String, arguments: String) {
        // ssh names its host in its arguments: the tab says where it went.
        if ["ssh", "mosh", "mosh-client"].contains(process.name.lowercased()) {
            return (process.name, arguments(process.pgid))
        }
        guard AgentNames.runsAnotherProgram(process.name) else { return (process.name, "") }
        // Children before grandchildren, and a wrapper is a level or two.
        var children = [pid_t](repeating: 0, count: 16)
        let count = Int(libertty_proc_descendants(process.pgid, &children, Int32(children.count)))
        for child in children.prefix(count) {
            let name = processName(child)
            if AgentNames.key(name) != nil { return (name, "") }
        }
        return (process.name, arguments(process.pgid))
    }

    /// The agent `identify`'s answer is, if it's one.
    public static func agent(_ program: (name: String, arguments: String)) -> String? {
        let name = AgentNames.baseName(program.name)
        if !program.arguments.isEmpty, AgentNames.runsAnotherProgram(name), let key = AgentNames.scripted(program.arguments) {
            return key
        }
        return AgentNames.key(name)
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        libertty_proc_name(pid, &buf, Int32(buf.count))
        return String(cString: buf)
    }

    static func arguments(_ pid: pid_t) -> String {
        var argv = [CChar](repeating: 0, count: 1024)
        _ = libertty_proc_argv(pid, &argv, Int32(argv.count))
        return String(cString: argv)
    }
}
