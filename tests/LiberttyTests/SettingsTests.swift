import Testing
@testable import LiberttyApp

/// The Settings window's controls, as its registry lists them: every key is
/// one the config knows, and every value a control can write is one it takes.
struct SettingsTests {
    @Test func everyKeyIsDocumented() {
        let documented = Set(Config.documentation.map(\.key))
        for item in SettingsRegistry.items {
            for key in item.keys {
                #expect(documented.contains(key), "\(item.id): \(key) isn't in Config.documentation")
            }
        }
    }

    @Test func everyValueIsAccepted() {
        for item in SettingsRegistry.items {
            for (key, value) in item.values {
                var c = Config()
                #expect(c.set(key, value) == nil, "\(item.id): \(key) = \(value) is refused")
            }
        }
    }

    @Test func idsAreUnique() {
        var seen = Set<String>()
        for item in SettingsRegistry.items {
            #expect(seen.insert(item.id).inserted, "\(item.id) is listed twice")
        }
    }

    /// Each section of a page has a title of its own: the page tells its
    /// sections apart by it, and a footer goes under the section it names
    /// (the startup command's under Shell, once shown under a second Shell).
    @Test @MainActor func sectionTitlesAreUniqueOnAPage() {
        for page in SettingsPage.allCases {
            let titles = SettingsForm.sections(of: page).map(\.title)
            #expect(Set(titles).count == titles.count, "\(page): \(titles)")
        }
    }

    /// Themes shows its switch and its Import button under the cards in
    /// every language: found by their controls (by English titles, they
    /// were missing in Chinese, whose section titles are its own).
    @Test @MainActor func theThemesPageShowsItsRowsBelowTheCards() {
        #expect(ThemesPage.sectionsBelowCards.flatMap(\.rows).map(\.id) == ["palette-generate", "theme-import"])
    }

    /// Each choice list holds the default, so a config that doesn't set the
    /// key still shows a choice picked.
    @Test func choicesIncludeTheDefault() {
        for item in SettingsRegistry.items where !item.options.isEmpty {
            let key = item.key!
            let value = Config().values(of: key).first ?? ""
            #expect(item.options.contains { SettingsModel.matches($0, value, of: key) }, "\(item.id): no choice for the default \(value)")
        }
    }

    @Test func everyShortcutIsAnAction() {
        for group in SettingsShortcuts.groups {
            for entry in group.actions {
                #expect(Action(entry.action) != nil, "\(group.title): \(entry.action) isn't an action")
            }
        }
    }

    @Test func searchFindsCursorOnTheTerminalPage() {
        #expect(SettingsRegistry.search("cursor").first?.page == .terminal)
        #expect(SettingsRegistry.search("tab style").first?.key == "tab-bar")
        #expect(SettingsRegistry.search("no such setting anywhere").isEmpty)
    }

    @Test func settingsHasTheCommaKey() {
        #expect(Keybinds(entries: []).trigger(for: .openSettings)?.configString == "cmd+comma")
        #expect(Action("open_settings") == .openSettings)
        #expect(Action("open_config") == .openConfig)
    }

    /// A choice matches the value as the config writes it back.
    @Test func choicesMatchSpellings() {
        let auto = SettingsOption(label: "Auto", value: "auto", also: ["system"])
        #expect(SettingsModel.matches(auto, "system", of: "window-theme"))
        #expect(SettingsModel.matches(SettingsOption(label: "1 minute", value: "60s"), "60s", of: "notify-on-command-finish-after"))
        #expect(!SettingsModel.matches(SettingsOption(label: "Light", value: "light"), "dark", of: "window-theme"))
    }

    @Test func ligatureLinesAreRecognized() {
        #expect(SettingsModel.onlyLigatures("-calt, -liga"))
        #expect(SettingsModel.onlyLigatures("-calt"))
        #expect(!SettingsModel.onlyLigatures("-calt, +ss01"))
        #expect(!SettingsModel.onlyLigatures("+calt"))
    }
}

