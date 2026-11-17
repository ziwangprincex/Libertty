import Foundation
import LiberttyCore
import Testing
@testable import LiberttyApp

/// Copy mode, hints and a click at the prompt, on a terminal written to
/// directly (no program, no window): where the keys take the cursor, what
/// they select and copy, what's labeled, and the arrows a click sends.
@Suite @MainActor struct CopyModeTests {
    private func session(cols: Int = 40, rows: Int = 6, _ text: String) throws -> TerminalSession {
        let s = try TerminalSession(size: GridSize(cols: UInt16(cols), rows: UInt16(rows), widthPx: 0, heightPx: 0), config: Config())
        s.show(text)
        return s
    }

    private func press(_ mode: CopyMode, _ keys: String...) {
        for k in keys { _ = mode.press(k, control: false) }
    }

    @Test func wordsLinesAndCounts() throws {
        let s = try session("alpha beta_gamma, delta\r\nsecond line here\r\nthird")
        let mode = CopyMode(session: s)
        // It starts on the terminal's cursor: after "third".
        #expect(mode.point == ScreenPoint(x: 5, y: 2))
        press(mode, "k", "k", "0")
        #expect(mode.point == ScreenPoint(x: 0, y: 0))
        // A word is letters, digits and _; punctuation is a word of its own.
        press(mode, "w"); #expect(mode.point?.x == 6)
        press(mode, "w"); #expect(mode.point?.x == 16)
        press(mode, "w"); #expect(mode.point?.x == 18)
        press(mode, "e"); #expect(mode.point?.x == 22)
        press(mode, "b"); #expect(mode.point?.x == 18)
        press(mode, "b", "b"); #expect(mode.point?.x == 6)
        // WORDs are anything not blank.
        press(mode, "0", "W"); #expect(mode.point?.x == 6)
        press(mode, "W"); #expect(mode.point?.x == 18)
        // $ and then down: to that line's end too.
        press(mode, "$"); #expect(mode.point == ScreenPoint(x: 22, y: 0))
        press(mode, "j"); #expect(mode.point == ScreenPoint(x: 15, y: 1))
        press(mode, "^"); #expect(mode.point?.x == 0)
        // A count repeats a motion; 0 after a digit is part of the count.
        press(mode, "1", "0", "l"); #expect(mode.point?.x == 10)
        press(mode, "g", "g"); #expect(mode.point == ScreenPoint(x: 0, y: 0))
        // G: the last line with anything on it.
        press(mode, "G"); #expect(mode.point == ScreenPoint(x: 0, y: 2))
        // Words go on over the line's end.
        press(mode, "g", "g", "$", "w"); #expect(mode.point == ScreenPoint(x: 0, y: 1))
    }

