import AppKit

/// A setting the command palette changes in place (Rex's Change Terminal
/// Font…, Change Cursor Style…): its choices, each tried out in every window
/// as it's selected; Return writes it to the config, Esc goes back.
struct SettingPicker {
    struct Option {
        var label: String
        /// The config value; empty removes the line (the default).
        var value: String
        var detail: String = ""
        /// The label drawn in this font (the font picker's rows).
        var font: NSFont?
    }

    var key: String
    var title: String
    var symbol: String
    var options: () -> [Option]

    /// The value the config files hold now (not one being tried out).
    var current: String { ConfigStore.shared.savedConfig.values(of: key).first ?? "" }

    static let all: [SettingPicker] = [
        SettingPicker(key: "theme", title: "Theme", symbol: "paintpalette") {
            var names = Theme.all.map(\.name)
            let known = Set(names.map { $0.lowercased() })
            names += ThemeLibrary.shared.entries.map(\.name).filter { !known.contains($0.lowercased()) }
            return names.map { Option(label: $0, value: $0.contains(",") ? "\"\($0)\"" : $0, detail: Theme.builtIn($0) != nil ? "built in" : "") }
        },
        SettingPicker(key: "font-family", title: "Terminal Font", symbol: "textformat") {
            [Option(label: FontRegistry.bundledFamily, value: "", detail: "bundled",
                    font: NSFont(name: FontRegistry.bundledFamily, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular))]
                + FontSet.monospacedFamilies().filter { $0 != FontRegistry.bundledFamily }.map { family in
                    let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
                    return Option(label: family, value: family, font: NSFont(descriptor: descriptor, size: 13))
                }
        },
        SettingPicker(key: "font-size", title: "Terminal Font Size", symbol: "textformat.size") {
            var sizes = [10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28].map(String.init)
            let current = ConfigStore.shared.savedConfig.values(of: "font-size").first ?? "13"
            if !sizes.contains(current) { sizes.append(current) }
            return sizes.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
                .map { Option(label: "\($0) pt", value: $0, detail: $0 == "13" ? "default" : "") }
        },
        SettingPicker(key: "adjust-cell-height", title: "Line Height", symbol: "arrow.up.and.down.text.horizontal") {
            [Option(label: "The font's own", value: "", detail: "default")]
                + ["-10%", "-5%", "5%", "10%", "15%", "20%", "25%", "30%", "40%", "50%"].map {
                    Option(label: $0.hasPrefix("-") ? "\($0) shorter" : "+\($0) taller", value: $0)
                }
        },
        SettingPicker(key: "minimum-contrast", title: "Minimum Text Contrast", symbol: "circle.lefthalf.filled") {
            [Option(label: "Off", value: "", detail: "colors as programs ask"),
             Option(label: "1.1", value: "1.1", detail: "no invisible text"),
             Option(label: "3", value: "3", detail: "easy to read"),
             Option(label: "4.5", value: "4.5", detail: "WCAG AA"),
             Option(label: "7", value: "7", detail: "WCAG AAA")]
        },
        SettingPicker(key: "cursor-style", title: "Cursor Style", symbol: "character.cursor.ibeam") {
            [Option(label: "Block", value: "", detail: "default"), Option(label: "Bar", value: "bar"),
             Option(label: "Underline", value: "underline"), Option(label: "Hollow Block", value: "block_hollow")]
        },
        SettingPicker(key: "cursor-style-blink", title: "Cursor Blink", symbol: "light.max") {
            [Option(label: "As programs ask", value: "", detail: "blinks unless one turns it off"),
             Option(label: "Blink", value: "true"), Option(label: "Steady", value: "false")]
        },
        SettingPicker(key: "window-padding-color", title: "Padding Color", symbol: "square.dashed") {
            [Option(label: "Background", value: "", detail: "default"),
             Option(label: "Extend", value: "extend", detail: "edge cells' colors, Rex's Match program backgrounds"),
             Option(label: "Extend Always", value: "extend-always", detail: "every edge")]
        },
        SettingPicker(key: "background-opacity", title: "Background Opacity", symbol: "square.on.square.intersection.dashed") {
            ["", "0.95", "0.9", "0.85", "0.8", "0.7", "0.6"].map {
                Option(label: $0.isEmpty ? "Opaque" : "\(Int((Double($0) ?? 1) * 100))%", value: $0, detail: $0.isEmpty ? "default" : "")
            }
        },
        SettingPicker(key: "unfocused-split-opacity", title: "Unfocused Pane Fade", symbol: "rectangle.split.2x1") {
            [("1", "None"), ("0.85", "Light"), ("0.75", "Medium"), ("", "Default"), ("0.5", "Strong")].map {
                Option(label: $0.1, value: $0.0, detail: $0.0.isEmpty ? "65%" : "\(Int((Double($0.0) ?? 1) * 100))%")
            }
        },
        SettingPicker(key: "macos-option-as-alt", title: "Option Key Behavior", symbol: "option") {
            [Option(label: "Types characters", value: "", detail: "⌥ makes accents and symbols (default)"),
             Option(label: "Alt", value: "true", detail: "both Option keys act as Alt (Meta)"),
             Option(label: "Left Option is Alt", value: "left"), Option(label: "Right Option is Alt", value: "right")]
        },
        SettingPicker(key: "tab-bar", title: "Tab Style", symbol: "sidebar.left") {
            [Option(label: "Sidebar", value: "", detail: "tabs listed down the side (default)"),
             Option(label: "Top", value: "top", detail: "tabs along the toolbar")]
        },
        SettingPicker(key: "pane-style", title: "Pane Style", symbol: "rectangle.grid.2x2") {
            [Option(label: "Comfortable", value: "", detail: "cards with room around them (default)"),
             Option(label: "Compact", value: "compact", detail: "edge to edge, a hairline between")]
        },
        SettingPicker(key: "pane-glass", title: "Glass Panes", symbol: "drop") {
            [Option(label: "Off", value: "", detail: "solid terminals (default)"),
             Option(label: "On", value: "true", detail: "the desktop shows through the terminals, blurred; the frame stays solid")]
        },
        SettingPicker(key: "accent-color", title: "Accent Color", symbol: "paintbrush.pointed") {
            [Option(label: "System", value: "", detail: "System Settings' accent (default)"),
             Option(label: "Theme", value: "theme", detail: "the theme's cursor color, or its blue")]
                + [("Blue", "#0a84ff"), ("Purple", "#bf5af2"), ("Pink", "#ff375f"), ("Red", "#ff453a"), ("Orange", "#ff9f0a"),
                   ("Yellow", "#ffd60a"), ("Green", "#30d158"), ("Teal", "#40c8e0"), ("Graphite", "#8e8e93")]
                .map { Option(label: $0.0, value: $0.1, detail: $0.1) }
        },
        SettingPicker(key: "tab-icon-color", title: "Tab Icon Colors", symbol: "app.badge") {
            [Option(label: "Off", value: "", detail: "every program's glyph in gray (default)"),
             Option(label: "On", value: "true", detail: "each program's glyph in its color")]
        },
        SettingPicker(key: "split-autobalance", title: "Autobalance Splits", symbol: "equal.square") {
            [Option(label: "Off", value: "", detail: "a split halves its pane (default)"),
             Option(label: "On", value: "true", detail: "the panes even out after every split, close and move")]
        },
        SettingPicker(key: "pane-headers", title: "Pane Headers", symbol: "rectangle.topthird.inset.filled") {
            [Option(label: "Never", value: "", detail: "default"), Option(label: "In Splits", value: "split"),
             Option(label: "Always", value: "always")]
        },
    ]

    static func named(_ key: String) -> SettingPicker? { all.first { $0.key == key } }
}
