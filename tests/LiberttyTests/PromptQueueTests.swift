import Foundation
import Testing
@testable import LiberttyApp

/// Prompts queued for a pane (PromptQueue) and what the composer makes of
/// rich text (HTMLToMarkdown).
struct PromptQueueTests {
    private func look(_ state: ProgramStatusStore.State? = nil, agent: Bool = true, atPrompt: Bool = false,
                      quiet: Double = 5, printed: Bool = false, now: Double = 100) -> PromptQueue.Look {
        .init(state: state, agent: agent, atPrompt: atPrompt, quietFor: quiet, printedSinceSend: printed, now: now)
    }

    @Test func oneAtATimeForAnAgent() {
        var q = PromptQueue()
        q.append("first")
        q.append("  second\n")
        q.append("   ")
        #expect(q.items.map(\.text) == ["first", "second"])
        // At rest: the first goes at once.
        #expect(q.step(look(.idle))?.text == "first")
        // Not yet seen at work on it: the second waits, however idle it looks.
        #expect(q.step(look(.idle, quiet: 1, printed: true, now: 101)) == nil)
        // At work, then waiting for your answer: nothing goes.
        #expect(q.step(look(.working, quiet: 0, now: 102)) == nil)
        #expect(q.step(look(.blocked, quiet: 4, now: 103)) == nil)
        #expect(q.step(look(.working, quiet: 0, now: 104)) == nil)
        // Done: the next.
        #expect(q.step(look(.done, quiet: 1, now: 110))?.text == "second")
        #expect(q.isEmpty)
    }

    @Test func blockedHoldsIt() {
        var q = PromptQueue()
        q.append("go")
        #expect(q.step(look(.blocked)) == nil)
        #expect(q.step(look(.blocked, quiet: 60)) == nil)
        #expect(q.step(look(nil, quiet: 0.2)) == nil)  // just answered: still printing
        #expect(q.step(look(nil, quiet: 1))?.text == "go")
    }

    /// A shell: at its prompt; a command it ran in between two looks counts once it printed and went quiet.
    @Test func shell() {
        var q = PromptQueue()
        q.append("make")
        q.append("make test")
        #expect(q.step(look(agent: false, atPrompt: false)) == nil)
        #expect(q.step(look(agent: false, atPrompt: true, quiet: 1))?.text == "make")
        // Running.
        #expect(q.step(look(agent: false, atPrompt: false, quiet: 0, now: 101)) == nil)
        #expect(q.step(look(agent: false, atPrompt: true, quiet: 0.1, now: 102)) == nil)
        #expect(q.step(look(agent: false, atPrompt: true, quiet: 0.5, now: 103))?.text == "make test")
        // A quick one, never seen running: once it printed and went quiet.
        var quick = PromptQueue()
        quick.append("echo a")
        quick.append("echo b")
        #expect(quick.step(look(agent: false, atPrompt: true))?.text == "echo a")
        #expect(quick.step(look(agent: false, atPrompt: true, quiet: 0.2, printed: true, now: 100.3)) == nil)
        #expect(quick.step(look(agent: false, atPrompt: true, quiet: 0.7, printed: true, now: 101))?.text == "echo b")
    }

    /// An agent that tells nothing of itself: done once it answered and stopped printing.
    @Test func agentThatSaysNothing() {
        var q = PromptQueue()
        q.append("one")
        q.append("two")
        #expect(q.step(look(nil))?.text == "one")
        #expect(q.step(look(nil, quiet: 1, printed: true, now: 101)) == nil)
        #expect(q.step(look(nil, quiet: 3.5, printed: true, now: 104))?.text == "two")
    }

    /// You typing into the pane holds the queue: a prompt pasted then would land on what you write.
    @Test func typingHoldsIt() {
        var q = PromptQueue()
        q.append("go")
        var typing = look(.idle)
        typing.typing = true
        #expect(q.step(typing) == nil)
        #expect(q.step(look(.idle, now: 103))?.text == "go")
    }

    @Test func pausedAndPutBack() {
        var q = PromptQueue()
        q.append("a")
        q.append("b")
        let a = q.step(look(.idle))!
        q.putBack(a)
        #expect(q.paused && q.items.map(\.text) == ["a", "b"])
        #expect(q.step(look(.idle, now: 200)) == nil)
        q.paused = false
        #expect(q.step(look(.idle, now: 201))?.text == "a")
    }

    /// The agent exited: what was queued for it waits for you, never typed into the shell.
    @Test func agentExitedPausesIt() {
        var q = PromptQueue()
        q.append("a")
        q.append("b")
        #expect(q.step(look(.idle))?.text == "a")
        q.agentExited()
        #expect(q.paused && q.pauseReason == .agentExited && q.items.map(\.text) == ["b"])
        #expect(q.step(look(agent: false, atPrompt: true, now: 200)) == nil)
        q.paused = false
        #expect(q.step(look(agent: false, atPrompt: true, now: 201))?.text == "b")
    }

