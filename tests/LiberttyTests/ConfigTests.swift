import Foundation
import Testing
@testable import LiberttyApp

/// The config file's keys: what each accepts, what it refuses, and that
/// what `values(of:)` writes reads back the same.
struct ConfigTests {
    @Test func everyDocumentedKeyRoundTrips() {
        let config = Config()
        for (key, _) in Config.documentation where !Config.repeatable.contains(key) && key != "config-file" {
            var back = Config()
            for value in config.values(of: key) {
                #expect(back.set(key, value) == nil, "\(key) = \(value) doesn't read back")
            }
            #expect(back.values(of: key) == config.values(of: key), "\(key)")
        }
    }

    @Test func emptyValueResetsToDefault() {
        var c = Config()
        _ = c.set("font-size", "20")
        _ = c.set("font-size", "")
        #expect(c.fontSize == Config().fontSize)
    }

    @Test(arguments: [("font-size", "abc"), ("cursor-style", "triangle"), ("minimum-contrast", "x"),
                      ("adjust-cell-height", "tall"), ("accent-color", "blurple"), ("pane-style", "roomy"),
                      ("web-access", "everywhere"), ("theme", "No Such Theme At All"),
                      ("ssh-agent", "keepass")])
    func badValuesAreRefused(key: String, value: String) {
        var c = Config()
        #expect(c.set(key, value) != nil)
    }

    /// Where the tabs are listed: a sidebar on either side, or a strip over
    /// the panes or under them. `sidebar` is the left one.
    @Test func tabBarPlaces() {
        var c = Config()
        #expect(c.tabBar == .left && c.tabBar.inSidebar && !c.tabBar.inStrip)
        #expect(c.set("tab-bar", "bottom") == nil && c.tabBar == .bottom)
        #expect(c.tabBar.inStrip && !c.tabBar.inSidebar)
        #expect(c.values(of: "tab-bar") == ["bottom"])
        #expect(c.set("tab-bar", "top") == nil && c.tabBar.inStrip)
        #expect(c.set("tab-bar", "sidebar") == nil && c.tabBar == .left)
        #expect(c.set("tab-bar", "right") == nil && c.tabBar.inSidebar)
        // Refused, saying what it takes; the setting stays.
        #expect(c.set("tab-bar", "under")?.contains("bottom") == true && c.tabBar == .right)
        #expect(Config.parse("tab-bar = bottom\n").0.tabBar == .bottom)
    }

    /// Where minimized floating panes' capsules sit, and the corner a drag lets go in.
    @Test func minimizedFloatingPanesCorner() {
        var c = Config()
        #expect(c.floatingMinimizedCorner == .bottomRight)
        #expect(c.set("floating-minimized-corner", "top-center") == nil && c.floatingMinimizedCorner == .topCenter)
        #expect(c.values(of: "floating-minimized-corner") == ["top-center"])
        #expect(c.set("floating-minimized-corner", "middle") != nil && c.floatingMinimizedCorner == .topCenter)
        #expect(c.set("floating-minimized-corner", "") == nil && c.floatingMinimizedCorner == .bottomRight)
        // Where a drag lets go: top or bottom, and which third across.
        for corner in Config.MinimizedCorner.allCases {
            #expect(Config.MinimizedCorner(top: corner.top, side: corner.side) == corner)
        }
        #expect(Config.MinimizedCorner(top: false, side: -3) == .bottomLeft)
    }

    @Test func numbersAreClamped() {
        var c = Config()
        _ = c.set("font-size", "500")
        #expect(c.fontSize == 72)
        _ = c.set("minimum-contrast", "40")
        #expect(c.minimumContrast == 21)
    }

    @Test func applyReportsLinesAndIncludes() {
        var c = Config()
        let (warnings, includes) = c.apply("font-size = 15\nnonsense\nbogus-key = 1\nconfig-file = ?extra\n# comment\n")
        #expect(c.fontSize == 15)
        #expect(includes == ["?extra"])
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.hasPrefix("line 2") })
    }

    @Test func durations() {
        #expect(Config.duration("10") == 10)
        #expect(Config.duration("1m30s") == 90)
        #expect(Config.duration("2h") == 7200)
        #expect(Config.duration("5x") == nil)
    }

    /// `notify-on-command-finish-after = 1e20` once trapped (Int(1e20)) on
    /// every ⌘⇧P, in Settings ▸ Notifications and in +show-config.
    @Test func hugeDurationsDontTrap() {
        let week = 7.0 * 24 * 3600
        #expect(Config.duration("1e20") == week)
        #expect(Config.duration(String(repeating: "9", count: 30) + "h") == week)
        for text in ["inf", "-inf", "nan", "1e400", String(repeating: "9", count: 400), "-5"] {
            #expect(Config.duration(text) == nil, "\(text)")
        }
        var c = Config()
        #expect(c.set("notify-on-command-finish-after", "1e20") == nil)
        #expect(c.values(of: "notify-on-command-finish-after") == ["604800s"])
        #expect(c.set("notify-on-command-finish-after", "inf") != nil)
        c.notifyOnCommandFinishAfter = 1e20
        #expect(c.values(of: "notify-on-command-finish-after") == ["1e+20s"])
        // Every key reads back, at once, without a trap.
        for (key, _) in Config.documentation { _ = c.values(of: key) }
    }

    @Test func programStates() throws {
        #expect(try Config.states("blocked,done").get() == [.blocked, .done])
        #expect(try Config.states("none").get().isEmpty)
        #expect(Config.statesString(Set(ProgramStatusStore.State.allCases)) == "all")
        if case .success = Config.states("bogus") { Issue.record("bogus accepted") }
    }

    @Test func ligaturesFollowFontFeatures() {
        var c = Config()
        #expect(c.ligatures)
        _ = c.set("font-feature", "-calt")
        #expect(!c.ligatures)
        _ = c.set("font-feature", "calt")
        #expect(c.ligatures)
    }

    @Test func themeSpecs() {
        #expect(ThemeSpec("Nord") == ThemeSpec(light: "Nord", dark: "Nord"))
        #expect(ThemeSpec("light:A, dark:B") == ThemeSpec(light: "A", dark: "B"))
        #expect(ThemeSpec("A,B") == nil)
    }

    @Test func paneOpacityWithGlass() {
        var c = Config()
        #expect(c.paneOpacity == 1)
        c.paneGlass = true
        #expect(c.paneOpacity == 0.7)
        // Glass terminals are Rex's 70% whatever background-opacity says:
        // at 0 a pane would vanish into the glass.
        c.backgroundOpacity = 0
        #expect(c.paneOpacity == 0.7)
        c.paneGlass = false
        #expect(c.paneOpacity == 0)
    }

    @Test func accentFromTheConfig() {
        var c = Config()
        let theme = Theme.named(Theme.defaultName)
        #expect(c.accent(with: theme) == nil)
        _ = c.set("accent-color", "#30D158")
        #expect(c.accent(with: theme) == RGB(0x30, 0xd1, 0x58))
        #expect(c.values(of: "accent-color") == ["#30d158"])
    }
}

