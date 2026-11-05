import Foundation

/// Pi, OMP and OpenCode in Libertty: they have no hooks to install as
/// Claude Code's, so `+agent-setup --agent pi|omp|opencode` installs an
/// extension (Pi, OMP) or a plugin (OpenCode) of Libertty's own that runs
/// `libertty +agent-hook AGENT SessionStart` with the conversation's id, as
/// Claude Code's hook does: the agent hears where it runs, and Libertty
/// can resume the conversation (Resume Conversation…). Their states come
/// from their screens (agent-screen-status). The skill goes where they
/// read skills: ~/.agents/skills/libertty.
enum AgentExtensions {
    /// The agents of this kind, and where each one's files are.
    enum Agent: String, CaseIterable {
        case pi, omp, opencode

        var name: String { self == .opencode ? "OpenCode" : self == .omp ? "OMP" : "Pi" }

        /// Its configuration folder, following the variables that move it.
        func root(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
            func given(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
            let home = NSHomeDirectory()
            let path: String = switch self {
            case .pi: given("PI_CODING_AGENT_DIR") ?? given("PI_CONFIG_DIR").map { $0 + "/agent" } ?? home + "/.pi/agent"
            case .omp: home + "/.omp/agent"
            case .opencode: (given("XDG_CONFIG_HOME") ?? home + "/.config") + "/opencode"
            }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }

        /// Whether it's set up on this Mac (its folder is there).
        func isInstalled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            FileManager.default.fileExists(atPath: root(env).path)
        }

        /// The files Libertty writes for it, and what goes in each.
        func files(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [(url: URL, text: String)] {
            let root = root(env)
            switch self {
            case .pi, .omp:
                return [(root.appendingPathComponent("extensions/libertty.ts"), AgentExtensions.piExtension(agent: rawValue))]
            case .opencode:
                let dir = root.appendingPathComponent("plugins/libertty")
                return [(dir.appendingPathComponent("package.json"), AgentExtensions.openCodePackage),
                        (dir.appendingPathComponent("index.js"), AgentExtensions.openCodeServer),
                        (dir.appendingPathComponent("tui.js"), AgentExtensions.openCodeTUI)]
            }
        }
    }

