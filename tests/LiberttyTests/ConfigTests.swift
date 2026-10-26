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
                      ("web-access", "everywhere"), ("theme", "No Such Theme At All")])
    func badValuesAreRefused(key: String, value: String) {
        var c = Config()
        #expect(c.set(key, value) != nil)
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
        c.backgroundOpacity = 0.5
        #expect(c.paneOpacity == 0.5)
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
