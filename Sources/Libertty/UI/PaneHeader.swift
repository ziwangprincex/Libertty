import AppKit

/// What a pane's header shows and does, asked of the window it's in.
@MainActor
protocol PaneHeaderSource: AnyObject {
    func headerInfo(for leaf: NSView) -> PaneHeader.Info
    func header(_ action: PaneHeader.Action, for leaf: NSView)
}

/// A pane's header (Tern's `pane-headers`): what runs there and where, its
/// grid size, and on the focused pane buttons to float it as a picture in
/// picture, zoom it and close it. It's the top of the pane's card: a click
/// focuses the pane, a double-click zooms it, as a title bar does.
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
    }

    enum Action { case focus, pictureInPicture, park, zoom, close }

    static let height: CGFloat = 30

    var onAction: ((Action) -> Void)?
    var info: Info? {
        didSet { if info != oldValue { update() } }
    }

    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let pip = PaneHeader.button("pip.enter", "Float Pane")
    private let park = PaneHeader.button("tray.and.arrow.down", "Park Pane")
    private let zoom = PaneHeader.button("arrow.up.left.and.arrow.down.right", "Zoom")
    private let close = PaneHeader.button("xmark", "Close")
    private let line = NSView()
    private let mark = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        name.font = Typeface.header
        detail.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingHead  // the folder at its end says where
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        size.font = Typeface.hint
        size.textColor = .tertiaryLabelColor
        line.wantsLayer = true
        mark.wantsLayer = true
        mark.isHidden = true
        pip.action = #selector(floatIt)
        zoom.action = #selector(zoomIt)
        close.action = #selector(closeIt)
        park.action = #selector(parkIt)
        let buttons = NSStackView(views: [pip, park, zoom, close])
        buttons.spacing = 2
        for v in [name, detail, size, buttons, line, mark] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for b in [pip, park, zoom, close] { b.target = self }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: size.leadingAnchor, constant: -10),
            size.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            // The buttons keep their room on every pane, so the size doesn't
            // jump as the focus moves.
            size.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 4 * 24 + 3 * 2),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor),
            mark.heightAnchor.constraint(equalToConstant: 1),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func button(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    private func update() {
        guard let info else { return }
        name.stringValue = info.name
        name.textColor = info.focused ? .labelColor : .secondaryLabelColor
        detail.stringValue = info.detail
        size.stringValue = info.size
        pip.isHidden = !info.focused || !info.floats || !info.parks
        park.isHidden = !info.focused || !info.floats || !info.parks
        zoom.isHidden = !info.focused
        close.isHidden = !info.focused
        mark.isHidden = !info.marked
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
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        mark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onAction?(event.clickCount == 2 ? .zoom : .focus)
    }

    @objc private func floatIt() { onAction?(.pictureInPicture) }
    @objc private func zoomIt() { onAction?(.zoom) }
    @objc private func parkIt() { onAction?(.park) }
    @objc private func closeIt() { onAction?(.close) }
}
