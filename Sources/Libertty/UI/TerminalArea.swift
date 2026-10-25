import AppKit

/// The middle column: the selected tab's panes below the toolbar, on the
/// window's frame (the theme's `chrome`, at `background-opacity`, optionally
/// blurred), which also runs under the toolbar and the side columns so the
/// window reads as one surface (Tern), and the find bar.
final class TerminalAreaView: NSView {
    /// The selected tab's panes, or its document.
    private(set) var content: NSView?
    let findBar = FindBar()
    private let fill = NSView()
    private var blur: NSVisualEffectView?

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

    func show(_ content: NSView) {
        guard content !== self.content else { return }
        self.content?.removeFromSuperview()
        self.content = content
        addSubview(content, positioned: .below, relativeTo: findBar)
        layoutSubtreeIfNeeded()
        needsLayout = true
    }

    /// `background`: the frame's color (a translucent window keeps the
    /// terminals' own: frame and cards blend into the one glass).
    func apply(background: RGB, opacity: Double, blurred: Bool) {
        fill.layer?.backgroundColor = background.nsColor.withAlphaComponent(opacity).cgColor
        if blurred, opacity < 1 {
            if blur == nil {
                let view = NSVisualEffectView()
                view.material = .underWindowBackground
                view.blendingMode = .behindWindow
                view.state = .active
                addSubview(view, positioned: .below, relativeTo: fill)
                blur = view
            }
        } else {
            blur?.removeFromSuperview()
            blur = nil
        }
        needsLayout = true
    }

    /// The part below the toolbar, in this (unflipped) view's coordinates.
    var contentRect: NSRect {
        guard let window else { return bounds }
        // Before the first layout the intersection is empty, and an empty
        // NSRect intersection is `.null`, at infinity: never hand that on.
        let rect = convert(window.contentLayoutRect, from: nil).intersection(bounds)
        return rect.isNull ? bounds : rect
    }

    override func layout() {
        super.layout()
        let content = contentRect
        fill.frame = bounds
        blur?.frame = bounds
        // Everything starts below the toolbar: the toolbar has no material
        // of its own, so text scrolling under it would collide with its
        // controls. Inset a little from the edges, as the cards are.
        let inset = Layout.stageInset
        self.content?.frame = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2),
                                     height: max(0, content.maxY - inset * 2))
        // The find bar only needs a frame while it's shown, and room for one.
        guard !findBar.isHidden, bounds.width > 120 else { return }
        let size = findBar.fittingSize
        let width = min(max(size.width, 360), bounds.width - 24)
        findBar.frame = NSRect(x: bounds.width - width - 12, y: content.maxY - size.height - 10,
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

/// The window's columns (sidebar, panes, inspector) with no line between
/// them: they're one surface, the divider drawn in the frame's color (a
/// clear one would leave a hole to black).
final class FrameSplitView: NSSplitView {
    /// Painted behind the columns too: the controller's dividers are gaps
    /// it doesn't draw into.
    var frameColor: NSColor = .windowBackgroundColor {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = frameColor.cgColor
            needsDisplay = true
        }
    }
    override var dividerColor: NSColor { frameColor }

    override func drawDivider(in rect: NSRect) {
        frameColor.setFill()
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
        field.placeholderString = "Find in scrollback"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            return b
        }
        let stack = NSStackView(views: [
            icon, field, count,
            button("chevron.up", "Previous Match (older) ⌘G", #selector(older)),
            button("chevron.down", "Next Match (newer) ⇧⌘G", #selector(newer)),
            button("xmark", "Close (Esc)", #selector(close)),
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
        count.stringValue = empty ? "" : found ? "" : "No matches"
    }

    func show(result: SearchResult) {
        if !result.active || field.stringValue.isEmpty {
            count.stringValue = ""
        } else if result.total == 0 {
            count.stringValue = "No matches"
        } else {
            count.stringValue = result.selected.map { "\($0) of \(result.total)" } ?? "\(result.total)"
        }
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            onNavigate?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func older() { if let onArrow { onArrow(true) } else { onNavigate?(true) } }
    @objc private func newer() { if let onArrow { onArrow(false) } else { onNavigate?(false) } }
    @objc private func close() { onClose?() }
}
