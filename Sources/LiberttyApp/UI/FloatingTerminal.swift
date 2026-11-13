import AppKit

/// A floating pane (Rex's New Floating Pane, zellij's floating panes): a
/// terminal of its own over the tab's split, not in it — moved by its
/// title bar, resized by its edges, and minimized out of sight with its
/// program running on (Toggle Floating Panes brings it back). Its pane is
/// one of the tab's parked ones, so everything that counts a tab's
/// programs counts it; it keeps its grid in step with its frame.
final class FloatingTerminalView: NSView {
    let pane: TerminalView
    /// Where it is in its split, as fractions of the split's size (so a
    /// window resize keeps it where it was, relatively).
    var fraction: CGRect
    var onMinimize: (() -> Void)?
    var onDock: (() -> Void)?
    var onClose: (() -> Void)?
    /// It moved or was resized (its new fraction, kept for the next layout and the saved one).
    var onChange: ((CGRect) -> Void)?
    /// A click in it: in front of the others.
    var onActivate: (() -> Void)?
    var title: () -> String = { "" }

    static let barHeight: CGFloat = 26
    static let minimum = NSSize(width: 220, height: 120)
    /// A new one's frame: a large card a little up and left of center.
    static let defaultFraction = CGRect(x: 0.18, y: 0.12, width: 0.64, height: 0.62)

    private let bar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var drag: (start: NSPoint, frame: NSRect, edges: Edges)?

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
        static let move: Edges = []
    }

    init(pane: TerminalView, fraction: CGRect) {
        self.pane = pane
        self.fraction = fraction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.floating
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.zPosition = 15

        bar.wantsLayer = true
        titleLabel.font = Typeface.ui(11.5, .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        let minimize = Self.button("minus", L10n.t("Minimize (it keeps running)"), self, #selector(minimize(_:)))
        let dock = Self.button("rectangle.split.2x1", L10n.t("Put in the Split"), self, #selector(dock(_:)))
        let close = Self.button("xmark", L10n.t("Close"), self, #selector(close(_:)))
        let stack = NSStackView(views: [close, minimize, titleLabel, dock])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        addSubview(bar)
        addSubview(pane)
        updateColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.t("Floating pane"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 10.5, weight: .semibold)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    @objc private func minimize(_ sender: Any?) { onMinimize?() }
    @objc private func dock(_ sender: Any?) { onDock?() }
    @objc private func close(_ sender: Any?) { onClose?() }

    /// Its frame in a split of `size`, from its fraction, kept inside it.
    func place(in size: NSSize) {
        guard drag == nil, size.width > 0, size.height > 0 else { return }
        var r = NSRect(x: fraction.minX * size.width, y: fraction.minY * size.height,
                       width: fraction.width * size.width, height: fraction.height * size.height)
        r.size.width = min(size.width, max(Self.minimum.width, r.width))
        r.size.height = min(size.height, max(Self.minimum.height, r.height))
        r.origin.x = min(max(0, r.minX), size.width - r.width)
        r.origin.y = min(max(0, r.minY), size.height - r.height)
        frame = r.integral
        layoutInside()
    }

    private func layoutInside() {
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        pane.frame = NSRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight))
        titleLabel.stringValue = title()
    }

    func refreshTitle() {
        titleLabel.stringValue = title()
        setAccessibilityLabel(L10n.t("Floating pane") + (titleLabel.stringValue.isEmpty ? "" : ", " + titleLabel.stringValue))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    // MARK: Moving and resizing (the bar moves it, the edges resize it)

    private static let edge: CGFloat = 6

    private func edges(at p: NSPoint) -> Edges? {
        var e: Edges = []
        if p.x < Self.edge { e.insert(.left) }
        if p.x > bounds.width - Self.edge { e.insert(.right) }
        if p.y > bounds.height - Self.edge { e.insert(.bottom) }
        if p.y < 3 { e.insert(.top) }
        if !e.isEmpty { return e }
        return p.y < Self.barHeight ? .move : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The edges belong to it, not to the terminal under them.
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let e = edges(at: p), e != .move { return self }
        // The bar moves it, but for its buttons (its title is no control to click).
        let hit = super.hitTest(point)
        if p.y < Self.barHeight, !(hit is NSButton) { return self }
        return hit
    }

    override func resetCursorRects() {
        let e = Self.edge
        addCursorRect(NSRect(x: 0, y: 0, width: e, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - e, y: 0, width: e, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: bounds.height - e, width: bounds.width, height: e), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        let p = convert(event.locationInWindow, from: nil)
        guard let e = edges(at: p) else { return super.mouseDown(with: event) }
        drag = (event.locationInWindow, frame, e)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let container = superview else { return }
        let dx = event.locationInWindow.x - drag.start.x
        // (The window's y goes up; the split's, flipped, down.)
        let dy = -(event.locationInWindow.y - drag.start.y)
        var r = drag.frame
        if drag.edges == .move {
            r.origin.x += dx
            r.origin.y += dy
        } else {
            if drag.edges.contains(.left) { r.origin.x += dx; r.size.width -= dx }
            if drag.edges.contains(.right) { r.size.width += dx }
            if drag.edges.contains(.top) { r.origin.y += dy; r.size.height -= dy }
            if drag.edges.contains(.bottom) { r.size.height += dy }
            if r.width < Self.minimum.width {
                if drag.edges.contains(.left) { r.origin.x = drag.frame.maxX - Self.minimum.width }
                r.size.width = Self.minimum.width
            }
            if r.height < Self.minimum.height {
                if drag.edges.contains(.top) { r.origin.y = drag.frame.maxY - Self.minimum.height }
                r.size.height = Self.minimum.height
            }
        }
        let size = container.bounds.size
        r.size.width = min(r.width, size.width)
        r.size.height = min(r.height, size.height)
        r.origin.x = min(max(0, r.minX), size.width - r.width)
        r.origin.y = min(max(0, r.minY), size.height - r.height)
        frame = r.integral
        layoutInside()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil, let size = superview?.bounds.size, size.width > 0, size.height > 0 else { return super.mouseUp(with: event) }
        drag = nil
        fraction = CGRect(x: frame.minX / size.width, y: frame.minY / size.height,
                          width: frame.width / size.width, height: frame.height / size.height)
        window?.invalidateCursorRects(for: self)
        onChange?(fraction)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        // Its bar's buttons and title, then its terminal (the stack holding them is no element itself).
        NSAccessibility.unignoredChildren(from: [bar, pane])
    }
}
