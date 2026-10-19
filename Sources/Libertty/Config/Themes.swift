import AppKit

/// Built-in color schemes. ANSI 0–15 come from each theme's published
/// palette; 16–255 are the standard xterm cube and gray ramp.
struct Theme: Equatable {
    var name: String
    var background: RGB
    var foreground: RGB
    var cursor: RGB
    var selection: RGB
    var ansi: [RGB]  // 16 entries

    var isDark: Bool {
        let b = background
        return 0.2126 * Double(b.r) + 0.7152 * Double(b.g) + 0.0722 * Double(b.b) < 128
    }

    /// The window around the panes — toolbar, sidebar, the gaps between
    /// cards — one surface (Tern's look): a dark theme's terminals are cards
    /// lit above a deeper frame; a light theme's sit flush with it.
    var chrome: RGB {
        guard isDark else { return background }
        func deeper(_ v: UInt8) -> UInt8 { UInt8((Double(v) * 0.64).rounded()) }
        return RGB(deeper(background.r), deeper(background.g), deeper(background.b))
    }

    /// Full 256-color palette for libghostty-vt.
    var palette256: [RGB] {
        var p = ansi
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { p.append(RGB(r, g, b)) } } }
        for i in 0..<24 {
            let v = UInt8(8 + i * 10)
            p.append(RGB(v, v, v))
        }
        return p
    }

    static let defaultName = "Libertty Dark"

    /// A built-in theme, or a theme file (see `ThemeLibrary`); the default
    /// when neither exists.
    static func named(_ name: String) -> Theme {
        builtIn(name) ?? ThemeLibrary.shared.load(name) ?? all[0]
    }

    static func builtIn(_ name: String) -> Theme? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func exists(_ name: String) -> Bool {
        builtIn(name) != nil || ThemeLibrary.shared.url(for: name) != nil
    }

    /// A theme file in Ghostty's format: `background`, `foreground`,
    /// `cursor-color`, `selection-background` and `palette = N=#rrggbb`
    /// lines; anything else is ignored. Missing colors come from Libertty Dark.
    static func parse(name: String, text: String) -> Theme {
        var t = all[0]
        t.name = name
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": RGB(string: value).map { t.background = $0 }
            case "foreground": RGB(string: value).map { t.foreground = $0 }
            case "cursor-color": RGB(string: value).map { t.cursor = $0 }
            case "selection-background": RGB(string: value).map { t.selection = $0 }
            case "palette":
                let p = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2, let i = Int(p[0]), (0..<16).contains(i), let c = RGB(string: p[1]) { t.ansi[i] = c }
            default: break
            }
        }
        return t
    }

    static let all: [Theme] = [
        // Apple's dark system colors: the default, to sit naturally in macOS.
        make("Libertty Dark", bg: 0x1c1c1e, fg: 0xe6e6e6, cursor: 0xf2f2f2, sel: 0x3a4a6b, [
            0x3a3a3c, 0xff453a, 0x30d158, 0xffd60a, 0x0a84ff, 0xbf5af2, 0x64d2ff, 0xd1d1d6,
            0x636366, 0xff6961, 0x63e6a2, 0xffe066, 0x5eb0ff, 0xda8fff, 0x9ae8ff, 0xffffff]),
        make("Libertty Light", bg: 0xfaf9f6, fg: 0x1d1d1f, cursor: 0x1d1d1f, sel: 0xc9dcf5, [
            0x1d1d1f, 0xd70015, 0x248a3d, 0xb25000, 0x0040dd, 0x8944ab, 0x0071a4, 0x8e8e93,
            0x636366, 0xff3b30, 0x34c759, 0xc93400, 0x007aff, 0xaf52de, 0x0098d1, 0x3a3a3c]),
        make("Catppuccin Mocha", bg: 0x1e1e2e, fg: 0xcdd6f4, cursor: 0xf5e0dc, sel: 0x585b70, [
            0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
            0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8]),
        make("Catppuccin Latte", bg: 0xeff1f5, fg: 0x4c4f69, cursor: 0xdc8a78, sel: 0xacb0be, [
            0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
            0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc]),
        make("Tokyo Night", bg: 0x1a1b26, fg: 0xc0caf5, cursor: 0xc0caf5, sel: 0x33467c, [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5]),
        make("Gruvbox Dark", bg: 0x282828, fg: 0xebdbb2, cursor: 0xebdbb2, sel: 0x504945, [
            0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
            0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2]),
        make("Dracula", bg: 0x282a36, fg: 0xf8f8f2, cursor: 0xf8f8f2, sel: 0x44475a, [
            0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
            0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]),
        make("Nord", bg: 0x2e3440, fg: 0xd8dee9, cursor: 0xd8dee9, sel: 0x434c5e, [
            0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
            0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]),
        make("One Dark", bg: 0x282c34, fg: 0xabb2bf, cursor: 0x528bff, sel: 0x3e4451, [
            0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
            0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff]),
        make("Solarized Dark", bg: 0x002b36, fg: 0x839496, cursor: 0x93a1a1, sel: 0x073642, [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]),
        make("Solarized Light", bg: 0xfdf6e3, fg: 0x657b83, cursor: 0x586e75, sel: 0xeee8d5, [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]),
    ]

    private static func make(_ name: String, bg: UInt32, fg: UInt32, cursor: UInt32, sel: UInt32,
                             _ ansi: [UInt32]) -> Theme {
        Theme(name: name, background: RGB(hex: bg), foreground: RGB(hex: fg), cursor: RGB(hex: cursor),
              selection: RGB(hex: sel), ansi: ansi.map(RGB.init(hex:)))
    }
}

