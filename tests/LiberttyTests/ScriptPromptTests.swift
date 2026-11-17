import Foundation
import Testing
@testable import LiberttyApp

/// `libertty +pick` and `+input` (ScriptPrompt): their command lines, the
/// items read from stdin, and the request and the answer as they travel.
struct ScriptPromptTests {
    private func pick(_ args: String..., stdin: String? = nil) -> Result<ScriptPrompt, ScriptPrompt.Problem> {
        ScriptPrompt.parse(args, kind: .pick, stdin: { _ in stdin })
    }

    private func input(_ args: String...) -> Result<ScriptPrompt, ScriptPrompt.Problem> {
        ScriptPrompt.parse(args, kind: .input, stdin: { _ in nil })
    }

    @Test func pickReadsItsFlagsAndItems() throws {
        let p = try pick("--title", "Branch", "--timeout", "30", "main", "dev").get()
        #expect(p.kind == .pick && p.title == "Branch" && p.timeout == 30)
        #expect(p.items == [.init(label: "main"), .init(label: "dev")])
        #expect(!p.multiple && !p.allowOther)
        #expect(try pick("--multiple", "a", "b").get().multiple)
        #expect(try pick("--allow-other", "a").get().allowOther)
        // After --, a word starting with a dash is an item; so is - alone.
        #expect(try pick("--", "--title", "-x").get().items.map(\.label) == ["--title", "-x"])
        #expect(try pick("-", "a").get().items.map(\.label) == ["-", "a"])
    }

    @Test func pickRefusesWhatItCantAsk() {
        #expect(throws: ScriptPrompt.Problem.self) { try pick().get() }
        #expect(throws: ScriptPrompt.Problem.self) { try pick("--multiple", "--allow-other", "a").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try pick("--timeout", "0", "a").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try pick("--timeout", "soon", "a").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try pick("--title").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try pick("--secure", "a").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try pick("--nope", "a").get() }
        let many = (0...ScriptPrompt.maxItems).map(String.init)
        #expect(throws: ScriptPrompt.Problem.self) { try ScriptPrompt.parse(many, kind: .pick, stdin: { _ in nil }).get() }
    }

    @Test func itemsComeFromStdinWithoutArguments() throws {
        let p = try pick("--title", "Files", stdin: "one\tfirst\r\ntwo\n\n  \nthree\tthe third\tone\n").get()
        #expect(p.items == [.init(label: "one", detail: "first"), .init(label: "two"), .init(label: "three", detail: "the third\tone")])
        // Arguments given: stdin isn't read.
        #expect(try pick("a", stdin: "b\n").get().items.map(\.label) == ["a"])
        #expect(ScriptPrompt.items(fromLines: "\tonly a detail\nlast") == [.init(label: "last")])
        #expect(throws: ScriptPrompt.Problem.self) { try pick(stdin: "\n\n").get() }
    }

    @Test func inputReadsItsFlags() throws {
        let p = try input("--title", "Name", "--placeholder", "Who?", "--value", "me", "--timeout", "1.5").get()
        #expect(p.kind == .input && p.title == "Name" && p.placeholder == "Who?" && p.value == "me" && !p.secure && p.timeout == 1.5)
        #expect(try input("--secure").get().secure)
        // A starting value would travel in the open: not for a secret.
        #expect(throws: ScriptPrompt.Problem.self) { try input("--value", "me", "--secure").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try input("stray").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try input("--multiple").get() }
        #expect(throws: ScriptPrompt.Problem.self) { try input("--value").get() }
    }

    @Test func theRequestTravelsWhole() throws {
        let p = try pick("--title", "Pick", "--multiple", "--timeout", "9", "a\"b", "ü 中", stdin: nil).get()
        let back = try #require(ScriptPrompt(fields: p.fields))
        #expect(back == p)
        #expect(ScriptPrompt(fields: ["kind": "prompt", "prompt": "pick", "items": "[]"]) == nil)
        #expect(ScriptPrompt(fields: ["kind": "split"]) == nil)
        #expect(ScriptPrompt(fields: ["kind": "prompt", "prompt": "draw"]) == nil)
        let i = try input("--secure", "--title", "x").get()
        #expect(ScriptPrompt(fields: i.fields) == i)
    }

    @Test func answersTravelAndPrint() throws {
        let p = try pick("a", "b", "c").get()
        for answer: ScriptPrompt.Answer in [.chosen([0, 2]), .chosen([]), .text(""), .text("my own"), .cancelled] {
            #expect(ScriptPrompt.answer(in: ScriptPrompt.reply(answer)) == answer, "\(answer)")
        }
        #expect(p.output(for: .chosen([0, 2])) == "a\nc")
        #expect(p.output(for: .chosen([7])) == "")
        #expect(p.output(for: .text("typed")) == "typed")
        #expect(p.output(for: .cancelled) == nil)
        #expect(ScriptPrompt.answer(in: ["result": "shown"]) == nil)
    }

    @Test func theCommandLineKnowsThem() {
        let sources = CLISpec.Sources(sessions: { [] }, actions: { [] }, themes: { [] }, configKeys: { [] }, configValues: { _ in [] },
                                      conversations: { [] }, hosts: { [] }, keys: { [] })
        let flags = CLISpec.complete(["+pick", "-"], sources: sources).candidates.map(\.value)
        #expect(flags.contains("--multiple") && flags.contains("--allow-other") && !flags.contains("--host"))
        #expect(CLISpec.complete(["+input", "--secure", "-"], sources: sources).candidates.map(\.value).contains("--placeholder"))
        // remote-control = false: a question in front of you is driving.
        var off = Config()
        _ = off.set("remote-control", "false")
        #expect(RemoteControlPolicy.refusal("+pick", ["a"], config: off) != nil)
        #expect(RemoteControlPolicy.refusal("+input", [], config: off) != nil)
        #expect(RemoteControlPolicy.refuses(["kind": "prompt"], config: off))
        #expect(!RemoteControlPolicy.refuses(["kind": "prompt"], config: Config()))
    }
}
