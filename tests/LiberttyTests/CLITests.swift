import Foundation
import Testing
@testable import LiberttyApp
@testable import LiberttyCore

/// The command line's shape (`+complete`), `remote-control`, and what
/// `+daemon` reads of liberttyd's log.
struct CLITests {
    /// Fixed candidates, so nothing here asks a liberttyd or reads the config.
    private let sources = CLISpec.Sources(
        sessions: { [.init(value: "1a2b3c4d", doc: "zsh  ~/src"), .init(value: "5e6f7a8b")] },
        actions: { [.init(value: "new_split:right"), .init(value: "new_tab")] },
        themes: { [.init(value: "Tokyo Night")] },
        configKeys: { [.init(value: "font-size"), .init(value: "window-theme")] },
        configValues: { $0 == "window-theme" ? [.init(value: "dark"), .init(value: "light")] : [] },
        conversations: { [.init(value: "c0ffee00")] },
        hosts: { [.init(value: "devbox")] },
        keys: { [.init(value: "enter"), .init(value: "ctrl+")] })

    private func values(_ words: String...) -> [String] { CLISpec.complete(words, sources: sources).candidates.map(\.value) }
    private func directives(_ words: String...) -> [CLISpec.Directive] { CLISpec.complete(words, sources: sources).directives }

    @Test func commandNames() {
        let all = values("+")
        #expect(all.contains("+daemon") && all.contains("+clients") && all.contains("+completions"))
        // Hidden: internal, or spelled another way.
        #expect(!all.contains("+complete") && !all.contains("+agent-hook") && !all.contains("+h"))
        #expect(values("+da") == ["+daemon"])
        // Every name once.
        let names = CLISpec.commands.flatMap { [$0.name] + $0.aliases }
        #expect(Set(names).count == names.count)
        #expect(CLISpec.command(named: "+h")?.name == "+help")
        #expect(CLISpec.command(named: "+nope") == nil)
    }

