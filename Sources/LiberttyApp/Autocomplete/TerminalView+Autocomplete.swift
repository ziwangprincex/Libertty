import AppKit

/// Autocomplete in a terminal pane: the ghost text after the cursor (asked
/// before each frame), the keys that take it, and the completion list.
///
/// Only at a prompt shell integration marks, on the main screen, with the
/// view scrolled to the bottom, in the focused pane, and never while a
/// password is read. Nothing reaches the program until a suggestion is
/// taken, and then only what's typed for it: the rest of the line, as keys.
extension TerminalView {
    /// What this pane's autocomplete has going (kept beside the view).
    final class AutocompleteState {
        /// The suggestion drawn last: what taking it types.
        var ghost: String?
        /// Input sent and output parsed when it was drawn: input since with
        /// no output back means the screen (and so the suggestion) may not
        /// show those keys yet, and taking it would type what's on its way.
        var ghostInput: UInt64 = 0
        var ghostOutput: UInt64 = 0
        var list: CompletionList?
        var listTyped = ""
        var listGeneration = 0
        /// The last lookup (line, folder, history generation) and its answer:
        /// a frame that changes nothing on the line doesn't ask history again.
        var asked: (typed: String, folder: String, generation: Int)?
        var answer: String?
    }

    private static var stateKey: UInt8 = 0
    var autocomplete: AutocompleteState {
        if let s = objc_getAssociatedObject(self, &Self.stateKey) as? AutocompleteState { return s }
        let s = AutocompleteState()
        objc_setAssociatedObject(self, &Self.stateKey, s, .OBJC_ASSOCIATION_RETAIN)
        return s
    }

    /// This pane has the keyboard (the probe's window is never key: there,
    /// the window's first responder does).
    private var hasKeyboard: Bool {
        guard window?.firstResponder === self else { return false }
        return window?.isKeyWindow == true || Probe.running
    }

    /// The folder history files this pane's commands under.
    var historyFolder: String { CommandHistory.folder(of: session) }

    /// Whether a suggestion may show at all now.
    private var autocompleteAllowed: Bool {
        !isReadOnly && hasKeyboard && !session.hasExited && !session.programStatus.readingSecret
            && session.scrollbar.atBottom
    }

    /// History made its index again (after a command, say): the pane with
    /// the keyboard looks again now, not at its next key.
    private static let watchesReindex: Void = {
        NotificationCenter.default.addObserver(forName: CommandHistory.reindexed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { (NSApp.keyWindow?.firstResponder as? TerminalView)?.setNeedsRender() }
        }
    }()

    /// The ghost text to draw this frame (the renderer's), and what taking it types.
    func autocompleteGhost() -> TerminalRenderer.Ghost? {
        _ = Self.watchesReindex
        let state = autocomplete
        defer { refreshListIfNeeded() }
        guard ConfigStore.shared.config.autocomplete, autocompleteAllowed else {
            state.ghost = nil
            return nil
        }
        let history = CommandHistory.shared
        if !history.isLoaded {
            history.loadInBackground { [weak self] in self?.setNeedsRender(force: true) }
            state.ghost = nil
            return nil
        }
        guard let (line, cursor) = session.promptLine(), line.atEnd, !line.typed.isEmpty,
              !line.typed.hasPrefix(" "), line.room > 0 else {
            state.ghost = nil
            return nil
        }
        let folder = historyFolder, generation = history.generation
        if state.asked.map({ $0.typed != line.typed || $0.folder != folder || $0.generation != generation }) ?? true {
            state.asked = (line.typed, folder, generation)
            state.answer = history.suggestion(for: line.typed, folder: folder)
        }
        guard let full = state.answer else {
            state.ghost = nil
            return nil
        }
        let rest = String(full.dropFirst(line.typed.count))
        state.ghost = rest
        state.ghostInput = session.inputMark
        state.ghostOutput = session.outputMark.count
        return TerminalRenderer.Ghost(text: rest, row: cursor.row, col: cursor.col, room: line.room)
    }

    /// A key, before keybinds see it: the list's keys while it's open, and
    /// the accept keys while a suggestion shows. Whether it was taken.
    func handleAutocompleteKey(_ event: NSEvent) -> Bool {
        let state = autocomplete
        if let list = state.list {
            switch list.handle(event) {
            case .taken: return true
            case .choose(let completion):
                closeCompletionList()
                typeCompletion(completion.insert)
                return true
            case .close:
                closeCompletionList()
                return true
            case .passThrough(let closing):
                if closing { closeCompletionList() }
            }
        }
        guard let ghost = state.ghost, !ghost.isEmpty else { return false }
        let config = ConfigStore.shared.config
        let triggers = Trigger.candidates(for: event)
        let whole = triggers.contains { config.autocompleteAccept.contains($0) }
        let word = !whole && triggers.contains { config.autocompleteAcceptWord.contains($0) }
        guard whole || word else { return false }
        // Typed on since it was drawn and nothing came back: the line may
        // already be longer than the screen shows. The key does what it would have.
        if session.inputMark != state.ghostInput, session.outputMark.count == state.ghostOutput { return false }
        let text = whole ? ghost : Self.nextWord(of: ghost)
        state.ghost = nil
        typeCompletion(text)
        return true
    }

