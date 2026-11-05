import Foundation

/// The interface's language (`language`, Kero's Language setting): English,
/// or Simplified Chinese from Resources/locales/zh-Hans.json, whose keys
/// are the English text. Settled once at launch: menus, the palette,
/// Settings and the sidebar's words; a string without a translation stays
/// English. Command-line output, notices of what went wrong and the config
/// file's documentation stay English.
enum L10n {
    /// "en" or "zh-Hans".
    private(set) static var language = "en"
    private static var table: [String: String] = [:]

    /// The language `setting` names: itself, or with `auto` the first of
    /// macOS's preferred languages Libertty speaks. A probe or a snapshot
    /// (the test suite) stays in English unless its config says otherwise.
    static func resolve(_ setting: String, preferred: [String] = Locale.preferredLanguages,
                        arguments: [String] = CommandLine.arguments) -> String {
        switch setting.lowercased() {
        case "en", "english": return "en"
        case "zh-hans", "zh", "zh-cn", "chinese": return "zh-Hans"
        default:
            if arguments.contains(where: { $0.hasSuffix("-probe") || $0 == "--snapshot" }) { return "en" }
            for p in preferred {
                if p.hasPrefix("zh-Hans") || p == "zh" || p.hasPrefix("zh-CN") { return "zh-Hans" }
                if p.hasPrefix("en") { return "en" }
            }
            return "en"
        }
    }

    /// Takes on `setting` (at launch).
    static func start(_ setting: String) {
        language = resolve(setting)
        table = language == "en" ? [:] : load(language)
    }

    static func load(_ language: String) -> [String: String] {
        guard let url = AppResources.url("locales/\(language).json"), let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }

    /// `english` in the interface's language.
    static func t(_ english: String) -> String { table[english] ?? english }
}