/// The keybindable setting actions: what a `keybind` line parses to, what
/// each would write given a config, and what the config's diagnostics say
/// when a setting can't do what the action asks.
struct SettingActionTests {
    private func problem(_ text: String) -> String? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        return SettingActions.parse(parts[0], parts.count > 1 ? parts[1] : nil).problem
    }

    @Test func eachOneParsesAndSaysItselfAgain() {
        for text in ["toggle_setting:copy-on-select", "cycle_setting:window-theme",
                     "cycle_setting:window-theme:light,dark", "increase_setting:font-size",
                     "increase_setting:font-size:2", "decrease_setting:font-size:2",
                     "reset_setting:font-size", "set_setting:font-size=16"] {
            let action = Action(text)
            #expect(action != nil, "\(text) didn't parse")
            #expect(action?.configString == text, "\(text) came back as \(action?.configString ?? "nothing")")
        }
    }

    /// Numbers no Int holds never reach `Int(_:)`, which traps: a step of
    /// infinity is refused, and one that goes past any Int writes nothing
    /// (it once crashed the app, and `libertty +action` with it).
    @Test func hugeNumbersDontTrap() {
        #expect(Action("increase_setting:scrollback-limit:inf") == nil)
        #expect(problem("increase_setting:scrollback-limit:inf")?.contains("positive number") == true)
        let huge = Action("increase_setting:scrollback-limit:1e19")
        #expect(huge != nil)
        #expect(huge?.configString == "increase_setting:scrollback-limit:1e+19")
        _ = huge.flatMap { SettingActions.next($0, in: Config()) }
        #expect(SettingsItem.number(1e19) == "1e+19")
        #expect(SettingsItem.number(.infinity) == "inf")
        #expect(SettingsItem.number(-.infinity) == "-inf")
        #expect(SettingsItem.number(12) == "12")
    }

    @Test func whatIsRefusedSaysWhatToDoInstead() {
        #expect(Action("toggle_setting") == nil)
        #expect(problem("toggle_setting")?.contains("needs a setting") == true)
        #expect(problem("toggle_setting:no-such-setting")?.contains("no setting called") == true)
        // A number isn't a switch, and the message names what it does take.
        let notSwitch = problem("toggle_setting:font-size")
        #expect(notSwitch?.contains("isn't a switch") == true)
        #expect(notSwitch?.contains("increase") == true)
        #expect(notSwitch?.contains("reset") == true)
        // Nor is a choice a number.
        #expect(problem("increase_setting:window-theme")?.contains("isn't a number") == true)
        #expect(problem("increase_setting:font-size:0")?.contains("positive number") == true)
        #expect(problem("increase_setting:font-size:soon")?.contains("positive number") == true)
        #expect(problem("set_setting:font-size")?.contains("KEY=VALUE") == true)
        #expect(problem("set_setting:font-size=huge")?.contains("doesn't take") == true)
        #expect(problem("cycle_setting:window-theme:light")?.contains("two values") == true)
        #expect(problem("cycle_setting:window-theme:light,nope")?.contains("doesn't take") == true)
        // A switch has nothing to cycle, and a plain setting no choices.
        #expect(problem("cycle_setting:copy-on-select")?.contains("toggle_setting") == true)
        #expect(problem("cycle_setting:command")?.contains("no set of values") == true)
        #expect(problem("reset_setting:font-size:2")?.contains("a setting only") == true)
        // A key of many lines: cycling, resetting or emptying it would drop them.
        for text in ["reset_setting:keybind", "cycle_setting:palette:1=#ff0000,1=#00ff00", "set_setting:font-feature=",
                     "reset_setting:palette"] {
            #expect(Action(text) == nil, "\(text)")
            #expect(problem(text)?.contains("would drop the others") == true, "\(text)")
        }
        #expect(problem("toggle_setting:keybind") == "“keybind” isn't a switch: it needs a value")
        #expect(Action("set_setting:palette=1=#ff5555") != nil)
        #expect(Action("set_setting:keybind=cmd+b=new_tab") != nil)
    }

    /// The config's own diagnostics carry it (the errors window lists these).
    @Test func theConfigSaysWhyALineIsWrong() {
        #expect(Keybinds.validate("cmd+b=toggle_setting:copy-on-select") == nil)
        #expect(Keybinds.validate("cmd+b=increase_setting:font-size:2") == nil)
        #expect(Keybinds.validate("cmd+b=toggle_setting:font-size")?.contains("isn't a switch") == true)
        #expect(Keybinds.validate("cmd+b=toggle_setting:no-such-setting")?.contains("no setting called") == true)
        var config = Config()
        #expect(config.set("keybind", "cmd+b=toggle_setting:font-size") != nil)
        #expect(config.set("keybind", "cmd+b=toggle_setting:copy-on-select") == nil)
    }

    @Test func aSwitchFlipsAndFlipsBack() {
        var config = Config()
        let toggle = Action("toggle_setting:copy-on-select")!
        guard let first = SettingActions.next(toggle, in: config) else { return #expect(Bool(false)) }
        #expect(first.key == "copy-on-select")
        #expect(config.set("copy-on-select", first.value) == nil)
        let back = SettingActions.next(toggle, in: config)
        #expect(back?.value != first.value)
        #expect(config.set("copy-on-select", back!.value) == nil)
        #expect(SettingActions.next(toggle, in: config)?.value == first.value)
    }

    /// A choice goes round its control's values, or the ones the keybind names.
    @Test func aChoiceGoesRound() {
        var config = Config()
        let cycle = Action("cycle_setting:window-theme")!
        _ = config.set("window-theme", "auto")
        #expect(SettingActions.next(cycle, in: config)?.value == "light")
        _ = config.set("window-theme", "light")
        #expect(SettingActions.next(cycle, in: config)?.value == "dark")
        _ = config.set("window-theme", "dark")
        #expect(SettingActions.next(cycle, in: config)?.value == "auto")
        // The ones named, and a value outside them starts at the first.
        let named = Action("cycle_setting:window-theme:light,dark")!
        _ = config.set("window-theme", "light")
        #expect(SettingActions.next(named, in: config)?.value == "dark")
        _ = config.set("window-theme", "auto")
        #expect(SettingActions.next(named, in: config)?.value == "light")
    }

    /// A number moves by its Settings control's step, or the keybind's, and
    /// no further than the control allows (font size: 6 to 72 by 1).
    @Test func aNumberStepsAndStopsAtItsEnds() {
        var config = Config()
        func next(_ text: String) -> String? { SettingActions.next(Action(text)!, in: config)?.value }
        _ = config.set("font-size", "13")
        #expect(next("increase_setting:font-size") == "14")
        #expect(next("decrease_setting:font-size") == "12")
        #expect(next("increase_setting:font-size:3") == "16")
        #expect(next("decrease_setting:font-size:3") == "10")
        #expect(next("increase_setting:font-size:0.5") == "13.5")
        // Clamped to the range, and nothing to write once it's there.
        _ = config.set("font-size", "70")
        #expect(next("increase_setting:font-size:100") == "72")
        _ = config.set("font-size", "72")
        #expect(next("increase_setting:font-size") == nil)
        _ = config.set("font-size", "6")
        #expect(next("decrease_setting:font-size:100") == nil)
        #expect(next("increase_setting:font-size") == "7")
    }

    @Test func settingAndResetting() {
        let config = Config()
        #expect(SettingActions.next(Action("set_setting:font-size=16")!, in: config)?.value == "16")
        // Reset writes nothing: the line leaves the file, and the default stands.
        let reset = SettingActions.next(Action("reset_setting:font-size")!, in: config)
        #expect(reset?.key == "font-size")
        #expect(reset?.value == "")
    }

    /// How they read where actions are listed, by the Settings window's own
    /// name for the setting.
    @Test func howTheyRead() {
        let fontSize = SettingsRegistry.items.first { $0.key == "font-size" }?.title ?? "?"
        #expect(SettingActions.title(Action("increase_setting:font-size")!) == fontSize + ": " + L10n.t("Bigger"))
        #expect(SettingActions.title(Action("decrease_setting:font-size:2")!) == fontSize + ": " + L10n.t("Smaller"))
        #expect(SettingActions.title(Action("set_setting:font-size=16")!) == fontSize + ": 16")
        let onSelect = SettingsRegistry.items.first { $0.key == "copy-on-select" }?.title ?? "?"
        #expect(SettingActions.title(Action("toggle_setting:copy-on-select")!) == L10n.t("Toggle") + " " + onSelect)
        // A setting with no control of its own reads by its config key.
        #expect(SettingsRegistry.items.allSatisfy { $0.key != "cursor-color" })
        #expect(SettingActions.title(Action("reset_setting:cursor-color")!) == L10n.t("Reset") + " cursor-color")
        #expect(SettingActions.title(.newTab) == nil)
    }
}
