import AppKit

/// What a pane's header shows and does, asked of the window it's in.
@MainActor
protocol PaneHeaderSource: AnyObject {
    func headerInfo(for leaf: NSView) -> PaneHeader.Info
    func header(_ action: PaneHeader.Action, for leaf: NSView)
    /// The header was dragged: move its pane (`event`: the drag's first move).
    func dragPane(_ leaf: NSView, from event: NSEvent)
}

/// A pane's header (Rex's): the program's glyph and name, where it runs,
/// and the pane's buttons — split right, split down, float, zoom, close —
/// close always, the rest once the pointer is over it. It's the top of the pane's card:
/// a click focuses the pane, a double-click zooms it, as a title bar does.
final class PaneHeader: NSView {
    struct Info: Equatable {
        var name: String
        var detail: String
        /// "78×22" for a terminal; empty for a document.
        var size: String = ""
        var focused = false
        /// The focused pane of a split: the accent line along the card's
        /// top, which with a header is the header's top.
        var marked = false
        /// Whether it can float and be parked (a terminal) or only zoom and close.
        var floats = true
        /// Whether parking it would leave another terminal in view.
        var parks = false
        /// Its repository's branch and changes ("fix-login +40 −2"), `git-status`.
        var branch = ""
    }

    enum Action { case focus, splitRight, splitDown, pictureInPicture, park, zoom, close, changes }

    static let height: CGFloat = 36

    var onAction: ((Action) -> Void)?
    /// Dragged past a few points: the window moves the pane from here.
    var onDrag: ((NSEvent) -> Void)?
    private var pressedAt: NSPoint?
    var info: Info? {
        didSet { if info != oldValue { update() } }
    }

    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    /// The branch and its changes: a click shows them (Kero's).
    private let branch = NSButton(title: "", target: nil, action: nil)
    private let right = PaneHeader.button("rectangle.split.2x1", "Split Right")
    private let down = PaneHeader.button("rectangle.split.1x2", "Split Down")
    private let pip = PaneHeader.button("square.on.square", "Float Pane")
    private let zoom = PaneHeader.button("arrow.up.left.and.arrow.down.right", "Zoom Pane")
    private let close = PaneHeader.button("xmark", "Close Pane")
    private var buttons: [NSButton] { [right, down, pip, zoom, close] }
    private let mark = NSView()
    private var tracking: NSTrackingArea?
    private var leadingEdge: NSLayoutConstraint!
    private var trailingEdge: NSLayoutConstraint!
    /// Room the window's buttons take at either end (`sharesTopRow`).
    var clearance: (leading: CGFloat, trailing: CGFloat) = (0, 0) {
        didSet {
            leadingEdge.constant = 12 + clearance.leading
            trailingEdge.constant = -7 - clearance.trailing
        }
    }
    private var hovering = false { didSet { if hovering != oldValue { updateColors() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glyph.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        name.font = Typeface.ui(13, .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = Typeface.ui(13)
        detail.lineBreakMode = .byTruncatingHead  // the folder at its end says where
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        size.isHidden = true  // Rex shows no size; the probe still reads it
        branch.isBordered = false
        branch.font = Typeface.ui(12)
        branch.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        branch.imagePosition = .imageLeading
        branch.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        branch.lineBreakMode = .byTruncatingMiddle
        branch.toolTip = L10n.t("Show the changes")
        branch.target = self
        branch.action = #selector(showChanges)
        branch.isHidden = true
        branch.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        mark.wantsLayer = true
        mark.isHidden = true
        right.action = #selector(splitRightIt)
        down.action = #selector(splitDownIt)
        pip.action = #selector(floatIt)
        zoom.action = #selector(zoomIt)
        close.action = #selector(closeIt)
        let stack = NSStackView(views: buttons)
        stack.spacing = 2
        for v in [glyph, name, detail, size, branch, stack, mark] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for b in buttons { b.target = self }
        leadingEdge = glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        trailingEdge = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        NSLayoutConstraint.activate([
            leadingEdge, trailingEdge,
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 5),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: branch.leadingAnchor, constant: -10),
            branch.centerYAnchor.constraint(equalTo: centerYAnchor),
            branch.trailingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -8),
            size.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            size.trailingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor),
            mark.heightAnchor.constraint(equalToConstant: 1),
        ])
        updateColors()
        // VoiceOver finds the pane's buttons in a group named for the pane.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func button(_ symbol: String, _ english: String) -> NSButton {
        let tip = L10n.t(english)
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    private func update() {
        guard let info else { return }
        glyph.image = NSImage(systemSymbolName: info.floats ? "apple.terminal" : "doc.text",
                              accessibilityDescription: L10n.t(info.floats ? "Terminal" : "Document"))
        setAccessibilityLabel(L10n.t("Pane") + ", " + info.name)
        name.stringValue = info.name
        detail.stringValue = info.detail
        size.stringValue = info.size
        branch.title = info.branch
        branch.isHidden = info.branch.isEmpty
        right.isHidden = !info.floats
        down.isHidden = !info.floats
        pip.isHidden = !info.floats
        mark.isHidden = !info.marked
        updateColors()
    }