/// Rex's interface style and the older pane-glass.
struct InterfaceStyleTests {
    @Test func interfaceStyleWinsOverPaneGlass() {
        var c = Config()
        #expect(c.set("pane-glass", "true") == nil)
        #expect(c.glass && c.values(of: "interface-style") == ["glass"])
        #expect(c.set("interface-style", "classic") == nil)
        #expect(!c.glass)
        #expect(c.set("interface-style", "") == nil)
        #expect(c.glass)
    }
}

/// What's written to the config file: a line each, in a file of the test's own.
struct ConfigFileTests {
    /// A temporary config file holding `text`, and its store.
    private func store(_ text: String) throws -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (ConfigStore(url: file, watch: false), file)
    }

    /// `libertty +set $'command=x\nremote-control = true'` once wrote two
    /// lines: the second a setting no program may change.
    @Test func aValueIsOneLine() throws {
        var c = Config()
        for value in ["x\nremote-control = true", "x\rremote-control = true", "x\r\nbrowser-automation = true",
                      "x\u{2028}y", "x\u{85}y", "x\u{1b}[31m", "x\u{0}"] {
            #expect(c.set("command", value) != nil, "\(value.debugDescription)")
        }
        #expect(c.set("command", "/bin/zsh -c 'echo\ta'") == nil)
        let (store, file) = try store("font-size = 13\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        store.set("command", "x\nremote-control = false")
        store.add("keybind", "cmd+b=new_tab\nbrowser-automation = true")
        #expect(try String(contentsOf: file, encoding: .utf8) == "font-size = 13\n")
        #expect(store.savedConfig.remoteControl && !store.savedConfig.browserAutomation)
    }

    /// set_setting on a key of many lines once wrote one line in place of all
    /// of them: the other palette colors, keybinds and font features gone.
    @Test func aSettingActionKeepsTheOtherLines() throws {
        let (store, file) = try store("""
            palette = 0=#000000
            palette = 1=#aa0000
            palette = 2=#00aa00
            keybind = cmd+b=new_tab
            keybind = cmd+j=new_window
            font-feature = -calt
            font-size = 13

            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for text in ["set_setting:palette=1=#ff5555", "set_setting:keybind=cmd+b=close_tab", "set_setting:font-feature=ss01",
                     "set_setting:font-size=14"] {
            #expect(SettingActions.perform(Action(text)!, in: store), "\(text)")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == """
            palette = 0=#000000
            palette = 2=#00aa00
            keybind = cmd+j=new_window
            font-feature = -calt
            font-size = 14
            palette = 1=#ff5555
            keybind = cmd+b=close_tab
            font-feature = ss01

            """)
        #expect(store.savedConfig.palette.count == 3)
        #expect(store.savedConfig.keybinds == ["cmd+j=new_window", "cmd+b=close_tab"])
    }

    /// A config kept with your dotfiles, linked into ~/.config/libertty: a
    /// change in Settings is written there, and the link stays a link.
    @Test func aLinkedConfigStaysLinked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
        let dotfiles = dir.appendingPathComponent("dotfiles"), folder = dir.appendingPathComponent("libertty")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in [dotfiles, folder] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let real = dotfiles.appendingPathComponent("libertty.conf"), link = folder.appendingPathComponent("config")
        try "font-size = 13\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/libertty.conf")
        let store = ConfigStore(url: link, watch: false)
        store.set("font-size", "14")
        store.add("palette", "1=#ff5555")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/libertty.conf")
        #expect(try String(contentsOf: real, encoding: .utf8) == "font-size = 14\npalette = 1=#ff5555\n")
        #expect(store.savedConfig.fontSize == 14)
    }
}
