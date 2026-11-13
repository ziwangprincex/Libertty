import AppKit

/// The window's one surface under the sidebar, the panes and the gaps
/// between them (Rex's canvas): the theme's canvas color, or, translucent,
/// the desktop blurred through a tint of it (Rex's glass, `hudWindow`).
/// Everything else sits on it, so no column or divider can leave a hole
/// to the desktop.
final class WindowBackdrop: NSView {
    private var blur: NSVisualEffectView?
    private let tint = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The canvas is title bar where nothing else is: it moves the window.
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `opacity` below 1 or `glass`: the desktop shows through. Glass
    /// blurs it in macOS's HUD material under the canvas, as Rex's does:
    /// 70% of it over a light theme, 60% over a dark one (Rex: 30% and a
    /// 60% overlay); untinted, a neutral shade instead of the theme's.
    func apply(canvas: RGB, opacity: Double, blurred: Bool, glass: Bool, tinted: Bool) {
        let dark = canvas.luminance < 0.18
        let shade = tinted ? canvas : (dark ? RGB(30, 30, 30) : RGB(236, 236, 236))
        let alpha = glass ? (dark ? 0.6 : 0.7) : opacity
        tint.layer?.backgroundColor = (glass ? shade : canvas).nsColor.withAlphaComponent(alpha).cgColor
        if glass || (blurred && opacity < 1) {
            let view = blur ?? NSVisualEffectView(frame: bounds)
            view.material = glass ? .hudWindow : .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .active
            view.autoresizingMask = [.width, .height]
            if blur == nil {
                addSubview(view, positioned: .below, relativeTo: tint)
                blur = view
            }
        } else {
            blur?.removeFromSuperview()
            blur = nil
        }
    }

    override func layout() {
        super.layout()
        blur?.frame = bounds
        tint.frame = bounds
    }
}

/// The window's own buttons (Rex's): the sidebar's toggle after the traffic
/// lights; activity, the command palette and a new tab at the other end.
/// They sit in the sidebar's top row while it's on the left, else in the
/// band along the panes' top.
@MainActor
final class WindowChrome {
    let sidebarToggle: NSButton
    let activity: NSButton
    let palette: NSButton
    let newTab: NSButton
    /// The trailing group: the host's chip (a remote window), activity, palette, new tab.
    let trailing = NSStackView()
    let leading = NSStackView()

    init(target: AnyObject, toggleSidebar: Selector, activity: Selector, palette: Selector, newTab: Selector) {
        sidebarToggle = Self.button("sidebar.left", TerminalWindowController.tip("Hide Sidebar", .toggleSidebar), target, toggleSidebar)
        self.activity = Self.button("eye", L10n.t("Show Activity"), target, activity)
        self.palette = Self.button("command", TerminalWindowController.tip("Command Palette", .toggleCommandPalette), target, palette)
        self.newTab = Self.button("plus", TerminalWindowController.tip("New Tab", .newTab), target, newTab)
        leading.addArrangedSubview(sidebarToggle)
        for b in [self.activity, self.palette, self.newTab] { trailing.addArrangedSubview(b) }
        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = true
        }
    }

    /// The host's chip goes first in the trailing group while the window is a host's.
    func show(hostChip: NSView?) {
        let current = trailing.arrangedSubviews.first { !($0 is NSButton) }
        guard current !== hostChip else { return }
        current?.removeFromSuperview()
        if let hostChip { trailing.insertArrangedSubview(hostChip, at: 0) }
    }

    /// Unread news lights the activity button.
    func show(unread: Bool) {
        activity.image = NSImage(systemSymbolName: unread ? "eye.circle.fill" : "eye", accessibilityDescription: L10n.t("Show Activity"))
        activity.contentTintColor = unread ? Accent.color : .secondaryLabelColor
        // What its light says, said.
        activity.setAccessibleLabel(L10n.t("Show Activity") + (unread ? ", " + L10n.t("new activity") : ""))
    }

    static let buttonSize = NSSize(width: 29, height: 25)

    static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        b.toolTip = tip
        b.setAccessibleLabel(tip.components(separatedBy: " (").first)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: buttonSize.width).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSize.height).isActive = true
        return b
    }

    /// Where the traffic lights' middle is, from the window's top (the
    /// rows they share line up on it).
    static func trafficLightMid(in window: NSWindow?) -> CGFloat {
        guard let window, let close = window.standardWindowButton(.closeButton), let frame = close.superview else { return 23 }
        let r = close.convert(close.bounds, to: nil)
        _ = frame
        return window.frame.height - r.midY
    }

    /// Room the traffic lights take from the window's left edge.
    static let trafficLightRoom: CGFloat = 78
    /// Rex's top row: the traffic lights' band.
    static let bandHeight: CGFloat = 46
}
