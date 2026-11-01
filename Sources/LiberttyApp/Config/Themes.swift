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
    /// The text under a block cursor (Ghostty's `cursor-text`); nil: the background.
    var cursorText: RGB? = nil
    /// Selected text (Ghostty's `selection-foreground`); nil: its own color.
    var selectionForeground: RGB? = nil
    /// Colors 16–255 from this theme's own (Ghostty's `palette-generate` and
    /// `palette-harmonious`, which a theme file may set; the config's win).
    var paletteGenerate = false
    var paletteHarmonious = false
    /// Colors 16–255 set one by one, over the generated (or xterm's) ones.
    var extendedPalette: [Int: RGB] = [:]

    var isDark: Bool {
        let b = background
        return 0.2126 * Double(b.r) + 0.7152 * Double(b.g) + 0.0722 * Double(b.b) < 128
    }

    /// The window around the panes — sidebar, the gaps between cards — one
    /// surface, a step below the terminals (Rex's canvas; see `Surfaces`).
    var chrome: RGB { surfaces.canvas }

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

    /// The 256 colors terminals get: xterm's or generated ones, with the
    /// theme's own entries over them.
    var fullPalette: [RGB] {
        var p = paletteGenerate ? generatedPalette256(harmonious: paletteHarmonious) : palette256
        for (i, c) in extendedPalette where (16..<256).contains(i) { p[i] = c }
        return p
    }

    /// Ghostty's `palette-generate`: 16–255 from this theme's own colors
    /// instead of xterm's fixed ones — the 6×6×6 cube interpolated in CIELAB
    /// between the background, the six base hues and the foreground, and the
    /// gray ramp from the background to the foreground. A light theme's cube
    /// still runs dark to light unless `harmonious` (Ghostty's
    /// `palette-harmonious`) keeps it background to foreground.
    func generatedPalette256(harmonious: Bool) -> [RGB] {
        var corners = [Lab(background)] + (1...6).map { Lab(ansi[$0]) } + [Lab(foreground)]
        if corners[7].l < corners[0].l, !harmonious { corners.swapAt(0, 7) }
        var p = ansi
        for ri in 0..<6 {
            let tr = Double(ri) / 5
            let c0 = corners[0].mix(corners[1], tr), c1 = corners[2].mix(corners[3], tr)
            let c2 = corners[4].mix(corners[5], tr), c3 = corners[6].mix(corners[7], tr)
            for gi in 0..<6 {
                let tg = Double(gi) / 5
                let c4 = c0.mix(c1, tg), c5 = c2.mix(c3, tg)
                for bi in 0..<6 { p.append(c4.mix(c5, Double(bi) / 5).rgb) }
            }
        }
        for i in 0..<24 { p.append(corners[0].mix(corners[7], Double(i + 1) / 25).rgb) }
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
    /// `cursor-color`, `cursor-text`, `selection-background`,
    /// `selection-foreground`, `palette = N=#rrggbb`, `palette-generate` and
    /// `palette-harmonious` lines; anything else is ignored. Missing colors
    /// come from Libertty Dark.
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
            case "cursor-text": t.cursorText = RGB(string: value)
            case "selection-background": RGB(string: value).map { t.selection = $0 }
            case "selection-foreground": t.selectionForeground = RGB(string: value)
            case "palette":
                let p = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard p.count == 2, let i = Int(p[0]), let c = RGB(string: p[1]) else { continue }
                if (0..<16).contains(i) { t.ansi[i] = c } else if (16..<256).contains(i) { t.extendedPalette[i] = c }
            case "palette-generate": t.paletteGenerate = value.lowercased() == "true"
            case "palette-harmonious": t.paletteHarmonious = value.lowercased() == "true"
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
        // One half alone: Libertty's own theme for the other.
        if light == nil, dark != nil { light = "Libertty Light" }
        if dark == nil, light != nil { dark = Theme.defaultName }
        guard let light, let dark, !light.isEmpty, !dark.isEmpty else { return nil }
        (self.light, self.dark) = (light, dark)
    }

    var followsSystem: Bool { light != dark }
    var configString: String { followsSystem ? "light:\(light),dark:\(dark)" : light }
    func name(dark isDark: Bool) -> String { isDark ? dark : light }
}

/// Themes by name: theme files in `~/.config/libertty/themes/NAME` first,
/// then the themes of an installed Rex (read from its app, never copied),
/// then the theme files that ship with an installed Ghostty.app (its files
/// use the same format, so hundreds of schemes work as-is).
class ThemeLibrary {
    static let shared = ThemeLibrary()

    struct Entry {
        enum Location {
            /// A theme file of its own.
            case file(URL)
            /// One of the themes in Rex's `themes.json`, read already.
            case rex(URL, Theme)
        }

        let name: String
        /// `user`, `Rex` or `Ghostty`.
        let source: String
        let location: Location

        /// The file its colors are read from (Rex's themes.json for each of Rex's).
        var url: URL {
            switch location {
            case .file(let url), .rex(let url, _): url
            }
        }

        /// Whether it's a file of its own the Theme Customizer may replace or delete.
        var isOwn: Bool { source == "user" }
    }

    private var cache: [String: Entry]?

    var directories: [(URL, String)] {
        var dirs = [(ConfigStore.directory.appendingPathComponent("themes"), "user")]
        for app in ["/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"] {
            dirs.append((URL(fileURLWithPath: app + "/Contents/Resources/ghostty/themes"), "Ghostty"))
        }
        return dirs
    }

    /// Rex's themes file, in the first Rex app found (Rex.app, Rex Beta.app…).
    /// Set (tests): this file instead, nil for none.
    var rexThemesFile: URL?? = nil

