import AppKit
import SwiftUI

/// Libertty ▸ Theme Editor… — Rex's Theme Customizer: a theme's colors as
/// swatches, each opening an OKLCH picker; with Preview on every window
/// (and the customizer itself) shows each change as it's made. Save & Apply
/// writes a theme file (Ghostty's format) to the config folder's `themes`
/// and uses it. Starts from the theme in use, or any other; imports Ghostty
/// theme files and iTerm2's `.itermcolors`; deletes themes of your own.
@MainActor
final class ThemeEditor: NSObject, NSWindowDelegate {
    static let shared = ThemeEditor()

    private var window: NSWindow?
    let model = ThemeCustomizerModel()
    private var popover: NSPopover?
    /// The swatches' views, for the picker to point at.
    var anchors: [ThemeCustomizerModel.Slot: NSView] = [:]
    /// A preview waiting for the run loop: dragging in the picker sends many
    /// changes a frame, and every window redraws for each preview.
    private var previewPending = false

    override init() {
        super.init()
        model.changed = { [weak self] in self?.modelChanged() }
    }

    @objc func show(_ sender: Any?) { show(startingFrom: nil) }

    /// Open it on `name` (nil: the theme in use), unless it's open already.
    func show(startingFrom name: String?) {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            if let name {
                model.load(Theme.named(name), from: name)
            } else {
                model.load(Self.themeInUse(), from: Self.themeInUseName())
            }
            model.preview = true
            updateLook()
            window.center()
        }
        // A probe's: off every screen, as its windows are.
        if Probe.running {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.setFrameOrigin(NSPoint(x: -20000, y: -23000))
            window.alphaValue = 1
            window.makeFirstResponder(nil)
            schedulePreview()
            return
        }
        Probe.activateApp()
        window.makeKeyAndOrderFront(nil)
        // Not the name, all of it selected: a key typed would replace it.
        window.makeFirstResponder(nil)
        schedulePreview()
    }

    /// The theme the files name for the current appearance, overrides and all.
    private static func themeInUse() -> Theme { ConfigStore.shared.savedConfig.resolvedTheme }
    private static func themeInUseName() -> String {
        ConfigStore.shared.savedConfig.theme.name(dark: SystemAppearance.isDark)
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: ThemeCustomizerView(model: model, editor: self))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Theme Customizer"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        self.window = window
        return window
    }

    /// The customizer in the theme's own colors while it previews (Rex's
    /// sheet does), else the system's.
    private func updateLook() {
        guard let window else { return }
        if model.preview {
            window.appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)
            window.backgroundColor = model.theme.surfaces.canvas.nsColor
        } else {
            window.appearance = nil
            window.backgroundColor = .windowBackgroundColor
        }
    }

    private func modelChanged() {
        updateLook()
        schedulePreview()
    }

    private func schedulePreview() {
        guard !previewPending else { return }
        previewPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            previewPending = false
            guard window?.isVisible == true else { return }
            if model.preview {
                ConfigStore.shared.preview(model.previewSettings())
            } else {
                ConfigStore.shared.endPreview()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        popover?.close()
        ConfigStore.shared.endPreview()
    }

    // MARK: The picker

    /// The OKLCH picker for `slot`, pointing at its swatch (one of colors
    /// 16–255: at `rect` in the extended palette's grid).
    func pick(_ slot: ThemeCustomizerModel.Slot, at rect: NSRect? = nil) {
        popover?.close()
        var key = slot
        if case .indexed = slot { key = .indexed(0) }
        guard let anchor = anchors[key], anchor.window != nil else { return }
        model.beginPicking(slot)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Probe.running
        popover.contentViewController = NSHostingController(rootView: OKLCHPickerView(model: model))
        popover.delegate = self
        let target: NSRect
        if case .indexed(let i) = slot { target = rect ?? ExtendedPaletteGrid.frame(of: i) } else { target = anchor.bounds }
        popover.show(relativeTo: target, of: anchor, preferredEdge: .maxY)
        // The hex field waits for a click (focused, it would show its text selected).
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        self.popover = popover
    }

    var pickerWindow: NSWindow? { popover?.isShown == true ? popover?.contentViewController?.view.window : nil }

    // MARK: Actions

    func revert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Revert to the colors you started with?"
        alert.informativeText = "Restore the palette and name from the start of this editing session or your last save."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self.model.revert() }
        }
    }

    func cancel() { window?.close() }

    func startFrom(_ name: String) {
        model.load(Theme.named(name), from: name)
    }

    func importTheme() {
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
                    self.model.status = "\(url.lastPathComponent) has no colors Libertty can read."
                    return
                }
                self.model.imported(imported, name: Theme.exists(stem) ? ThemeCustomizerModel.freeName(from: stem) : stem)
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
            t.cursorText = rgb("Cursor Text Color")
            t.selection = rgb("Selection Color") ?? t.selection
            t.selectionForeground = rgb("Selected Text Color")
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

    func deleteTheme() {
        guard let window, let entry = ThemeLibrary.shared.entry(for: model.startedFrom), entry.isOwn else { return }
        let picked = entry.name
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
                self.model.load(Self.themeInUse(), from: Self.themeInUseName())
            }
        }
    }

    func save() {
        guard let window else { return }
        let title = model.name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            model.status = "Give your theme a name."
            return
        }
        guard !title.contains("/"), !title.hasPrefix("."), !title.contains(",") else {
            model.status = "A name without “/” or “,”, not starting with “.”."
            return
        }
        guard Theme.builtIn(title) == nil else {
            model.status = "“\(title)” is one of Libertty's own themes: save it under another name."
            return
        }
        let folder = ConfigStore.directory.appendingPathComponent("themes")
        let url = folder.appendingPathComponent(title)
        let replacing = FileManager.default.fileExists(atPath: url.path) && title != model.startedFrom
        let config = ConfigStore.shared.savedConfig
        // What the config sets itself would cover the theme's.
        var covering = [("background", config.background != nil), ("foreground", config.foreground != nil),
                        ("cursor-color", config.cursorColor != nil), ("cursor-text", config.cursorText != nil),
                        ("selection-background", config.selectionBackground != nil),
                        ("selection-foreground", config.selectionForeground != nil),
                        ("palette", !config.palette.isEmpty),
                        ("palette-generate", config.paletteGenerate != nil),
                        ("palette-harmonious", config.paletteHarmonious != nil)].filter(\.1).map(\.0)
        func write() {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var named = model.theme
                named.name = title
                try Self.text(of: named).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.status = "Couldn't write \(url.path): \(error.localizedDescription)"
                return
            }
            ThemeLibrary.shared.invalidate()
            let store = ConfigStore.shared
            for key in covering { store.set(key, nil) }
            // Following the system's light and dark: this side becomes the new theme.
            let spec = config.theme
            if spec.light != spec.dark {
                let dark = SystemAppearance.isDark
                store.set("theme", "\"light:\(dark ? spec.light : title),dark:\(dark ? title : spec.dark)\"")
            } else {
                store.set("theme", title)
            }
            model.saved(as: title)
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
            "# \(theme.name), made with Libertty's Theme Customizer. Ghostty's theme format.",
            "",
            "background = \(theme.background.hexString)",
            "foreground = \(theme.foreground.hexString)",
            "cursor-color = \(theme.cursor.hexString)",
        ]
        if let c = theme.cursorText { lines.append("cursor-text = \(c.hexString)") }
        lines.append("selection-background = \(theme.selection.hexString)")
        if let c = theme.selectionForeground { lines.append("selection-foreground = \(c.hexString)") }
        lines.append("")
        for (i, c) in theme.ansi.enumerated() { lines.append("palette = \(i)=\(c.hexString)") }
        if theme.paletteGenerate || theme.paletteHarmonious || !theme.extendedPalette.isEmpty { lines.append("") }
        if theme.paletteGenerate { lines.append("palette-generate = true") }
        if theme.paletteHarmonious { lines.append("palette-harmonious = true") }
        for i in theme.extendedPalette.keys.sorted() { lines.append("palette = \(i)=\(theme.extendedPalette[i]!.hexString)") }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Probe

    /// `--ui-probe`: set one of the colors as if picked.
    func probeSet(_ slot: String, _ hex: String) -> Bool {
        guard let rgb = RGB(string: hex), let key = ThemeCustomizerModel.Slot(probeName: slot) else { return false }
        model.set(key, rgb)
        return true
    }

    /// `--ui-probe`: set one of the colors by OKLCH, as the picker's disc
    /// and sliders do (its picker opens on it).
    func probeOKLCH(_ slot: String, _ lch: OKLCH) -> Bool {
        guard let key = ThemeCustomizerModel.Slot(probeName: slot) else { return false }
        pick(key)
        // (Not laid out yet, or no room for the popover: the colors all the same.)
        if model.picking != key { model.beginPicking(key) }
        model.setPicked(lch)
        return true
    }

    func probePick(_ slot: String) -> Bool {
        guard let key = ThemeCustomizerModel.Slot(probeName: slot) else { return false }
        pick(key)
        return popover?.isShown == true
    }

    func probePreview(_ on: Bool) { model.preview = on }
    func probeExtended(_ shown: Bool) { model.showExtended = shown }
    func probeName(_ text: String) { model.name = text }
    func probeSave() { popover?.close(); save() }
    func probeCancel() { cancel() }
    func probeRevert() { model.revert() }
    var isOpen: Bool { window?.isVisible == true }
    var openWindow: NSWindow? { isOpen ? window : nil }
}

