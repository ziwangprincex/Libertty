import AppKit

/// The middle column: the selected tab's panes on the window's backdrop,
/// inset as Rex lays them out (`insets`, set by the window), a band along
/// the top while the traffic lights or the tabs are over this column, and
/// the find bar.
final class TerminalAreaView: NSView {
    /// The selected tab's panes, or its document.
    private(set) var content: NSView?
    let findBar = FindBar()
    private let fill = NSView()
    /// Between the column's edges (below the band) and the panes.
    var insets = NSEdgeInsets() { didSet { needsLayout = true } }
    /// The band along the top: its height, the room the traffic lights take
    /// at its left, and what it holds (left, middle, right).
    var bandHeight: CGFloat = 0 { didSet { needsLayout = true } }
    var bandClearance: CGFloat = 0 { didSet { needsLayout = true } }
    private(set) var bandViews: (left: NSView?, middle: NSView?, right: NSView?) = (nil, nil, nil)
    /// Where the band's controls line up (the traffic lights' middle, from the top).
    var bandMid: CGFloat = 23 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.wantsLayer = true
        addSubview(fill)
        findBar.isHidden = true
        addSubview(findBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Its empty stretches are the window's surface: they move it.
    override var mouseDownCanMoveWindow: Bool { true }

    func show(_ content: NSView) {
        guard content !== self.content else { return }
        self.content?.removeFromSuperview()
        self.content = content
        addSubview(content, positioned: .below, relativeTo: findBar)
        layoutSubtreeIfNeeded()
        needsLayout = true
    }

    /// The band's views; nil leaves that place empty.
    func setBand(left: NSView?, middle: NSView?, right: NSView?) {
        for old in [bandViews.left, bandViews.middle, bandViews.right] {
            if let old, old !== left, old !== middle, old !== right, old.superview === self { old.removeFromSuperview() }
        }
        for new in [left, middle, right] {
            guard let new, new.superview !== self else { continue }
            new.removeFromSuperview()
            new.translatesAutoresizingMaskIntoConstraints = true
            addSubview(new, positioned: .below, relativeTo: findBar)
        }
        bandViews = (left, middle, right)
        needsLayout = true
    }

    /// Glass panes (`interface-style = glass`): the backdrop shows through
    /// the terminals; their cards are counted for the probe.
    private var glass = false

    /// The backdrop (the window's) is the frame now: nothing is painted here.
    func apply(background: RGB, opacity: Double, blurred: Bool, glass: Bool = false) {
        fill.layer?.backgroundColor = nil
        self.glass = glass
        updateHoles()
        needsLayout = true
    }

    /// Cut the terminals out of the frame (glass panes), or fill it whole.
    /// The split calls this after every layout, so the holes follow its
    /// animations.
    func updateHoles() {
        guard let layer = fill.layer else { return }
        guard glass, let split = content.flatMap(Self.split(in:)) else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let path = CGMutablePath()
        path.addRect(fill.bounds)
        for rect in split.terminalCards {
            let r = fill.convert(rect, from: split)
            if Radius.pane > 0, r.width > Radius.pane * 2, r.height > Radius.pane * 2 {
                path.addRoundedRect(in: r, cornerWidth: Radius.pane, cornerHeight: Radius.pane)
            } else {
                path.addRect(r)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
        mask.frame = fill.bounds
        mask.fillRule = .evenOdd
        mask.path = path
        layer.mask = mask
        CATransaction.commit()
    }

    /// How many terminals the frame lets through (`--ui-probe`).
    var holeCount: Int {
        guard let mask = fill.layer?.mask as? CAShapeLayer, let path = mask.path else { return 0 }
        var subpaths = 0
        path.applyWithBlock { element in if element.pointee.type == .moveToPoint { subpaths += 1 } }
        return max(0, subpaths - 1)
    }

    private static func split(in view: NSView) -> SplitContainerView? {
        if let split = view as? SplitContainerView { return split }
        for sub in view.subviews { if let found = split(in: sub) { return found } }
        return nil
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        defer { updateHoles() }
        let top = bounds.height - bandHeight
        // Whole points: the split view can leave this column half a point
        // wide, and a card between pixels rounds a point bigger.
        self.content?.frame = NSRect(x: insets.left, y: insets.bottom,
                                     width: max(0, (bounds.width - insets.left - insets.right).rounded(.down)),
                                     height: max(0, (top - insets.top - insets.bottom).rounded(.down)))
        // The band: its controls on the traffic lights' line.
        let mid = bounds.height - bandMid
        var left = bandClearance
        if let v = bandViews.left {
            let size = v.fittingSize
            v.frame = NSRect(x: left, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
            left = v.frame.maxX + 6
        }
        var right = bounds.width - 9
        if let v = bandViews.right {
            let size = v.fittingSize
            v.frame = NSRect(x: right - size.width, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
            right = v.frame.minX - 6
        }
        if let v = bandViews.middle {
            let height = min(bandHeight, max(v.fittingSize.height, TabStrip.height))
            v.frame = NSRect(x: left, y: (mid - height / 2).rounded(), width: max(0, right - left), height: height)
        }
        // No band: the buttons are over the panes' top row, which keeps clear of them.
        if let content, let split = Self.split(in: content) {
            let frame = content.frame
            split.sharesTopRow = bandHeight == 0 && (bandViews.left != nil || bandViews.right != nil || bandClearance > 9)
            split.topClearance = bandHeight > 0 ? (0, 0)
                : (max(bandClearance, (bandViews.left?.frame.maxX ?? 0) + 4) - frame.minX,
                   bandViews.right.map { frame.maxX - ($0.frame.minX - 4) } ?? 0)
        }
        // The find bar only needs a frame while it's shown, and room for one.
        guard !findBar.isHidden, bounds.width > 120 else { return }
        let size = findBar.fittingSize
        let width = min(max(size.width, 360), bounds.width - 24)
        findBar.frame = NSRect(x: bounds.width - width - 12, y: top - insets.top - size.height - 10,
                               width: width, height: size.height)
    }
}

/// The window's columns. Showing or hiding the sidebar or inspector (the
/// toolbar's button, a menu, a key) goes to the window, through `toggle`
/// (true: the sidebar): it keeps its terminals as they are.
final class ColumnsController: NSSplitViewController {
    var toggle: ((_ sidebar: Bool) -> Void)?

    override func toggleSidebar(_ sender: Any?) {
        guard let toggle else { return super.toggleSidebar(sender) }
        toggle(true)
    }

    override func toggleInspector(_ sender: Any?) {
        guard let toggle else { return super.toggleInspector(sender) }
        toggle(false)
    }

}

/// The window's columns (sidebar, panes, inspector) on one backdrop: the
/// dividers draw nothing (the backdrop shows), or a hairline with compact
/// panes (Rex's boundary lines).
final class FrameSplitView: NSSplitView {
    let backdrop = WindowBackdrop()
    /// The hairline between the columns, compact; nil draws none.
    var line: NSColor? { didSet { needsDisplay = true } }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if backdrop.superview !== self {
            backdrop.frame = bounds
            addSubview(backdrop, positioned: .below, relativeTo: nil)
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Always under everything the split view adds (its items, AppKit's own).
        if subview !== backdrop, backdrop.superview === self, subviews.first !== backdrop {
            addSubview(backdrop, positioned: .below, relativeTo: nil)
        }
    }

    override var dividerColor: NSColor { line ?? .clear }
    /// A whole point: a thin divider is half of one on a Retina screen, and
    /// a column a half point wide leaves the panes' cards between pixels.
    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        guard let line else { return }
        line.setFill()
        rect.fill()
    }
}

final class TerminalAreaViewController: NSViewController {
    let area = TerminalAreaView()
    override func loadView() { view = area }
}

/// Tern's "Find in scrollback" bar: the query, "k of n", older/newer, close.
/// Return goes to the next (older) match, Shift-Return the newer one, Esc closes.
final class FindBar: NSVisualEffectView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNavigate: ((_ older: Bool) -> Void)?
    /// The bar's arrows: up the page or down it (older is up in a
    /// terminal's scrollback, but a document's next match is below).
    var onArrow: ((_ up: Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Radius.control + 2
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = NSShadow()

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.hideFromAccessibility()
        field.placeholderString = "Find in scrollback"
        field.setAccessibleLabel(L10n.t("Find"))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.ui(13)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor

        func button(_ symbol: String, _ name: String, _ more: String, _ action: Selector) -> NSButton {
            let label = L10n.t(name)
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = label + " " + more
            // Its name; the shortcut is in its tip.
            b.setAccessibleLabel(label)
            return b
        }
        let stack = NSStackView(views: [
            icon, field, count,
            button("chevron.up", "Previous Match", "(older) ⌘G", #selector(older)),
            button("chevron.down", "Next Match", "(newer) ⇧⌘G", #selector(newer)),
            button("xmark", "Close", "(Esc)", #selector(close)),
        ])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Find"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Its edge in the window's light or dark (a layer's color is resolved once).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
    }

    /// Documents report only whether the text was found.
    func showDocument(found: Bool, empty: Bool) {
        count.stringValue = empty ? "" : found ? "" : L10n.t("No matches")
        // (Found: the page shows it, there's no count to say.)
        if announcesNext {
            if found { announcesNext = false } else { tellCount() }
        }
    }

    func show(result: SearchResult) {
        if !result.active || field.stringValue.isEmpty {
            count.stringValue = ""
        } else if result.total == 0 {
            count.stringValue = L10n.t("No matches")
        } else {
            count.stringValue = result.selected.map { String(format: L10n.t("%d of %d"), $0, result.total) } ?? "\(result.total)"
        }
        if announcesNext { tellCount() }
    }

    /// Return or an arrow went to another match: VoiceOver says which
    /// ("3 of 12") once its count comes. (Not as matches come in with new
    /// output, nor as you type: it says the letters then.) Typing, or the
    /// count coming, ends it; else it lapses after a while (a search that
    /// never answers).
    private var announcesNext = false
    private var navigation = 0

    private func navigated() {
        announcesNext = true
        navigation += 1
        let mine = navigation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.navigation == mine { self?.announcesNext = false }
        }
    }

    private func tellCount() {
        announcesNext = false
        AccessibilityNews.announce(count.stringValue, from: count)
    }

    func controlTextDidChange(_ obj: Notification) {
        announcesNext = false
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            navigated()
            onNavigate?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func older() { navigated(); if let onArrow { onArrow(true) } else { onNavigate?(true) } }
    @objc private func newer() { navigated(); if let onArrow { onArrow(false) } else { onNavigate?(false) } }
    @objc private func close() { onClose?() }
}
