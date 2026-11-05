import Foundation
import Testing
@testable import LiberttyApp

/// Agents' conversations as hooks record them, and what resumes them.
struct ConversationTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("conversations-\(UUID().uuidString).json")
    }

    @Test func ids() {
        #expect(Conversations.isValidID("13b9c2e4-77aa-4f0e-9d1c-0a2b3c4d5e6f"))
        #expect(Conversations.isValidID("abc_DEF-123"))
        #expect(!Conversations.isValidID(""))
        #expect(!Conversations.isValidID("a; rm -rf ~"))
        #expect(!Conversations.isValidID("$(id)"))
        #expect(!Conversations.isValidID("é"))
        #expect(!Conversations.isValidID(String(repeating: "a", count: 129)))
    }

    @Test func resumeCommands() {
        let c = Conversation(agent: "claude", id: "abc-1", session: "s", directory: "/tmp", started: 0, active: 0)
        #expect(Conversations.resumeCommand(c) == "claude --resume abc-1")
        var codex = c
        codex.agent = "codex"
        #expect(Conversations.resumeCommand(codex) == "codex resume abc-1")
        codex.agent = "aider"
        #expect(Conversations.resumeCommand(codex) == nil)
    }

    @Test func aPaneRunsOneConversationAtATime() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        Conversations.record(agent: "claude", id: "one", session: "pane1", directory: "/a", title: "fix the login\nredirect", now: 1, at: url)
        Conversations.record(agent: "claude", id: "one", session: "pane1", directory: "/a", title: "later prompt", now: 2, at: url)
        var list = Conversations.load(from: url)
        #expect(list.count == 1)
        #expect(list[0].title == "fix the login")  // the first prompt, its first line
        #expect(Conversations.running(in: "pane1", among: list)?.id == "one")
        // /clear: another conversation in the same pane ends the first.
        Conversations.record(agent: "claude", id: "two", session: "pane1", directory: "/a", now: 3, at: url)
        list = Conversations.load(from: url)
        #expect(list.map(\.id) == ["two", "one"])
        #expect(list[1].ended)
        #expect(Conversations.running(in: "pane1", among: list)?.id == "two")
        // It ends: nothing to resume in that pane.
        Conversations.end(agent: "claude", id: "two", now: 4, at: url)
        #expect(Conversations.running(in: "pane1", among: Conversations.load(from: url)) == nil)
        // Resumed in another pane: it runs there now.
        Conversations.record(agent: "claude", id: "one", session: "pane2", directory: "/a", now: 5, at: url)
        list = Conversations.load(from: url)
        #expect(Conversations.running(in: "pane2", among: list)?.id == "one")
        #expect(list[0].started == 1)
    }

    /// Codex says nothing as it exits: its leaving the pane ends what it ran
    /// there, so a reboot doesn't type `codex resume` into a shell.
    @Test func anAgentLeavingItsPaneEndsItsConversation() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        Conversations.record(agent: "codex", id: "c1", session: "pane1", directory: "/a", now: 1, at: url)
        Conversations.record(agent: "claude", id: "k1", session: "pane1", directory: "/a", now: 2, at: url)
        Conversations.record(agent: "codex", id: "c2", session: "pane2", directory: "/b", now: 3, at: url)
        Conversations.endRunning(session: "pane1", agent: "codex", at: url)
        var list = Conversations.load(from: url)
        // Only that agent's, in that pane.
        #expect(list.first { $0.id == "c1" }?.ended == true)
        #expect(list.first { $0.id == "k1" }?.ended == false)
        #expect(list.first { $0.id == "c2" }?.ended == false)
        #expect(Conversations.running(in: "pane1", among: list)?.id == "k1")
        // Its next turn there makes it running again.
        Conversations.record(agent: "codex", id: "c1", session: "pane1", directory: "/a", now: 4, at: url)
        list = Conversations.load(from: url)
        #expect(list.first { $0.id == "c1" }?.ended == false)
    }

    @Test func namesFindingAndTheLimit() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        for i in 0..<(Conversations.limit + 5) {
            Conversations.record(agent: "codex", id: "id\(i)", session: "s\(i)", directory: "/r", now: Double(i), at: url)
        }
        var list = Conversations.load(from: url)
        #expect(list.count == Conversations.limit)
        #expect(list.first?.id == "id\(Conversations.limit + 4)")
        Conversations.rename(session: "s7", to: "fix-login", at: url)
        list = Conversations.load(from: url)
        #expect(Conversations.find("fix-login", among: list)?.id == "id7")
        #expect(Conversations.find("ID7", among: list)?.id == "id7")
        #expect(Conversations.matching("fix", among: list).map(\.id) == ["id7"])
        #expect(list.first { $0.id == "id7" }?.label == "fix-login")
    }

    /// What Claude Code's hooks and Codex's notify hand over.
    @Test func hooksRecordThem() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let env = ["LIBERTTY_SESSION": "pane9", "PWD": "/home"]
        AgentCLI.noteConversation(agent: "claude", event: "SessionStart",
                                  input: ["session_id": "c-1", "cwd": "/repo", "source": "startup"], environment: env, at: url)
        AgentCLI.noteConversation(agent: "claude", event: "UserPromptSubmit",
                                  input: ["session_id": "c-1", "prompt": "add tests", "cwd": "/repo"], environment: env, at: url)
        AgentCLI.noteConversation(agent: "codex", event: "turn",
                                  input: ["type": "agent-turn-complete", "thread-id": "x-2", "input-messages": ["hello"]],
                                  environment: ["LIBERTTY_SESSION": "pane8", "PWD": "/w"], at: url)
        // Outside Libertty, or an id a shell would read: nothing.
        AgentCLI.noteConversation(agent: "claude", event: "SessionStart", input: ["session_id": "c-3"], environment: [:], at: url)
        AgentCLI.noteConversation(agent: "claude", event: "SessionStart", input: ["session_id": "`id`"], environment: env, at: url)
        var list = Conversations.load(from: url)
        #expect(Set(list.map(\.id)) == ["c-1", "x-2"])
        let claude = list.first { $0.id == "c-1" }
        #expect(claude?.directory == "/repo" && claude?.title == "add tests" && claude?.session == "pane9")
        #expect(list.first { $0.id == "x-2" }?.directory == "/w")
        AgentCLI.noteConversation(agent: "claude", event: "SessionEnd", input: ["session_id": "c-1"], environment: env, at: url)
        list = Conversations.load(from: url)
        #expect(list.first { $0.id == "c-1" }?.ended == true)
    }
}