extension ThemeEditor: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        model.endPicking()
    }
}

/// What the customizer shows and edits.
@MainActor
final class ThemeCustomizerModel: ObservableObject {
    enum Slot: Hashable {
        case background, foreground, cursor, cursorText, selection, selectionForeground
        case ansi(Int)
        /// One of colors 16–255.
        case indexed(Int)

        static let terminal: [Slot] = [.background, .foreground, .cursor, .cursorText, .selection, .selectionForeground]
        static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

        var title: String {
            switch self {
            case .background: "Background"
            case .foreground: "Text"
            case .cursor: "Cursor"
            case .cursorText: "Cursor Text"
            case .selection: "Selection"
            case .selectionForeground: "Selected Text"
            case .ansi(let i): Self.ansiNames[i % 8]
            case .indexed(let i): "Color \(i)"
            }
        }

        /// The picker's title: the bright ones say so.
        var longTitle: String {
            if case .ansi(let i) = self { return (i < 8 ? "" : "Bright ") + title }
            return title
        }

        /// The probe's names: background, foreground, cursor, cursor-text,
        /// selection, selection-foreground, 0–255.
        init?(probeName: String) {
            switch probeName {
            case "background": self = .background
            case "foreground": self = .foreground
            case "cursor": self = .cursor
            case "cursor-text": self = .cursorText
            case "selection": self = .selection
            case "selection-foreground": self = .selectionForeground
            default:
                guard let i = Int(probeName), (0..<256).contains(i) else { return nil }
                self = i < 16 ? .ansi(i) : .indexed(i)
            }
        }
    }