    /// vim's f F t T in the cursor's line, with counts, and ; and , doing
    /// the last one again.
    @Test func findACharacterInTheLine() throws {
        // a0 l1 p2 h3 a4 _5 b6 e7 t8 a9 _10 g11 a12 m13 m14 a15 ,16 _17 d18…
        let s = try session("alpha beta_gamma, delta\r\nsecond")
        let mode = CopyMode(session: s)
        press(mode, "k", "0")
        #expect(mode.point == ScreenPoint(x: 0, y: 0))
        // f: onto the next one; a count takes the nth.
        press(mode, "f", "a"); #expect(mode.point?.x == 4)
        press(mode, "0", "3", "f", "a"); #expect(mode.point?.x == 12)
        // t: the cell before it.
        press(mode, "0", "t", "a"); #expect(mode.point?.x == 3)
        // ; again, , the other way.
        press(mode, "0", "f", "a", ";"); #expect(mode.point?.x == 9)
        press(mode, ","); #expect(mode.point?.x == 4)
        // ; after a t goes on to the next: not stuck before the same one.
        press(mode, "0", "t", "a"); #expect(mode.point?.x == 3)
        press(mode, ";"); #expect(mode.point?.x == 8)
        press(mode, ";"); #expect(mode.point?.x == 11)
        // A t beside its character stays; ; then goes to the one after it,
        // even when that's the next cell (gamma's mm: on the first m).
        press(mode, "0", "f", "g", "t", "m"); #expect(mode.point?.x == 12)
        press(mode, ";"); #expect(mode.point?.x == 13)
        // F and T look back up the line.
        press(mode, "$"); #expect(mode.point?.x == 22)
        press(mode, "F", "b"); #expect(mode.point?.x == 6)
        press(mode, "$", "T", "a"); #expect(mode.point?.x == 16)
        // Nothing of that character in the line: the cursor stays.
        press(mode, "0", "f", "z"); #expect(mode.point?.x == 0)
        // Space is found by its key name.
        press(mode, "0", "f", "space"); #expect(mode.point?.x == 5)
        // It never leaves the line, and a named key cancels the wait.
        press(mode, "0", "f", "s"); #expect(mode.point == ScreenPoint(x: 0, y: 0))
        press(mode, "f", "escape"); #expect(mode.point == ScreenPoint(x: 0, y: 0))
        press(mode, "l"); #expect(mode.point?.x == 1)
    }

    /// D: from the cursor to the end of its line, and out of copy mode
    /// (tmux's copy-end-of-line).
    @Test func copyToTheEndOfTheLine() throws {
        let s = try session("alpha beta\r\nsecond line")
        let mode = CopyMode(session: s)
        press(mode, "k", "0", "w")
        #expect(mode.point == ScreenPoint(x: 6, y: 0))
        #expect(mode.press("D", control: false) == .leave(copied: "beta"))
        // From the line's start: all of it. On a blank line: nothing.
        let whole = CopyMode(session: s)
        press(whole, "k", "0")
        #expect(whole.press("D", control: false) == .leave(copied: "alpha beta"))
        let blank = CopyMode(session: s)
        press(blank, "j", "j", "0")
        #expect(blank.press("D", control: false) == .leave(copied: nil))
    }

    /// Leaving copy mode puts the view back where it was when it began, so a
    /// look up the scrollback doesn't leave the pane there — unless the view
    /// was scrolled by hand meanwhile, which was meant.
    @Test func theViewGoesBackOnLeaving() throws {
        let text = (1...40).map { "line \($0)" }.joined(separator: "\r\n")
        let s = try session(rows: 4, text)
        #expect(s.scrollbar.atBottom)
        let mode = CopyMode(session: s)
        press(mode, "2", "0", "k")
        #expect(!s.scrollbar.atBottom)
        mode.end()
        #expect(s.scrollbar.atBottom)

        // Scrolled by hand while in copy mode: left where it was put.
        let byHand = CopyMode(session: s)
        press(byHand, "2", "0", "k")
        byHand.keepsViewOnLeaving = true
        let where_ = s.scrollbar.offset
        byHand.end()
        #expect(s.scrollbar.offset == where_)
        #expect(!s.scrollbar.atBottom)

        // Begun up the scrollback: back to that line, not to the bottom.
        s.scrollToTop()
        let top = s.scrollbar.offset
        let fromTop = CopyMode(session: s)
        press(fromTop, "G")
        #expect(s.scrollbar.offset != top)
        fromTop.end()
        #expect(s.scrollbar.offset == top)
    }

