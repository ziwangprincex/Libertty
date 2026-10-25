import AppKit

/// Binary tree of panes. A leaf holds one view (a terminal, or a document
/// beside one); an inner node splits its rectangle between two children.
final class PaneNode {
    enum Axis {
        /// Children side by side (split right).
        case horizontal
        /// Children stacked (split down).
        case vertical
    }

    weak var parent: PaneNode?
    private(set) var pane: NSView?
    private(set) var axis: Axis = .horizontal
    /// Share of the first child, 0...1.
    var ratio: CGFloat = 0.5
    private(set) var children: [PaneNode] = []
    /// Last laid-out rectangle, in container coordinates.
    var frame: CGRect = .zero

    init(pane: NSView) { self.pane = pane }

    /// An inner node (restoring a saved layout).
    init(axis: Axis, ratio: CGFloat, first: PaneNode, second: PaneNode) {
        self.axis = axis
        self.ratio = ratio
        children = [first, second]
        first.parent = self
        second.parent = self
    }

    var isLeaf: Bool { pane != nil }

    var leaves: [NSView] {
        if let pane { return [pane] }
        return children.flatMap(\.leaves)
    }

    func find(_ view: NSView) -> PaneNode? {
        if pane === view { return self }
        for child in children { if let hit = child.find(view) { return hit } }
        return nil
    }

    /// Turn this leaf into a split holding its pane and `newPane`, which
    /// goes second (right/below) or, with `newFirst`, first (left/above).
    func split(with newPane: NSView, axis: Axis, ratio: CGFloat, newFirst: Bool = false) {
        guard let old = pane else { return }
        let existing = PaneNode(pane: old), added = PaneNode(pane: newPane)
        existing.parent = self
        added.parent = self
        pane = nil
        self.axis = axis
        self.ratio = ratio
        children = newFirst ? [added, existing] : [existing, added]
    }

    /// Replace this node's content with `other`'s (used when a sibling closes).
    func adopt(_ other: PaneNode) {
        pane = other.pane
        axis = other.axis
        ratio = other.ratio
        children = other.children
        children.forEach { $0.parent = self }
    }

    /// A leaf takes another view in its place (Restart Shell in Pane).
    func replacePane(with view: NSView) {
        guard pane != nil else { return }
        pane = view
    }
}

/// Lays out the pane tree as cards with a small gap, and owns the dividers
/// that resize splits. With a single pane it is a plain edge-to-edge terminal.
final class SplitContainerView: NSView {
    enum Direction: String { case left, right, up, down }

    private(set) var root: PaneNode
    private var dividers: [DividerView] = []
    private var animator: FrameAnimator?
    /// The pane filling the whole container (toggle_split_zoom), if any.
    private(set) var zoomed: NSView?

    // MARK: Floating card (in-window picture in picture)

    /// A parked pane shown live in a corner, if one is.
    private(set) var card: FloatingPaneCard?

    func showCard(for pane: TerminalView, corner: FloatingPaneCard.Corner, title: @escaping () -> String,
                  expand: @escaping () -> Void, putAway: @escaping () -> Void,
                  moved: @escaping (FloatingPaneCard.Corner) -> Void) {
        hideCard()
        let card = FloatingPaneCard(pane: pane)
        card.corner = corner
        card.title = title
        card.onExpand = expand
        card.onPutAway = putAway
        card.onMove = moved
        addSubview(card, positioned: .above, relativeTo: nil)
        card.place(in: bounds.size)
        self.card = card
    }

    func hideCard() {
        card?.stop()
        card?.removeFromSuperview()
        card = nil
    }

    // MARK: Headers (pane-headers)

    /// When panes wear a header; what it says and does comes from `headerSource`.
    var headers = Config.PaneHeaders.never {
        didSet { if headers != oldValue { layoutPanes() } }
    }
    weak var headerSource: PaneHeaderSource?
    /// The cards' color, which a header shares with its pane.
    var cardColor: NSColor = .textBackgroundColor {
        didSet { headerViews.values.forEach { $0.apply(background: cardColor) } }
    }
    private var headerViews: [ObjectIdentifier: PaneHeader] = [:]

    /// Whether `leaf` shows a header now.
    func showsHeader(for leaf: NSView) -> Bool {
        switch headers {
        case .never: false
        case .always: true
        case .split: !root.isLeaf
        }
    }

    /// Ask the source again what each header says (titles, sizes, focus).
    func updateHeaders() {
        for leaf in views {
            guard let header = headerViews[ObjectIdentifier(leaf)], !header.isHidden else { continue }
            header.info = headerSource?.headerInfo(for: leaf)
        }
    }

