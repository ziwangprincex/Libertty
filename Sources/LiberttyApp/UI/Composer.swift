import AppKit

/// The composer (Otty's ⌘⇧E): a prompt written at leisure — several lines,
/// undo, rich text pasted as Markdown, a screenshot as its file — for the
/// pane it opens on, then sent as one paste (an agent takes it as one
/// prompt), or queued to go when the pane is ready (PromptQueue). It sits
/// at the bottom of its pane, or pops out into a window of its own. Esc
/// puts it away; what was written waits for the next time, pane by pane.
final class ComposerView: NSView {
    weak var pane: TerminalView?
    /// The keys ⌘Return does: Send, or Queue (opened as the prompt queue, ⌘⇧M).
    var queueByDefault = false { didSet { updateButtons() } }

    let textView = ComposerTextView()
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let sendButton = NSButton()
    private let queueButton = NSButton()
    private let popButton = NSButton()
    private let closeButton = NSButton()
    private let queueList = NSStackView()
    private let pausedNote = NSButton()
    private var observer: NSObjectProtocol?
    /// While it's over its pane: the pane's size changing.
    var paneResized: NSObjectProtocol?
    /// While it's popped out: whether its pane is still there.
    private var orphanCheck: Timer?
    /// In a window of its own (popped out), not over its pane.
    private(set) var window_: NSPanel?

    static let maxRows = 5

