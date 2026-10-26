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
}
