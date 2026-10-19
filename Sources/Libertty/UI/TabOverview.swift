import AppKit

/// Every tab of the window at once, as live thumbnails in a grid (Tern's tab
/// overview; Safari's ⌘⇧\). Click or Return picks one; arrows move; Esc
/// leaves. It opens from the selected tab and closes into the chosen one.
final class TabOverviewView: NSView {
    struct Card {
        var title: String
        var image: CGImage?
        var symbol: String
        var status: ProgramStatusStore.State?
    }

    var onPick: ((Int?) -> Void)?
    private var cards: [Card] = []
    private var cardViews: [CardView] = []
    private var selected = 0
    private let background = NSVisualEffectView()

    init(cards: [Card], selected: Int) {
        self.cards = cards
        self.selected = selected
        super.init(frame: .zero)
        background.material = .underWindowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        addSubview(background)
        for (i, card) in cards.enumerated() {
            let view = CardView(card: card, index: i)
            view.onClick = { [weak self] in self?.pick(i) }
            view.onHover = { [weak self] in self?.select(i) }
            addSubview(view)
            cardViews.append(view)
        }
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// Columns and card size for `count` cards in this view, keeping the
    /// content's aspect ratio.
    private func grid() -> (cols: Int, size: NSSize, origin: NSPoint, gap: CGFloat) {
        let gap: CGFloat = 22, inset: CGFloat = 36
        let area = bounds.insetBy(dx: inset, dy: inset)
        let aspect = max(0.3, min(3, bounds.width / max(1, bounds.height)))
        var best = (cols: 1, size: NSSize.zero)
        for cols in 1...max(1, cards.count) {
            let rows = Int(ceil(Double(cards.count) / Double(cols)))
            let w = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = w / aspect + 26  // title below the thumbnail
            let totalH = h * CGFloat(rows) + gap * CGFloat(rows - 1)
            let fit = totalH > area.height ? w * area.height / totalH : w
            if fit > best.size.width { best = (cols, NSSize(width: fit, height: fit / aspect + 26)) }
        }
        let rows = Int(ceil(Double(cards.count) / Double(best.cols)))
        let totalW = best.size.width * CGFloat(best.cols) + gap * CGFloat(best.cols - 1)
        let totalH = best.size.height * CGFloat(rows) + gap * CGFloat(rows - 1)
        return (best.cols, best.size, NSPoint(x: bounds.midX - totalW / 2, y: bounds.midY - totalH / 2), gap)
    }

    func frame(ofCard i: Int) -> NSRect {
        let g = grid()
        let col = i % g.cols, row = i / g.cols
        return NSRect(x: g.origin.x + CGFloat(col) * (g.size.width + g.gap),
                      y: g.origin.y + CGFloat(row) * (g.size.height + g.gap), width: g.size.width, height: g.size.height)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        guard !animating else { return }
        for (i, view) in cardViews.enumerated() { view.frame = frame(ofCard: i) }
    }

    private var animating = false

    /// The thumbnail of card `i` alone, flying between the card and the
    /// full-size tab: a separate image view so the picture itself scales
    /// (a card's own subviews are laid out once, at its final size).
    private func flyer(for i: Int) -> NSImageView? {
        guard let image = cards[i].image else { return nil }
        let view = NSImageView()
        view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.cornerRadius = Radius.card
        view.layer?.masksToBounds = true
        addSubview(view)
        return view
    }

    /// Fly out from (or back into) the full-size tab.
    func animateIn() {
        layoutSubtreeIfNeeded()
        guard Motion.duration(Motion.card) > 0, cardViews.indices.contains(selected) else { return }
        animating = true
        let card = cardViews[selected]
        let flyer = flyer(for: selected)
        flyer?.frame = bounds
        card.alphaValue = flyer == nil ? 1 : 0
        background.alphaValue = 0
        for (i, v) in cardViews.enumerated() where i != selected { v.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.card
            ctx.timingFunction = Motion.out
            flyer?.animator().frame = card.convert(card.imageFrame, to: self)
            background.animator().alphaValue = 1
            for (i, v) in cardViews.enumerated() where i != selected { v.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            card.alphaValue = 1
            flyer?.removeFromSuperview()
            self?.animating = false
        })
    }

    private func pick(_ index: Int?) {
        guard !animating else { return }
        guard let index, cardViews.indices.contains(index), Motion.duration(Motion.card) > 0 else {
            onPick?(index)
            return
        }
        animating = true
        let card = cardViews[index]
        let flyer = flyer(for: index)
        flyer?.frame = card.convert(card.imageFrame, to: self)
        if flyer != nil { card.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.small * 1.2
            ctx.timingFunction = Motion.ease
            flyer?.animator().frame = bounds
            background.animator().alphaValue = 0
            for (i, v) in cardViews.enumerated() where i != index { v.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in self?.onPick?(index) })
    }

    /// A thumbnail that arrived late (documents render asynchronously).
    func setImage(_ image: CGImage, at index: Int) {
        guard cardViews.indices.contains(index) else { return }
        cards[index].image = image
        cardViews[index].setImage(image)
    }

    private func select(_ i: Int) {
        guard cards.indices.contains(i), i != selected else { return }
        selected = i
        updateSelection()
    }

    private func updateSelection() {
        for (i, v) in cardViews.enumerated() { v.isChosen = i == selected }
    }

    override func keyDown(with event: NSEvent) {
        let cols = grid().cols
        switch Int(event.keyCode) {
        case 53: pick(nil)                                   // escape
        case 36, 76, 49: pick(selected)                      // return, enter, space
        case 123: select(max(0, selected - 1))               // left
        case 124: select(min(cards.count - 1, selected + 1)) // right
        case 126: select(max(0, selected - cols))            // up
        case 125: select(min(cards.count - 1, selected + cols))
        default:
            // ⌘1…9 still pick a tab.
            if event.modifierFlags.contains(.command), let n = Int(event.charactersIgnoringModifiers ?? ""), n >= 1 {
                pick(min(cards.count, n) - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A click between the cards leaves the overview as it was.
        pick(nil)
    }
}

private final class CardView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isChosen = false { didSet { updateChosen() } }
    private let image = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let frameLayer = CALayer()

    init(card: TabOverviewView.Card, index: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        image.wantsLayer = true
        image.layer?.cornerRadius = Radius.card
        image.layer?.masksToBounds = true
        image.imageScaling = .scaleProportionallyUpOrDown
        if let cg = card.image {
            image.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            image.image = NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 40, weight: .light)
            image.contentTintColor = .secondaryLabelColor
            image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        title.stringValue = (index < 9 ? "⌘\(index + 1)  " : "") + card.title
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 12, weight: .medium)
        if let status = card.status { title.textColor = TerminalWindowController.color(for: status) }
        addSubview(image)
        addSubview(title)
        frameLayer.cornerRadius = Radius.card + 3
        frameLayer.borderWidth = 3
        frameLayer.borderColor = NSColor.controlAccentColor.cgColor
        frameLayer.opacity = 0
        layer?.addSublayer(frameLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var imageFrame: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 26)) }

    override func layout() {
        super.layout()
        image.frame = imageFrame
        title.frame = NSRect(x: 0, y: bounds.height - 20, width: bounds.width, height: 18)
        // The ring follows at once (no implicit layer animation trailing behind).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = image.frame.insetBy(dx: -4, dy: -4)
        CATransaction.commit()
    }

    func setImage(_ cg: CGImage) {
        image.symbolConfiguration = nil
        image.contentTintColor = nil
        image.layer?.backgroundColor = nil
        image.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func updateChosen() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.duration(Motion.hover))
        frameLayer.opacity = isChosen ? 1 : 0
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