    init(pane: TerminalView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Composer"))

        title.font = Typeface.ui(11.5, .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        hint.font = Typeface.ui(11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        addSubview(hint)

        for (button, symbol, label, action) in [
            (popButton, "macwindow", "Pop Out", #selector(togglePopOut(_:))),
            (closeButton, "xmark", "Close Composer", #selector(closeComposer(_:))),
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.t(label))
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = L10n.t(label)
            button.setAccessibilityLabel(L10n.t(label))
            addSubview(button)
        }
        for (button, label, action) in [(sendButton, "Send", #selector(send(_:))), (queueButton, "Queue", #selector(queue(_:)))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.title = L10n.t(label)
            button.target = self
            button.action = action
            addSubview(button)
        }
        pausedNote.isBordered = false
        pausedNote.target = self
        pausedNote.action = #selector(resumeQueue(_:))
        pausedNote.isHidden = true
        addSubview(pausedNote)

        queueList.orientation = .vertical
        queueList.alignment = .leading
        queueList.spacing = 2
        addSubview(queueList)

        textView.composer = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Typeface.ui(13.5)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(L10n.t("Prompt"))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        updateColors()
        updateButtons()
        observer = NotificationCenter.default.addObserver(forName: PromptQueues.changed, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as AnyObject?) === self.pane?.session else { return }
            self.reloadQueue()
        }
        reloadQueue()
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
        paneResized.map(NotificationCenter.default.removeObserver)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(window_ == nil ? 0.97 : 1).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func updateButtons() {
        let keys = queueByDefault ? ("⌘⇧↩", "⌘↩") : ("⌘↩", "⌘⇧↩")
        sendButton.keyEquivalent = ""
        queueButton.keyEquivalent = ""
        sendButton.toolTip = L10n.t("Send now") + " (" + keys.0 + ")"
        queueButton.toolTip = L10n.t("Send when the pane is ready") + " (" + keys.1 + ")"
        hint.stringValue = keys.0 + " " + L10n.t("Send") + "  ·  " + keys.1 + " " + L10n.t("Queue") + "  ·  ⌥⌘↩ "
            + L10n.t("Insert") + "  ·  esc " + L10n.t("Close")
        if let pane {
            let name = TerminalWindowController.title(ofPane: pane)
            title.stringValue = L10n.t("Composer") + " — " + name
        }
        needsLayout = true
    }

    /// The pane's queue, under the text: each prompt, and what can be done to it.
    func reloadQueue() {
        queueList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let session = pane?.session else { return }
        let queue = PromptQueues.shared.queue(of: session)
        for (i, item) in queue.items.prefix(Self.maxRows).enumerated() {
            queueList.addArrangedSubview(QueueRow(item: item, index: i, count: queue.items.count, composer: self))
        }
        if queue.items.count > Self.maxRows {
            let more = NSTextField(labelWithString: L10n.t("%d more").replacingOccurrences(of: "%d", with: String(queue.items.count - Self.maxRows)))
            more.font = Typeface.ui(11)
            more.textColor = .tertiaryLabelColor
            queueList.addArrangedSubview(more)
        }
        pausedNote.isHidden = !queue.paused || queue.isEmpty
        pausedNote.attributedTitle = NSAttributedString(
            string: L10n.t("The queue is paused: the last prompt couldn't go as one paste. Resume"),
            attributes: [.font: Typeface.ui(11, .medium), .foregroundColor: NSColor.systemOrange])
        pausedNote.setAccessibilityLabel(pausedNote.attributedTitle.string)
        needsLayout = true
        superviewNeedsLayout()
    }

    private func superviewNeedsLayout() {
        if window_ == nil, let pane { ComposerController.place(self, in: pane) }
    }

    /// How tall it wants to be: its text's lines (2 to 8), its queue, its rims.
    var preferredHeight: CGFloat {
        let lineHeight = (textView.font.map { $0.ascender - $0.descender + $0.leading } ?? 17) + 1
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? lineHeight
        let text = min(max(used, lineHeight * 2), lineHeight * 8) + 14
        let rows = CGFloat(queueList.arrangedSubviews.count) * 22 + (pausedNote.isHidden ? 0 : 20)
        return 26 + rows + text + 32
    }

    override func layout() {
        super.layout()
        let w = bounds.width, pad: CGFloat = 10
        closeButton.frame = NSRect(x: w - 26, y: 5, width: 18, height: 18)
        popButton.frame = NSRect(x: w - 48, y: 5, width: 18, height: 18)
        title.frame = NSRect(x: pad, y: 6, width: max(0, w - 60 - pad), height: 16)
        var y: CGFloat = 26
        if !pausedNote.isHidden {
            pausedNote.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: 18)
            y += 20
        }
        let rows = CGFloat(queueList.arrangedSubviews.count) * 22
        queueList.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: rows)
        for row in queueList.arrangedSubviews { row.frame.size.width = w - 2 * pad }
        y += rows
        let footer: CGFloat = 32
        scroll.frame = NSRect(x: pad - 4, y: y, width: w - 2 * pad + 8, height: max(30, bounds.height - y - footer))
        let buttonY = bounds.height - footer + 5
        sendButton.sizeToFit()
        queueButton.sizeToFit()
        sendButton.frame.origin = NSPoint(x: w - pad - sendButton.frame.width, y: buttonY)
        queueButton.frame.origin = NSPoint(x: sendButton.frame.minX - 6 - queueButton.frame.width, y: buttonY)
        hint.frame = NSRect(x: pad, y: buttonY + 4, width: max(0, queueButton.frame.minX - pad - 8), height: 16)
    }

    // MARK: What it does

    private var text: String { textView.string }

    /// ⌘Return (or the Send button): typed into the pane now as one paste,
    /// then Return. A program that didn't ask for pasted text as one piece
    /// and a prompt of several lines asks first: each line would go alone.
    @objc func send(_ sender: Any?) { deliver(submit: true) }

    /// ⌥⌘Return: into the pane without Return, to finish there.
    func insert() { deliver(submit: false) }

    private func deliver(submit: Bool) {
        guard let pane, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        let prompt = text.trimmingCharacters(in: .newlines)
        guard !pane.isReadOnly, !pane.session.hasExited else { NSSound.beep(); return }
        if PromptSender.send(prompt, to: pane.session, submit: submit) {
            sent()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("Send it line by line?")
        alert.informativeText = L10n.t("The program in this pane didn't ask for pasted text as one piece, so each line of the prompt would go on its own, as if you'd pressed Return after it.")
        alert.addButton(withTitle: L10n.t("Send"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        guard let window = window ?? pane.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let pane = self.pane else { return }
            _ = pane.session.paste(prompt, allowUnsafe: true)
            if submit { PromptSender.pressReturn(in: pane.session) }
            self.sent()
        }
    }

    private func sent() {
        textView.string = ""
        ComposerController.saveDraft(of: self)
        ComposerController.close(self, refocus: true)
    }

    /// ⌘⇧Return (or Queue): to go when the pane is ready; the composer stays for the next.
    @objc func queue(_ sender: Any?) {
        guard let session = pane?.session, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        PromptQueues.shared.enqueue(text, for: session)
        textView.string = ""
        ComposerController.saveDraft(of: self)
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: L10n.t("Queued"), .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// The keys' default: what ⌘Return does.
    func primary() { if queueByDefault { queue(nil) } else { send(nil) } }
    func secondary() { if queueByDefault { send(nil) } else { queue(nil) } }

    @objc private func resumeQueue(_ sender: Any?) {
        guard let session = pane?.session else { return }
        PromptQueues.shared.update(session) { $0.paused = false }
    }

    @objc func closeComposer(_ sender: Any?) {
        ComposerController.saveDraft(of: self)
        ComposerController.close(self, refocus: true)
    }

    @objc private func togglePopOut(_ sender: Any?) {
        if window_ == nil { popOut() } else { popIn() }
    }

    /// Into a window of its own, which floats over Libertty's: by its pane,
    /// or with its top left at `origin` (the UI probe's, off screen).
    func popOut(at origin: NSPoint? = nil) {
        guard window_ == nil, let pane else { return }
        paneResized.map(NotificationCenter.default.removeObserver)
        paneResized = nil
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: max(220, frame.height)),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title.stringValue
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = ComposerController.windowDelegate
        removeFromSuperview()
        frame = panel.contentView!.bounds
        autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(self)
        if let origin {
            panel.setFrameTopLeftPoint(origin)
        } else if let screenFrame = pane.window?.convertToScreen(pane.convert(pane.bounds, to: nil)) {
            panel.setFrameTopLeftPoint(NSPoint(x: screenFrame.minX + 20, y: screenFrame.minY + panel.frame.height + 20))
        }
        window_ = panel
        // Its pane closing (or leaving every window) takes it along.
        orphanCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.pane?.window == nil else { return }
            self.closeWindow()
        }
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        popButton.image = NSImage(systemSymbolName: "rectangle.bottomhalf.inset.filled", accessibilityDescription: L10n.t("Pop In"))
        popButton.toolTip = L10n.t("Pop In")
        popButton.setAccessibilityLabel(L10n.t("Pop In"))
        updateColors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    /// Back over its pane.
    func popIn() {
        guard let panel = window_, let pane else { return }
        orphanCheck?.invalidate()
        orphanCheck = nil
        window_ = nil
        removeFromSuperview()
        panel.delegate = nil
        panel.orderOut(nil)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        popButton.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: L10n.t("Pop Out"))
        popButton.toolTip = L10n.t("Pop Out")
        popButton.setAccessibilityLabel(L10n.t("Pop Out"))
        updateColors()
        ComposerController.attach(self, to: pane)
    }

    func closeWindow() {
        orphanCheck?.invalidate()
        orphanCheck = nil
        window_?.delegate = nil
        window_?.orderOut(nil)
        window_ = nil
    }
}

/// The text of the composer: plain, with its own keys and paste.
final class ComposerTextView: NSTextView {
    weak var composer: ComposerView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, !hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        // The composer's own keys (⌘⇧E, ⌘⇧M, as bound) put it away or switch
        // what ⌘Return does, whether or not a menu has them.
        if let action = ConfigStore.shared.keybinds.action(for: event), let pane = composer?.pane {
            switch action {
            case .toggleComposer, .togglePromptQueue:
                ActionDispatcher.perform(action, in: pane)
                return true
            default: break
            }
        }
        guard event.keyCode == 36 || event.keyCode == 76 else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch mods {
        case [.command]: composer?.primary()
        case [.command, .shift]: composer?.secondary()
        case [.command, .option]: composer?.insert()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        // (An input method composing takes Esc itself.)
        guard !hasMarkedText() else { return super.cancelOperation(sender) }
        composer?.closeComposer(nil)
    }

    override func didChangeText() {
        super.didChangeText()
        if let composer, composer.window_ == nil, let pane = composer.pane { ComposerController.place(composer, in: pane) }
    }

    /// Files as their quoted paths; HTML or RTF (a page, a chat message) as
    /// Markdown; text as it is; an image alone as a file of its own (as a
    /// paste into a pane does), its path inserted.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let pane = composer?.pane else { return super.paste(sender) }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            if pane.session.host != nil {
                return ComposerController.sendToHost(pane, urls: urls, image: nil) { [weak self] paths in self?.insertPaths(paths) }
            }
            return insertPaths(urls.map(\.path))
        }
        if let markdown = Self.markdown(from: pasteboard) { return insertText(markdown, replacementRange: selectedRange()) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return insertText(text, replacementRange: selectedRange())
        }
        guard let png = PasteContent.pngData(pasteboard) else { return super.paste(sender) }
        if pane.session.host != nil {
            return ComposerController.sendToHost(pane, urls: [], image: png) { [weak self] paths in self?.insertPaths(paths) }
        }
        guard let path = try? PasteContent.save(png, in: PasteContent.imageDirectory) else { return NSSound.beep() }
        insertPaths([path])
    }

