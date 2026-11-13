import AppKit
import CGhosttyVt

/// A view clicks go through, to what's under it (the hint labels' layer).
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Which-key hints (Rex's key sequence hints): after a sequence's first
/// key, the keys that can follow and what each does.
final class KeyHintsView: NSView {
    private let grid = NSGridView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        grid.rowSpacing = 3
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Keys That Can Follow"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What it lists now (the UI probe): "V Split Right" a row.
    private(set) var rows: [String] = []

    func show(_ entries: [(key: String, title: String)]) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for entry in entries {
            let key = NSTextField(labelWithString: entry.key)
            key.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            key.textColor = .labelColor
            let title = NSTextField(labelWithString: entry.title)
            title.font = Typeface.ui(11)
            title.textColor = .secondaryLabelColor
            grid.addRow(with: [key, title])
        }
        rows = entries.map { "\($0.key) \($0.title)" }
        setAccessibilityValue(rows.joined(separator: ", "))
        updateColors()
    }

    func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

extension TerminalView {
    /// Copy mode or hint mode has the keyboard: nothing typed reaches the program.
    var isInMode: Bool { copyMode != nil || hintsActive }

    /// What the mode tag says (the UI probe): nil when hidden.
    var modeShown: String? { modeTagView.flatMap { $0.isHidden ? nil : $0.stringValue.trimmingCharacters(in: .whitespaces) } }

    /// The hints as labeled (the UI probe): label and what it's on.
    var hintsShown: [(label: String, text: String)] { hintsActive ? hints.map { ($0.label, $0.text) } : [] }

    /// What the which-key hints list (the UI probe): nil when hidden.
    var keyHintsShown: [String]? { keyHints.flatMap { $0.isHidden ? nil : $0.rows } }

    /// Where copy goes: the clipboard, or while a probe runs a pasteboard
    /// of its own, so a test never takes what the user copied.
    static var clipboard: NSPasteboard {
        Probe.running ? NSPasteboard(name: NSPasteboard.Name("dev.libertty.probe")) : .general
    }

    func writeClipboard(_ text: String) {
        let board = Self.clipboard
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Said to VoiceOver, now.
    func announce(_ text: String) {
        AccessibilityNews.announce(text, from: self, high: true)
    }

    /// A composition under way (Pinyin) is dropped as a mode takes the keys.
    private func discardComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
    }

    /// What a key types for copy and hint mode: named keys by name; a
    /// character as the layout in use types it (Shift too, not Option or
    /// Control), or, where it types no Latin one, as the US layout would —
    /// h j k l are the same keys under a Russian or a Greek layout.
    static func modeKey(_ event: NSEvent) -> String? {
        let named: [UInt16: String] = [53: "escape", 36: "return", 76: "return", 51: "backspace", 48: "tab",
                                       123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end",
                                       116: "pageup", 121: "pagedown", 49: "space"]
        if let name = named[event.keyCode] { return name }
        let shifted = event.modifierFlags.contains(.shift)
        if let c = event.characters(byApplyingModifiers: shifted ? [.shift] : []), c.count == 1,
           let s = c.unicodeScalars.first, s.isASCII, s.value > 0x20, s.value < 0x7F { return c }
        guard let base = KeyName.code(Int(event.keyCode)), !base.isSpecial else { return nil }
        guard shifted else { return base.character }
        return usShifted[base.character] ?? base.character.uppercased()
    }

    private static let usShifted = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*",
                                    "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":",
                                    "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~"]

    /// A key pressed in copy or hint mode.
    func modeKeyDown(_ event: NSEvent) {
        modeKeys.insert(event.keyCode)
        hideMouseForModeKey()
        guard let key = Self.modeKey(event) else { return keybindInMode(event) }
        if hintsActive { return hintKey(key, event) }
        guard let mode = copyMode else { return }
        // The program switched screens since the last frame: its cursor was on the other.
        if session.isAlternateScreen != mode.alternate { return endCopyMode() }
        switch mode.press(key, control: event.modifierFlags.contains(.control)) {
        case .moved: copyCursorMoved(key)
        case .unchanged: break
        case .unknown: keybindInMode(event)
        case .leave(let copied): return endCopyMode(copied: copied)
        case .search: (window?.windowController as? TerminalWindowController)?.startSearch()
        case .nextMatch(let sameWay): copySearchStep(older: sameWay == mode.searchesOlder)
        }
        // (What it selects shows on the tag: "Copy Mode · Visual".)
        if copyMode != nil { showModeTag() }
    }

    /// A key the mode has no use for: a keybind's (⌃Tab, a sequence) — never the program's.
    private func keybindInMode(_ event: NSEvent) {
        switch PendingKeys.shared.press(event, in: self, keybinds: ConfigStore.shared.keybinds, flush: { _ in }) {
        case .action(let action), .completed(let action): ActionDispatcher.perform(action, in: self)
        case .held, .unbound: break
        }
    }

    private func hideMouseForModeKey() {
        if ConfigStore.shared.config.mouseHideWhileTyping { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: Copy mode

    func toggleCopyMode() {
        if copyMode != nil { return endCopyMode() }
        if hintsActive { endHintMode() }
        discardComposition()
        PendingKeys.shared.cancel(in: self)
        copyMode = CopyMode(session: session)
        syncCopyCursor()
        showModeTag()
        announce(L10n.t("Copy mode") + ". " + (copyMode?.currentLine() ?? ""))
    }

    /// Leave copy mode, with what was copied, if anything (`written`: it's
    /// on the clipboard already, ⌘C's way). A search it opened (/ ?) closes too.
    func endCopyMode(copied: String? = nil, written: Bool = false) {
        guard let mode = copyMode else { return }
        mode.end()
        copyMode = nil
        renderer.copyCursor = nil
        if let controller = window?.windowController as? TerminalWindowController, controller.isSearching,
           controller.searchedPane === self || controller.focusedTerminal === self {
            _ = controller.endSearch()
        }
        if let copied {
            if !written { writeClipboard(copied) }
            flashModeTag(L10n.t("Copied"))
            announce(L10n.t("Copied"))
        } else {
            showModeTag()
            announce(L10n.t("Left copy mode"))
        }
        setNeedsRender(force: true)
    }

    /// The copy cursor's cell in view, for the renderer.
    private func syncCopyCursor() {
        renderer.copyCursor = copyMode?.viewportCursor().map { TerminalRenderer.MarkedCell(row: $0.row, col: $0.col, wide: $0.wide) }
        setNeedsRender(force: true)
    }

    private func copyCursorMoved(_ key: String) {
        syncCopyCursor()
        // VoiceOver reads where it went: the character, the word, or the line.
        guard NSWorkspace.shared.isVoiceOverEnabled, let mode = copyMode else { return }
        let text: String
        switch key {
        case "h", "l", "left", "right", "0", "^", "$", "home", "end": text = mode.underCursor(word: false)
        case "w", "W", "b", "B", "e", "E": text = mode.underCursor(word: true)
        case "v", "V": text = L10n.t(mode.selecting == .none ? "Selection cleared" : "Selecting")
        default: text = mode.currentLine()
        }
        announce(text.trimmingCharacters(in: .whitespaces).isEmpty ? L10n.t("Blank") : text)
    }

    /// A click in copy mode puts its cursor there.
    func moveCopyCursor(to cell: (col: Int, row: Int)) {
        guard let mode = copyMode else { return }
        let target: ScreenPoint? = session.withTerminal { t in
            ScreenCells.screenPoint(t, GHOSTTY_POINT_TAG_VIEWPORT, x: max(0, cell.col), y: max(0, cell.row))
        }
        guard let target else { return }
        mode.moveTo(target)
        syncCopyCursor()
    }

    /// n N, ⌘G, Return in the find bar, in copy mode: the cursor goes to the
    /// first match past it, up the page (`older`) or down; the keyboard
    /// comes back from the find bar.
    func copySearchStep(older: Bool) {
        guard let mode = copyMode, let at = mode.point else { return }
        if let match = session.selectMatch(beyond: at, older: older) {
            mode.moveTo(match)
            copyCursorMoved("n")
        } else {
            NSSound.beep()
        }
        window?.makeFirstResponder(self)
        setNeedsRender(force: true)
    }

    /// Before each frame: the copy cursor where its text has gone (output
    /// scrolls it). A program switching screens (vim starting, less
    /// quitting) ends copy mode: its cursor was on the other screen.
    func modesBeforeFrame() {
        guard let mode = copyMode else { return }
        if session.isAlternateScreen != mode.alternate { return endCopyMode() }
        let at = mode.viewportCursor().map { TerminalRenderer.MarkedCell(row: $0.row, col: $0.col, wide: $0.wide) }
        if at != renderer.copyCursor { renderer.copyCursor = at }
    }

    /// Where the copy cursor is (the UI probe): its line's text up to it,
    /// and its column.
    var copyCursorShown: (line: String, col: Int)? {
        guard let mode = copyMode, let p = mode.point else { return nil }
        return (mode.currentLine(), p.x)
    }

    // MARK: Hint mode

    func toggleHintMode() { hintsActive ? endHintMode() : beginHintMode() }

    func beginHintMode() {
        if copyMode != nil { endCopyMode() }
        discardComposition()
        PendingKeys.shared.cancel(in: self)
        let found = session.hintTargets()
        guard !found.isEmpty else {
            NSSound.beep()
            flashModeTag(L10n.t("Nothing to Hint"))
            return
        }
        hintsActive = true
        showHints(found)
        showModeTag()
        announce(L10n.t("Hints") + ": \(found.count)")
    }

    func endHintMode() {
        guard hintsActive else { return }
        hintsActive = false
        hints = []
        hintTyped = ""
        hintPlace = []
        renderer.linkSpans = []
        layoutHints()
        showModeTag()
        setNeedsRender(force: true)
    }

    private func showHints(_ found: [HintTarget]) {
        hints = found
        hintTyped = ""
        hintPlace = currentHintPlace()
        hintsFoundAt = CACurrentMediaTime()
        renderer.linkSpans = found.flatMap(\.spans)
        layoutHints()
        setNeedsRender(force: true)
    }

    /// The viewport's place and the grid's size: when these change, the
    /// labels would point at other text.
    private func currentHintPlace() -> [Int] {
        let s = session.scrollbar
        return [Int(s.offset), Int(s.total), Int(session.size.cols), Int(session.size.rows),
                Int(cellSizePoints.width * 100), Int(cellSizePoints.height * 100)]
    }

    /// After a frame: if the text moved under the labels, they're found
    /// again (at most four times a second, while output streams).
    func hintsAfterFrame() {
        guard hintsActive, currentHintPlace() != hintPlace else { return }
        let wait = 0.25 - (CACurrentMediaTime() - hintsFoundAt)
        if wait > 0 {
            // Once: the frames until then each find the same.
            guard !hintsRefreshDue else { return }
            hintsRefreshDue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.hintsRefreshDue = false
                self?.setNeedsRender(force: true)
            }
            return
        }
        let found = session.hintTargets()
        if found.isEmpty { return endHintMode() }
        showHints(found)
        showModeTag()
    }

    /// A key in hint mode: a label's letters (capitals: copy it, not open
    /// it), ⌫ takes the last back, Esc leaves.
    private func hintKey(_ key: String, _ event: NSEvent) {
        switch key {
        case "escape": return endHintMode()
        case "backspace":
            if !hintTyped.isEmpty { hintTyped.removeLast() }
            return layoutHints()
        default: break
        }
        guard key.count == 1, let c = key.first, c.isLetter, c.isASCII else { return keybindInMode(event) }
        let typed = (hintTyped + String(c)).lowercased()
        let matching = hints.filter { $0.label.hasPrefix(typed) }
        guard !matching.isEmpty else { return NSSound.beep() }
        hintTyped.append(c)
        if let hit = matching.first(where: { $0.label == typed }) {
            return chooseHint(hit, copy: hintTyped.contains { $0.isUppercase })
        }
        layoutHints()
    }

    /// A label typed in full: open what it's on, as ⌘-click opens it, or
    /// copy it (a capital typed, or there's nothing to open).
    private func chooseHint(_ hint: HintTarget, copy: Bool) {
        endHintMode()
        if copy || hint.link == nil {
            writeClipboard(hint.text)
            flashModeTag(L10n.t("Copied"))
            announce(L10n.t("Copied") + " " + hint.text)
        } else if let link = hint.link {
            open(link)
        }
    }

    /// The labels, each over the start of its target; the letters typed so
    /// far dimmed, the labels they rule out gone. Black on white, or white
    /// on black, in the pane's appearance.
    func layoutHints() {
        hintOverlay.subviews.forEach { $0.removeFromSuperview() }
        hintOverlay.isHidden = !hintsActive
        guard hintsActive else { return }
        hintOverlay.frame = bounds
        let typed = hintTyped.lowercased()
        let cell = cellSizePoints, pad = padding
        let font = NSFont.monospacedSystemFont(ofSize: max(9, min(fontSize - 1, 15)), weight: .bold)
        var ink = NSColor.white, ground = NSColor.black
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
            ground = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        for hint in hints where hint.label.hasPrefix(typed) {
            guard let span = hint.spans.first else { continue }
            let text = NSMutableAttributedString(string: hint.label.uppercased(), attributes: [.font: font, .foregroundColor: ink])
            text.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.45), range: NSRange(location: 0, length: typed.count))
            let label = PassThroughLabel(labelWithAttributedString: text)
            label.drawsBackground = true
            label.backgroundColor = ground
            label.wantsLayer = true
            label.layer?.cornerRadius = 3
            label.layer?.masksToBounds = true
            label.alignment = .center
            let size = label.fittingSize
            label.frame = NSRect(x: pad.left + CGFloat(span.columns.lowerBound) * cell.width,
                                 y: pad.top + CGFloat(span.row) * cell.height - smoothOffset + (cell.height - size.height) / 2,
                                 width: size.width + 4, height: size.height)
            label.setAccessibilityLabel("\(hint.label): \(hint.text)")
            hintOverlay.addSubview(label)
        }
    }

    // MARK: The mode's tag

    /// "Copy Mode", "Copy Mode · Visual", "Hints · AS": at the pane's bottom right.
    func showModeTag() {
        let text: String?
        if hintsActive {
            text = L10n.t("Hints") + (hintTyped.isEmpty ? "" : " · " + hintTyped.uppercased())
        } else if let mode = copyMode {
            switch mode.selecting {
            case .none: text = L10n.t("Copy Mode")
            case .characters: text = L10n.t("Copy Mode · Visual")
            case .lines: text = L10n.t("Copy Mode · Visual Line")
            case .block: text = L10n.t("Copy Mode · Visual Block")
            }
        } else {
            text = nil
        }
        modeTagFlash?.invalidate()
        guard let text else {
            modeTagView?.isHidden = true
            return
        }
        modeTag.isHidden = false
        modeTag.stringValue = " " + text + " "
        updateGround(of: modeTag, alpha: 0.92)
        layoutModeOverlays()
    }

    /// A word on the tag for a moment ("Copied").
    private func flashModeTag(_ text: String) {
        modeTag.stringValue = " " + text + " "
        modeTag.isHidden = false
        updateGround(of: modeTag, alpha: 0.92)
        layoutModeOverlays()
        modeTagFlash?.invalidate()
        modeTagFlash = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self, !self.isInMode else { return }
            self.modeTagView?.isHidden = true
        }
    }

    func layoutModeOverlays() {
        var bottom = bounds.height - 6
        if pendingKeysShown != nil { bottom -= pendingKeysLabelHeight + 4 }
        if let modeTag = modeTagView, !modeTag.isHidden {
            let size = modeTag.fittingSize
            let width = min(size.width, max(0, bounds.width - 12))
            modeTag.frame = NSRect(x: bounds.width - width - 18, y: bottom - size.height, width: width, height: size.height)
            bottom -= size.height + 4
        }
        if let keyHints, !keyHints.isHidden {
            let size = keyHints.fittingSize
            keyHints.frame = NSRect(x: max(6, bounds.width - size.width - 18), y: max(6, bottom - size.height),
                                    width: size.width, height: size.height)
        }
        if hintsActive { layoutHints() }
    }

    func modesAppearanceChanged() {
        if let modeTag = modeTagView, !modeTag.isHidden { updateGround(of: modeTag, alpha: 0.92) }
        keyHints?.updateColors()
        if hintsActive { layoutHints() }
    }

    // MARK: Which-key hints

    /// How long a sequence's first key waits before what can follow shows.
    static let keyHintsDelay: TimeInterval = 0.4

    /// The sequence under way changed: list what can follow it (after a
    /// moment, the first time), or put the list away.
    func updateKeyHints() {
        keyHintsTimer?.invalidate()
        keyHintsTimer = nil
        let entries = pendingSequence.isEmpty || !ConfigStore.shared.config.keySequenceHints ? []
            : ConfigStore.shared.keybinds.continuations(after: pendingSequence).map { next in
                (key: next.key.displayString, title: next.action.map(Self.title(of:)) ?? "…")
            }
        guard !entries.isEmpty else {
            keyHints?.isHidden = true
            return
        }
        if let shown = keyHints, !shown.isHidden {
            shown.show(entries)
            return layoutModeOverlays()
        }
        let timer = Timer(timeInterval: Self.keyHintsDelay, repeats: false) { [weak self] _ in
            guard let self, !self.pendingSequence.isEmpty else { return }
            let view = self.keyHints ?? {
                let v = KeyHintsView()
                v.layer?.zPosition = 3
                self.addSubview(v)
                self.keyHints = v
                return v
            }()
            view.show(entries)
            view.isHidden = false
            self.layoutModeOverlays()
            // Still waiting for the next key: VoiceOver hears what it can be.
            AccessibilityNews.announce(self.pendingSequence.displayString + " … " + view.rows.joined(separator: ", "), from: view)
            if !Motion.reduced {
                view.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; view.animator().alphaValue = 1 }
            } else {
                view.alphaValue = 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keyHintsTimer = timer
    }

    /// An action as Settings ▸ Shortcuts names it (in the interface's
    /// language), else as the menus do, else by its config name.
    static func title(of action: Action) -> String {
        let name = action.configString
        if let entry = SettingsShortcuts.groups.lazy.flatMap(\.actions).first(where: { $0.action == name }) { return entry.title }
        if let item = menuItem(for: action, in: NSApp.mainMenu) {
            return item.title.trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespaces))
        }
        return name
    }

    private static func menuItem(for action: Action, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if (item.representedObject as? ActionBox)?.action == action { return item }
            if let found = menuItem(for: action, in: item.submenu) { return found }
        }
        return nil
    }

    // MARK: A click at the prompt

    /// A plain click on the cell at `col`, `row` (the UI probe): down and
    /// up, as the mouse would.
    func probeClick(col: Int, row: Int) {
        guard let window else { return }
        let cell = cellSizePoints, pad = padding
        let point = convert(CGPoint(x: pad.left + (CGFloat(col) + 0.5) * cell.width,
                                    y: pad.top + (CGFloat(row) + 0.5) * cell.height - smoothOffset), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        mouseDown(with: down)
        mouseUp(with: up)
    }

    /// `cursor-click-to-move`: a plain click in the command being typed
    /// sends the arrow presses that take the shell's cursor there.
    func clickToMove(_ cell: (col: Int, row: Int)) {
        guard ConfigStore.shared.config.cursorClickToMove, !isReadOnly, !isInMode, !session.isMouseTracking,
              !session.hasSelection, let moves = session.promptClickMove(col: cell.col, row: cell.row), moves != 0
        else { return }
        let key = moves < 0 ? GHOSTTY_KEY_ARROW_LEFT : GHOSTTY_KEY_ARROW_RIGHT
        for _ in 0..<abs(moves) {
            session.send(.init(action: GHOSTTY_KEY_ACTION_PRESS, key: key, mods: 0, consumedMods: 0, text: nil,
                               unshiftedCodepoint: 0, composing: false))
        }
        setNeedsRender()
    }
}
