import AppKit

/// Trackpad gestures over a terminal (`trackpad-gestures`, Rex's): spread two
/// fingers to zoom the pane of a split, pinch them to restore it; swipe
/// sideways, either way (`sidebar-swipe`), to show or hide the sidebar. One
/// action a gesture, as soon as it has gone far enough.
enum TrackpadGestures {
    /// `sidebar-swipe`: a plain two-finger swipe, one with Option held, or none.
    enum SidebarSwipe: String, CaseIterable { case option, swipe, off }

    /// How far a pinch goes (its magnification, summed) before it acts.
    static let pinchThreshold: CGFloat = 0.25
    /// How far a swipe goes sideways, in points, and how much straighter
    /// than up and down, before it acts: scrolling the history mustn't.
    static let swipeDistance: CGFloat = 70
    static let swipeStraightness: CGFloat = 2

    enum Pinch: Equatable { case zoom, restore }

    /// What a pinch of `total` does in a tab of `panes` panes, zoomed or not.
    static func pinch(_ total: CGFloat, zoomed: Bool, panes: Int) -> Pinch? {
        if total >= pinchThreshold, !zoomed, panes > 1 { return .zoom }
        if total <= -pinchThreshold, zoomed { return .restore }
        return nil
    }

    /// Whether fingers that moved `dx` sideways and `dy` up or down made a
    /// swipe for the sidebar: far enough, and straight enough that it isn't
    /// a scroll through the history. Either way: it comes if it's away, goes
    /// if it's out (which way to swipe for which was easy to get wrong).
    static func isSidebarSwipe(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) >= swipeDistance && abs(dx) > swipeStraightness * abs(dy)
    }

    /// Fingers' sideways movement in a scroll event, positive to the right,
    /// whichever way the scroll direction setting turns the content.
    static func fingersDX(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    }

    static func fingersDY(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
    }
}