    private func insertPaths(_ paths: [String]?) {
        guard let paths, !paths.isEmpty else { return NSSound.beep() }
        insertText(paths.map(ShellQuote.quote).joined(separator: " ") + " ", replacementRange: selectedRange())
    }

    /// The clipboard's rich text as Markdown, when it has some (and its
    /// plain text isn't the same thing already: a paste from a text editor).
    static func markdown(from pasteboard: NSPasteboard) -> String? {
        var html = pasteboard.string(forType: .html)
        if html == nil, let rtf = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
           let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            html = String(data: data, encoding: .utf8)
        }
        guard let html, !html.isEmpty, HTMLToMarkdown.hasStructure(html) else { return nil }
        let markdown = HTMLToMarkdown.convert(html)
        return markdown.isEmpty ? nil : markdown
    }
}

/// One queued prompt in the composer: its text (click: back into the
/// composer to edit), up, down, and out.
private final class QueueRow: NSView {
    init(item: PromptQueue.Item, index: Int, count: Int, composer: ComposerView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        weak var composer = composer
        let id = item.id
        // Clicked: back into the composer to edit, out of the queue.
        let label = ClosureButton(symbol: nil, label: "") {
            guard let composer, let session = composer.pane?.session else { return }
            let text = PromptQueues.shared.queue(of: session).items.first { $0.id == id }?.text ?? ""
            PromptQueues.shared.update(session) { $0.remove(id) }
            let view = composer.textView
            view.string = view.string.isEmpty ? text : view.string + "\n" + text
            view.window?.makeFirstResponder(view)
        }
        label.alignment = .left
        let line = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text
        label.attributedTitle = NSAttributedString(string: "\(index + 1).  " + line, attributes: [
            .font: Typeface.ui(12), .foregroundColor: NSColor.labelColor,
        ])
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = L10n.t("Edit") + ": " + item.text
        label.setAccessibilityLabel(L10n.t("Queued prompt %d").replacingOccurrences(of: "%d", with: String(index + 1)) + ": " + item.text)
        var buttons: [NSButton] = []
        func button(_ symbol: String, _ label: String, _ enabled: Bool, _ act: @escaping () -> Void) {
            let b = ClosureButton(symbol: symbol, label: L10n.t(label), act: act)
            b.isEnabled = enabled
            buttons.append(b)
        }
        button("chevron.up", "Move Up", index > 0) { composer?.pane.map { s in PromptQueues.shared.update(s.session) { $0.move(id, by: -1) } } }
        button("chevron.down", "Move Down", index < count - 1) { composer?.pane.map { s in PromptQueues.shared.update(s.session) { $0.move(id, by: 1) } } }
        button("xmark", "Remove from Queue", true) { composer?.pane.map { s in PromptQueues.shared.update(s.session) { $0.remove(id) } } }
        addSubview(label)
        buttons.forEach(addSubview)
        self.label = label
        self.buttons = buttons
    }

