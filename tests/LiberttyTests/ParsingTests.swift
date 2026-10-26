import AppKit
import Testing
@testable import LiberttyApp

/// Keys, actions, programs and paths as Libertty reads them.
struct ParsingTests {
    @Test(arguments: ["cmd+d", "ctrl+shift+c", "cmd++", "global:ctrl+alt+t"])
    func triggersParse(text: String) {
        let spec = text.hasPrefix("global:") ? String(text.dropFirst(7)) : text
        #expect(Trigger(spec) != nil, "\(text)")
    }

    @Test func badTriggers() {
        #expect(Trigger("cmd+nosuchkey") == nil)
        #expect(Keybinds.validate("cmd+d") != nil)
    }

    @Test(arguments: ["new_split:right", "new_split:auto", "goto_tab:3", "move_surface_to_tab:2", "open_theme_editor",
                      "show_tabs:working", "resize_split:left,10", "text:hi"])
    func actionsRoundTrip(text: String) throws {
        let action = try #require(Action(text))
        #expect(Action(action.configString) == action)
    }

    @Test func autoSplitIsItsOwnAction() {
        #expect(Action("new_split:auto") == .newSplitAuto)
        #expect(Action("new_split") == .newSplit(.right))
        #expect(Action("new_split:sideways") == nil)
    }

    @Test func programBadges() {
        #expect(ProgramBadge.forProcess("claude").name == "Claude Code")
        #expect(ProgramBadge.forProcess("-zsh").symbol == "terminal")
        #expect(ProgramBadge.forProcess("node", arguments: "/opt/homebrew/bin/claude --resume").name == "Claude Code")
        #expect(ProgramBadge.forProcess("node", arguments: "/Users/claude/server.js").name == "Node")
        #expect(ProgramBadge.forProcess("vim").tint == .green)
        #expect(ProgramBadge.forProcess("mytool").symbol == nil)
    }

    @Test func sshHosts() {
        #expect(ProgramTile.sshHost("-p 2222 -l me box.example") == "box.example")
        #expect(ProgramTile.sshHost("me@host -t tmux") == "me@host")
        #expect(ProgramTile.sshHost("-v") == nil)
    }

    @Test func shellQuoting() {
        #expect(ShellQuote.quote("/Users/me/src") == "/Users/me/src")
        #expect(ShellQuote.quote("it's here") == "'it'\\''s here'")
        #expect(ShellQuote.quote("") == "''")
    }

    @Test func filesThatWouldRun() {
        #expect(TerminalView.wouldRun(URL(fileURLWithPath: "/bin/ls")))
        #expect(TerminalView.wouldRun(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        #expect(!TerminalView.wouldRun(URL(fileURLWithPath: "/etc/hosts")))
        #expect(!TerminalView.wouldRun(URL(fileURLWithPath: "/tmp")))
        #expect(!TerminalView.wouldRun(URL(fileURLWithPath: "/no/such/file")))
    }

    @Test @MainActor func itermColorsImport() throws {
        func color(_ r: Double, _ g: Double, _ b: Double) -> [String: Double] {
            ["Red Component": r, "Green Component": g, "Blue Component": b]
        }
        let plist: [String: Any] = ["Background Color": color(0, 0, 0), "Foreground Color": color(1, 1, 1),
                                    "Ansi 1 Color": color(1, 0, 0)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID()).itermcolors")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let theme = try #require(ThemeEditor.read(url, name: "Probe"))
        #expect(theme.background == RGB(0, 0, 0))
        #expect(theme.ansi[1] == RGB(255, 0, 0))
    }
}
