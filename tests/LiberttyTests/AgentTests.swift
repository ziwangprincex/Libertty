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
