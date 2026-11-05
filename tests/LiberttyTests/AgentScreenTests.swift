import Foundation
import Testing
@testable import LiberttyApp

/// Agents' states from their screens, by herdr's rules (Resources/agent-rules).
struct AgentScreenTests {
    private func screen(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-screens/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func detect(_ agent: String, _ input: AgentScreen.Input) throws -> AgentScreen.Result {
        let manifest = try #require(AgentScreen.manifest(for: agent), "no rules for \(agent)")
        return AgentScreen.detect(manifest, input)
    }

    /// Every rule compiles (a regex ICU can't read fails the load), for
    /// every agent Libertty tells by its process name.
    @Test func manifestsLoad() throws {
        let url = try #require(AppResources.url("agent-rules/rules.json"))
        let manifests = try AgentScreen.load(Data(contentsOf: url))
        for agent in ["claude", "codex", "gemini", "opencode", "amp", "cursor-agent", "droid", "qwen", "copilot",
                      "kiro-cli", "cline", "kimi", "pi", "omp"] {
            #expect(AgentScreen.manifest(for: agent, in: manifests) != nil, "no rules for \(agent)")
        }
        #expect(AgentScreen.manifest(for: "bash", in: manifests) == nil)
        #expect(!AgentScreen.bundled.isEmpty)
    }

    /// Claude Code's screens, as Kero's tests read them.
    @Test func claude() throws {
        let idle = try screen("claude-idle.txt"), working = try screen("claude-working.txt")
        let blocked = try screen("claude-blocked.txt")
        #expect(try detect("claude", .init(screen: idle, title: "✳ Claude Code")).state == .idle)
        #expect(try detect("claude", .init(screen: working, title: "⠂ Probe")).state == .working)
        // The title not yet turning.
        #expect(try detect("claude", .init(screen: working)).state == .working)
        #expect(try detect("claude", .init(screen: blocked, title: "✳ Probe")).state == .blocked)
        // The prompt shows, but the title turns: a turn that started.
        #expect(try detect("claude", .init(screen: idle, title: "⠐ Probe")).state == .working)
        // A redraw at another width shows the same: still idle.
        let rewrapped = idle.replacingOccurrences(of: "────", with: "──")
        #expect(try detect("claude", .init(screen: rewrapped, title: "✳ Claude Code")).state == .idle)
    }

    /// Codex: its status line's timer while a turn runs, nothing at rest.
    @Test func codex() throws {
        let working = "• Ran ls\n  └ a b\n\n• Working (5s • esc to interrupt)\n\n› Summarize recent commits\n"
        #expect(try detect("codex", .init(screen: working)).state == .working)
        #expect(try detect("codex", .init(screen: "• Done, two files.\n\n› Summarize recent commits\n")).state == .idle)
        #expect(try detect("codex", .init(screen: "› \n", title: "⠋ codex")).state == .working)
    }

    /// Kiro's progress turns while it works.
    @Test func progress() throws {
        #expect(try detect("kiro-cli", .init(screen: "", progress: "4;3")).state == .working)
        #expect(try detect("kiro-cli", .init(screen: "", progress: "4;0")).state == .idle)
    }

    @Test func regions() {
        let s = "a\n\nb\n───\nbox\n───\nfoot\n"
        let input = AgentScreen.Input(screen: s, title: "T", progress: "4;3")
        let want: [String: String] = [
            "bottom_non_empty_lines(2)": "───\nfoot\n",
            "bottom_lines(1)": "foot\n",
            "top_non_empty_lines(2)": "a\n\nb\n",
            "after_last_horizontal_rule": "foot\n",
            "prompt_box_body": "box\n",
            "above_prompt_box": "a\n\nb\n",
            "osc_title": "T",
            "osc_progress": "4;3",
        ]
        for (spec, text) in want {
            #expect(AgentScreen.region(input, spec) == text, "\(spec)")
        }
    }
}