    @Test func editing() {
        var q = PromptQueue()
        q.append("a"); q.append("b"); q.append("c")
        let ids = q.items.map(\.id)
        q.move(ids[2], by: -2)
        #expect(q.items.map(\.text) == ["c", "a", "b"])
        q.edit(ids[0], to: "A")
        q.edit(ids[1], to: "  ")
        #expect(q.items.map(\.text) == ["c", "A"])
        q.remove(ids[2])
        #expect(q.items.map(\.text) == ["A"])
    }

    @Test func markdown() {
        let html = """
        <html><head><style>p{}</style></head><body>
        <h2>Bug   report</h2>
        <p>The <b>build</b> fails in <code>make test</code>; see <a href="https://x.test/run/1">the run</a>.</p>
        <ul><li>one</li><li>two<ul><li>inner</li></ul></li></ul>
        <ol><li>first</li><li>second</li></ol>
        <pre><code class="language-swift">let a = 1
        print(a)</code></pre>
        <blockquote>quoted</blockquote>
        <table><tr><th>k</th><th>v</th></tr><tr><td>a|b</td><td>2</td></tr></table>
        <p>line<br>break <img src="https://x.test/i.png" alt="shot"></p>
        </body></html>
        """
        let md = HTMLToMarkdown.convert(html)
        #expect(md.contains("## Bug report"))
        #expect(md.contains("The **build** fails in `make test`; see [the run](https://x.test/run/1)."))
        #expect(md.contains("- one\n- two\n  - inner"))
        #expect(md.contains("1. first\n2. second"))
        #expect(md.contains("```swift\nlet a = 1\nprint(a)\n```"))
        #expect(md.contains("> quoted"))
        #expect(md.contains("| k | v |\n| --- | --- |\n| a\\|b | 2 |"))
        #expect(md.contains("line\nbreak ![shot](https://x.test/i.png)"))
        #expect(!md.contains("p{}"))
        #expect(HTMLToMarkdown.hasStructure(html))
        // An editor's code: styled divs and spans, its plain text the paste.
        #expect(!HTMLToMarkdown.hasStructure(#"<div style="white-space: pre;"><span>    let a = 1</span></div>"#))
        #expect(HTMLToMarkdown.hasStructure("<p>see <A HREF=x>it</A></p>"))
        #expect(!md.contains("\n\n\n"))
    }

    /// A long page (thousands of blocks) converts at once: each block looks
    /// at the end of what's written so far, not all of it.
    @Test func longPageIsQuick() {
        var html = "<html><body>"
        for i in 0..<3000 { html += "<div><p>Paragraph \(i) with <a href=\"https://x.test/\(i)\">a link</a>.</p></div>" }
        html += "</body></html>"
        let start = Date()
        let md = HTMLToMarkdown.convert(html)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(md.hasPrefix("Paragraph 0 with [a link](https://x.test/0).\n\nParagraph 1 with [a link](https://x.test/1)."))
        #expect(md.hasSuffix("\n\nParagraph 2999 with [a link](https://x.test/2999)."))
        // A quote's marks left at a block's end go, before a last line break too.
        let quoted = "<blockquote><p>one</p><p>two<br>three</p><blockquote><p>deep</p><pre>code\nmore</pre></blockquote>"
            + "<ul><li>l1</li><li>l2</li></ul></blockquote><p>after</p>"
        #expect(HTMLToMarkdown.convert(quoted)
            == "> one\n\n> two\n> three\n\n> > deep\n\n> > ```\n> > code\n> > more\n> > ```\n\n> - l1\n> - l2\n\nafter")
        #expect(HTMLToMarkdown.convert("<blockquote><pre>x &gt;\n\n</pre><p>y</p></blockquote>") == "> ```\n> x >\n> ```\n\n> y")
    }

    @Test func forkCommands() {
        let claude = Conversation(agent: "claude", id: "abc-123", session: "s", directory: "/tmp", started: 0, active: 0)
        #expect(Conversations.forkCommand(claude) == "claude --resume abc-123 --fork-session")
        let codex = Conversation(agent: "codex", id: "019a-77", session: "s", directory: "/tmp", started: 0, active: 0)
        #expect(Conversations.forkCommand(codex) == "codex fork 019a-77")
        let pi = Conversation(agent: "pi", id: "x", session: "s", directory: "/tmp", started: 0, active: 0)
        #expect(Conversations.forkCommand(pi) == nil)
        let bad = Conversation(agent: "claude", id: "a; rm -rf /", session: "s", directory: "/tmp", started: 0, active: 0)
        #expect(Conversations.forkCommand(bad) == nil)
    }
}