    /// The suggestion's next word: up to (and with) the next space after
    /// what isn't one, or the end.
    static func nextWord(of text: String) -> String {
        var out = ""
        var seenWord = false
        for ch in text {
            if ch == " " {
                if seenWord { break }
            } else {
                seenWord = true
            }
            out.append(ch)
        }
        return out
    }

    /// What a suggestion or a completion types: as keys, to this pane's program.
    private func typeCompletion(_ text: String) {
        guard !text.isEmpty else { return }
        sendInput(text)
    }

    // MARK: The completion list

    /// `show_completions`: at the prompt, the list of what the word (or the
    /// line) can go on with — one alone is typed at once. Elsewhere false:
    /// the key is the program's.
    func showCompletions() -> Bool {
        guard autocompleteAllowed, let (line, _) = session.promptLine(), line.atEnd else { return false }
        let state = autocomplete
        state.listGeneration += 1
        let generation = state.listGeneration
        computeCompletions(for: line.typed) { [weak self] completions in
            guard let self, self.autocomplete.listGeneration == generation else { return }
            // Typed on meanwhile: the list for what's there now.
            guard let (now, at) = self.session.promptLine(), now.typed == line.typed else { return }
            if completions.isEmpty {
                NSSound.beep()
                return
            }
            if completions.count == 1, completions[0].kind != .history {
                self.typeCompletion(completions[0].insert)
                return
            }
            self.presentList(completions, typed: line.typed, at: at)
        }
        return true
    }

    private func computeCompletions(for typed: String, then done: @escaping ([Completion]) -> Void) {
        let folder = session.workingDirectory, local = session.host == nil, historyFolder = historyFolder
        let history = CommandHistory.shared
        if !history.isLoaded { history.loadInBackground() }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Completer.completions(for: typed, folder: folder, local: local, historyFolder: historyFolder)
            DispatchQueue.main.async { done(found) }
        }
    }

    private func presentList(_ completions: [Completion], typed: String, at cursor: (row: Int, col: Int)) {
        let state = autocomplete
        let list = state.list ?? CompletionList()
        if state.list == nil {
            addSubview(list)
            list.layer?.zPosition = 3
            // A click on a row is choosing it.
            list.onChoose = { [weak self] completion in
                self?.closeCompletionList()
                self?.typeCompletion(completion.insert)
            }
            state.list = list
        }
        state.listTyped = typed
        list.show(completions, font: completionFont)
        placeList(list, at: cursor)
    }

    private var completionFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(10, min(14, cellSizePoints.height * 0.6)), weight: .regular)
    }

    /// Under the cursor's row, or above it near the bottom; inside the pane.
    private func placeList(_ list: CompletionList, at cursor: (row: Int, col: Int)) {
        let cell = cellSizePoints
        let size = list.fittingSize
        let width = min(size.width, bounds.width - 8), height = min(size.height, bounds.height - 8)
        var x = padding.left + CGFloat(cursor.col) * cell.width
        x = max(4, min(x, bounds.width - width - 4))
        let rowTop = padding.top + CGFloat(cursor.row) * cell.height - smoothOffset
        var y = rowTop + cell.height + 2
        if y + height > bounds.height - 4 { y = max(4, rowTop - height - 2) }
        list.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    /// The list follows the line: typed on, it's the list for what's there;
    /// left the prompt (a command ran, a program took over, the view
    /// scrolled back, the keyboard went elsewhere), it goes.
    private func refreshListIfNeeded() {
        let state = autocomplete
        guard let list = state.list else { return }
        guard autocompleteAllowed, let (line, cursor) = session.promptLine(), line.atEnd else {
            closeCompletionList()
            return
        }
        guard line.typed != state.listTyped else { return }
        state.listTyped = line.typed
        state.listGeneration += 1
        let generation = state.listGeneration
        computeCompletions(for: line.typed) { [weak self] completions in
            guard let self, self.autocomplete.listGeneration == generation, self.autocomplete.list === list else { return }
            if completions.isEmpty { return self.closeCompletionList() }
            list.show(completions, font: self.completionFont)
            self.placeList(list, at: cursor)
        }
    }

    func closeCompletionList() {
        let state = autocomplete
        state.listGeneration += 1
        state.list?.removeFromSuperview()
        state.list = nil
    }

    /// What the list shows (the UI probe): its titles, the chosen one marked "> ".
    var completionListShown: [String]? { autocomplete.list?.shownRows }
    /// The suggestion drawn last (the UI probe).
    var ghostShown: String? { autocomplete.ghost }
}