    private var label: ClosureButton?
    private var buttons: [NSButton] = []

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }

    override func layout() {
        super.layout()
        var x = bounds.width
        for b in buttons.reversed() {
            x -= 20
            b.frame = NSRect(x: x, y: 1, width: 18, height: 18)
        }
        label?.frame = NSRect(x: 0, y: 1, width: max(0, x - 6), height: 18)
    }
}

/// A borderless symbol button that runs a closure.
private final class ClosureButton: NSButton {
    private let act: () -> Void

    init(symbol: String?, label: String, act: @escaping () -> Void) {
        self.act = act
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(run(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { act() }
}

/// Opening, placing and closing composers, and their drafts.
enum ComposerController {
    private static var composerKey: UInt8 = 0

    /// What each pane's composer had in it when put away, by session.
    private static var drafts: [ObjectIdentifier: (session: () -> TerminalSession?, text: String)] = [:]

    /// A file or an image for a pane on another machine: sent there
    /// (RemoteUpload), and the paths there handed back (nil: it couldn't go;
    /// a host's older liberttyd takes no files: this Mac's paths, for files).
    static func sendToHost(_ pane: TerminalView, urls: [URL], image: Data?, done: @escaping ([String]?) -> Void) {
        pane.upload(urls: urls, image: image) { outcome in
            switch outcome {
            case .sent(let paths): done(paths)
            case .unsupported: done(urls.isEmpty ? nil : urls.map(\.path))
            case .failed: done(nil)
            }
        }
    }

    static func composer(of pane: TerminalView) -> ComposerView? {
        objc_getAssociatedObject(pane, &composerKey) as? ComposerView
    }

    /// ⌘⇧E: open the focused pane's composer (with its draft), or put it away.
    static func toggle(in pane: TerminalView?, queue: Bool = false) {
        guard let pane else { return NSSound.beep() }
        if let open = composer(of: pane) {
            // Open but not where you type (you clicked the terminal), or open
            // for the other default: there it is, not gone.
            let window = open.window_ ?? pane.window
            if open.queueByDefault != queue || window?.firstResponder !== open.textView {
                open.queueByDefault = queue
                return focus(open)
            }
            saveDraft(of: open)
            return close(open, refocus: true)
        }
        show(in: pane, queue: queue)
    }

    @discardableResult
    static func show(in pane: TerminalView, queue: Bool = false) -> ComposerView {
        if let open = composer(of: pane) {
            open.queueByDefault = queue
            focus(open)
            return open
        }
        let composer = ComposerView(pane: pane)
        composer.queueByDefault = queue
        let key = ObjectIdentifier(pane.session)
        if let draft = drafts[key], draft.session() === pane.session { composer.textView.string = draft.text }
        objc_setAssociatedObject(pane, &composerKey, composer, .OBJC_ASSOCIATION_RETAIN)
        attach(composer, to: pane)
        composer.textView.setSelectedRange(NSRange(location: (composer.textView.string as NSString).length, length: 0))
        if !Motion.reduced {
            composer.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.small
                composer.animator().alphaValue = 1
            }
        }
        focus(composer)
        NSAccessibility.post(element: composer, notification: .layoutChanged)
        return composer
    }

    static func attach(_ composer: ComposerView, to pane: TerminalView) {
        pane.addSubview(composer)
        composer.layer?.zPosition = 3
        place(composer, in: pane)
        // Its pane resizing (the window, a divider): it keeps fitting.
        pane.postsFrameChangedNotifications = true
        composer.paneResized = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: pane, queue: .main) { [weak composer, weak pane] _ in
            guard let composer, let pane else { return }
            place(composer, in: pane)
        }
        focus(composer)
    }

    private static func focus(_ composer: ComposerView) {
        let window = composer.window_ ?? composer.pane?.window
        window?.makeFirstResponder(composer.textView)
    }

    /// At the bottom of its pane, as wide as it less a margin, as tall as its text wants.
    static func place(_ composer: ComposerView, in pane: TerminalView) {
        guard composer.superview === pane else { return }
        let margin: CGFloat = 12
        let height = min(composer.preferredHeight, max(80, pane.bounds.height - 2 * margin))
        composer.frame = NSRect(x: margin, y: pane.bounds.height - height - margin,
                                width: max(120, pane.bounds.width - 2 * margin), height: height)
        composer.autoresizingMask = [.width, .minYMargin]
    }

    static func saveDraft(of composer: ComposerView) {
        guard let session = composer.pane?.session else { return }
        let key = ObjectIdentifier(session)
        let text = composer.textView.string
        if text.isEmpty { drafts[key] = nil } else { drafts[key] = ({ [weak session] in session }, text) }
    }

    /// What's in a pane's composer, open or put away.
    static func draft(of pane: TerminalView) -> String {
        if let open = composer(of: pane) { return open.textView.string }
        let key = ObjectIdentifier(pane.session)
        guard let draft = drafts[key], draft.session() === pane.session else { return "" }
        return draft.text
    }

    static func close(_ composer: ComposerView, refocus: Bool) {
        guard let pane = composer.pane else { return composer.removeFromSuperview() }
        composer.closeWindow()
        composer.paneResized.map(NotificationCenter.default.removeObserver)
        composer.paneResized = nil
        composer.removeFromSuperview()
        objc_setAssociatedObject(pane, &composerKey, nil, .OBJC_ASSOCIATION_RETAIN)
        if refocus {
            pane.window?.makeKeyAndOrderFront(nil)
            pane.window?.makeFirstResponder(pane)
        }
    }

    /// A popped-out composer's window closing is the composer closing (its draft kept).
    static let windowDelegate = PanelDelegate()

    final class PanelDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let panel = notification.object as? NSPanel,
                  let composer = panel.contentView?.subviews.first(where: { $0 is ComposerView }) as? ComposerView else { return }
            ComposerController.saveDraft(of: composer)
            panel.delegate = nil
            ComposerController.close(composer, refocus: true)
        }
    }
}
