import Foundation
import Testing
@testable import LiberttyApp

/// `+agent-setup`'s edits to Claude Code's and Codex's settings, and the
/// OSC 7501 reports it sends.
struct AgentTests {
    @Test func claudeHooksGoInOnceAndComeOut() {
        let theirs: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]], "model": "opus"]
        let installed = AgentCLI.settings(theirs, installing: true)
        let again = AgentCLI.settings(installed, installing: true)
        #expect(NSDictionary(dictionary: installed).isEqual(to: again))
        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        #expect(Set(hooks.keys) == Set(AgentCLI.hookedEvents))
        #expect((hooks["Stop"] as? [Any])?.count == 2)
        let removed = AgentCLI.settings(installed, installing: false)
        #expect(NSDictionary(dictionary: removed).isEqual(to: theirs))
    }

    @Test func codexNotifyBeforeTheFirstTable() throws {
        let original = "model = \"gpt-5-codex\"\n\n[tui]\nnotifications = true\n"
        let installed = try #require(AgentCLI.codexConfig(original, installing: true))
        let lines = installed.split(separator: "\n").map(String.init)
        let notify = try #require(lines.firstIndex(of: AgentCLI.codexNotify))
        let table = try #require(lines.firstIndex(of: "[tui]"))
        #expect(notify < table)
        #expect(AgentCLI.codexConfig(installed, installing: true) == installed)
        #expect(AgentCLI.codexConfig(installed, installing: false) == original)
    }

    @Test func codexLeavesSomeoneElsesNotify() {
        let theirs = "notify = [\"say\", \"done\"]\n"
        #expect(AgentCLI.codexConfig(theirs, installing: true) == nil)
        #expect(AgentCLI.codexConfig(theirs, installing: false) == theirs)
        #expect(AgentCLI.codexConfig("", installing: false) == "")
    }

    @Test func reportsFollowTheSpecification() throws {
        var r = AgentCLI.Report(state: "blocked")
        r.app = "codex"
        r.kind = "permission"
        r.message = "line one\nline two"
        let seq = try r.sequence().get()
        #expect(seq.hasPrefix("\u{1b}]7501;state=blocked:app=codex:kind=permission:msg="))
        #expect(seq.hasSuffix("\u{1b}\\"))
        #expect(!seq.contains("\n"))
        r.kind = "maybe"
        if case .success = r.sequence() { Issue.record("a bad kind passed") }
        var bad = AgentCLI.Report(state: "working")
        bad.app = "has space"
        if case .success = bad.sequence() { Issue.record("a bad app name passed") }
        #expect(throws: (any Error).self) { try AgentCLI.Report(state: "sleeping").sequence().get() }
    }
}

/// Pi, OMP and OpenCode: their files, where they go, and keeping them current.
struct AgentExtensionTests {
    private func home() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)").path
    }

    @Test func whereTheyGo() {
        let env = ["PI_CODING_AGENT_DIR": "/x/pi", "XDG_CONFIG_HOME": "/x/config"]
        #expect(AgentExtensions.Agent.pi.files(env).map(\.url.path) == ["/x/pi/extensions/libertty.ts"])
        #expect(AgentExtensions.Agent.opencode.files(env).map(\.url.lastPathComponent) == ["package.json", "index.js", "tui.js"])
        #expect(AgentExtensions.Agent.opencode.root(env).path == "/x/config/opencode")
        // Each file says whose it is, and the Pi one runs the hook for its own agent.
        for agent in AgentExtensions.Agent.allCases {
            for file in agent.files(env) { #expect(file.text.contains(AgentExtensions.marker), "\(file.url.path)") }
        }
        #expect(AgentExtensions.Agent.omp.files(env)[0].text.contains(#""+agent-hook", "omp""#))
        #expect(AgentCLI.skill().contains(AgentExtensions.marker))
        #expect(AgentCLI.skill().hasPrefix("---\nname: libertty\n"))
    }

    @Test func resumeCommands() {
        let c = Conversation(agent: "pi", id: "s1", session: "x", directory: "/", started: 0, active: 0)
        #expect(Conversations.resumeCommand(c) == "pi --session s1")
        #expect(c.agentName == "Pi")
    }

    /// At launch: Libertty's own files come up to date; a file without its
    /// mark, or a skill someone wrote, is left as it is.
    @Test func refreshKeepsOnlyLibertysCurrent() throws {
        let root = home()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let claude = URL(fileURLWithPath: root + "/claude/SKILL.md"), codex = URL(fileURLWithPath: root + "/codex/SKILL.md")
        for url in [claude, codex] { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        // An old one of Libertty's, from before the mark; and someone's own.
        try (AgentExtensions.earlierSkillHeader + " (old)\n---\nold text\n").write(to: claude, atomically: true, encoding: .utf8)
        try "---\nname: libertty\ndescription: mine\n---\n".write(to: codex, atomically: true, encoding: .utf8)
        let env = ["PI_CODING_AGENT_DIR": root + "/pi", "XDG_CONFIG_HOME": root + "/config"]
        let pi = try #require(AgentExtensions.Agent.pi.files(env).first)
        try fm.createDirectory(at: pi.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("// " + AgentExtensions.marker + " (an earlier version)\n").write(to: pi.url, atomically: true, encoding: .utf8)
        AgentExtensions.refresh(skill: AgentCLI.skill(), claudeSkill: claude, codexSkill: codex,
                                sharedSkill: URL(fileURLWithPath: root + "/agents/SKILL.md"), env: env)
        #expect(try String(contentsOf: claude, encoding: .utf8) == AgentCLI.skill())
        #expect(try fm.contentsOfDirectory(atPath: claude.deletingLastPathComponent().path).contains { $0.contains("libertty-backup") })
        #expect(try String(contentsOf: codex, encoding: .utf8).contains("mine"))
        #expect(try String(contentsOf: pi.url, encoding: .utf8) == pi.text)
        // Nothing installed that wasn't there.
        #expect(!fm.fileExists(atPath: root + "/config/opencode"))
    }
}