/// The `theme` setting: one theme, or `light:A,dark:B` to follow the
/// system appearance (Ghostty's syntax).
struct ThemeSpec: Equatable {
    var light: String
    var dark: String

    init(light: String, dark: String) { (self.light, self.dark) = (light, dark) }

    init?(_ text: String) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var light: String?, dark: String?
        for p in parts {
            if p.lowercased().hasPrefix("light:") { light = String(p.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if p.lowercased().hasPrefix("dark:") { dark = String(p.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else if parts.count == 1 { (light, dark) = (p, p) }
            else { return nil }
        }
        guard let light, let dark, !light.isEmpty, !dark.isEmpty else { return nil }
        (self.light, self.dark) = (light, dark)
    }

    var followsSystem: Bool { light != dark }
    var configString: String { followsSystem ? "light:\(light),dark:\(dark)" : light }
    func name(dark isDark: Bool) -> String { isDark ? dark : light }
}

/// Theme files: `~/.config/libertty/themes/NAME` first, then the themes that
/// ship with an installed Ghostty.app (its files use the same format, so
/// hundreds of schemes work as-is).
final class ThemeLibrary {
    static let shared = ThemeLibrary()

    struct Entry { let name: String; let url: URL; let source: String }

    private var cache: [String: Entry]?

    var directories: [(URL, String)] {
        var dirs = [(ConfigStore.directory.appendingPathComponent("themes"), "user")]
        for app in ["/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"] {
            dirs.append((URL(fileURLWithPath: app + "/Contents/Resources/ghostty/themes"), "Ghostty"))
        }
        return dirs
    }

    /// Forget the directory listings (on config reload, so new files show up).
    func invalidate() { cache = nil }

    /// Every theme file, deduplicated by name (earlier directories win).
    var entries: [Entry] {
        if cache == nil {
            var found: [String: Entry] = [:]
            for (dir, source) in directories {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let key = name.lowercased()
                    if found[key] == nil { found[key] = Entry(name: name, url: dir.appendingPathComponent(name), source: source) }
                }
            }
            cache = found
        }
        return cache!.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func url(for name: String) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let path = (name as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if cache == nil { _ = entries }
        return cache?[name.lowercased()]?.url
    }

    func load(_ name: String) -> Theme? {
        guard let url = url(for: name), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Theme.parse(name: name, text: text)
    }
}

extension RGB {
    init(hex: UInt32) {
        self.init(UInt8(hex >> 16 & 0xff), UInt8(hex >> 8 & 0xff), UInt8(hex & 0xff))
    }

    /// `#rrggbb`, `rrggbb` or `#rgb`.
    init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String { String(format: "#%02x%02x%02x", r, g, b) }
}
