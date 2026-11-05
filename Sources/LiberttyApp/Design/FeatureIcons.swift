import AppKit

/// Libertty's own full-colour icons (`assets/icons`, built into `Resources/icons` by
/// `assets/icons/scripts/build.mjs`): the Settings window's pages and the tools the
/// command palette opens. Each picture is a square with room around the icon for its
/// shadow, so it's drawn about 1.4× the size of the glyph it stands for.
enum FeatureIcon {
    /// The icon file's side over the icon's own width, from the build's padding.
    static let bleed: CGFloat = 1.4

    private static var cache: [String: NSImage?] = [:]

    /// The picture named `name` (a file in Resources/icons), nil if there's none.
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let image = AppResources.url("icons/\(name).png").flatMap(NSImage.init(contentsOf:))
        cache[name] = image
        return image
    }

    /// The picture for what an SF Symbol stood for in the command palette: a tool
    /// (Git, Browser, Tasks…) or a kind of document. Nil for everything else, which
    /// keeps its symbol.
    static func image(forSymbol symbol: String) -> NSImage? {
        let name: String? = switch symbol {
        case GitBlock.symbol: "branch"
        case "globe": "compass"
        case TasksBlock.symbol: "chart"
        case CanvasBlock.symbol: "pencil"
        case ProfilerBlock.symbol: "flame"
        case BoardBlock.symbol: "board"
        case SQLiteBlock.symbol: "database"
        case NotebookBlock.symbol: "notebook"
        case PluginsBlock.symbol: "puzzle"
        case ScreenShareBlock.symbol: "monitor"
        case "doc.richtext", "doc.plaintext": "document"
        case "photo": "photo"
        default: nil
        }
        return name.flatMap { image($0) }
    }

    /// A Settings page's picture; a page without one keeps its symbol tile.
    static func image(for page: SettingsPage) -> NSImage? {
        let names = [
            "liberttyd": "server", "interface": "window", "themes": "appearance", "terminal": "terminal",
            "shortcuts": "keycap", "integrations": "link", "notifications": "bell", "remoteHosts": "globe",
            "advanced": "gear",
        ]
        return names[page.rawValue].flatMap { image($0) }
    }
}
