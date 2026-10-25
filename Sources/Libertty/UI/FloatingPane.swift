import AppKit
import QuartzCore

/// A parked pane shown as a small live card in a corner of its split
/// (Tern's in-window picture in picture): it draws the pane's own frames,
/// scaled down, so nothing resizes and the program never knows. A click
/// brings the pane back into the split; a drag moves the card to the nearest
/// corner; on hover, a button puts it away (parked, out of sight).
final class FloatingPaneCard: NSView {
    enum Corner: String { case topLeft, topRight, bottomLeft, bottomRight }

    weak var pane: TerminalView?
    var corner = Corner.bottomRight
    var onExpand: (() -> Void)?
    var onPutAway: (() -> Void)?
    /// Dragged to another corner.
    var onMove: ((Corner) -> Void)?

    private let mirror = MirrorView()
    private let chrome = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var link: CADisplayLink?
    private var dragStart: NSPoint?
    private var origin: NSPoint = .zero
    private var dragging = false
    private var frames = 0
    var title: () -> String = { "" }

    static let margin: CGFloat = 14

    init(pane: TerminalView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.pane
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.zPosition = 20
        mirror.autoresizingMask = [.width, .height]
        mirror.onClick = nil
        addSubview(mirror)

        chrome.material = .hudWindow
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.alphaValue = 0
        titleLabel.font = Typeface.ui(11.5, .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        let away = Self.button("tray.and.arrow.down", "Put Away (keep it parked)", self, #selector(putAway))
        let back = Self.button("arrow.up.backward.and.arrow.down.forward", "Back to the Split", self, #selector(expand))
        let bar = NSStackView(views: [away, titleLabel, back])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(bar)
        chrome.frame = NSRect(x: 0, y: 0, width: 0, height: 26)
        chrome.autoresizingMask = [.width, .minYMargin]
        addSubview(chrome)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor), bar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            bar.topAnchor.constraint(equalTo: chrome.topAnchor), bar.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Floating pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        b.toolTip = tip
        return b
    }

    override var isFlipped: Bool { true }

    /// A third of the container, between 220 and 420 points wide, in the
    /// pane's shape — and no more than half its height (a tall, narrow
    /// column would otherwise cover the split from top to bottom).
    func size(in container: NSSize) -> NSSize {
        guard let pane, pane.drawableSize.width > 0, pane.drawableSize.height > 0 else { return NSSize(width: 300, height: 190) }
        let shape = pane.drawableSize.height / pane.drawableSize.width
        var width = min(420, max(220, container.width / 3), max(80, container.width - 2 * Self.margin))
        let tallest = max(60, (container.height - 2 * Self.margin) / 2)
        if width * shape > tallest { width = tallest / shape }
        return NSSize(width: width, height: width * shape)
    }

    func place(in container: NSSize) {
        guard !dragging else { return }
        let size = size(in: container)
        let m = Self.margin
        let x = corner == .topLeft || corner == .bottomLeft ? m : container.width - size.width - m
        let y = corner == .topLeft || corner == .topRight ? m : container.height - size.height - m
        frame = NSRect(x: max(0, x), y: max(0, y), width: size.width, height: size.height)
        chrome.frame = NSRect(x: 0, y: 0, width: size.width, height: 26)
    }

    /// Its edge in the window's light or dark (a layer's color is resolved once).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
        link?.invalidate()
        link = nil
        guard let window, let pane else { return }
        mirror.configure(device: pane.metalDevice, scale: window.backingScaleFactor)
        let link = mirror.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let pane else { return stop() }
        _ = pane.renderMirror(into: mirror.metalLayer)
        frames += 1
        if frames % 60 == 1 { titleLabel.stringValue = title() }
    }

    /// The card is going away: stop drawing and let the renderer forget the layer.
    func stop() {
        link?.invalidate()
        link = nil
        pane?.forgetMirror(mirror.metalLayer)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { fade(chrome, to: 1) }
    override func mouseExited(with event: NSEvent) { fade(chrome, to: 0) }

    private func fade(_ view: NSView, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.hover)
            view.animator().alphaValue = alpha
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The buttons take their own clicks; the rest is the card's.
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = superview?.convert(event.locationInWindow, from: nil)
        origin = frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview, let start = dragStart else { return }
        let now = superview.convert(event.locationInWindow, from: nil)
        if !dragging, hypot(now.x - start.x, now.y - start.y) < 4 { return }
        dragging = true
        frame.origin = NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let superview else { return }
        guard dragging else { return onExpand?() ?? () }
        // To the corner the card's middle is nearest.
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        let left = mid.x < superview.bounds.midX, top = mid.y < superview.bounds.midY
        corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        dragging = false
        onMove?(corner)
        let size = size(in: superview.bounds.size)
        let m = Self.margin
        let x = left ? m : superview.bounds.width - size.width - m
        let y = top ? m : superview.bounds.height - size.height - m
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.small)
            ctx.timingFunction = Motion.out
            animator().setFrameOrigin(NSPoint(x: max(0, x), y: max(0, y)))
        }
    }

    @objc private func expand() { onExpand?() }
    @objc private func putAway() { onPutAway?() }
}