    @Test func selectingAndCopying() throws {
        let s = try session("alpha beta\r\nsecond line here\r\nthird")
        let mode = CopyMode(session: s)
        press(mode, "g", "g", "v", "l", "l")
        #expect(mode.selecting == .characters)
        #expect(s.selectedText() == "alp")
        #expect(mode.press("y", control: false) == .leave(copied: "alp"))

        let lines = CopyMode(session: s)
        press(lines, "k", "V")
        #expect(s.selectedText() == "second line here")
        // o goes to the other end; the same key again stops selecting.
        press(lines, "j", "o")
        #expect(lines.point?.y == 1)
        press(lines, "V")
        #expect(lines.selecting == .none)
        #expect(!s.hasSelection)
        // y with nothing selected: the cursor's line.
        #expect(lines.press("y", control: false) == .leave(copied: "second line here"))

        let block = CopyMode(session: s)
        press(block, "g", "g", "l")
        _ = block.press("v", control: true)
        press(block, "j", "l", "l")
        #expect(block.selecting == .block)
        #expect(s.selectedText() == "lph\neco")
        block.end()
        #expect(!s.hasSelection)
    }

    @Test func wideCharactersAreOneStep() throws {
        let s = try session("中文ab")
        let mode = CopyMode(session: s)
        press(mode, "0"); #expect(mode.point?.x == 0)
        press(mode, "l"); #expect(mode.point?.x == 2)
        press(mode, "l"); #expect(mode.point?.x == 4)
        press(mode, "h"); #expect(mode.point?.x == 2)
        press(mode, "h"); #expect(mode.point?.x == 0)
        // Selected to a wide character: all of it.
        press(mode, "v", "l")
        #expect(s.selectedText() == "中文")
    }

    @Test func theCursorStaysOnItsTextAsOutputArrives() throws {
        let s = try session(rows: 4, (1...20).map { "line \($0)" }.joined(separator: "\r\n"))
        let mode = CopyMode(session: s)
        #expect(mode.currentLine() == "line 20")
        // Up past the viewport's top: the view follows.
        let top = s.scrollbar.offset
        press(mode, "1", "0", "k")
        #expect(mode.currentLine() == "line 10")
        #expect(s.scrollbar.offset < top)
        // In view, at the viewport's top row (scrolled just far enough).
        #expect(mode.viewportCursor()?.row == 0)
        // Scrolled away (the wheel), it isn't drawn.
        s.scrollToBottom()
        #expect(mode.viewportCursor() == nil)
        // More output: the cursor is on the same line of text.
        s.show("\r\n" + (21...40).map { "line \($0)" }.joined(separator: "\r\n"))
        #expect(mode.currentLine() == "line 10")
        press(mode, "j")
        #expect(mode.currentLine() == "line 11")
        press(mode, "G")
        #expect(mode.currentLine() == "line 40")
    }

    @Test func prompts() throws {
        let prompt = "\u{1b}]133;A;cl=line\u{07}$ \u{1b}]133;B\u{07}"
        let s = try session(rows: 8, prompt + "make\u{1b}]133;C\u{07}\r\nbuilt\r\n" + prompt + "ls\u{1b}]133;C\u{07}\r\na b\r\n" + prompt)
        let mode = CopyMode(session: s)
        // { and }: to the input of the prompt before, or after.
        press(mode, "{")
        #expect(mode.point == ScreenPoint(x: 2, y: 2))
        press(mode, "{")
        #expect(mode.point == ScreenPoint(x: 2, y: 0))
        press(mode, "}")
        #expect(mode.point == ScreenPoint(x: 2, y: 2))
    }

    @Test func nextMatchFromTheCursor() throws {
        let s = try session(rows: 6, "foo 1\r\nbar\r\nfoo 2\r\nfoo 3")
        s.find("foo")
        #expect(s.selectMatch(beyond: ScreenPoint(x: 0, y: 3), older: true) == ScreenPoint(x: 0, y: 2))
        #expect(s.selectMatch(beyond: ScreenPoint(x: 0, y: 2), older: true) == ScreenPoint(x: 0, y: 0))
        #expect(s.selectMatch(beyond: ScreenPoint(x: 0, y: 0), older: true) == nil)
        #expect(s.selectMatch(beyond: ScreenPoint(x: 0, y: 0), older: false) == ScreenPoint(x: 0, y: 2))
        #expect(s.selectMatch(beyond: ScreenPoint(x: 3, y: 2), older: false) == ScreenPoint(x: 0, y: 3))
    }
}