    /// The skill these agents (and others) read: ~/.agents/skills/libertty.
    static func sharedSkillURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".agents/skills/libertty/SKILL.md")
    }

    /// The first line of every file Libertty writes for an agent: what
    /// tells, at launch, that it's Libertty's to keep current.
    static let marker = "Written by Libertty (libertty +agent-setup)"
    /// How the skill began before it carried the mark (0.4.1 and earlier).
    static let earlierSkillHeader = "---\nname: libertty\ndescription: Use Libertty, the macOS terminal"

    static func piExtension(agent: String) -> String {
        """
        // \(marker), which keeps it current as Libertty updates;
        // `libertty +agent-setup --agent \(agent) --remove` takes it out. Inside Libertty it tells the agent
        // which session it runs in, and tells Libertty its conversation, to resume it later. Outside it does nothing.
        import { execFile } from "node:child_process";

        function hook(sessionID: string, cwd: string): Promise<string> {
          return new Promise((resolve) => {
            const child = execFile("libertty", ["+agent-hook", "\(agent)", "SessionStart"], { timeout: 5000 }, (err, stdout) => {
              resolve(err ? "" : String(stdout).trim());
            });
            child.on("error", () => resolve(""));
            child.stdin?.end(JSON.stringify({ session_id: sessionID, cwd }));
          });
        }

        export default function (pi: any) {
          if (process.env.TERM_PROGRAM !== "Libertty" || !process.env.LIBERTTY_SESSION) return;
          let context = "";
          let told: string | undefined;
          const sync = async (ctx: any) => {
            if (ctx?.mode !== "tui") return;
            let id = "";
            try { id = ctx.sessionManager.getSessionId() ?? ""; } catch {}
            if (id === told && context) return;
            told = id;
            context = await hook(id, process.cwd());
          };
          for (const event of ["session_start", "session_switch", "turn_end"]) pi.on(event, (_e: any, ctx: any) => sync(ctx));
          pi.on("before_agent_start", (event: any) => {
            if (!context) return;
            const sections = event?.systemPromptOptions?.sections;
            if (sections) { sections.libertty = context; return; }
            if (Array.isArray(event?.systemPrompt)) return { systemPrompt: [...event.systemPrompt, context] };
          });
        }

        """
    }

    static let openCodePackage = """
        {
          "name": "libertty-opencode",
          "description": "\(marker)",
          "private": true,
          "type": "module",
          "exports": { ".": "./index.js", "./tui": "./tui.js" }
        }

        """

    /// OpenCode's service side: nothing (its agents run there, apart from
    /// the pane; the terminal side tells Libertty the conversation).
    static let openCodeServer = """
        // \(marker), which keeps it current as Libertty updates.
        export default { id: "libertty", async setup() {} }

        """

    static let openCodeTUI = """
        // \(marker), which keeps it current as Libertty updates;
        // `libertty +agent-setup --agent opencode --remove` takes it out. Inside Libertty it tells Libertty
        // the conversation this terminal shows, to resume it later. Outside it does nothing.
        import { execFile } from "node:child_process"

        function tell(sessionID) {
          const child = execFile("libertty", ["+agent-hook", "opencode", "SessionStart"], { timeout: 5000 }, () => {})
          child.on("error", () => {})
          child.stdin?.end(JSON.stringify({ session_id: sessionID, cwd: process.cwd() }))
        }

        export default {
          id: "libertty",
          setup(context) {
            if (process.env.TERM_PROGRAM !== "Libertty" || !process.env.LIBERTTY_SESSION) return
            let told
            const poll = setInterval(() => {
              const route = context.ui?.router?.current?.()
              let id = route?.type === "session" ? route.sessionID : undefined
              // A subagent's session belongs to its parent's conversation.
              for (let i = 0; id && i < 8; i++) {
                const parent = context.data?.session?.get?.(id)?.parentID
                if (!parent) break
                id = parent
              }
              if (id && id !== told) { told = id; tell(id) }
            }, 500)
            return () => clearInterval(poll)
          },
        }

        """

    // MARK: Setup

    /// What `+agent-setup --agent AGENT` changes for one of these: its
    /// files (written, or with --remove taken out), and the shared skill.
    static func setup(_ agent: Agent, removing: Bool, dryRun: Bool, yes: Bool, skill: String,
                      env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let fm = FileManager.default
        let shown = { (url: URL) in (url.path as NSString).abbreviatingWithTildeInPath }
        print("\(agent.name)'s settings: \(shown(agent.root(env)))")
        var changes = agent.files(env).filter { file in
            let now = try? String(contentsOf: file.url, encoding: .utf8)
            return removing ? now != nil : now != file.text
        }
        let skillURL = sharedSkillURL()
        let skillNow = try? String(contentsOf: skillURL, encoding: .utf8)
        // The shared skill stays while another agent uses it.
        let othersUse = Agent.allCases.contains { $0 != agent && $0.files(env).contains { fm.fileExists(atPath: $0.url.path) } }
        if removing ? (skillNow != nil && !othersUse) : skillNow != skill { changes.append((skillURL, skill)) }
        guard !changes.isEmpty else {
            print(removing ? "Libertty's \(agent == .opencode ? "plugin" : "extension") isn't there; nothing to do." : "Already set up; nothing to do.")
            return 0
        }
        for change in changes {
            let what = change.url == skillURL ? "the libertty skill" : agent == .opencode ? "Libertty's plugin" : "Libertty's extension"
            print("  \(shown(change.url)): \(removing ? "remove" : "write") \(what)")
        }
        if !removing, agent == .opencode {
            print("      OpenCode loads plugins as its service starts: run `opencode service restart` when no session is busy.")
        }
        if dryRun { print("(--dry-run: nothing written)"); return 0 }
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                FileHandle.standardError.write(Data("libertty: not asked on a terminal: run again with --yes to go ahead\n".utf8))
                return 1
            }
            print("Go ahead? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print("Nothing changed."); return 1 }
        }
        do {
            for change in changes {
                if removing {
                    try? fm.removeItem(at: change.url)
                    let dir = change.url.deletingLastPathComponent()
                    if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
                } else {
                    try fm.createDirectory(at: change.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try change.text.write(to: change.url, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("libertty: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print(removing ? "Removed." : "Done. \(agent.name) sessions started in Libertty from now on use it.")
        return 0
    }

    /// At launch: what Libertty wrote for agents earlier (the skill in each
    /// place, the extensions and the plugin) brought up to this version.
    /// Only files that carry its mark and are there already: nothing new
    /// is installed, and a skill someone made their own is left alone.
    static func refresh(skill: String, claudeSkill: URL, codexSkill: URL, sharedSkill: URL = sharedSkillURL(),
                        env: [String: String] = ProcessInfo.processInfo.environment) {
        var files: [(url: URL, text: String)] = [(claudeSkill, skill), (codexSkill, skill), (sharedSkill, skill)]
        for agent in Agent.allCases { files += agent.files(env) }
        for file in files {
            guard let now = try? String(contentsOf: file.url, encoding: .utf8), now != file.text else { continue }
            // A skill from before the mark: Libertty's by its first lines, kept aside once.
            let earlier = now.hasPrefix(earlierSkillHeader)
            guard now.contains(marker) || earlier else { continue }
            if earlier {
                let backup = file.url.deletingLastPathComponent()
                    .appendingPathComponent("\(file.url.lastPathComponent).libertty-backup-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: file.url, to: backup)
            }
            try? file.text.write(to: file.url, atomically: true, encoding: .utf8)
        }
    }
}
