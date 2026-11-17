import Foundation
import LiberttyCore
import Testing
@testable import LiberttyApp

/// The input modes a program turns on to read the mouse and the keyboard
/// its own way, on a terminal written to directly: a command's end puts
/// back what the shell had, so a program that was killed leaves none of
/// them on, and what the shell sets for itself stands.
@Suite @MainActor struct InputModeTests {
    private let promptMark = "\u{1b}]133;A;cl=line\u{07}$ "
    /// What a full-screen program turns on: mouse reporting (SGR), focus
    /// reporting, bracketed paste, and the kitty keyboard protocol.
    private let programModes = "\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[?2004h\u{1b}[>1u"

    private func session() throws -> TerminalSession {
        try TerminalSession(size: GridSize(cols: 40, rows: 6, widthPx: 0, heightPx: 0), config: Config())
    }

    /// `kill -9 vim`: the shell marks the command's end, and the modes the
    /// program never turned off go off with it.
    @Test func aKilledProgramLeavesNoneOfThemOn() throws {
        let s = try session()
        s.show(promptMark + "vim\u{1b}]133;C\u{07}")
        s.show(programModes)
        #expect(s.inputModeSummary == ["mouse": "on", "focus": "on", "paste": "on", "kitty": "1"])
        // Killed: nothing of its own goes out, only the shell's own mark.
        s.show("\u{1b}]133;D;137\u{07}")
        #expect(s.inputModeSummary == ["mouse": "off", "focus": "off", "paste": "off", "kitty": "0"])
    }

    /// vim and htop draw on the alternate screen, and a killed one never
    /// leaves it: the screen is still theirs as the shell's prompt arrives,
    /// and the modes go back all the same.
    @Test func onTheAlternateScreenToo() throws {
        let s = try session()
        s.show(promptMark + "vim\u{1b}]133;C\u{07}")
        s.show("\u{1b}[?1049h" + programModes)
        #expect(s.isAlternateScreen)
        s.show("\u{1b}]133;D;137\u{07}")
        #expect(s.inputModeSummary == ["mouse": "off", "focus": "off", "paste": "off", "kitty": "0"])
    }

    /// What the shell had before the command is what comes back: fish turns
    /// on the kitty keyboard protocol and bracketed paste at its prompt, and
    /// a killed program must not cost it those.
    @Test func theShellsOwnModesComeBack() throws {
        let s = try session()
        // The shell's prompt, as fish 4's leaves the terminal.
        s.show(promptMark + "\u{1b}[?2004h\u{1b}[>5u")
        #expect(s.inputModeSummary["paste"] == "on")
        #expect(s.inputModeSummary["kitty"] == "5")
        s.show("htop\u{1b}]133;C\u{07}")
        s.show(programModes)
        #expect(s.inputModeSummary["kitty"] == "1")
        s.show("\u{1b}]133;D;137\u{07}")
        // Back to the shell's, not off.
        #expect(s.inputModeSummary == ["mouse": "off", "focus": "off", "paste": "on", "kitty": "5"])
    }

    /// A prompt that marks no command end (a shell without D): the next
    /// prompt puts them back instead.
    @Test func aPromptWithoutACommandEndPutsThemBack() throws {
        let s = try session()
        s.show(promptMark + "vim\u{1b}]133;C\u{07}" + programModes)
        #expect(s.inputModeSummary["mouse"] == "on")
        s.show("\r\n" + promptMark)
        #expect(s.inputModeSummary == ["mouse": "off", "focus": "off", "paste": "off", "kitty": "0"])
    }

    /// A program that turns them off itself is left alone: the modes it set
    /// and unset are the shell's again by the time the command ends.
    @Test func aProgramThatTidiesUpChangesNothing() throws {
        let s = try session()
        s.show(promptMark + "vim\u{1b}]133;C\u{07}" + programModes)
        // As vim does on exit.
        s.show("\u{1b}[?1002l\u{1b}[?1006l\u{1b}[?1004l\u{1b}[?2004l\u{1b}[<u")
        let tidied = s.inputModeSummary
        s.show("\u{1b}]133;D;0\u{07}")
        #expect(s.inputModeSummary == tidied)
        #expect(s.inputModeSummary["mouse"] == "off")
    }

    /// Two command marks with no end between them: a shell running inside
    /// the program (tmux) marks its own prompts, and those come through. The
    /// first mark is the one put back, so what the program turned on is
    /// never mistaken for what the shell had. (A program still in front of
    /// the terminal also keeps its modes; that needs a real pty to see.)
    @Test func theFirstCommandMarkIsTheOneRestored() throws {
        let s = try session()
        s.show(promptMark + "tmux\u{1b}]133;C\u{07}")
        s.show(programModes)
        s.show(promptMark + "ls\u{1b}]133;C\u{07}")
        s.show("\u{1b}]133;D;0\u{07}")
        #expect(s.inputModeSummary == ["mouse": "off", "focus": "off", "paste": "off", "kitty": "0"])
    }

    /// Without the shell's marks there is nothing to go back to, and
    /// nothing is touched: a program's own modes stand while it runs.
    @Test func withoutShellIntegrationNothingIsTouched() throws {
        let s = try session()
        s.show(programModes)
        #expect(s.inputModeSummary["mouse"] == "on")
        #expect(s.inputModeSummary["kitty"] == "1")
    }

    /// Each of the four mouse reporting modes is noticed, and X10 (mode 9)
    /// too: the summary says the mouse is reported whichever it is.
    @Test func everyMouseReportingMode() throws {
        for mode in [9, 1000, 1002, 1003] {
            let s = try session()
            s.show(promptMark + "p\u{1b}]133;C\u{07}" + "\u{1b}[?\(mode)h")
            #expect(s.inputModeSummary["mouse"] == "on", "mode \(mode)")
            s.show("\u{1b}]133;D;137\u{07}")
            #expect(s.inputModeSummary["mouse"] == "off", "mode \(mode)")
        }
    }
}