    /// A command the CLI runs but CLISpec doesn't know is refused as unknown:
    /// every `case "+…"` of its dispatch must be in the table.
    @Test func everyDispatchedCommandIsInTheTable() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LiberttyApp/App/CLI.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let dispatch = try #require(text.range(of: "switch command {").map { text[$0.upperBound...] })
        let body = dispatch[..<(dispatch.range(of: "default:")?.lowerBound ?? dispatch.endIndex)]
        let cases = try Regex(#""(\+[a-z-]+)""#)
        let names = body.matches(of: cases).compactMap { $0.output[1].substring.map(String.init) }
        #expect(names.count > 40)
        for name in names { #expect(CLISpec.command(named: name) != nil, "\(name) isn't in CLISpec.commands") }
    }

    @Test func flagsAndTheirValues() {
        // Flags not given yet; --host for the commands that take one.
        let capture = values("+capture", "1a2b3c4d", "--scrollback", "-")
        #expect(capture.contains("--ansi") && capture.contains("--host") && !capture.contains("--scrollback"))
        #expect(!values("+focus", "-").contains("--host"))
        #expect(values("+wait", "1a2b3c4d", "--until", "") == ["exit", "idle=", "prompt"])
        #expect(directives("+wait", "1a2b3c4d", "--until", "") == [.nospace])
        #expect(values("+connect", "") == ["devbox"])
        #expect(values("+capture", "") == ["1a2b3c4d", "5e6f7a8b"])
        // Another machine's sessions aren't looked up at each Tab.
        #expect(values("+capture", "--host", "devbox", "").isEmpty)
        #expect(directives("+open", "") == [.files])
        #expect(directives("+split", "--cwd", "") == [.dirs])
        // Comma lists: what's not there yet, after what is.
        #expect(values("+events", "--for", "working,").contains("working,done"))
        #expect(!values("+events", "--for", "working,").contains("working,working"))
        #expect(values("+send-key", "1a2b3c4d", "") == ["enter", "ctrl+"])
        #expect(values("+resume", "") == ["c0ffee00"])
        #expect(values("+completions", "") == ["zsh", "bash", "fish"])
    }

    @Test func aCommandToRun() {
        // -e COMMAND: its name, then (its arguments) files.
        #expect(directives("+new-window", "-e", "") == [.commands])
        #expect(directives("+new-window", "-e", "vim", "") == [.files])
        #expect(directives("+split", "1a2b3c4d", "-e", "make", "test", "") == [.files])
    }

    @Test func settings() {
        #expect(values("+set", "") == ["font-size=", "window-theme="])
        #expect(directives("+set", "") == [.nospace])
        #expect(values("+set", "window-theme=") == ["window-theme=dark", "window-theme=light"])
        #expect(values("+set", "font-size=14", "") == ["font-size=", "window-theme="])
        #expect(values("+get", "") == ["font-size", "window-theme"])
        #expect(values("+action", "") == ["new_split:right", "new_tab"])
    }

    @Test func linesForEachShell() {
        let completion = CLISpec.Completion(candidates: [.init(value: "+daemon", doc: "liberttyd\tand more"), .init(value: "+diff")],
                                            directives: [.nospace])
        #expect(CLISpec.lines(completion, shell: "zsh", current: "+da") == ["+daemon\tliberttyd and more", "+diff", ":nospace"])
        // bash matches nothing itself: only what fits, without descriptions.
        #expect(CLISpec.lines(completion, shell: "bash", current: "+da") == ["+daemon", ":nospace"])
    }

    @Test func actionSpellings() {
        #expect(CLISpec.spellings(of: "new_split:right|down") == ["new_split:right", "new_split:down"])
        #expect(CLISpec.spellings(of: "goto_tab:N") == ["goto_tab:"])
        #expect(CLISpec.spellings(of: "new_tab") == ["new_tab"])
    }

    @Test func liveSourcesNameRealThings() {
        let live = CLISpec.liveSources
        #expect(live.configKeys().contains { $0.value == "remote-control" })
        #expect(live.configValues("window-padding-color").map(\.value).contains("extend"))
        #expect(live.configValues("remote-control").map(\.value) == ["true", "false"])
        #expect(live.actions().contains { $0.value == "new_split:right" })
        // What +action refuses to send isn't offered.
        #expect(!live.actions().contains { $0.value.hasPrefix("text:") || $0.value == "quit" })
        #expect(live.keys().contains { $0.value == "page_up" })
    }

    // MARK: remote-control

    private func config(_ remoteControl: Bool) -> Config {
        var c = Config()
        _ = c.set("remote-control", remoteControl ? "true" : "false")
        return c
    }

    @Test func remoteControlRefusesDriving() {
        let off = config(false), on = config(true)
        #expect(Config().remoteControl)
        #expect(RemoteControlPolicy.refusal("+split", [], config: on) == nil)
        for command in ["+split", "+send", "+send-key", "+action", "+focus", "+new-window", "+kill-session", "+prompt", "+resume"] {
            #expect(RemoteControlPolicy.refusal(command, ["x"], config: off) != nil, "\(command)")
        }
        // Reading, and showing something, still work.
        for command in ["+capture", "+list-sessions", "+wait", "+events", "+history", "+open", "+diff", "+list-panes", "+clients"] {
            #expect(RemoteControlPolicy.refusal(command, ["x"], config: off) == nil, "\(command)")
        }
        #expect(RemoteControlPolicy.refusal("+daemon", ["status"], config: off) == nil)
        #expect(RemoteControlPolicy.refusal("+daemon", ["logs", "-f"], config: off) == nil)
        #expect(RemoteControlPolicy.refusal("+daemon", ["stop", "--force"], config: off) != nil)
        #expect(RemoteControlPolicy.refusal("+daemon", ["restart"], config: off) != nil)
    }

    @Test func remoteControlLetsAnAgentNameItsOwnSession() {
        let off = config(false), env = ["LIBERTTY_SESSION": "1a2b3c4d"]
        #expect(RemoteControlPolicy.refusal("+rename-session", ["fix login"], config: off, environment: env) == nil)
        #expect(RemoteControlPolicy.refusal("+rename-session", ["1a2b3c4d", "fix login"], config: off, environment: env) == nil)
        #expect(RemoteControlPolicy.refusal("+rename-session", ["5e6f7a8b", "theirs"], config: off, environment: env) != nil)
        // Outside a Libertty pane there's no own session.
        #expect(RemoteControlPolicy.refusal("+rename-session", ["mine"], config: off, environment: [:]) != nil)
    }

    @Test func theAppRefusesToo() {
        let off = config(false)
        #expect(RemoteControlPolicy.refuses(["kind": "split"], config: off))
        #expect(RemoteControlPolicy.refuses(["action": "new_tab"], config: off))
        #expect(!RemoteControlPolicy.refuses(["kind": "open"], config: off))
        #expect(!RemoteControlPolicy.refuses(["kind": "list-panes"], config: off))
        #expect(!RemoteControlPolicy.refuses(["kind": "split"], config: config(true)))
        var c = Config()
        #expect(c.set("remote-control", "maybe") != nil)
    }

    // MARK: liberttyd's log

    @Test func readingTheLog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: url)
        #expect(DaemonServer.readLog(url.path, from: nil, lines: 2)?.0 == "three\nfour\n")
        #expect(DaemonServer.readLog(url.path, from: nil, lines: 9)?.0 == "one\ntwo\nthree\nfour\n")
        #expect(DaemonServer.readLog(url.path, from: nil, lines: 0)?.0 == "")
        let all = try #require(DaemonServer.readLog(url.path, from: nil, lines: nil))
        #expect(all.0 == "one\ntwo\nthree\nfour\n" && all.1 == 19)
        // Following it: what came since; one that shrank, from its start.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("five\n".utf8))
        try handle.close()
        #expect(DaemonServer.readLog(url.path, from: 19, lines: nil)?.0 == "five\n")
        #expect(DaemonServer.readLog(url.path, from: 24, lines: nil)?.0 == "")
        try Data("new\n".utf8).write(to: url)
        #expect(DaemonServer.readLog(url.path, from: 24, lines: nil)?.0 == "new\n")
        #expect(DaemonServer.readLog(url.path + ".none", from: nil, lines: 5) == nil)
    }

    @Test func clientsRoundTrip() throws {
        let c = ConnectedClient(pid: 42, process: "Libertty", client: "cli +events", since: 1, session: "1a2b3c4d",
                                listening: true, waiting: ["5e6f7a8b"])
        let back = try JSONDecoder().decode(ConnectedClient.self, from: JSONEncoder().encode(c))
        #expect(back.pid == 42 && back.client == "cli +events" && back.session == "1a2b3c4d" && back.listening && back.waiting == ["5e6f7a8b"])
        #expect(CLI.isMissing("no such session") && CLI.isMissing("no session 1a2b3c4d") && !CLI.isMissing("unknown key x"))
    }
}