    /// The card's color, so header and terminal read as one card.
    func apply(background: NSColor) {
        layer?.backgroundColor = background.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let s = Surfaces.current
        let focused = info?.focused ?? false
        name.textColor = focused ? s.content.nsColor : s.contentSecondary.nsColor
        glyph.contentTintColor = name.textColor
        detail.textColor = s.contentTertiary.nsColor
        branch.contentTintColor = s.contentTertiary.nsColor
        branch.attributedTitle = NSAttributedString(string: info?.branch ?? "", attributes: [
            .font: Typeface.ui(12), .foregroundColor: s.contentTertiary.nsColor,
        ])
        // Rex's buttons: faint on every pane, clear under the pointer.
        let tint = hovering ? s.contentSecondary.nsColor : s.contentTertiary.nsColor.withAlphaComponent(0.7)
        buttons.forEach { $0.contentTintColor = tint }
        updateButtonVisibility()
        mark.layer?.backgroundColor = Accent.color.cgColor
    }

    /// Only Close stays on every pane; the rest come in with the pointer,
    /// so a split of several panes isn't a row of icons over each. They
    /// stay in place, transparent (not hidden), so the header's layout
    /// doesn't shift and VoiceOver still finds them.
    private func updateButtonVisibility() {
        let shown: CGFloat = hovering ? 1 : 0
        let fading = [right, down, pip, zoom]
        let duration = Motion.duration(Motion.hover)
        guard duration > 0, window != nil else {
            fading.forEach { $0.alphaValue = shown }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Motion.ease
            fading.forEach { $0.animator().alphaValue = shown }
        }
    }

    /// While they're transparent the hidden buttons take no clicks: the
    /// header under them focuses, drags and zooms the pane as elsewhere.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let button = hit as? NSButton, button !== close, buttons.contains(button), button.alphaValue < 0.5 { return self }
        return hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// The buttons one can see and press now, by tooltip (`--ui-probe`).
    var shownButtons: [String] {
        buttons.filter { !$0.isHidden && $0.alphaValue >= 0.5 }.compactMap(\.toolTip)
    }

    /// The pointer over it or not, as its tracking area says (`--ui-probe`).
    func setPointerOver(_ over: Bool) { hovering = over }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        onAction?(event.clickCount == 2 ? .zoom : .focus)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        pressedAt = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { pressedAt = nil }

    @objc private func splitRightIt() { onAction?(.splitRight) }
    @objc private func splitDownIt() { onAction?(.splitDown) }
    @objc private func floatIt() { onAction?(.pictureInPicture) }
    @objc private func zoomIt() { onAction?(.zoom) }
    @objc private func closeIt() { onAction?(.close) }
    @objc private func showChanges() { onAction?(.changes) }
}