/// The completion list: a small panel of what the word can go on with, under
/// the cursor. Arrows (or ⌃N, ⌃P) choose, Return or Tab types it, Esc closes;
/// typing goes on to the program and the list follows what's typed.
final class CompletionList: NSView {
    enum Outcome {
        case taken
        case choose(Completion)
        case close
        /// The program's key; `closing`: and the list goes (it moved off the word).
        case passThrough(closing: Bool)
    }

    private(set) var completions: [Completion] = []
    /// A row clicked.
    var onChoose: ((Completion) -> Void)?
    private var selected = 0
    private var first = 0
    private let visible = 10
    private var rowViews: [NSTextField] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let k = rowViews.firstIndex(where: { $0.frame.contains(point) }), completions.indices.contains(first + k) else { return }
        onChoose?(completions[first + k])
    }

    override func scrollWheel(with event: NSEvent) {
        // Through the list, not the terminal under it.
        guard abs(event.scrollingDeltaY) >= 1 else { return }
        move(event.scrollingDeltaY < 0 ? 1 : -1)
    }

    /// Clicks on its rows are its own (labels would hand them to the terminal).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(L10n.t("Completions"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override var wantsUpdateLayer: Bool { true }

    func show(_ list: [Completion], font: NSFont) {
        completions = list
        self.font = font
        selected = 0
        first = 0
        rebuild()
        announce()
    }

    var shownRows: [String] {
        completions.enumerated().map { ($0.offset == selected ? "> " : "") + $0.element.title }
    }

    private func rebuild() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        let shown = completions.indices.dropFirst(first).prefix(visible)
        let detailFont = NSFont.systemFont(ofSize: max(9, font.pointSize - 1))
        var widest: CGFloat = 0
        for i in shown {
            let c = completions[i]
            let text = NSMutableAttributedString(string: c.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            if !c.detail.isEmpty {
                text.append(NSAttributedString(string: "   " + c.detail,
                                               attributes: [.font: detailFont, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let label = NSTextField(labelWithAttributedString: text)
            label.lineBreakMode = .byTruncatingTail
            label.wantsLayer = true
            label.drawsBackground = true
            label.backgroundColor = i == selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : .clear
            label.setAccessibleLabel(c.detail.isEmpty ? c.title : c.title + ", " + c.detail)
            label.cell?.setAccessibilitySelected(i == selected)
            addSubview(label)
            rowViews.append(label)
            widest = max(widest, label.fittingSize.width)
        }
        let rowHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let width = min(max(widest + 16, 120), 560)
        for (k, label) in rowViews.enumerated() {
            label.frame = NSRect(x: 0, y: 4 + CGFloat(k) * rowHeight, width: width, height: rowHeight)
        }
        setFrameSize(NSSize(width: width, height: CGFloat(rowViews.count) * rowHeight + 8))
    }

    override var fittingSize: NSSize { frame.size }

    private func announce() {
        guard completions.indices.contains(selected) else { return }
        let c = completions[selected]
        AccessibilityNews.announce(c.detail.isEmpty ? c.title : c.title + ", " + c.detail, from: self, high: true)
    }

    private func move(_ by: Int) {
        guard !completions.isEmpty else { return }
        selected = (selected + by + completions.count) % completions.count
        if selected < first { first = selected }
        if selected >= first + visible { first = selected - visible + 1 }
        rebuild()
        announce()
    }

    func handle(_ event: NSEvent) -> Outcome {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let ctrl = flags == .control
        switch event.keyCode {
        case 125: move(1); return .taken                          // ↓
        case 126: move(-1); return .taken                         // ↑
        case 121: move(visible); return .taken                    // page down
        case 116: move(-visible); return .taken                   // page up
        case 53: return .close                                    // esc
        case 36, 76, 48:                                          // return, enter, tab
            guard flags.isEmpty || flags == .shift, completions.indices.contains(selected) else { return .passThrough(closing: true) }
            return .choose(completions[selected])
        case 123, 124, 115, 119: return .passThrough(closing: true)   // ← → home end
        default: break
        }
        if ctrl, let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "n" { move(1); return .taken }
            if c == "p" { move(-1); return .taken }
            if c == "g" { return .close }
        }
        // ⌘ and ⌃ keys (⌃C among them) are the app's and the shell's, the list
        // gone; typing (and ⌫) goes on and the list follows it.
        if flags.contains(.command) || flags.contains(.control) { return .passThrough(closing: true) }
        return .passThrough(closing: false)
    }
}