    /// Told of every change (the editor previews it and repaints the window).
    var changed: () -> Void = {}

    @Published var theme = Theme.named(Theme.defaultName) { didSet { if theme != oldValue { changed() } } }
    @Published var name = "" { didSet { if name != oldValue { status = "" } } }
    /// Every window (and the customizer) in these colors as they're edited.
    @Published var preview = true { didSet { if preview != oldValue { changed() } } }
    /// Off: colors 16–255 stay as they were when it was turned off.
    @Published var autoRegenerate = true
    @Published var showExtended = false
    @Published var status = ""
    /// The swatch whose picker is open, and the color in it as OKLCH: kept
    /// as dragged (the swatch gets the nearest sRGB color), so hue and
    /// chroma don't wander as the color is clipped.
    @Published private(set) var picking: Slot?
    @Published private(set) var picked = OKLCH(l: 0, c: 0, h: 0)
    /// The picker's hex field, as typed.
    @Published var pickedHex = ""

    /// The theme and name at the start of this editing session or the last save.
    private(set) var original = Theme.named(Theme.defaultName)
    private(set) var originalName = ""
    /// The theme it started from (its name as the library has it).
    private(set) var startedFrom = ""

    func load(_ theme: Theme, from name: String) {
        startedFrom = name
        self.name = ThemeLibrary.shared.entry(for: name)?.isOwn == true ? name : Self.freeName(from: name)
        self.theme = theme
        original = theme
        originalName = self.name
        autoRegenerate = !Self.isFrozen(theme)
        status = ""
    }

    /// A theme file read in: these colors, under this name, to save as yours.
    func imported(_ theme: Theme, name: String) {
        self.theme = theme
        self.name = name
        autoRegenerate = !Self.isFrozen(theme)
    }

    func saved(as title: String) {
        startedFrom = title
        original = theme
        originalName = title
    }

    func revert() {
        theme = original
        name = originalName
        autoRegenerate = !Self.isFrozen(theme)
        if let picking { picked = OKLCH(color(picking)) }
        status = ""
    }

    /// Every one of 16–255 set: a generated palette that keeps its colors.
    private static func isFrozen(_ theme: Theme) -> Bool {
        theme.paletteGenerate && (16..<256).allSatisfy { theme.extendedPalette[$0] != nil }
    }

