import AppKit
import QuartzCore

/// Window ▸ Picture in Picture: a pane, live, in a small window that floats
/// over every app and Space, while the pane stays where it is. Watch a build
/// or an agent from anywhere; click it to go to the pane. It draws the
/// pane's own frames (no second copy of the terminal), scaled down.
@MainActor
final class PictureInPicture: NSObject, NSWindowDelegate {
    private static var open: [ObjectIdentifier: PictureInPicture] = [:]

    /// Show `pane` in a floating window, or close the one showing it.
    static func toggle(_ pane: TerminalView, title: @escaping () -> String, reveal: @escaping () -> Void) {
        if let existing = open[ObjectIdentifier(pane)] { return existing.close() }
        let pip = PictureInPicture(pane: pane, title: title, reveal: reveal)
        open[ObjectIdentifier(pane)] = pip
        pip.show()
    }

    static func isShowing(_ pane: TerminalView) -> Bool { open[ObjectIdentifier(pane)] != nil }

    /// The pane is going away (closed, or its program ended and it closed).
    static func paneClosed(_ pane: TerminalView) { open[ObjectIdentifier(pane)]?.close() }

    private weak var pane: TerminalView?
    private let reveal: () -> Void
    private let titleProvider: () -> String
    private let panel: NSPanel
    private let mirror = MirrorView()
    private let chrome = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var link: CADisplayLink?
    private var tracking: NSTrackingArea?

    private init(pane: TerminalView, title: @escaping () -> String, reveal: @escaping () -> Void) {
        self.pane = pane
        self.reveal = reveal
        titleProvider = title
        let size = Self.initialSize(for: pane)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 160, height: 160 * size.height / max(1, size.width))

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        mirror.frame = content.bounds
        mirror.autoresizingMask = [.width, .height]
        mirror.onClick = { [weak self] in self?.goToPane() }
        content.addSubview(mirror)

        // On hover: what it is, and its two buttons.
        chrome.material = .hudWindow
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.alphaValue = 0
        titleLabel.stringValue = title()
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        let back = Self.button("arrow.up.backward.and.arrow.down.forward", "Go to the Pane", self, #selector(goToPane))
        let close = Self.button("xmark", "Close Picture in Picture", self, #selector(closeClicked))
        let bar = NSStackView(views: [close, titleLabel, back])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(bar)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor), bar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            bar.topAnchor.constraint(equalTo: chrome.topAnchor), bar.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])
        mirror.onHover = { [weak self] inside in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.hover)
                self?.chrome.animator().alphaValue = inside ? 1 : 0
            }
        }
        panel.contentView = content
    }

    private static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        b.toolTip = tip
        return b
    }

    /// A third of the pane's width (between 240 and 480 points), in its shape.
    private static func initialSize(for pane: TerminalView) -> NSSize {
        let s = pane.bounds.size
        guard s.width > 0, s.height > 0 else { return NSSize(width: 360, height: 220) }
        let width = min(480, max(240, s.width / 3))
        return NSSize(width: width, height: width * s.height / s.width)
    }

    private func show() {
        guard let pane else { return }
        mirror.configure(device: pane.metalDevice, scale: pane.window?.backingScaleFactor ?? 2)
        // The bottom right of the screen the pane is on.
        let screen = pane.window?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.minY + 20))
        }
        panel.orderFrontRegardless()
        let link = mirror.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private var frames = 0

    @objc private func step(_ link: CADisplayLink) {
        // Closed (taken out of its split, or its window gone): so is the picture.
        guard let pane, pane.superview != nil || pane.isParked else { return close() }
        pane.renderMirror(into: mirror.metalLayer)
        frames += 1
        if frames % 60 == 1 { titleLabel.stringValue = titleProvider() }
    }

    @objc private func goToPane() {
        reveal()
    }

    @objc private func closeClicked() { close() }

    func close() {
        link?.invalidate()
        link = nil
        if let pane {
            pane.forgetMirror(mirror.metalLayer)
            Self.open[ObjectIdentifier(pane)] = nil
        } else {
            Self.open = Self.open.filter { $0.value !== self }
        }
        panel.delegate = nil
        panel.close()
    }
}

/// The picture: a Metal layer the pane's renderer draws into at the pane's
/// size; Core Animation scales it to the window.
final class MirrorView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var downAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    func configure(device: MTLDevice?, scale: CGFloat) {
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resize
        metalLayer.contentsScale = scale
        metalLayer.magnificationFilter = .linear
        metalLayer.minificationFilter = .trilinear
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A click goes to the pane; a drag moves the window (movable by its background).
    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        window?.performDrag(with: event)
        if let downAt, hypot(NSEvent.mouseLocation.x - downAt.x, NSEvent.mouseLocation.y - downAt.y) < 3 { onClick?() }
        downAt = nil
    }
}
