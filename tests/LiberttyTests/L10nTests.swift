import Foundation
import Testing
@testable import LiberttyApp

/// The interface's language.
struct L10nTests {
    @Test func resolves() {
        #expect(L10n.resolve("en", preferred: ["zh-Hans-CN"], arguments: ["Libertty"]) == "en")
        #expect(L10n.resolve("zh-Hans", preferred: ["en-US"], arguments: ["Libertty"]) == "zh-Hans")
        #expect(L10n.resolve("auto", preferred: ["zh-Hans-CN", "en"], arguments: ["Libertty"]) == "zh-Hans")
        #expect(L10n.resolve("auto", preferred: ["ja-JP", "en-US"], arguments: ["Libertty"]) == "en")
        // The test suite's probes stay in English, whatever macOS uses.
        #expect(L10n.resolve("auto", preferred: ["zh-Hans-CN"], arguments: ["Libertty", "--ui-probe", "x"]) == "en")
        #expect(L10n.resolve("auto", preferred: ["zh-Hans-CN"], arguments: ["Libertty", "--paste-probe"]) == "en")
        #expect(L10n.resolve("zh-Hans", preferred: [], arguments: ["Libertty", "--snapshot"]) == "zh-Hans")
    }

    /// Every menu, palette and Settings word has its translation, and each
    /// translation keeps the text's ellipsis and placeholders.
    @Test func theChineseTable() throws {
        let table = L10n.load("zh-Hans")
        #expect(table.count > 300)
        var english = Set<String>()
        for item in SettingsRegistry.items where !item.title.isEmpty { english.insert(item.title) }
        for page in SettingsPage.allCases { english.insert(page.title) }
        let missing = english.filter { table[$0] == nil && !$0.hasPrefix("Show Tab ") && $0 != $0.uppercased()
            && !["liberttyd", "Git"].contains($0) && !$0.contains("·") }
        #expect(missing.isEmpty, "untranslated: \(missing.sorted().prefix(20))")
        for (en, zh) in table {
            #expect(en.hasSuffix("…") == zh.hasSuffix("…") || en.hasSuffix("...") , "\(en) → \(zh)")
            #expect(!zh.isEmpty)
        }
    }
}
