import Foundation
import Testing
@testable import LiberttyApp
@testable import LiberttyCore

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

    /// liberttyd on Linux reads the rules with Swift's regexes, not ICU:
    /// the same screens must come out the same.
    @Test func swiftRegexesAgree() throws {
        let before = AgentScreen.Pattern.engine
        AgentScreen.Pattern.engine = .swift
        defer { AgentScreen.Pattern.engine = before }
        let manifests = try AgentScreen.load(Data(AgentRulesData.json.utf8))
        let idle = try screen("claude-idle.txt"), working = try screen("claude-working.txt")
        let blocked = try screen("claude-blocked.txt")
        let codexWorking = "• Ran ls\n  └ a b\n\n• Working (5s • esc to interrupt)\n\n› Summarize recent commits\n"
        let cases: [(String, AgentScreen.Input)] = [
            ("claude", .init(screen: idle, title: "✳ Claude Code")), ("claude", .init(screen: working, title: "⠂ Probe")),
            ("claude", .init(screen: blocked, title: "✳ Probe")), ("claude", .init(screen: idle, title: "⠐ Probe")),
            ("codex", .init(screen: codexWorking)), ("codex", .init(screen: "› \n", title: "⠋ codex")),
            ("kiro-cli", .init(screen: "", progress: "4;3")), ("amp", .init(screen: idle, title: "⠋ x")),
        ]
        for (agent, input) in cases {
            let swift = try #require(AgentScreen.manifest(for: agent, in: manifests))
            let icu = try #require(AgentScreen.manifest(for: agent, in: AgentScreen.bundled))
            #expect(AgentScreen.detect(swift, input) == AgentScreen.detect(icu, input), "\(agent)")
        }
    }

    /// The rules liberttyd carries are Resources' file, word for word.
    @Test func embeddedRulesAreTheFile() throws {
        let url = try #require(AppResources.url("agent-rules/rules.json"))
        #expect(try String(contentsOf: url, encoding: .utf8) == AgentRulesData.json + "\n"
                || String(contentsOf: url, encoding: .utf8) == AgentRulesData.json,
                "run scripts/update-agent-rules.py --swift")
    }

    /// Yours, in herdr's TOML or as JSON, over Libertty's: a new agent by its
    /// process names, one of the same name in place of Libertty's, and a
    /// file that can't be read named with its reason.
    @Test func yourRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        # My agent
        name = "My Agent"
        processes = ["myagent", "my-agent"]

        [[rules]]
        id = "spinner"
        state = "working"
        priority = 200
        region = "bottom_lines(3)"
        line_regex = ['^[⠋⠙⠹] working']
        visible_working = true

        [[rules]]
        id = "ask"
        state = "blocked"
        priority = 300
        any = [{ contains = ["Allow?"] }, { contains = ["Approve?"] }]
        """.write(to: dir.appendingPathComponent("mine.toml"), atomically: true, encoding: .utf8)
        try #"{"id": "claude", "rules": [{"id": "always", "state": "blocked", "contains": ["zzz"]}]}"#
            .write(to: dir.appendingPathComponent("claude.json"), atomically: true, encoding: .utf8)
        try "[[rules]]\nid = 1 2\n".write(to: dir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
        try #"{"id": "typo", "rules": [{"id": "r", "state": "working", "region": "bottom_line(3)"}]}"#
            .write(to: dir.appendingPathComponent("typo.json"), atomically: true, encoding: .utf8)

        let (mine, errors) = AgentScreen.user(in: dir.path)
        let agent = try #require(AgentScreen.manifest(for: "my-agent", in: mine))
        #expect(agent.id == "mine" && agent.name == "My Agent")
        #expect(AgentScreen.detect(agent, .init(screen: "x\n⠙ working\n")).state == .working)
        #expect(AgentScreen.detect(agent, .init(screen: "Approve? y/n\n")).state == .blocked)
        #expect(AgentScreen.detect(agent, .init(screen: "done\n")).state == .idle)
        #expect(AgentScreen.manifest(for: "claude", in: mine)?.rules.map(\.id) == ["always"])
        #expect(errors.keys.contains { $0.hasSuffix("broken.toml") })
        #expect(errors.first { $0.key.hasSuffix("typo.json") }?.value.contains("bottom_line(3)") == true)
    }

    @Test func toml() throws {
        let doc = try TOML.parse(#"""
        title = "a \"quoted\" \u00e9"  # comment
        literal = 'C:\path'
        multi = """
        one \
          two"""
        n = 1_000
        hex = 0xff
        neg = -3
        f = 1.5e2
        yes = true
        list = [1, 2,
          3, # trailing
        ]
        site."google.com" = true
        inline = { a = 1, b.c = "x" }

        [table]
        key = "v"

        [[things]]
        name = "first"
        [things.sub]
        x = 1

        [[things]]
        name = "second"
        """#)
        #expect(doc["title"] as? String == "a \"quoted\" é")
        #expect(doc["literal"] as? String == #"C:\path"#)
        #expect(doc["multi"] as? String == "one two")
        #expect(doc["n"] as? Int == 1000 && doc["hex"] as? Int == 255 && doc["neg"] as? Int == -3)
        #expect(doc["f"] as? Double == 150 && doc["yes"] as? Bool == true)
        #expect(doc["list"] as? [Int] == [1, 2, 3])
        #expect((doc["site"] as? [String: Any])?["google.com"] as? Bool == true)
        #expect(((doc["inline"] as? [String: Any])?["b"] as? [String: Any])?["c"] as? String == "x")
        #expect((doc["table"] as? [String: Any])?["key"] as? String == "v")
        let things = try #require(doc["things"] as? [[String: Any]])
        #expect(things.map { $0["name"] as? String } == ["first", "second"])
        #expect((things[0]["sub"] as? [String: Any])?["x"] as? Int == 1)
        for bad in ["a = 1\na = 2", "[t]\n[t]", "a = ", "a = \"open", "d = 1979-05-27", "x = {a = 1}\n[x]"] {
            #expect(throws: TOML.ParseError.self, "\(bad)") { try TOML.parse(bad) }
        }
    }
}

/// Who's an agent: the app's logos and liberttyd's screen-watching agree.
struct AgentNameTests {
    @Test func oneList() {
        #expect(Set(ProgramBadge.agents.keys) == AgentNames.builtIn)
    }

    @Test func names() {
        #expect(AgentNames.key("claude-code") == "claude")
        #expect(AgentNames.key("pi-hole") == nil)
        #expect(AgentNames.key("pdx") == "plandex")
        #expect(AgentNames.scripted("/opt/node_modules/@openai/codex/bin/codex.js --yolo") == "codex")
        #expect(AgentNames.scripted("/Users/claude/server.js") == nil)
        #expect(ForegroundProgram.agent(("node", "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js")) == "gemini")
        #expect(ForegroundProgram.agent(("-zsh", "")) == nil)
        #expect(ForegroundProgram.agent(("codex", "")) == "codex")
    }
}
