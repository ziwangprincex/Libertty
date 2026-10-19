import AppKit

/// macOS's overlay scrollbar, for the scrollback: a thin knob at the right
/// edge that shows while you scroll (or point at the edge), widens under the
/// pointer, and drags the viewport. Clicking the track pages.
final class OverlayScroller: NSView {
    /// The viewport moved to `row` (0 = oldest line).
    var onScroll: ((UInt64) -> Void)?

    private var state = TerminalSession.Scrollbar(total: 0, offset: 0, length: 0)
    private var hovering = false
    private var dragging: (startY: CGFloat, startOffset: UInt64)?
    private var hideWork: DispatchWorkItem?
    private var knobFrame = NSRect.zero
    private var knobColor = NSColor.black

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private var dark: Bool?

    func updateColors(dark: Bool? = nil) {
        if let dark { self.dark = dark }
        let isDark = self.dark ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        knobColor = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(hovering ? 0.55 : 0.42)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state.scrollable, !knobFrame.isEmpty else { return }
        knobColor.setFill()
        NSBezierPath(roundedRect: knobFrame, xRadius: knobFrame.width / 2, yRadius: knobFrame.width / 2).fill()
    }

    /// New position; `reveal` shows it for a moment (the user scrolled).
    func update(_ scrollbar: TerminalSession.Scrollbar, reveal: Bool) {
        let changed = scrollbar != state
        state = scrollbar
        guard scrollbar.scrollable else { return fade(to: 0) }
        if changed { layoutKnob() }
        if reveal { show() }
    }

    private func layoutKnob() {
        guard state.total > 0 else { return }
        let inset: CGFloat = 3
        let track = bounds.height - inset * 2
        let height = max(28, track * CGFloat(state.length) / CGFloat(state.total))
        let range = CGFloat(state.total - state.length)
        let y = inset + (range > 0 ? (track - height) * CGFloat(state.offset) / range : 0)
        let width: CGFloat = hovering || dragging != nil ? 9 : 6
        knobFrame = NSRect(x: bounds.width - width - 3, y: y, width: width, height: height)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutKnob()
    }

    private func show() {
        hideWork?.cancel()
        fade(to: 1)
        guard !hovering, dragging == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.fade(to: 0) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func fade(to alpha: CGFloat) {
        guard alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(alpha > 0 ? 0.1 : 0.3)
            animator().alphaValue = alpha
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard state.scrollable else { return }
        hovering = true
        updateColors()
        layoutKnob()
        show()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateColors()
        layoutKnob()
        show()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the strip at the edge, and only when there's something to scroll.
        state.scrollable && alphaValue > 0.01 || hovering ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if knobFrame.insetBy(dx: -4, dy: 0).contains(p) {
            dragging = (p.y, state.offset)
        } else {
            // A click in the track pages toward it.
            let page = state.length
            let target = p.y < knobFrame.minY ? (state.offset > page ? state.offset - page : 0)
                : min(state.total - state.length, state.offset + page)
            onScroll?(target)
        }
        layoutKnob()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let track = bounds.height - 6 - knobFrame.height
        guard track > 0 else { return }
        let range = Double(state.total - state.length)
        let delta = Double(p.y - dragging.startY) / Double(track) * range
        let row = max(0, min(range, Double(dragging.startOffset) + delta))
        onScroll?(UInt64(row.rounded()))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        layoutKnob()
        show()
    }
}
