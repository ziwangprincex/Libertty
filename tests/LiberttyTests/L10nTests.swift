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
            // As many values, each one once (a translation may number them to move them: %2$@).
            #expect(Self.placeholders(en).count == Self.placeholders(zh).count, "\(en) → \(zh)")
            let numbered = Self.placeholders(zh).compactMap { $0 }
            #expect(numbered.isEmpty || numbered.sorted() == Array(1...Self.placeholders(en).count), "\(en) → \(zh)")
        }
        // A moved value lands where its translation puts it.
        #expect(String(format: "%2$@ 上的 %1$@", "5173", "devbox") == "devbox 上的 5173")
    }

    /// The `%@` in `text`, each with its number when it has one (`%2$@`).
    private static func placeholders(_ text: String) -> [Int?] {
        var out: [Int?] = [], rest = Substring(text)
        while let at = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: at)...]
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix("$@"), !digits.isEmpty { out.append(Int(digits)) } else if rest.hasPrefix("@") { out.append(nil) }
        }
        return out
    }
}
