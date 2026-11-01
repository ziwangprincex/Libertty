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
