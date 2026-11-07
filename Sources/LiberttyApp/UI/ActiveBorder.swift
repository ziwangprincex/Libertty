import AppKit

/// The focused pane's border (`active-border`, Rex's active pane highlight):
/// a line round its card, header and all, that follows focus — gliding to
/// the newly focused pane, crossfading there, or simply going — and draws
/// fainter while its window isn't in front. Over the panes; never in the
/// way of a click.
final class ActiveBorderView: NSView {
    struct Look: Equatable {
        var color: NSColor
        var opacity: Double
        /// `active-border-animation`: move, fade or off.
        var animation: String
    }

    static let width: CGFloat = 2

    private var shown: CALayer?
    /// Where the border was last put (the UI probe reads it).
    private(set) var frameShown: CGRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Round `card` (in this view), or none. `animated` false: where the
    /// same pane's card went (a resize, a divider dragged), at once.
    func show(_ card: CGRect?, look: Look, radius: CGFloat, animated: Bool = true) {
        guard let card, let host = layer else {
            if let old = shown { fadeOut(old, animated: animated && look.animation != "off" && !Motion.reduced) }
            shown = nil
            frameShown = nil
            return
        }
        // On the card's own edge, drawn inward (a layer's border is): never
        // cut off where the card meets the sidebar or the window's edge.
        let frame = card.integral
        let color = look.color.withAlphaComponent(look.color.alphaComponent * look.opacity).cgColor
        let animation = Motion.reduced || !animated ? "off" : look.animation
        frameShown = frame
        if let current = shown, animation == "move" || current.frame == frame || animation == "off" {
            CATransaction.begin()
            CATransaction.setDisableActions(animation == "off" || current.frame == frame)
            CATransaction.setAnimationDuration(Motion.small)
            CATransaction.setAnimationTimingFunction(Motion.ease)
            current.frame = frame
            current.borderColor = color
            current.cornerRadius = radius
            CATransaction.commit()
            return
        }
        // Fade (or the first one): a new border comes in as the old one goes.
        if let old = shown { fadeOut(old, animated: animation == "fade") }
        let border = CALayer()
        border.frame = frame
        border.borderWidth = Self.width
        border.borderColor = color
        border.cornerRadius = radius
        border.cornerCurve = .continuous
        host.addSublayer(border)
        shown = border
        if animation == "fade" {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = Motion.small
            border.add(fade, forKey: "in")
        }
    }

    private func fadeOut(_ old: CALayer, animated: Bool) {
        guard animated else { return old.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.small)
        CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
        old.opacity = 0
        CATransaction.commit()
    }
}