    /// "Merino Dark" → "Merino Dark (Duplicated)", or "(Duplicated 2)" when that's taken.
    static func freeName(from base: String) -> String {
        var stem = base
        if let range = stem.range(of: #" \(Duplicated( \d+)?\)$"#, options: .regularExpression) { stem.removeSubrange(range) }
        var candidate = "\(stem) (Duplicated)", n = 2
        while Theme.exists(candidate) { candidate = "\(stem) (Duplicated \(n))"; n += 1 }
        return candidate
    }

    var isOwnTheme: Bool { ThemeLibrary.shared.entry(for: startedFrom)?.isOwn == true }

    // MARK: Colors

    func color(_ slot: Slot) -> RGB {
        switch slot {
        case .background: theme.background
        case .foreground: theme.foreground
        case .cursor: theme.cursor
        case .cursorText: theme.cursorText ?? theme.background
        case .selection: theme.selection
        case .selectionForeground: theme.selectionForeground ?? theme.foreground
        case .ansi(let i): theme.ansi[i]
        case .indexed(let i): palette[i]
        }
    }

    func set(_ slot: Slot, _ rgb: RGB) {
        var t = theme
        switch slot {
        case .background: t.background = rgb
        case .foreground: t.foreground = rgb
        case .cursor: t.cursor = rgb
        case .cursorText: t.cursorText = rgb
        case .selection: t.selection = rgb
        case .selectionForeground: t.selectionForeground = rgb
        case .ansi(let i): t.ansi[i] = rgb
        case .indexed(let i): t.extendedPalette[i] = rgb
        }
        theme = t
        if slot == picking, OKLCH(rgb).rgb != picked.rgb { picked = OKLCH(rgb) }
    }

    func beginPicking(_ slot: Slot) {
        picking = slot
        picked = OKLCH(color(slot))
    }

    func endPicking() { picking = nil }

    /// The picker moved: the swatch takes the nearest sRGB color.
    func setPicked(_ lch: OKLCH) {
        picked = lch
        guard let picking else { return }
        set(picking, lch.rgb)
    }

    // MARK: Extended palette

    /// The 256 colors as terminals will get them.
    var palette: [RGB] { theme.fullPalette }

    var generate: Bool {
        get { theme.paletteGenerate }
        set {
            var t = theme
            t.paletteGenerate = newValue
            // Off is xterm's colors: the ones kept from a generated palette go.
            if !newValue, !autoRegenerate { t.extendedPalette = [:] }
            theme = t
            if !newValue { autoRegenerate = true }
        }
    }

    var harmonious: Bool {
        get { theme.paletteHarmonious }
        set {
            var t = theme
            t.paletteHarmonious = newValue
            // Kept colors: made again in the new order.
            if !autoRegenerate {
                t.extendedPalette = [:]
                t.extendedPalette = Self.frozen(t)
            }
            theme = t
        }
    }

    func setAutoRegenerate(_ on: Bool) {
        autoRegenerate = on
        var t = theme
        // Off: every color as it's generated now, set one by one; on: none.
        t.extendedPalette = on ? [:] : Self.frozen(t)
        theme = t
    }

    /// Colors 16–255 generated from the base colors now (Regenerate Palette).
    func regenerate() {
        var t = theme
        t.extendedPalette = [:]
        t.extendedPalette = Self.frozen(t)
        theme = t
    }

    func resetOverrides() {
        var t = theme
        t.extendedPalette = [:]
        theme = t
    }

    /// Entries of 16–255 set one by one over the generated ones.
    var overrides: Int { autoRegenerate ? theme.extendedPalette.count : 0 }

    private static func frozen(_ theme: Theme) -> [Int: RGB] {
        let p = theme.fullPalette
        return Dictionary(uniqueKeysWithValues: (16..<256).map { ($0, p[$0]) })
    }

    // MARK: Preview

    /// The colors as config lines over the files' own: the theme the files
    /// name stays, these cover it.
    func previewSettings() -> [(key: String, value: String)] {
        var settings: [(key: String, value: String)] = [
            ("background", theme.background.hexString), ("foreground", theme.foreground.hexString),
            ("cursor-color", theme.cursor.hexString), ("cursor-text", theme.cursorText?.hexString ?? ""),
            ("selection-background", theme.selection.hexString),
            ("selection-foreground", theme.selectionForeground?.hexString ?? ""),
            ("palette-generate", theme.paletteGenerate ? "true" : "false"),
            ("palette-harmonious", theme.paletteHarmonious ? "true" : "false"),
        ]
        for (i, c) in theme.ansi.enumerated() { settings.append(("palette", "\(i)=\(c.hexString)")) }
        for i in theme.extendedPalette.keys.sorted() { settings.append(("palette", "\(i)=\(theme.extendedPalette[i]!.hexString)")) }
        return settings
    }
}
