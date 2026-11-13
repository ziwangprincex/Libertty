import AppKit

/// One surface (SurfaceProtocol) as native controls, over its pane: a card
/// that always says whose it is — the program's name at its top, a border
/// of its own — so nothing a program draws passes for Libertty's. Controls
/// tell their events through `onEvent`; a surface whose program has ended
/// (not live) shows dimmed, its controls off.
final class SurfaceView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private(set) var surface: SurfaceStore.Surface
    /// An event for the program: {type, element?, item?, items?, values?}.
    var onEvent: (([String: Any]) -> Void)?
    /// The overlay's × (Libertty's own control, always there).
    var onClose: (() -> Void)?
    /// A link ⌘-clicked: http(s) or a file.
    var onOpenLink: ((URL) -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let caption = NSTextField(labelWithString: "")
    private var closeButton: NSButton?
    /// The user's text in inputs, and choices in lists and tables, by element
    /// id: kept when the program sends the surface again (a progress update).
    private var values: [String: String] = [:]
    private var edited = Set<String>()
    private var tables: [NSTableView: Element] = [:]

    static let captionHeight: CGFloat = 18

    init(_ surface: SurfaceStore.Surface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.control
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        caption.font = Typeface.ui(10.5, .medium)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        addSubview(caption)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: document.leadingAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: document.topAnchor).isActive = true
        stackWidth = stack.widthAnchor.constraint(equalToConstant: 300)
        stackWidth.isActive = true
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
        if !surface.spec.isInline {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("Close"))!,
                                 target: self, action: #selector(closeTapped))
            close.isBordered = false
            close.contentTintColor = .secondaryLabelColor
            close.setAccessibilityLabel(L10n.t("Close"))
            addSubview(close)
            closeButton = close
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorize()
    }

    private func colorize() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// The program sent it again (or it ended): rebuilt, the user's state kept.
    func update(_ surface: SurfaceStore.Surface) {
        guard surface.revision != self.surface.revision || surface.live != self.surface.live else { return }
        let specChanged = surface.spec != self.surface.spec
        self.surface = surface
        if specChanged { rebuild() } else { applyLive() }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tables = [:]
        let spec = surface.spec
        // Whose it is, always: "python3 · Build".
        let who = L10n.t("From %@").replacingOccurrences(of: "%@", with: surface.program)
        caption.stringValue = spec.title.isEmpty ? who : who + " · " + spec.title
        setAccessibilityLabel(L10n.t("Panel") + ", " + caption.stringValue)
        for element in spec.elements {
            guard let view = make(element) else { continue }
            stack.addArrangedSubview(view)
            // Lists, tables, text and rules take the card's width; the rest what they need.
            if [.markdown, .diff, .list, .table, .divider].contains(element.kind) {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            } else {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -20).isActive = true
            }
        }
        colorize()
        applyLive()
        needsLayout = true
    }

    private func applyLive() {
        alphaValue = surface.live ? 1 : 0.6
        // Its program ended: buttons, fields and lists stop working (labels stay as they are).
        func walk(_ v: NSView) {
            if let field = v as? NSTextField, !field.isEditable {
                // a label
            } else if let control = v as? NSControl {
                control.isEnabled = surface.live && !(control.identifier?.rawValue.hasPrefix("disabled:") ?? false)
            }
            if let t = v as? NSTableView { t.isEnabled = surface.live }
            v.subviews.forEach(walk)
        }
        walk(stack)
        if !surface.live {
            let ended = L10n.t("ended")
            if !caption.stringValue.hasSuffix(ended) { caption.stringValue += " · " + ended }
        }
    }

    override func layout() {
        super.layout()
        let close: CGFloat = closeButton == nil ? 0 : 22
        caption.frame = NSRect(x: 10, y: 3, width: max(0, bounds.width - 20 - close), height: Self.captionHeight - 4)
        closeButton?.frame = NSRect(x: bounds.width - 24, y: 2, width: 18, height: 16)
        scroll.frame = NSRect(x: 0, y: Self.captionHeight, width: bounds.width, height: max(0, bounds.height - Self.captionHeight))
        let width = scroll.contentSize.width
        if stackWidth.constant != width { stackWidth.constant = width }
        stack.layoutSubtreeIfNeeded()
        let height = max(stack.fittingSize.height, scroll.contentSize.height)
        scroll.documentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private var stackWidth: NSLayoutConstraint!

    /// How tall its content is at `width` (an overlay sized to fit).
    func contentHeight(width: CGFloat) -> CGFloat {
        stackWidth.constant = width
        stack.layoutSubtreeIfNeeded()
        return stack.fittingSize.height + Self.captionHeight
    }

    // MARK: Elements

    private func make(_ e: Element) -> NSView? {
        switch e.kind {
        case .text:
            let label = NSTextField(wrappingLabelWithString: e.text)
            label.isSelectable = true
            switch e.style {
            case "title": label.font = Typeface.ui(13, .semibold)
            case "secondary": label.font = Typeface.ui(12); label.textColor = .secondaryLabelColor
            case "mono": label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            default: label.font = Typeface.ui(12.5)
            }
            return label
        case .markdown:
            return textView(markdown(e.text))
        case .buttons:
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            for item in e.items {
                let button = NSButton(title: item.label, target: self, action: #selector(buttonTapped(_:)))
                button.bezelStyle = .rounded
                button.controlSize = .regular
                button.identifier = NSUserInterfaceItemIdentifier((item.disabled ? "disabled:" : "") + "\(e.id ?? ""):\(item.id)")
                button.isEnabled = !item.disabled
                if item.style == "primary" { button.bezelColor = Accent.color; button.keyEquivalent = "" }
                if item.style == "destructive" { button.hasDestructiveAction = true; button.contentTintColor = .systemRed }
                row.addArrangedSubview(button)
            }
            return row
        case .list, .table:
            return tableView(e)
        case .progress:
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 3
            if !e.label.isEmpty {
                let label = NSTextField(labelWithString: e.label)
                label.font = Typeface.ui(12)
                box.addArrangedSubview(label)
            }
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = e.value == nil
            bar.minValue = 0
            bar.maxValue = 1
            if let v = e.value { bar.doubleValue = v } else if !Motion.reduced { bar.startAnimation(nil) }
            bar.setAccessibilityLabel(e.label.isEmpty ? L10n.t("Progress") : e.label)
            box.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalToConstant: 260).isActive = true
            return box
        case .keyvalue:
            let grid = NSGridView(views: e.pairs.map { pair -> [NSView] in
                let key = NSTextField(labelWithString: pair.0)
                key.font = Typeface.ui(12)
                key.textColor = .secondaryLabelColor
                let value = NSTextField(wrappingLabelWithString: pair.1)
                value.font = Typeface.ui(12)
                value.isSelectable = true
                return [key, value]
            })
            grid.rowSpacing = 3
            grid.columnSpacing = 12
            return grid
        case .input:
            let box = NSStackView()
            box.orientation = .horizontal
            box.spacing = 8
            if !e.label.isEmpty {
                let label = NSTextField(labelWithString: e.label)
                label.font = Typeface.ui(12)
                box.addArrangedSubview(label)
            }
            let field = NSTextField(string: "")
            let id = e.id ?? ""
            if edited.contains(id), let kept = values[id] { field.stringValue = kept } else { field.stringValue = e.text; values[id] = e.text }
            field.placeholderString = e.placeholder
            field.identifier = NSUserInterfaceItemIdentifier(id)
            field.delegate = self
            field.target = self
            field.action = #selector(fieldSubmitted(_:))
            field.font = Typeface.ui(12.5)
            field.setAccessibilityLabel(e.label.isEmpty ? e.placeholder : e.label)
            box.addArrangedSubview(field)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            return box
        case .image:
            guard let image = Self.image(e.image) else {
                let note = NSTextField(labelWithString: L10n.t("(an image that couldn't be shown)"))
                note.textColor = .secondaryLabelColor
                return note
            }
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyDown
            view.setAccessibilityLabel(e.label.isEmpty ? L10n.t("Image") : e.label)
            let height = CGFloat(e.height ?? 6) * 16
            let width = image.size.height > 0 ? min(600, height * image.size.width / image.size.height) : height
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
            return view
        case .diff:
            return textView(Self.diff(e.text))
        case .divider:
            let line = NSBox()
            line.boxType = .separator
            return line
        }
    }

    private func textView(_ text: NSAttributedString) -> NSView {
        let view = AutoHeightTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textStorage?.setAttributedString(text)
        view.delegate = self
        return view
    }

    /// Markdown as AppKit draws it: no images, no HTML; links only to the
    /// web or to files, and those open with ⌘-click.
    private func markdown(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? NSMutableAttributedString(AttributedString(markdown: source, options: options)))
            ?? NSMutableAttributedString(string: source)
        let whole = NSRange(location: 0, length: parsed.length)
        parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        parsed.enumerateAttribute(.font, in: whole) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var font = Typeface.ui(12.5, traits.contains(.bold) ? .semibold : .regular)
            if traits.contains(.monoSpace) { font = .monospacedSystemFont(ofSize: 11.5, weight: .regular) }
            parsed.addAttribute(.font, value: font, range: range)
        }
        parsed.enumerateAttribute(.link, in: whole) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, Self.allowsLink(url) else {
                parsed.removeAttribute(.link, range: range)
                return
            }
            parsed.addAttribute(.toolTip, value: L10n.t("⌘-click to open") + "\n" + url.absoluteString, range: range)
        }
        return parsed
    }

    static func allowsLink(_ url: URL) -> Bool {
        ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    static func diff(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let color: NSColor = line.hasPrefix("+++") || line.hasPrefix("---") ? .secondaryLabelColor
                : line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? .systemBlue : .labelColor
            out.append(NSAttributedString(string: String(line) + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    /// An image from the program's bytes, or a file of this Mac's that is
    /// one (a regular file of an image type, within the size limit).
    static func image(_ source: Element.ImageSource?) -> NSImage? {
        switch source {
        case .data(let data):
            return NSImage(data: data)
        case .file(let path):
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
                  values.isRegularFile == true, (values.fileSize ?? .max) <= SurfaceProtocol.maxImageFileBytes,
                  values.contentType?.conforms(to: .image) == true else { return nil }
            return NSImage(contentsOf: url)
        case nil:
            return nil
        }
    }

    private func tableView(_ e: Element) -> NSView {
        let table = NSTableView()
        table.headerView = e.kind == .table ? NSTableHeaderView() : nil
        table.allowsMultipleSelection = e.selection == .multi
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = e.kind == .table
        table.rowHeight = 20
        table.style = .plain
        table.backgroundColor = .clear
        let columns = e.kind == .table ? e.columns : [""]
        for (i, title) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            column.title = title
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowActivated(_:))
        table.setAccessibilityLabel(e.id ?? (e.kind == .table ? L10n.t("Table") : L10n.t("List")))
        tables[table] = e
        table.reloadData()
        if e.selection == .none { table.selectionHighlightStyle = .none }
        // The choice the user made stays through the program's updates.
        if let id = e.id, let kept = values[id] {
            let ids = Set(kept.split(separator: "\n").map(String.init))
            let rows = IndexSet((0..<count(e)).filter { ids.contains(rowID(e, $0)) })
            restoring = true
            table.selectRowIndexes(rows, byExtendingSelection: false)
            restoring = false
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let visible = CGFloat(min(count(e), e.height ?? 8)) + (e.kind == .table ? 1.3 : 0)
        scroll.heightAnchor.constraint(equalToConstant: max(22, visible * 20 + 4)).isActive = true
        return scroll
    }

    /// Selecting what was chosen before: not the user's doing, not an event.
    private var restoring = false

    private func count(_ e: Element) -> Int { e.kind == .table ? e.rows.count : e.items.count }
    private func rowID(_ e: Element, _ row: Int) -> String { e.kind == .table ? e.rows[row].id : e.items[row].id }

    func numberOfRows(in tableView: NSTableView) -> Int { tables[tableView].map(count) ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let e = tables[tableView], let column = tableColumn else { return nil }
        let index = Int(column.identifier.rawValue.dropFirst()) ?? 0
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        cell.font = Typeface.ui(12)
        if e.kind == .table {
            cell.stringValue = e.rows[row].cells[safe: index] ?? ""
        } else {
            let item = e.items[row]
            let text = NSMutableAttributedString(string: item.label, attributes: [.font: Typeface.ui(12.5), .foregroundColor: NSColor.labelColor])
            if !item.detail.isEmpty {
                text.append(NSAttributedString(string: "  " + item.detail, attributes: [.font: Typeface.ui(11.5), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            cell.attributedStringValue = text
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tables[tableView]?.selection != Element.Selection.none && surface.live
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring, let table = notification.object as? NSTableView, let e = tables[table] else { return }
        let id = e.id ?? ""
        let ids = table.selectedRowIndexes.map { rowID(e, $0) }
        values[id] = ids.joined(separator: "\n")
        edited.insert(id)
        var fields: [String: Any] = ["type": "select", "items": ids]
        if !id.isEmpty { fields["element"] = id }
        send(fields)
    }

    // MARK: Events

    private var inputValues: [String: String] {
        var out: [String: String] = [:]
        for e in surface.spec.elements where e.kind == .input {
            if let id = e.id { out[id] = values[id] ?? e.text }
        }
        return out
    }

    private func send(_ fields: [String: Any]) {
        guard surface.live else { return }
        var event = fields
        event["surface"] = surface.spec.id
        if event["values"] == nil, !inputValues.isEmpty { event["values"] = inputValues }
        onEvent?(event)
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        let parts = raw.replacingOccurrences(of: "disabled:", with: "").split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var fields: [String: Any] = ["type": "click", "item": parts.count > 1 ? String(parts[1]) : ""]
        if let element = parts.first, !element.isEmpty { fields["element"] = String(element) }
        send(fields)
    }

    @objc private func rowActivated(_ sender: NSTableView) {
        guard let e = tables[sender], sender.clickedRow >= 0 else { return }
        var fields: [String: Any] = ["type": "activate", "item": rowID(e, sender.clickedRow)]
        if let id = e.id { fields["element"] = id }
        send(fields)
    }

    @objc private func fieldSubmitted(_ sender: NSTextField) {
        let id = sender.identifier?.rawValue ?? ""
        values[id] = sender.stringValue
        edited.insert(id)
        send(["type": "submit", "element": id])
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        values[id] = field.stringValue
        edited.insert(id)
    }

    /// Esc in a field: back to the terminal (what's typed stays).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onDone?()
        return true
    }

    /// The keyboard goes back to the pane (Esc in a field).
    var onDone: (() -> Void)?

    @objc private func closeTapped() {
        send(["type": "closed"])
        onClose?()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // ⌘-click opens, as a link in the terminal does; a plain click doesn't.
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return true }
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, Self.allowsLink(url) { onOpenLink?(url) }
        return true
    }

    // MARK: For the UI probe

    /// Presses the button with this item id (as a click would).
    func press(_ item: String) -> Bool {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.identifier?.rawValue.hasSuffix(":" + item) == true { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        guard let button = find(stack), button.isEnabled else { return false }
        buttonTapped(button)
        return true
    }

    /// Types into the input `id` and submits it.
    func submit(_ id: String, _ text: String) -> Bool {
        func find(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable, f.identifier?.rawValue == id { return f }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let field = find(stack), field.isEnabled else { return false }
        field.stringValue = text
        fieldSubmitted(field)
        return true
    }

    /// Chooses the row `item` in the list or table `element`.
    func choose(_ element: String, _ item: String) -> Bool {
        guard let (table, e) = tables.first(where: { $0.value.id == element }),
              let row = (0..<count(e)).first(where: { rowID(e, $0) == item }), table.isEnabled else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return true
    }

    /// What it shows, as words: the caption and every label (the UI probe).
    var shownText: String {
        var parts = [caption.stringValue]
        func walk(_ v: NSView) {
            if let f = v as? NSTextField { parts.append(f.stringValue) }
            if let b = v as? NSButton { parts.append(b.title) }
            if let t = v as? NSTextView { parts.append(t.string) }
            v.subviews.forEach(walk)
        }
        walk(stack)
        for (_, e) in tables { parts += e.kind == .table ? e.rows.flatMap(\.cells) : e.items.map(\.label) }
        return parts.joined(separator: " | ")
    }
}

/// A document view whose y grows downward (the stack's top at the top).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Text as tall as it needs at the width it's given (Markdown, a diff).
private final class AutoHeightTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(manager.usedRect(for: container).height) + 2)
    }

    override func setFrameSize(_ size: NSSize) {
        let widthChanged = size.width != frame.width
        super.setFrameSize(size)
        if widthChanged {
            textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