    private func header(for leaf: NSView) -> PaneHeader {
        if let header = headerViews[ObjectIdentifier(leaf)] { return header }
        let header = PaneHeader()
        header.apply(background: cardColor)
        header.onAction = { [weak self, weak leaf] action in
            guard let self, let leaf else { return }
            self.headerSource?.header(action, for: leaf)
        }
        addSubview(header, positioned: .below, relativeTo: dividers.first)
        headerViews[ObjectIdentifier(leaf)] = header
        return header
    }

    init(pane: TerminalView) {
        root = PaneNode(pane: pane)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(pane)
    }

    /// A whole tree at once (restoring a saved layout).
    init(root: PaneNode) {
        self.root = root
        super.init(frame: .zero)
        wantsLayer = true
        root.leaves.forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Every leaf: terminals and documents.
    var views: [NSView] { root.leaves }
    /// The terminals among them.
    var panes: [TerminalView] { root.leaves.compactMap { $0 as? TerminalView } }

    // MARK: Structure

    /// Split `pane`, the new pane budding out of it toward `direction`.
    /// `share`: how much of the space the new pane ends up with.
    func split(_ pane: NSView, with newPane: NSView, toward direction: Direction, share: CGFloat = 0.5) {
        animator?.finish()
        // Each view lives in the tree once.
        guard let node = root.find(pane), root.find(newPane) == nil else { return }
        zoomed = nil
        addSubview(newPane, positioned: .below, relativeTo: dividers.first)
        let axis: PaneNode.Axis = direction == .left || direction == .right ? .horizontal : .vertical
        let newFirst = direction == .left || direction == .up
        // The ratio is the first child's share: the new pane grows from nothing.
        node.split(with: newPane, axis: axis, ratio: newFirst ? 0 : 1, newFirst: newFirst)
        layoutPanes()
        animator = FrameAnimator.run(on: self, duration: Motion.card, update: { [weak self, weak node] p in
            node?.ratio = newFirst ? share * CGFloat(p) : 1 - share * CGFloat(p)
            self?.layoutPanes()
        })
    }

    /// Let `pane` fill the container, or with nil (or the zoomed pane) go back.
    func toggleZoom(_ pane: NSView) {
        zoomed = zoomed === pane || root.isLeaf ? nil : pane
        layoutPanes()
    }

    /// `newPane` takes `pane`'s place, size and zoom; `pane` leaves. False
    /// when `pane` isn't in the split (any more: it was closing).
    @discardableResult
    func replace(_ pane: NSView, with newPane: NSView) -> Bool {
        animator?.finish()
        guard let node = root.find(pane), root.find(newPane) == nil else { return false }
        addSubview(newPane, positioned: .below, relativeTo: dividers.first)
        newPane.frame = pane.frame
        node.replacePane(with: newPane)
        if zoomed === pane { zoomed = newPane }
        pane.removeFromSuperview()
        layoutPanes()
        return true
    }

    /// Whether `view` is in the split once any change under way is done (a
    /// pane shrinking away is gone by then).
    func contains(_ view: NSView) -> Bool {
        animator?.finish()
        return root.find(view) != nil
    }

    /// Move the divider that bounds `pane` on the `direction` side by
    /// `points` (Ghostty's resize_split).
    func resize(_ pane: NSView, toward direction: Direction, by points: CGFloat) {
        guard var node = root.find(pane) else { return }
        let axis: PaneNode.Axis = direction == .left || direction == .right ? .horizontal : .vertical
        // The nearest enclosing split along that axis owns the divider.
        while let parent = node.parent, parent.axis != axis { node = parent }
        guard let split = node.parent else { return }
        let length = axis == .horizontal ? split.frame.width : split.frame.height
        let sign: CGFloat = direction == .right || direction == .down ? 1 : -1
        split.ratio = min(0.9, max(0.1, split.ratio + sign * points / max(1, length)))
        layoutPanes()
    }

    /// The pane after (or before) `pane` in reading order, wrapping around.
    func cycle(from pane: NSView, forward: Bool) -> NSView? {
        let all = views
        guard let i = all.firstIndex(where: { $0 === pane }), all.count > 1 else { return nil }
        return all[(i + (forward ? 1 : all.count - 1)) % all.count]
    }

    /// Close `pane`: it shrinks away and its sibling grows into the space.
    func remove(_ pane: NSView, completion: @escaping () -> Void) {
        // A removal under way first: it changes the tree this one looks in
        // (two sibling panes closing at once, as a broadcast `exit` does).
        animator?.finish()
        guard let node = root.find(pane), let parent = node.parent,
              let sibling = parent.children.first(where: { $0 !== node }) else {
            completion()
            return
        }
        // A pane closing behind the zoomed one leaves the zoom alone; the
        // zoomed pane closing ends it (layoutPanes notices it's gone).
        if zoomed === pane { zoomed = nil }
        let isFirst = parent.children.first === node
        let from = parent.ratio
        animator = FrameAnimator.run(on: self, duration: Motion.small, curve: Motion.easeCurve, update: { [weak self] p in
            parent.ratio = from + ((isFirst ? 0 : 1) - from) * CGFloat(p)
            self?.layoutPanes()
        }, completion: { [weak self] in
            pane.removeFromSuperview()
            parent.adopt(sibling)
            self?.layoutPanes()
            completion()
        })
    }

    /// Even out the panes: three side by side get a third each, not 50/25/25
    /// — a split's share follows how many panes lie along its axis on each
    /// side (GoRex).
    func equalize() {
        /// How many panes a node lays side by side along `axis`.
        func span(_ node: PaneNode, _ axis: PaneNode.Axis) -> Int {
            guard !node.isLeaf else { return 1 }
            let spans = node.children.map { span($0, axis) }
            return node.axis == axis ? spans.reduce(0, +) : spans.max() ?? 1
        }
        func visit(_ node: PaneNode) {
            if !node.isLeaf, node.children.count == 2 {
                let first = span(node.children[0], node.axis), second = span(node.children[1], node.axis)
                node.ratio = CGFloat(first) / CGFloat(max(1, first + second))
            }
            node.children.forEach(visit)
        }
        visit(root)
        layoutPanes()
    }

    /// Where `view` sits in the split: its slot, whatever it shows now (a
    /// zoomed pane fills the container; the others are hidden in theirs).
    func slot(of view: NSView) -> CGRect { root.find(view)?.frame ?? view.frame }

    /// The pane whose center is closest in `direction` from `pane`.
    func neighbor(of pane: NSView, _ direction: Direction) -> NSView? {
        let from = slot(of: pane)
        return views.filter { $0 !== pane }.compactMap { other -> (NSView, CGFloat)? in
            let to = slot(of: other)
            let ok: Bool = switch direction {
            case .left: to.maxX <= from.minX + 1
            case .right: to.minX >= from.maxX - 1
            case .up: to.maxY <= from.minY + 1
            case .down: to.minY >= from.maxY - 1
            }
            guard ok else { return nil }
            let dx = to.midX - from.midX, dy = to.midY - from.midY
            return (other, dx * dx + dy * dy)
        }.min { $0.1 < $1.1 }?.0
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutPanes()
    }

    func layoutPanes() {
        if let zoomed, root.find(zoomed) == nil { self.zoomed = nil }
        // Headers of panes that left go with them.
        let leaves = Set(views.map(ObjectIdentifier.init))
        for (id, header) in headerViews where !leaves.contains(id) {
            header.removeFromSuperview()
            headerViews[id] = nil
        }
        // Every pane is a card on the window's frame (Tern's look), one pane
        // too: each sits in its slot inset by `Layout.paneInset`, so the
        // frame shows between neighbors and around the edges.
        layer?.backgroundColor = nil
        place(root, in: bounds)
        for pane in views {
            pane.wantsLayer = true
            pane.isHidden = zoomed != nil && pane !== zoomed
        }
        if let zoomed { placeCard(zoomed, in: bounds) }
        card?.place(in: bounds.size)
        for pane in views {
            // (placeCard hid the header of a card too short for one.)
            guard let header = headerViews[ObjectIdentifier(pane)] else { continue }
            let room = header.frame.height > 0 && pane.frame.minY >= header.frame.maxY - 0.5
            header.isHidden = pane.isHidden || !showsHeader(for: pane) || !room
        }
        updateHeaders()
        rebuildDividers()
        dividers.forEach { $0.isHidden = zoomed != nil }
    }

    /// A card's frame in its slot. A slot smaller than the inset (a tab not
    /// laid out yet) gets an empty frame at its corner: `insetBy` would give
    /// `.null`, which sits at infinity and poisons every constraint inside.
    private static func card(in slot: CGRect) -> CGRect {
        let inset = Layout.paneInset
        guard slot.width > inset * 2, slot.height > inset * 2 else { return CGRect(origin: slot.origin, size: .zero) }
        return slot.insetBy(dx: inset, dy: inset).integral
    }

    /// A pane's card in its slot: the pane, under its header when it shows
    /// one. Header and pane round only their outer corners, reading as one card.
    private func placeCard(_ pane: NSView, in slot: CGRect) {
        let card = Self.card(in: slot)
        guard showsHeader(for: pane), card.height > PaneHeader.height else {
            pane.frame = card
            Self.round(pane, top: true, bottom: true)
            // A header with no room is parked, empty, so nothing can reveal it stale.
            headerViews[ObjectIdentifier(pane)].map { $0.isHidden = true; $0.frame = .zero }
            return
        }
        let header = header(for: pane)
        header.frame = CGRect(x: card.minX, y: card.minY, width: card.width, height: PaneHeader.height)
        pane.frame = CGRect(x: card.minX, y: card.minY + PaneHeader.height, width: card.width,
                            height: card.height - PaneHeader.height)
        Self.round(header, top: true, bottom: false)
        Self.round(pane, top: false, bottom: true)
    }

    /// Round a view's top and/or bottom corners (as seen on screen: a flipped
    /// layer's minimum y is its top).
    private static func round(_ view: NSView, top: Bool, bottom: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = Radius.pane
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        let flipped = layer.isGeometryFlipped
        var corners: CACornerMask = []
        if top { corners.formUnion(flipped ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        if bottom { corners.formUnion(flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        layer.maskedCorners = corners
    }

    /// Slots meet edge to edge; a split's ratio is where its two slots meet.
    private func place(_ node: PaneNode, in rect: CGRect) {
        node.frame = rect
        if let pane = node.pane {
            placeCard(pane, in: rect)
            return
        }
        guard node.children.count == 2 else { return }
        let (a, b) = (node.children[0], node.children[1])
        switch node.axis {
        case .horizontal:
            let w = max(0, rect.width * node.ratio)
            place(a, in: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
            place(b, in: CGRect(x: rect.minX + w, y: rect.minY, width: max(0, rect.width - w), height: rect.height))
        case .vertical:
            let h = max(0, rect.height * node.ratio)
            place(a, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h))
            place(b, in: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: max(0, rect.height - h)))
        }
    }

    private func rebuildDividers() {
        var splits: [PaneNode] = []
        func collect(_ node: PaneNode) {
            guard !node.isLeaf else { return }
            splits.append(node)
            node.children.forEach(collect)
        }
        collect(root)

        while dividers.count > splits.count { dividers.removeLast().removeFromSuperview() }
        while dividers.count < splits.count {
            let divider = DividerView()
            divider.container = self
            // Below a floating card, which stays over everything and takes clicks first.
            if let card { addSubview(divider, positioned: .below, relativeTo: card) } else { addSubview(divider) }
            dividers.append(divider)
        }
        for (divider, node) in zip(dividers, splits) {
            divider.node = node
            // The gap between the two cards, where their slots meet, and a
            // little beyond it to grab.
            let edge = node.children[0].frame
            let half = Layout.paneGap / 2 + 3
            divider.frame = switch node.axis {
            case .horizontal:
                CGRect(x: edge.maxX - half, y: node.frame.minY, width: half * 2, height: node.frame.height)
            case .vertical:
                CGRect(x: node.frame.minX, y: edge.maxY - half, width: node.frame.width, height: half * 2)
            }
        }
    }
}

/// Handle in the gap between two panes; drag to resize the split. A small
/// grip shows while the pointer is over it or it's being dragged (GoRex),
/// so the handle can be found without hunting for the cursor change.
final class DividerView: NSView {
    weak var container: SplitContainerView?
    weak var node: PaneNode? { didSet { needsDisplay = true } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }
    private var area: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Whether the pointer is over it now. Some ways of parting get no exit
    /// event: the divider moving from under the pointer (a split opening or
    /// closing, a drag held at its limit), a drag let go of elsewhere, the
    /// window losing the keyboard. Without this the grip stays lit.
    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            hovering = false
            return
        }
        hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: $0, queue: .main) {
                [weak self] _ in self?.hovering = false
            }
        }
        refreshHover()
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || dragging, let node else { return }
        // A 36 × 3 pill along the gap, in the gap's middle.
        let long: CGFloat = 36, thick: CGFloat = 3
        let rect = node.axis == .horizontal
            ? NSRect(x: bounds.midX - thick / 2, y: bounds.midY - long / 2, width: thick, height: long)
            : NSRect(x: bounds.midX - long / 2, y: bounds.midY - thick / 2, width: long, height: thick)
        (dragging ? NSColor.labelColor : NSColor.secondaryLabelColor).withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thick / 2, yRadius: thick / 2).fill()
    }

    override func resetCursorRects() {
        guard let node else { return }
        addCursorRect(bounds, cursor: node.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        dragged = node
    }

    /// The split a drag started on: dividers are paired with splits by
    /// position, and a pane closing mid-drag reshuffles them.
    private weak var dragged: PaneNode?

    override func mouseDragged(with event: NSEvent) {
        guard let node = dragged ?? node, let container else { return }
        dragging = true
        let p = container.convert(event.locationInWindow, from: nil)
        let f = node.frame
        let ratio: CGFloat = switch node.axis {
        case .horizontal: (p.x - f.minX) / max(1, f.width)
        case .vertical: (p.y - f.minY) / max(1, f.height)
        }
        node.ratio = min(0.9, max(0.1, ratio))
        container.layoutPanes()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        dragged = nil
        // Double-click a divider to even the split, like Finder column handles.
        if event.clickCount == 2, let node, let container {
            node.ratio = 0.5
            container.layoutPanes()
        }
        refreshHover()
    }
}
