import AppKit

/// A tab's minimized floating panes (Rex's taskbar): each a small capsule
/// in a corner of its split, saying what runs there and, when it reports
/// it, what it's doing (working, waiting for you, done). A click brings
/// one back with the keyboard; its menu brings it back or closes it;
/// dragging the row takes them all to another corner
/// (`floating-minimized-corner`). Small and see-through enough to leave the
/// text under it readable, and never the keyboard's: clicks only.
final class FloatingTaskbar: NSView {
    /// One minimized pane, as its capsule shows it.
    struct Entry: Equatable {
        let pane: ObjectIdentifier
        var name: String
        /// Its program's glyph; nil draws the name's first letter.
        var symbol: String?
        var badge: StatusBadge.Look = .none
        /// What it's doing, in a word ("working"), for VoiceOver; empty for nothing.
        var state = ""
    }

    var corner = Config.MinimizedCorner.bottomRight
    var onRestore: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    /// Dragged to another corner (written to the config by the window).
    /// Dragged to `corner`: false when that can't be kept, and the row goes back.
    var onMove: ((Config.MinimizedCorner) -> Bool)?

    private(set) var capsules: [FloatingCapsule] = []
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint = .zero
    private(set) var dragging = false

    static let height: CGFloat = 26
    static let spacing: CGFloat = 6
    /// From the split's edges: clear of the cards' rounded corners and an overlay scrollbar.
    static var margin: CGFloat { 10 + Layout.stageInset }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Over the split's panes and its floating ones alike.
        layer?.zPosition = 25
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Minimized floating panes"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Only the capsules take clicks: the gaps between them are the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// What the capsules show now, in order.
    var entries: [Entry] { capsules.map(\.entry) }

    /// What it shows: a capsule per entry, in order; those already there kept.
    func show(_ entries: [Entry]) {
        var kept: [FloatingCapsule] = []
        for entry in entries {
            let capsule = capsules.first { $0.entry.pane == entry.pane } ?? {
                let new = FloatingCapsule(entry: entry, bar: self)
                addSubview(new)
                appear(new)
                return new
            }()
            capsule.entry = entry
            kept.append(capsule)
        }
        for gone in capsules where !kept.contains(where: { $0 === gone }) { gone.removeFromSuperview() }
        capsules = kept
        capsules.forEach { $0.updateColors() }
    }

    /// A new capsule fades in (at once, with Reduce Motion).
    private func appear(_ capsule: FloatingCapsule) {
        let duration = Motion.duration(Motion.small)
        guard duration > 0 else { return }
        capsule.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.ease
            capsule.animator().alphaValue = 1
        }
    }

    /// Where it goes in a split of `size`, in `corner`: the capsules side
    /// by side, their names shortened to fit when there are many.
    func frame(in size: NSSize, corner: Config.MinimizedCorner) -> NSRect {
        let m = Self.margin
        let room = max(0, size.width - 2 * m)
        let fixed = capsules.reduce(0) { $0 + $1.fixedWidth } + Self.spacing * CGFloat(max(0, capsules.count - 1))
        let cap = capsules.isEmpty ? FloatingCapsule.nameCap
            : min(FloatingCapsule.nameCap, max(28, (room - fixed) / CGFloat(capsules.count)))
        var x: CGFloat = 0
        for capsule in capsules {
            let width = capsule.width(nameCap: cap)
            capsule.frame = NSRect(x: x, y: 0, width: width, height: Self.height)
            x += width + Self.spacing
        }
        let width = min(room, max(0, x - Self.spacing))
        let left: CGFloat = switch corner.side {
        case -1: m
        case 0: (size.width - width) / 2
        default: size.width - width - m
        }
        let top = corner.top ? m : size.height - Self.height - m
        return NSRect(x: max(0, left), y: max(0, top), width: width, height: Self.height).integral
    }

    /// To `rect`, gliding there when asked (not with Reduce Motion), unless
    /// it's being dragged.
    func move(to rect: NSRect, animated: Bool = false) {
        guard !dragging else { return }
        let duration = animated ? Motion.duration(Motion.small) : 0
        guard duration > 0 else { frame = rect; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.out
            animator().frame = rect
        }
    }

    // MARK: Dragging (a capsule's press starts it)

    fileprivate func press(_ event: NSEvent) {
        dragStart = superview?.convert(event.locationInWindow, from: nil)
        dragOrigin = frame.origin
        dragging = false
    }

    fileprivate func drag(_ event: NSEvent) {
        guard let superview, let start = dragStart else { return }
        let now = superview.convert(event.locationInWindow, from: nil)
        if !dragging, hypot(now.x - start.x, now.y - start.y) < 4 { return }
        dragging = true
        let size = superview.bounds.size
        frame.origin = NSPoint(x: min(max(0, dragOrigin.x + now.x - start.x), max(0, size.width - frame.width)),
                               y: min(max(0, dragOrigin.y + now.y - start.y), max(0, size.height - frame.height)))
    }

    /// Let go: a press that didn't move was a click on `capsule`; a drag
    /// ends in the corner (or edge's middle) its middle is nearest.
    fileprivate func release(_ capsule: FloatingCapsule) {
        defer { dragStart = nil }
        guard dragging, let superview else {
            if dragStart != nil { onRestore?(capsule.entry.pane) }
            return
        }
        dragging = false
        let bounds = superview.bounds
        let third = bounds.width / 3
        let side = frame.midX < bounds.minX + third ? -1 : frame.midX > bounds.maxX - third ? 1 : 0
        let before = corner
        corner = Config.MinimizedCorner(top: frame.midY < bounds.midY, side: side)
        // Not kept (the setting is set in an included file): back where it was.
        if onMove?(corner) == false { corner = before }
        move(to: self.frame(in: bounds.size, corner: corner), animated: true)
        (superview as? SplitContainerView)?.setNeedsTaskbarPlacement()
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { capsules }

    /// What each capsule says, in order (`--ui-probe`).
    var shownNames: [String] { capsules.map(\.entry.name) }
}