    private var rexFile: URL? {
        if let rexThemesFile { return rexThemesFile }
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasPrefix("Rex") && $0.hasSuffix(".app") }.sorted()
            for app in apps {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(app)
                    .appendingPathComponent(RexThemes.path)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Forget the directory listings (on config reload, so new files show up).
    func invalidate() { cache = nil }

    /// Every theme, deduplicated by name (yours, then Rex's, then Ghostty's).
    var entries: [Entry] {
        if cache == nil {
            var found: [String: Entry] = [:]
            func add(_ entry: Entry) {
                let key = entry.name.lowercased()
                if found[key] == nil { found[key] = entry }
            }
            let dirs = directories
            func addFiles(in dir: URL, source: String) {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
                for name in names where !name.hasPrefix(".") {
                    add(Entry(name: name, source: source, location: .file(dir.appendingPathComponent(name))))
                }
            }
            for (dir, source) in dirs where source == "user" { addFiles(in: dir, source: source) }
            if let file = rexFile {
                for theme in RexThemes.read(file) { add(Entry(name: theme.name, source: "Rex", location: .rex(file, theme))) }
            }
            for (dir, source) in dirs where source != "user" { addFiles(in: dir, source: source) }
            cache = found
        }
        return cache!.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func entry(for name: String) -> Entry? {
        if cache == nil { _ = entries }
        return cache?[name.lowercased()]
    }

    func url(for name: String) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let path = (name as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return entry(for: name)?.url
    }

    func load(_ name: String) -> Theme? {
        if case .rex(_, var theme)? = entry(for: name)?.location {
            theme.name = name
            return theme
        }
        guard let url = url(for: name), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Theme.parse(name: name, text: text)
    }
}

/// Rex's themes, as its app ships them: a JSON array in its design tokens'
/// bundle, each `{id, name, appearance, source: {background, foreground,
/// cursor, cursorText, selectionBackground, selectionForeground, ansi[16],
/// paletteGenerate, paletteHarmonious}}` in sRGB hex. Read where Rex is
/// installed, as Ghostty's theme files are; never copied.
enum RexThemes {
    static let path = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"

    private struct Item: Decodable {
        let name: String
        let source: Source
    }

    private struct Source: Decodable {
        let background: String
        let foreground: String
        let cursor: String?
        let cursorText: String?
        let selectionBackground: String?
        let selectionForeground: String?
        let ansi: [String]
        let paletteGenerate: Bool?
        let paletteHarmonious: Bool?
    }

    /// The file as last read, until it changes (it's a few megabytes; the
    /// library is listed again on every config reload).
    nonisolated(unsafe) private static var last: (url: URL, date: Date?, themes: [Theme])?
    private static let lock = NSLock()

    static func read(_ url: URL) -> [Theme] {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if let last, last.url == url, last.date == date { return last.themes }
        let themes = (try? Data(contentsOf: url)).map(parse) ?? []
        last = (url, date, themes)
        return themes
    }

    /// The themes in the file; one without its two main colors, or with an
    /// ANSI palette that isn't 16 colors, is left out.
    static func parse(_ data: Data) -> [Theme] {
        guard let items = try? JSONDecoder().decode([Failable<Item>].self, from: data) else { return [] }
        return items.compactMap { item -> Theme? in
            guard let item = item.value, !item.name.isEmpty, !item.name.contains(","),
                  let bg = RGB(string: item.source.background), let fg = RGB(string: item.source.foreground) else { return nil }
            let ansi = item.source.ansi.compactMap { RGB(string: $0) }
            guard ansi.count == 16 else { return nil }
            var t = Theme(name: item.name, background: bg, foreground: fg,
                          cursor: item.source.cursor.flatMap { RGB(string: $0) } ?? fg,
                          selection: item.source.selectionBackground.flatMap { RGB(string: $0) } ?? Theme.all[0].selection,
                          ansi: ansi)
            t.cursorText = item.source.cursorText.flatMap { RGB(string: $0) }
            t.selectionForeground = item.source.selectionForeground.flatMap { RGB(string: $0) }
            t.paletteGenerate = item.source.paletteGenerate ?? false
            t.paletteHarmonious = item.source.paletteHarmonious ?? false
            return t
        }
    }

    /// One element of the array, nil when it doesn't decode (the rest still do).
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
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

/// CIELAB (D65), for mixing colors evenly by eye (Ghostty's `LAB`).
struct Lab {
    var l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) { (self.l, self.a, self.b) = (l, a, b) }

    init(_ c: RGB) {
        func linear(_ v: UInt8) -> Double {
            let x = Double(v) / 255
            return x > 0.04045 ? pow((x + 0.055) / 1.055, 2.4) : x / 12.92
        }
        let (r, g, b) = (linear(c.r), linear(c.g), linear(c.b))
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let x = f((r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047)
        let y = f(r * 0.2126729 + g * 0.7151522 + b * 0.0721750)
        let z = f((r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883)
        self.init(l: 116 * y - 16, a: 500 * (x - y), b: 200 * (y - z))
    }

    var rgb: RGB {
        let y = (l + 16) / 116, x = a / 500 + y, z = y - b / 200
        func inverse(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let (xf, yf, zf) = (inverse(x) * 0.95047, inverse(y), inverse(z) * 1.08883)
        func gamma(_ v: Double) -> UInt8 {
            let c = v > 0.0031308 ? 1.055 * pow(v, 1 / 2.4) - 0.055 : 12.92 * v
            return UInt8(min(max(c, 0), 1) * 255 + 0.5)
        }
        return RGB(gamma(xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314),
                   gamma(-xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560),
                   gamma(xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252))
    }

    func mix(_ other: Lab, _ t: Double) -> Lab {
        Lab(l: l + t * (other.l - l), a: a + t * (other.a - a), b: b + t * (other.b - b))
    }
}
