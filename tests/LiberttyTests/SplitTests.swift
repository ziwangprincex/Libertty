import AppKit
import Testing
@testable import LiberttyApp

/// The split tree: swapping, moving beside, evening out, where a drop lands.
@MainActor
struct SplitTests {
    let a = NSView(), b = NSView(), c = NSView()

    private func split() -> SplitContainerView {
        // a | (b / c)
        let root = PaneNode(axis: .horizontal, ratio: 0.5, first: PaneNode(pane: a),
                            second: PaneNode(axis: .vertical, ratio: 0.5, first: PaneNode(pane: b), second: PaneNode(pane: c)))
        let view = SplitContainerView(root: root)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutPanes()
        return view
    }

    private func names(_ v: NSView) -> String { v === a ? "a" : v === b ? "b" : v === c ? "c" : "?" }

    @Test func describes() {
        #expect(split().layoutDescription(names) == "h50(a,v50(b,c))")
    }

    @Test func swapKeepsThePlaces() {
        let s = split()
        s.swap(a, with: c)
        #expect(s.layoutDescription(names) == "h50(c,v50(b,a))")
    }

    @Test func moveBeside() {
        let s = split()
        s.move(c, beside: a, toward: .down)
        #expect(s.layoutDescription(names) == "h50(v50(a,c),b)")
        s.move(b, beside: a, toward: .left)
        #expect(s.layoutDescription(names) == "v50(h50(b,a),c)")
    }

    @Test func equalizeBySpan() {
        let s = split()
        s.move(c, beside: b, toward: .right)  // a | b | c, nested
        s.equalize()
        #expect(s.layoutDescription(names) == "h33(a,h50(b,c))")
    }

    @Test func dropZones() {
        let s = split()
        // a is the left half: its middle trades places, its edges go beside.
        #expect(s.drop(at: NSPoint(x: 200, y: 300), dragging: b) == .swap(a))
        #expect(s.drop(at: NSPoint(x: 20, y: 300), dragging: b) == .side(a, .left))
        #expect(s.drop(at: NSPoint(x: 200, y: 580), dragging: b) == .side(a, .down))
        #expect(s.drop(at: NSPoint(x: 200, y: 300), dragging: a) == nil)
    }

    /// Another split's panes join beside a pane as one block, arranged as
    /// they were (Merge into Current Tab); each view is in the tree once.
    @Test func joinKeepsTheOtherSplitsArrangement() {
        let s = split()
        let d = NSView(), e = NSView(), f = NSView()
        let other = SplitContainerView(root: PaneNode(axis: .vertical, ratio: 0.25, first: PaneNode(pane: d),
                                                      second: PaneNode(axis: .horizontal, ratio: 0.5, first: PaneNode(pane: e),
                                                                       second: PaneNode(pane: f))))
        func named(_ v: NSView) -> String { v === d ? "d" : v === e ? "e" : v === f ? "f" : names(v) }
        #expect(s.join(other, beside: b, toward: .right))
        #expect(s.layoutDescription(named) == "h50(a,v50(h50(b,v25(d,h50(e,f))),c))")
        #expect([d, e, f].allSatisfy { $0.superview === s })
        // Not twice, and not beside a pane that isn't there.
        #expect(!s.join(other, beside: b, toward: .right))
        #expect(!s.join(SplitContainerView(root: PaneNode(pane: NSView())), beside: NSView(), toward: .left))
        #expect(s.views.count == 6)
    }

    /// Below, as wide as the column: the tabs' band takes the bottom inset's place.
    @Test func bottomTabsTakeTheBottomInset() {
        var config = Config()
        let left = TerminalWindowController.stageExtra(config, sidebar: false, inspector: false)
        config.tabBar = .bottom
        let bottom = TerminalWindowController.stageExtra(config, sidebar: false, inspector: false)
        #expect(bottom.width == left.width)
        #expect(bottom.height - left.height == WindowChrome.bottomBandHeight - (config.paneStyle == .compact ? 0 : 8))
        config.tabBar = .top
        let top = TerminalWindowController.stageExtra(config, sidebar: false, inspector: false)
        #expect(top.height > left.height && bottom.height > left.height)
    }
}

/// An animation that ended keeps nothing it was given: a container keeps
/// its last animator till its next change, and a pane closing is captured
/// by the animator's completion.
@MainActor
struct AnimatorTests {
    final class Captured {}

    @Test func anEndedAnimationLetsGoOfItsClosures() {
        weak var captured: Captured?
        var animator: FrameAnimator?
        do {
            let pane = Captured()
            captured = pane
            // Not in a window: it ends at once, as Reduce Motion does.
            animator = FrameAnimator.run(on: NSView(), duration: 0.2, update: { _ in _ = pane }, completion: { _ = pane })
        }
        #expect(animator != nil)
        #expect(captured == nil)
    }
}

/// The sidebar never gets narrower than its top row's buttons: the toggle
/// after the traffic lights, then Show Activity, the palette and New Tab.
@MainActor struct SidebarMinimumTests {
    @Test func itsButtonsFit() {
        let clearance = WindowChrome.trafficLightRoom + 10, toggle = WindowChrome.buttonSize.width
        let group = WindowChrome.buttonSize.width * 3 + 2
        let minimum = TerminalWindowController.sidebarMinimum(clearance: clearance, leading: toggle, trailing: group)
        // The toggle ends before the group begins, with room between.
        #expect(clearance + toggle + 8 <= minimum - 9 - group)
        #expect(minimum > 180)
        // On the right (no traffic lights to clear), and without its buttons: 180.
        #expect(TerminalWindowController.sidebarMinimum(clearance: 9, leading: nil, trailing: group) == 180)
        #expect(TerminalWindowController.sidebarMinimum(clearance: clearance, leading: toggle, trailing: nil) == 180)
    }
}
