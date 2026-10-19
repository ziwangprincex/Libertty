import AppKit

/// The tabs along the window's top (`tab-bar = top`, Tern's horizontal
/// tabs): each its glyphs and name, the selected one on the sidebar's
/// gliding card, a + after the last. A click selects, a double-click
/// renames in place, a drag reorders, the middle button or the × that
/// shows on hover closes, and the menu does the rest — as the sidebar's
/// rows do. Tabs share the room when there are many, then scroll.
final class TabStrip: NSView {
    weak var controller: TerminalWindowController?

    static let height: CGFloat = 28
    private static let tabHeight: CGFloat = 26
    private static let spacing: CGFloat = 2
    private static let maxTabWidth: CGFloat = 220
    private static let minTabWidth: CGFloat = 64

    private var tabs: [SidebarTabInfo] = []
    private var selected = 0
    private var buttons: [TabStripButton] = []
    private let card = SelectionCard()
    private let add = NSButton()
    /// The workspace's name, before the tabs (Tern's "Default"): a menu of the window's workspaces.
    private let workspace = NSButton()
    private var workspaceWidth: CGFloat = 0
    /// How far the tabs are scrolled left, when they don't all fit.
    private var offset: CGFloat = 0
    /// The card glides when the selection moved; scrolling and resizing carry it along.
    private var animateCard = false
    private var dragging: (button: TabStripButton, tab: TerminalTab?, grab: CGFloat, to: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        card.flat = true
        addSubview(card)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        add.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        add.target = self
        add.action = #selector(newTab(_:))
        add.toolTip = TerminalWindowController.tip("New Tab", .newTab)
        addSubview(add)
        workspace.isBordered = false
        workspace.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Workspaces")
        workspace.imagePosition = .imageLeading
        workspace.font = Typeface.ui(12.5, .medium)
        workspace.contentTintColor = .secondaryLabelColor
        workspace.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        workspace.target = self
        workspace.action = #selector(showWorkspaces(_:))
        workspace.toolTip = "Workspaces"
        addSubview(workspace)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    // Its empty stretch is title bar: it moves the window.
    override var mouseDownCanMoveWindow: Bool { true }

    /// What each tab says as drawn, a name being typed included (`--ui-probe`).
    var shownNames: [String] { buttons.map(\.shownName) }

    @objc private func showWorkspaces(_ sender: NSView) { controller?.showWorkspaceMenu(from: sender) }

    /// The workspace's name, shown once the window has several.
    func show(workspace name: String, of count: Int) {
        let shown = count > 1
        workspace.isHidden = !shown
        guard shown else {
            if workspaceWidth != 0 { workspaceWidth = 0; needsLayout = true }
            return
        }
        workspace.attributedTitle = NSAttributedString(string: " " + name, attributes: [
            .font: Typeface.ui(12.5, .medium), .foregroundColor: NSColor.labelColor])
        let width = ceil(workspace.attributedTitle.size().width) + 28
        if width != workspaceWidth { workspaceWidth = width; needsLayout = true }
    }

    func show(tabs: [SidebarTabInfo], selected: Int) {
        let selectionMoved = selected != self.selected
        let countChanged = tabs.count != self.tabs.count
        // A name being typed keeps its field unless its tab went or moved;
        // then it's kept first, and keeping it brings the tabs up to date.
        if let editing = buttons.firstIndex(where: \.isEditing),
           tabs.count != self.tabs.count || editing != selected {
            return buttons[editing].finishEditing()
        }
        // Tabs coming or going end a drag: its tab may be among them.
        if countChanged, let drag = dragging {
            dragging = nil
            drag.button.layer?.zPosition = 0
        }
        self.tabs = tabs
        self.selected = selected
        animateCard = selectionMoved || countChanged
        while buttons.count < tabs.count {
            let button = TabStripButton()
            button.strip = self
            addSubview(button, positioned: .above, relativeTo: card)
            buttons.append(button)
        }
        while buttons.count > tabs.count { buttons.removeLast().removeFromSuperview() }
        for (i, button) in buttons.enumerated() {
            button.configure(tabs[i], selected: i == selected, closable: tabs.count > 1)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if selectionMoved { scrollToSelected() }
    }

    // MARK: Layout

    /// Each tab's width: its own up to a cap, all shrunk alike when they
    /// don't fit, never below a minimum (then they scroll).
    private func widths() -> [CGFloat] {
        let natural = buttons.map { min(Self.maxTabWidth, max(Self.minTabWidth, $0.naturalWidth)) }
        let room = bounds.width - addWidth - leading - Self.spacing * CGFloat(max(0, buttons.count - 1))
        let total = natural.reduce(0, +)
        guard total > room, !natural.isEmpty else { return natural }
        // The widest give way first, down to one common width (a browser's
        // way): the cap where the k widest at it and the rest as they are fill the room.
        let sorted = natural.sorted(by: >)
        var rest = total
        var cap = Self.minTabWidth
        for k in sorted.indices {
            rest -= sorted[k]
            let fair = (room - rest) / CGFloat(k + 1)
            if fair >= (k + 1 < sorted.count ? sorted[k + 1] : 0) { cap = fair; break }
        }
        return natural.map { max(Self.minTabWidth, min($0, cap)) }
    }

    private var addWidth: CGFloat { 4 + 28 }
    /// Room the workspace name takes before the first tab.
    private var leading: CGFloat { workspaceWidth > 0 ? workspaceWidth + 8 : 0 }

    private var contentWidth: CGFloat {
        widths().reduce(0, +) + Self.spacing * CGFloat(max(0, buttons.count - 1)) + addWidth + leading
    }

    override func layout() {
        super.layout()
        offset = max(0, min(offset, contentWidth - bounds.width))
        let y = ((bounds.height - Self.tabHeight) / 2).rounded()
        workspace.frame = NSRect(x: 4, y: ((bounds.height - 24) / 2).rounded(), width: workspaceWidth, height: 24)
        var x = -offset + leading
        for (i, (button, width)) in zip(buttons, widths()).enumerated() {
            let frame = NSRect(x: x, y: y, width: width, height: Self.tabHeight)
            // A drag places the tabs itself until it ends.
            if dragging == nil {
                button.frame = frame
                if i == selected { if animateCard { card.move(to: frame) } else { card.place(frame) } }
            }
            x += width + Self.spacing
        }
        animateCard = false
        if buttons.isEmpty { card.place(.zero) }
        add.frame = NSRect(x: x - Self.spacing + 4, y: ((bounds.height - 28) / 2).rounded(), width: 28, height: 28)
    }

    private func scrollToSelected() {
        guard buttons.indices.contains(selected) else { return }
        let frame = buttons[selected].frame
        if frame.minX < 0 { offset += frame.minX } else if frame.maxX > bounds.width - addWidth {
            offset += frame.maxX - (bounds.width - addWidth)
        }
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard contentWidth > bounds.width else { return super.scrollWheel(with: event) }
        // A vertical wheel scrolls the tabs too: there's nothing else to scroll here.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        offset -= event.hasPreciseScrollingDeltas ? delta : delta * 10
        needsLayout = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    // MARK: Tabs' actions

    fileprivate func index(of button: TabStripButton) -> Int? { buttons.firstIndex { $0 === button } }

    fileprivate func select(_ button: TabStripButton) {
        if let i = index(of: button) { controller?.selectTab(at: i) }
    }

    fileprivate func close(_ button: TabStripButton) {
        if let i = index(of: button) { controller?.closeTab(at: i) }
    }

    fileprivate func rename(_ button: TabStripButton) {
        guard let i = index(of: button) else { return }
        controller?.selectTab(at: i)
        beginRename(at: i)
    }

    /// Rename tab `index` in place: its name becomes a field. Return or
    /// clicking away keeps it, Esc goes back, empty goes back to the
    /// automatic name.
    func beginRename(at index: Int) {
        guard buttons.indices.contains(index), let tab = controller?.tab(at: index) else { return }
        buttons.filter(\.isEditing).forEach { $0.finishEditing() }
        buttons[index].beginEditing(current: tab.titleOverride, placeholder: tabs[index].title) { [weak self, weak tab] name, refocus in
            guard let self else { return }
            if let name, let tab { self.controller?.rename(tab, to: name) }
            self.controller?.updateSidebar()
            if refocus { self.controller?.focusTerminal() }
        }
    }

    fileprivate func menu(for button: TabStripButton) -> NSMenu? {
        guard let i = index(of: button), let tab = controller?.tab(at: i) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // The tab itself, found again when the item runs: tabs may come and
        // go while the menu is open, and an index from before would be another's.
        func item(_ title: String, enabled: Bool = true, _ action: @escaping (Int) -> Void) {
            let item = ClosureMenuItem(title: title) { [weak self, weak tab] in
                guard let self, let tab, let now = self.controller?.tabs.firstIndex(where: { $0 === tab }) else { return }
                action(now)
            }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        item("Rename Tab…") { [weak self] now in
            self?.controller?.selectTab(at: now)
            self?.beginRename(at: now)
        }
        item("Reset Name", enabled: !tab.titleOverride.isEmpty) { [weak self] now in self?.controller?.renameTab(at: now, to: "") }
        item("Duplicate Tab") { [weak self] now in self?.controller?.duplicateTab(at: now) }
        menu.addItem(.separator())
        item("Move Left", enabled: i > 0) { [weak self] now in self?.controller?.moveTab(from: now, to: now - 1) }
        item("Move Right", enabled: i < tabs.count - 1) { [weak self] now in self?.controller?.moveTab(from: now, to: now + 1) }
        menu.addItem(.separator())
        item("Close Tab") { [weak self] now in self?.controller?.closeTab(at: now) }
        item("Close Other Tabs", enabled: tabs.count > 1) { [weak self] now in self?.controller?.closeOtherTabs(keeping: now) }
        return menu
    }

    @objc private func newTab(_ sender: Any?) { controller?.newTab() }

    // MARK: Dragging to reorder

    fileprivate func beginDrag(_ button: TabStripButton, at point: NSPoint) {
        guard let i = index(of: button) else { return }
        dragging = (button, controller?.tab(at: i), point.x - button.frame.minX, i)
        button.layer?.zPosition = 1
    }

    fileprivate func drag(to point: NSPoint) {
        guard var drag = dragging else { return }
        let width = drag.button.frame.width
        let x = max(-offset + leading, min(point.x - drag.grab, contentWidth - offset - addWidth - width))
        drag.button.frame.origin.x = x
        // The selected tab's card goes with it.
        if index(of: drag.button) == selected { card.place(drag.button.frame) }
        // Where it would land: past each other tab whose slot's middle the
        // dragged tab's middle has passed. Slots, not the tabs' own frames
        // (they are shifting to make room), so a wide tab can still reach either end.
        let others = zip(buttons, widths()).filter { $0.0 !== drag.button }
        let mid = x + width / 2
        var slot = -offset + leading
        var landing = 0
        for (_, w) in others {
            if mid > slot + w / 2 { landing += 1 }
            slot += w + Self.spacing
        }
        drag.to = landing
        dragging = drag
        // The others make room there.
        slot = -offset + leading
        for (placed, (button, w)) in others.enumerated() {
            if placed == drag.to { slot += width + Self.spacing }
            if button.frame.minX != slot {
                (Motion.reduced ? button : button.animator()).setFrameOrigin(NSPoint(x: slot, y: button.frame.minY))
            }
            slot += w + Self.spacing
        }

    }

    fileprivate func endDrag() {
        guard let drag = dragging else { return }
        dragging = nil
        drag.button.layer?.zPosition = 0
        // From where the tab is now, not where it was when the drag began:
        // a tab may have closed meanwhile (and the dragged one with it).
        if let tab = drag.tab, let from = controller?.tabs.firstIndex(where: { $0 === tab }), from != drag.to {
            controller?.moveTab(from: from, to: min(drag.to, (controller?.tabs.count ?? 1) - 1))
        } else {
            needsLayout = true
        }
    }
}

/// One tab of the strip.
private final class TabStripButton: NSView, NSTextFieldDelegate {
    weak var strip: TabStrip?

    private let badge = StatusBadge()
    private let tiles = TileStack()
    private let title = NSTextField(labelWithString: "")
    private let news = CAShapeLayer()
    private let newsView = NSView()
    private let close = NSButton()
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var closable = true
    private var isSelected = false
    private var showsBadge = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = Typeface.secondary
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        close.target = self
        close.action = #selector(closeIt)
        close.toolTip = "Close Tab"
        close.isHidden = true
        newsView.wantsLayer = true
        news.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 6, height: 6), transform: nil)
        news.lineWidth = 1.2
        newsView.layer?.addSublayer(news)
        newsView.isHidden = true
        for v in [badge, tiles, title, newsView, close] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let inset: CGFloat = 10
    private static let gap: CGFloat = 6
    /// Room for the × on the right, kept so the name doesn't shift on hover.
    private static let closeRoom: CGFloat = 16

    /// What it would take to show everything.
    var naturalWidth: CGFloat {
        let glyph = showsBadge ? 13 : tiles.intrinsicContentSize.width
        let text = ceil(title.intrinsicContentSize.width)  // the cell's own padding included
        return Self.inset + glyph + (glyph > 0 ? Self.gap : 0) + text + (newsView.isHidden ? 0 : 12) + 4 + Self.closeRoom + 4
    }

    func configure(_ tab: SidebarTabInfo, selected: Bool, closable: Bool) {
        isSelected = selected
        self.closable = closable
        tiles.tiles = tab.tiles
        tiles.fallbackSymbol = tab.documentURL
            .map(DocumentView.symbol(for:)) ?? "apple.terminal"
        let look = StatusBadge.look(status: tab.status, progress: tab.progress)
        badge.show(look)
        showsBadge = look != .none
        badge.isHidden = !showsBadge
        tiles.isHidden = showsBadge
        if !isEditing {
            // A folder goes by its last part, as Tern names a tab "cwd";
            // the whole path is in the tooltip.
            let path = tab.title.hasPrefix("/") || tab.title.hasPrefix("~/") || tab.title.hasPrefix("…/")
            let name = path ? (tab.title as NSString).lastPathComponent : tab.title
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            title.attributedStringValue = NSAttributedString(string: name, attributes: [
                .font: Typeface.secondary, .paragraphStyle: paragraph,
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
        }
        var tip = [tab.title]
        if !tab.detail.isEmpty { tip.append(tab.detail) }
        if tab.paneCount > 1 { tip.append(tab.zoomed ? "\(tab.paneCount) panes, zoomed" : "\(tab.paneCount) panes") }
        if tab.parked > 0 { tip.append("\(tab.parked) parked") }
        if let status = tab.status { tip.append(TerminalWindowController.label(for: status)) }
        toolTip = tip.joined(separator: " · ")
        showNews(tab.news)
        close.isHidden = !(closable && hovering)
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(selected)
        needsLayout = true
    }

    // The whole tab answers the mouse, its name too; only the × and the
    // rename field take their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === close || editor.map({ hit.isDescendant(of: $0) }) == true { return hit }
        return self
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = Self.inset
        if showsBadge {
            badge.frame = NSRect(x: x, y: (h - 13) / 2, width: 13, height: 13)
            x += 13 + Self.gap
        } else {
            let size = tiles.intrinsicContentSize
            tiles.frame = NSRect(x: x, y: ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
            if size.width > 0 { x += size.width + Self.gap }
        }
        let closeX = bounds.width - 4 - Self.closeRoom
        close.frame = NSRect(x: closeX, y: (h - Self.closeRoom) / 2, width: Self.closeRoom, height: Self.closeRoom)
        var end = closeX - 2
        if !newsView.isHidden {
            newsView.frame = NSRect(x: end - 8, y: (h - 8) / 2, width: 8, height: 8)
            end -= 12
        }
        let textHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: x, y: ((h - textHeight) / 2).rounded(), width: max(0, end - x), height: textHeight)
        editor?.frame = NSRect(x: x - 3, y: (h - 22) / 2, width: max(60, bounds.width - x - 4), height: 22)
    }

    private func showNews(_ value: TabNews) {
        let accent = NSColor.controlAccentColor.cgColor
        switch value {
        case .none:
            newsView.isHidden = true
        case .printing:
            newsView.isHidden = false
            news.fillColor = accent
            news.strokeColor = nil
        case .attention:
            newsView.isHidden = false
            news.fillColor = nil
            news.strokeColor = accent
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if news.fillColor != nil { news.fillColor = NSColor.controlAccentColor.cgColor }
        if news.strokeColor != nil { news.strokeColor = NSColor.controlAccentColor.cgColor }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ on: Bool) {
        hovering = on
        close.isHidden = !(closable && on) || isEditing
    }

    private var pressed: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        guard !isEditing else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            strip?.rename(self)
            return
        }
        pressed = superview.map { $0.convert(event.locationInWindow, from: nil) }
        dragged = false
        strip?.select(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let strip, let start = pressed else { return }
        let point = strip.convert(event.locationInWindow, from: nil)
        if !dragged {
            guard abs(point.x - start.x) > 4 else { return }
            dragged = true
            strip.beginDrag(self, at: start)
        }
        strip.drag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { strip?.endDrag() }
        pressed = nil
        dragged = false
    }

    // The middle button closes a tab, as in a browser.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, closable, bounds.contains(convert(event.locationInWindow, from: nil)) {
            strip?.close(self)
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { strip?.menu(for: self) }

    @objc private func closeIt() { strip?.close(self) }

    override func accessibilityPerformPress() -> Bool {
        strip?.select(self)
        return true
    }

    // MARK: Renaming in place

    private var editor: NSTextField?
    private var finish: ((String?, Bool) -> Void)?

    var isEditing: Bool { editor != nil }
    var shownName: String { editor?.stringValue ?? title.stringValue }

    func beginEditing(current: String, placeholder: String, done: @escaping (String?, Bool) -> Void) {
        let field = NSTextField(string: current)
        field.placeholderString = placeholder
        field.font = Typeface.secondary
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        addSubview(field)
        editor = field
        finish = done
        title.isHidden = true
        close.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Keep what was typed: the tabs are changing under the field.
    func finishEditing() { endEditing(keep: true, refocus: editor?.currentEditor() != nil) }

    private func endEditing(keep: Bool, refocus: Bool) {
        guard let field = editor else { return }
        editor = nil
        let done = finish
        finish = nil
        let name = keep ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        field.removeFromSuperview()
        title.isHidden = false
        done?(name, refocus)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endEditing(keep: true, refocus: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(keep: false, refocus: true); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing(keep: true, refocus: false) }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
