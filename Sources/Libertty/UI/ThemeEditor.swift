import AppKit
import UniformTypeIdentifiers

/// Libertty ▸ Theme Editor… (Rex's custom themes): a theme's colors in
/// wells, every window showing each change as it's made; Save writes a theme
/// file (Ghostty's format) to the config folder's `themes` and uses it.
/// Starts from the theme in use, or any other; imports Ghostty theme files
/// and iTerm2's `.itermcolors`; deletes themes of your own.
@MainActor
final class ThemeEditor: NSObject, NSWindowDelegate {
    static let shared = ThemeEditor()

    private enum Slot: Hashable {
        case background, foreground, cursor, selection, ansi(Int)
    }

    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    private var window: NSWindow?
    private var theme = Theme.named(Theme.defaultName)
    /// The theme it started from, as its file (or Libertty) has it.
    private var original = Theme.named(Theme.defaultName)
    private var wells: [Slot: NSColorWell] = [:]
    /// Each palette color's contrast against the background, under its well.
    private var ratios: [Int: NSTextField] = [:]
    private let start = NSPopUpButton()
    private let name = NSTextField()
    private let generate = NSButton(checkboxWithTitle: "Make colors 16–255 from these (palette-generate)", target: nil, action: nil)
    private let harmonious = NSButton(checkboxWithTitle: "Keep a light theme's order (palette-harmonious)", target: nil, action: nil)
    private let extended = ExtendedPaletteView()
    private let delete = NSButton(title: "Delete Theme…", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    /// A preview waiting for the run loop: dragging in the color panel sends
    /// many changes a frame, and every window redraws for each preview.
    private var previewPending = false

    @objc func show(_ sender: Any?) {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            load(Self.themeInUse(), startingFrom: Self.themeInUseName())
            window.center()
        }
        // A probe's: off every screen, as its windows are.
        if Probe.running {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.setFrameOrigin(NSPoint(x: -20000, y: -23000))
            window.alphaValue = 1
            return
        }
        Probe.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// The theme the files name for the current appearance, overrides and all.
    private static func themeInUse() -> Theme { ConfigStore.shared.savedConfig.resolvedTheme }
    private static func themeInUseName() -> String {
        ConfigStore.shared.savedConfig.theme.name(dark: SystemAppearance.isDark)
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Theme Editor"
        window.isReleasedWhenClosed = false
        window.delegate = self

        start.target = self
        start.action = #selector(startChanged(_:))
        name.placeholderString = "Name"
        name.lineBreakMode = .byTruncatingTail
        let top = NSGridView(views: [
            [label("Start from"), start],
            [label("Save as"), name],
        ])
        top.column(at: 0).xPlacement = .trailing
        top.rowSpacing = 8
        start.widthAnchor.constraint(equalToConstant: 300).isActive = true
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let base = row([(.background, "Background"), (.foreground, "Text"), (.cursor, "Cursor"), (.selection, "Selection")],
                       ratios: false)
        let normal = row((0..<8).map { (.ansi($0), Self.ansiNames[$0]) }, ratios: true)
        let bright = row((8..<16).map { (.ansi($0), "Bright " + Self.ansiNames[$0 - 8]) }, ratios: true)

        for box in [generate, harmonious] {
            box.target = self
            box.action = #selector(generateChanged(_:))
        }
        extended.translatesAutoresizingMaskIntoConstraints = false
        extended.heightAnchor.constraint(equalToConstant: 56).isActive = true
        extended.widthAnchor.constraint(equalToConstant: 588).isActive = true

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importTheme(_:)))
        importButton.toolTip = "A Ghostty theme file, or iTerm2's .itermcolors"
        delete.target = self
        delete.action = #selector(deleteTheme(_:))
        let revert = NSButton(title: "Revert", target: self, action: #selector(revert(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save and Use", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [importButton, delete, NSView(), revert, cancel, save])
        buttons.spacing = 8

        let stack = NSStackView(views: [
            top, separator(),
            heading("Base"), base,
            heading("Normal colors"), normal,
            heading("Bright colors"), bright,
            separator(), generate, harmonious, extended,
            status, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: stack.views[2])
        stack.setCustomSpacing(4, after: stack.views[4])
        stack.setCustomSpacing(4, after: stack.views[6])
        stack.setCustomSpacing(2, after: generate)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 26, bottom: 18, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: extended.widthAnchor),
            status.widthAnchor.constraint(equalTo: extended.widthAnchor),
        ])
        window.contentView = content
        self.window = window
        return window
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func heading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 588).isActive = true
        return box
    }

    /// Wells side by side, each with its name (and its contrast) under it.
    private func row(_ slots: [(Slot, String)], ratios withRatios: Bool) -> NSStackView {
        let columns: [NSView] = slots.map { slot, title in
            let well = NSColorWell(style: .default)
            well.supportsAlpha = false
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 56).isActive = true
            well.heightAnchor.constraint(equalToConstant: 28).isActive = true
            wells[slot] = well
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 10.5)
            name.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingTail
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 70).isActive = true
            var views: [NSView] = [well, name]
            if withRatios, case .ansi(let i) = slot {
                let ratio = NSTextField(labelWithString: "")
                ratio.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                ratio.toolTip = "Contrast against the background (WCAG): below 3 is hard to read"
                ratios[i] = ratio
                views.append(ratio)
            }
            let column = NSStackView(views: views)
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 3
            return column
        }
        let row = NSStackView(views: columns)
        row.spacing = withRatios ? 6 : 18
        row.alignment = .top
        return row
    }

    // MARK: Contents

    private func load(_ theme: Theme, startingFrom startName: String) {
        self.theme = theme
        original = theme
        start.removeAllItems()
        var names = Theme.all.map(\.name)
        let known = Set(names.map { $0.lowercased() })
        names += ThemeLibrary.shared.entries.map(\.name).filter { !known.contains($0.lowercased()) }
        start.addItems(withTitles: names)
        if let item = start.item(withTitle: startName) { start.select(item) }
        let ownName = isOwnTheme(startName)
        name.stringValue = ownName ? startName : Self.freeName(from: startName)
        let config = ConfigStore.shared.savedConfig
        generate.state = config.paletteGenerate ? .on : .off
        harmonious.state = config.paletteHarmonious ? .on : .off
        refresh()
    }

    /// "Nord" → "Nord Custom", or "Nord Custom 2" when that's taken.
    private static func freeName(from base: String) -> String {
        let stem = base.hasSuffix(" Custom") ? base : base + " Custom"
        var candidate = stem, n = 2
        while Theme.exists(candidate) { candidate = "\(stem) \(n)"; n += 1 }
        return candidate
    }

    private func isOwnTheme(_ name: String) -> Bool {
        ThemeLibrary.shared.entries.contains { $0.name == name && $0.source == "user" }
    }

    private func color(_ slot: Slot) -> RGB {
        switch slot {
        case .background: theme.background
        case .foreground: theme.foreground
        case .cursor: theme.cursor
        case .selection: theme.selection
        case .ansi(let i): theme.ansi[i]
        }
    }

    private func refresh() {
        for (slot, well) in wells { well.color = color(slot).nsColor }
        for (i, field) in ratios {
            let ratio = theme.ansi[i].contrast(with: theme.background)
            field.stringValue = String(format: "%.1f", ratio)
            // Black on a dark background is meant to be dim.
            field.textColor = ratio < 3 && i != 0 && i != 8 ? .systemRed : .tertiaryLabelColor
        }
        harmonious.isEnabled = generate.state == .on
        extended.colors = generate.state == .on
            ? theme.generatedPalette256(harmonious: harmonious.state == .on) : theme.palette256
        delete.isEnabled = isOwnTheme(start.titleOfSelectedItem ?? "")
        status.stringValue = theme == original ? "" : "Every window shows these colors until you save or cancel."
        schedulePreview()
    }

    private func schedulePreview() {
        guard !previewPending else { return }
        previewPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            previewPending = false
            guard window?.isVisible == true else { return }
            ConfigStore.shared.preview(previewSettings())
        }
    }

    /// The colors as config lines over the files' own: the theme the files
    /// name stays, these cover it.
    private func previewSettings() -> [(key: String, value: String)] {
        var settings: [(key: String, value: String)] = [
            ("background", theme.background.hexString), ("foreground", theme.foreground.hexString),
            ("cursor-color", theme.cursor.hexString), ("selection-background", theme.selection.hexString),
            ("palette-generate", generate.state == .on ? "true" : "false"),
            ("palette-harmonious", harmonious.state == .on ? "true" : "false"),
        ]
        for (i, c) in theme.ansi.enumerated() { settings.append(("palette", "\(i)=\(c.hexString)")) }
        // The files' entries above 15 stay (only 0–15 are the theme's).
        for (i, c) in ConfigStore.shared.savedConfig.palette where i >= 16 { settings.append(("palette", "\(i)=\(c.hexString)")) }
        return settings
    }

    // MARK: Actions

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let slot = wells.first(where: { $0.value === sender })?.key,
              let c = sender.color.usingColorSpace(.sRGB) else { return }
        func channel(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = RGB(channel(c.redComponent), channel(c.greenComponent), channel(c.blueComponent))
        switch slot {
        case .background: theme.background = rgb
        case .foreground: theme.foreground = rgb
        case .cursor: theme.cursor = rgb
        case .selection: theme.selection = rgb
        case .ansi(let i): theme.ansi[i] = rgb
        }
        refresh()
    }

    @objc private func generateChanged(_ sender: Any?) { refresh() }

    @objc private func startChanged(_ sender: Any?) {
        guard let picked = start.titleOfSelectedItem else { return }
        let fresh = Theme.named(picked)
        theme = fresh
        original = fresh
        name.stringValue = isOwnTheme(picked) ? picked : Self.freeName(from: picked)
        refresh()
    }

    @objc private func revert(_ sender: Any?) {
        theme = original
        refresh()
    }

    @objc private func cancel(_ sender: Any?) { window?.close() }

    func windowWillClose(_ notification: Notification) {
        ConfigStore.shared.endPreview()
    }

    @objc private func importTheme(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "A Ghostty theme file, or an iTerm2 color preset (.itermcolors)"
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let stem = url.deletingPathExtension().lastPathComponent
                guard let imported = Self.read(url, name: stem) else {
                    self.status.stringValue = "\(url.lastPathComponent) has no colors Libertty can read."
                    return
                }
                self.theme = imported
                self.name.stringValue = Theme.exists(stem) ? Self.freeName(from: stem) : stem
                self.refresh()
            }
        }
    }

    /// A Ghostty theme file, or an `.itermcolors` property list.
    static func read(_ url: URL, name: String) -> Theme? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "itermcolors" {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            func rgb(_ key: String) -> RGB? {
                guard let d = plist[key] as? [String: Any] else { return nil }
                func c(_ k: String) -> UInt8 { UInt8((min(max((d[k] as? Double) ?? 0, 0), 1) * 255).rounded()) }
                return RGB(c("Red Component"), c("Green Component"), c("Blue Component"))
            }
            var t = Theme.named(Theme.defaultName)
            t.name = name
            guard let bg = rgb("Background Color"), let fg = rgb("Foreground Color") else { return nil }
            t.background = bg
            t.foreground = fg
            t.cursor = rgb("Cursor Color") ?? fg
            t.selection = rgb("Selection Color") ?? t.selection
            for i in 0..<16 { if let c = rgb("Ansi \(i) Color") { t.ansi[i] = c } }
            return t
        }
        guard let text = String(data: data, encoding: .utf8),
              text.split(whereSeparator: \.isNewline).contains(where: {
                  let key = ConfigStore.key(of: String($0))
                  return key == "background" || key == "foreground" || key == "palette"
              }) else { return nil }
        return Theme.parse(name: name, text: text)
    }

    @objc private func deleteTheme(_ sender: Any?) {
        guard let window, let picked = start.titleOfSelectedItem,
              let entry = ThemeLibrary.shared.entries.first(where: { $0.name == picked && $0.source == "user" }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the theme “\(picked)”?"
        alert.informativeText = "Its file goes to the Trash: \((entry.url.path as NSString).abbreviatingWithTildeInPath)"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                // In use: back to the default, rather than a theme that's gone.
                let config = ConfigStore.shared.savedConfig
                if [config.theme.light, config.theme.dark].contains(picked) { ConfigStore.shared.set("theme", nil) }
                ThemeLibrary.shared.invalidate()
                ConfigStore.shared.reload(force: true)
                self.load(Self.themeInUse(), startingFrom: Self.themeInUseName())
            }
        }
    }

    @objc private func save(_ sender: Any?) {
        guard let window else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !title.contains("/"), !title.hasPrefix("."), !title.contains(",") else {
            status.stringValue = "A name, please: no “/” or “,”, not starting with “.”."
            return
        }
        guard Theme.builtIn(title) == nil else {
            status.stringValue = "“\(title)” is one of Libertty's own themes: save it under another name."
            return
        }
        let folder = ConfigStore.directory.appendingPathComponent("themes")
        let url = folder.appendingPathComponent(title)
        let replacing = FileManager.default.fileExists(atPath: url.path) && title != start.titleOfSelectedItem
        let config = ConfigStore.shared.savedConfig
        // Colors the config sets itself would cover the theme's.
        var covering = [("background", config.background != nil), ("foreground", config.foreground != nil),
                        ("cursor-color", config.cursorColor != nil), ("selection-background", config.selectionBackground != nil),
                        ("palette", config.palette.keys.contains { $0 < 16 })].filter(\.1).map(\.0)
        func write() {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var named = theme
                named.name = title
                try Self.text(of: named).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                status.stringValue = "Couldn't write \(url.path): \(error.localizedDescription)"
                return
            }
            ThemeLibrary.shared.invalidate()
            let store = ConfigStore.shared
            for key in covering {
                if key == "palette" {
                    store.unset("palette") { value in
                        Int(value.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? "").map { $0 < 16 } ?? false
                    }
                } else {
                    store.set(key, nil)
                }
            }
            store.set("palette-generate", generate.state == .on ? "true" : nil)
            store.set("palette-harmonious", harmonious.state == .on ? "true" : nil)
            // Following the system's light and dark: this side becomes the new theme.
            let spec = config.theme
            if spec.light != spec.dark {
                let dark = SystemAppearance.isDark
                store.set("theme", "\"light:\(dark ? spec.light : title),dark:\(dark ? title : spec.dark)\"")
            } else {
                store.set("theme", title)
            }
            original = theme
            window.close()
        }
        func confirmCovering() {
            guard !covering.isEmpty else { return write() }
            let alert = NSAlert()
            alert.messageText = "Your config sets colors of its own"
            alert.informativeText = "It sets \(covering.joined(separator: ", ")), which would cover this theme's. Take them out of the config?"
            alert.addButton(withTitle: "Take Them Out")
            alert.addButton(withTitle: "Keep Them")
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    if response != .alertFirstButtonReturn { covering = [] }
                    write()
                }
            }
        }
        guard replacing else { return confirmCovering() }
        let alert = NSAlert()
        alert.messageText = "Replace the theme “\(title)”?"
        alert.informativeText = "A theme of that name is already in \((folder.path as NSString).abbreviatingWithTildeInPath)."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { confirmCovering() }
        }
    }

    /// The theme as a Ghostty theme file.
    static func text(of theme: Theme) -> String {
        var lines = [
            "# \(theme.name), made with Libertty's Theme Editor. Ghostty's theme format.",
            "",
            "background = \(theme.background.hexString)",
            "foreground = \(theme.foreground.hexString)",
            "cursor-color = \(theme.cursor.hexString)",
            "selection-background = \(theme.selection.hexString)",
            "",
        ]
        for (i, c) in theme.ansi.enumerated() { lines.append("palette = \(i)=\(c.hexString)") }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Probe

    /// `--ui-probe`: set one of the colors as if picked in its well.
    func probeSet(_ slot: String, _ hex: String) -> Bool {
        guard let rgb = RGB(string: hex) else { return false }
        let key: Slot? = switch slot {
        case "background": .background
        case "foreground": .foreground
        case "cursor": .cursor
        case "selection": .selection
        default: Int(slot).flatMap { (0..<16).contains($0) ? .ansi($0) : nil }
        }
        guard let key, let well = wells[key] else { return false }
        well.color = rgb.nsColor
        colorChanged(well)
        return true
    }

    func probeName(_ text: String) { name.stringValue = text }
    func probeSave() { save(nil) }
    func probeCancel() { cancel(nil) }
    var isOpen: Bool { window?.isVisible == true }
    var openWindow: NSWindow? { isOpen ? window : nil }
}

/// The 256-color palette's colors 16–255: the cube as six 6×6 squares
/// (red across them, green up, blue along), then the gray ramp — how
/// palette-generate's colors come out, or xterm's.
private final class ExtendedPaletteView: NSView {
    var colors: [RGB] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard colors.count == 256 else { return }
        let cell = floor(min(bounds.width / 48, bounds.height / 6))
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    colors[16 + r * 36 + g * 6 + b].nsColor.setFill()
                    NSRect(x: CGFloat(r * 7 + b) * cell, y: CGFloat(g) * cell, width: cell, height: cell).fill()
                }
            }
        }
        // The grays after them, six to a row.
        for i in 0..<24 {
            colors[232 + i].nsColor.setFill()
            NSRect(x: CGFloat(42 + i % 6) * cell, y: CGFloat(5 - i / 6) * cell, width: cell, height: cell).fill()
        }
    }
}