/// One minimized floating pane: its program's glyph, its name, and its
/// status badge when it reports one, on a small capsule. To VoiceOver
/// it's a button that restores the pane, with Close among its actions.
final class FloatingCapsule: NSView {
    var entry: FloatingTaskbar.Entry {
        didSet { if entry != oldValue { update() } }
    }
    private weak var bar: FloatingTaskbar?
    private let glyph = NSImageView()
    private let letter = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let badge = StatusBadge()
    private var hovering = false { didSet { if hovering != oldValue { updateColors() } } }

    static let nameCap: CGFloat = 120
    private static let padding: CGFloat = 9, glyphSize: CGFloat = 14, gap: CGFloat = 5

    init(entry: FloatingTaskbar.Entry, bar: FloatingTaskbar) {
        self.entry = entry
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = FloatingTaskbar.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        glyph.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        glyph.imageScaling = .scaleNone
        letter.font = Typeface.ui(11, .semibold)
        letter.alignment = .center
        name.font = Typeface.ui(12, .medium)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        // The capsule speaks for them all.
        for v in [glyph, letter, name, badge] as [NSView] {
            v.hideFromAccessibility()
            addSubview(v)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var label: String { String(format: L10n.t("Bring back %@"), entry.name) }

    private func update() {
        if let symbol = entry.symbol {
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            glyph.isHidden = false
            letter.isHidden = true
        } else {
            letter.stringValue = String(entry.name.prefix(1)).uppercased()
            glyph.isHidden = true
            letter.isHidden = false
        }
        name.stringValue = entry.name
        badge.show(entry.badge)
        badge.isHidden = entry.badge == .none
        toolTip = entry.state.isEmpty ? label : label + " (" + entry.state + ")"
        setAccessibilityLabel(label)
        setAccessibilityValue(entry.state.isEmpty ? nil : entry.state)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: L10n.t("Close")) { [weak self] in
            guard let self, let bar = self.bar else { return false }
            bar.onClose?(self.entry.pane)
            return true
        }])
        needsLayout = true
    }

    /// Its width but for the name's.
    var fixedWidth: CGFloat {
        2 * Self.padding + Self.glyphSize + Self.gap + (badge.isHidden ? 0 : Self.gap + 13)
    }

    /// Its width with the name at most `nameCap` wide (the label's cell
    /// insets the text: room for those too).
    func width(nameCap: CGFloat) -> CGFloat {
        fixedWidth + min(nameCap, ceil(name.attributedStringValue.size().width) + 6)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let icon = NSRect(x: Self.padding, y: (h - Self.glyphSize) / 2, width: Self.glyphSize, height: Self.glyphSize)
        glyph.frame = icon
        letter.frame = icon.offsetBy(dx: 0, dy: -0.5)
        let badgeWidth: CGFloat = badge.isHidden ? 0 : 13 + Self.gap
        let nameX = icon.maxX + Self.gap
        let textHeight = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nameX, y: (h - textHeight) / 2, width: max(0, bounds.width - nameX - Self.padding - badgeWidth),
                            height: textHeight)
        badge.frame = NSRect(x: bounds.width - Self.padding - 13, y: (h - 13) / 2, width: 13, height: 13)
    }

    // MARK: Colors

    /// The capsule's ground: the theme's raised surface, a little see-through
    /// so the text under it still shows; whole under the pointer.
    static func ground(_ s: Surfaces, hovering: Bool = false) -> NSColor {
        s.raised.nsColor.withAlphaComponent(hovering ? 0.98 : 0.9)
    }

    func updateColors() {
        let s = Surfaces.current
        layer?.backgroundColor = Self.ground(s, hovering: hovering).cgColor
        layer?.borderColor = (hovering ? s.strokeStrong : s.stroke).nsColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        name.textColor = s.content.nsColor
        glyph.contentTintColor = s.contentSecondary.nsColor
        letter.textColor = s.contentSecondary.nsColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // MARK: Mouse (never the keyboard)

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !isHidden ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click: its menu, as a right click.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            return NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        bar?.press(event)
    }
    override func mouseDragged(with event: NSEvent) { bar?.drag(event) }
    override func mouseUp(with event: NSEvent) { bar?.release(self) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("Bring Back"), action: #selector(restoreIt(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.t("Close"), action: #selector(closeIt(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func restoreIt(_ sender: Any?) { bar?.onRestore?(entry.pane) }
    @objc private func closeIt(_ sender: Any?) { bar?.onClose?(entry.pane) }

    override func accessibilityPerformPress() -> Bool {
        bar?.onRestore?(entry.pane)
        return true
    }

    /// One button: its glyph, name and badge are what its label says.
    override func accessibilityChildren() -> [Any]? { [] }
}

/// A view over a split that its capsules (FloatingTaskbar) keep clear of —
/// a pane's composer, the floating card, a floating pane — and tells the
/// split when it moves, comes or goes, so the capsules move out of its way.
protocol CapsuleObstacle: NSView {}

extension CapsuleObstacle {
    /// The split it's in places its capsules again, once, soon. (Called as
    /// it's about to leave, it's still in the split it leaves.)
    func capsulesMayMove() {
        SplitContainerView.enclosing(self)?.setNeedsTaskbarPlacement()
    }
}