@Suite @MainActor struct HintTests {
    @Test func whatGetsLabeled() throws {
        let s = try TerminalSession(size: GridSize(cols: 100, rows: 4, widthPx: 0, heightPx: 0), config: Config())
        s.show("see https://example.com/x, then 1a2b3c4d at 10.0.0.1:8080 in /tmp; deadbeef 1234567 no\r\n")
        let targets = s.hintTargets()
        let found = Set(targets.map(\.text))
        #expect(found == ["https://example.com/x", "1a2b3c4d", "10.0.0.1:8080", "/tmp"])
        #expect(targets.first { $0.text == "1a2b3c4d" }?.kind == .hash)
        #expect(targets.first { $0.text == "10.0.0.1:8080" }?.link == nil)
        #expect(targets.first { $0.text == "https://example.com/x" }?.link?.url == "https://example.com/x")
        #expect(targets.first { $0.text == "/tmp" }?.kind == .path)
        // Its cells: where the URL is, on the first row.
        #expect(targets.first { $0.kind == .link }?.spans == [TerminalLink.Span(row: 0, columns: 4...24)])
        #expect(Set(targets.map(\.label)).count == targets.count)
    }

    @Test func labelsNeverStartOneAnother() {
        func targets(_ n: Int) -> [HintTarget] {
            (0..<n).map { HintTarget(kind: .hash, text: "\($0)", link: nil, spans: []) }
        }
        let few = HintLabels.assign(targets(5))
        #expect(few.map(\.label) == ["a", "s", "d", "f", "g"])
        let many = HintLabels.assign(targets(30)).map(\.label)
        #expect(Set(many).count == 30)
        #expect(many.allSatisfy { $0.count == 2 })
        #expect(HintLabels.assign(targets(1000)).count == 26 * 26)
    }
}

@Suite @MainActor struct PromptClickTests {
    private let prompt = "\u{1b}]133;A;cl=line\u{07}$ \u{1b}]133;B\u{07}"

    private func session(cols: Int = 40, _ text: String) throws -> TerminalSession {
        let s = try TerminalSession(size: GridSize(cols: UInt16(cols), rows: 4, widthPx: 0, heightPx: 0), config: Config())
        s.show(text)
        return s
    }

    @Test func arrowsToTheClick() throws {
        let s = try session(prompt + "echo hello")
        // The cursor is after the command: back to the e, to the h.
        #expect(s.promptClickMove(col: 2, row: 0) == -10)
        #expect(s.promptClickMove(col: 7, row: 0) == -5)
        // On the prompt itself: to the command's start.
        #expect(s.promptClickMove(col: 0, row: 0) == -10)
        // Past the end, already there: nowhere.
        #expect(s.promptClickMove(col: 30, row: 0) == 0)
        // From the h: past the end goes after its last character.
        s.show("\u{1b}[5D")
        #expect(s.promptClickMove(col: 30, row: 0) == 5)
        #expect(s.promptClickMove(col: 9, row: 0) == 2)
        // Another line, or a command running: not the prompt's.
        #expect(s.promptClickMove(col: 2, row: 1) == nil)
        s.show("\r\n\u{1b}]133;C\u{07}")
        #expect(s.promptClickMove(col: 0, row: 1) == nil)
    }

    @Test func aWideCharacterIsOnePress() throws {
        let s = try session(prompt + "echo 中文")
        // Either half of 中.
        #expect(s.promptClickMove(col: 7, row: 0) == -2)
        #expect(s.promptClickMove(col: 8, row: 0) == -2)
    }

    @Test func overASoftWrappedCommand() throws {
        let s = try session(cols: 20, prompt + String(repeating: "x", count: 30))
        // The cursor's on the second row; the click on the first.
        #expect(s.promptClickMove(col: 2, row: 0) == -30)
        #expect(s.promptClickMove(col: 19, row: 0) == -13)
    }
}
