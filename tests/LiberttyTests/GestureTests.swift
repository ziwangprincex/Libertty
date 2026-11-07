import CoreGraphics
import Testing
@testable import LiberttyApp

/// Trackpad gestures: a pinch far enough zooms or restores a split's pane;
/// a swipe far and straight enough shows or hides the sidebar.
struct GestureTests {
    @Test func pinch() {
        #expect(TrackpadGestures.pinch(0.3, zoomed: false, panes: 2) == .zoom)
        #expect(TrackpadGestures.pinch(0.1, zoomed: false, panes: 2) == nil)  // not far enough
        #expect(TrackpadGestures.pinch(0.3, zoomed: false, panes: 1) == nil)  // nothing to zoom out of
        #expect(TrackpadGestures.pinch(0.3, zoomed: true, panes: 2) == nil)   // zoomed already
        #expect(TrackpadGestures.pinch(-0.3, zoomed: true, panes: 2) == .restore)
        #expect(TrackpadGestures.pinch(-0.3, zoomed: false, panes: 2) == nil)
    }

    @Test func sidebarSwipe() {
        // Either way, far and straight enough.
        #expect(TrackpadGestures.isSidebarSwipe(dx: 120, dy: 10))
        #expect(TrackpadGestures.isSidebarSwipe(dx: -120, dy: 10))
        // Too short, or too diagonal (a scroll through the history): nothing.
        #expect(!TrackpadGestures.isSidebarSwipe(dx: 50, dy: 0))
        #expect(!TrackpadGestures.isSidebarSwipe(dx: 120, dy: 80))
    }
}

@Suite struct CursorTrailTests {
    let from = SIMD4<Float>(0, 0, 10, 20)
    let to = SIMD4<Float>(100, 40, 10, 20)

    @Test func trailRunsFromTheTailToTheCursor() {
        let rects = TerminalRenderer.trailRects(from: from, to: to, progress: 0, color: RGB(255, 0, 0))
        #expect(rects.count == 8)
        #expect(rects.first?.rect == from)
        // Toward the cursor, never on it (it draws itself), brighter as it goes.
        #expect(rects.last.map { $0.rect.x < to.x } == true)
        let alphas = rects.map { $0.color >> 24 }
        #expect(alphas == alphas.sorted())
    }

    @Test func tailCatchesUpAndFades() {
        let early = TerminalRenderer.trailRects(from: from, to: to, progress: 0.2, color: RGB(255, 0, 0))
        let late = TerminalRenderer.trailRects(from: from, to: to, progress: 0.8, color: RGB(255, 0, 0))
        #expect(late.first!.rect.x > early.first!.rect.x)
        #expect(late.last!.color >> 24 < early.last!.color >> 24)
        #expect(TerminalRenderer.trailRects(from: from, to: to, progress: 1, color: RGB(255, 0, 0)).isEmpty)
        #expect(TerminalRenderer.trailRects(from: to, to: to, progress: 0, color: RGB(255, 0, 0)).isEmpty)
    }
}

@Suite struct ActivityGroupTests {
    func item(_ id: String, _ state: ProgramStatusStore.State) -> ActivityItem {
        ActivityItem(paneID: id, title: id, detail: "", state: state)
    }

    @Test func mostPressingFirstIdleLeftOut() {
        let groups = ActivityItem.grouped([item("a", .working), item("b", .done), item("c", .blocked),
                                           item("d", .idle), item("e", .working), item("f", .error)])
        #expect(groups.map(\.name) == ["Waiting for you", "Failed", "Working", "Done"])
        #expect(groups[2].items.map(\.paneID) == ["a", "e"])
        #expect(ActivityItem.grouped([item("d", .idle)]).isEmpty)
    }
}

@Suite struct CursorJumpTests {
    @Test func stepsAndNewlinesAreNotJumps() {
        #expect(!TerminalRenderer.isJump(from: (4, 2), to: (5, 2)))   // typing
        #expect(!TerminalRenderer.isJump(from: (4, 2), to: (6, 2)))   // a wide character
        #expect(!TerminalRenderer.isJump(from: (4, 2), to: (3, 2)))   // backspace
        #expect(!TerminalRenderer.isJump(from: (40, 2), to: (0, 3)))  // newline
        #expect(!TerminalRenderer.isJump(from: (40, 23), to: (0, 23))) // output scrolling at the bottom
        #expect(!TerminalRenderer.isJump(from: (40, 5), to: (0, 5)))  // a progress bar's \r
    }

    @Test func jumpsAre() {
        #expect(TerminalRenderer.isJump(from: (40, 23), to: (0, 0)))  // clear screen
        #expect(TerminalRenderer.isJump(from: (2, 2), to: (30, 2)))   // across the line
        #expect(TerminalRenderer.isJump(from: (10, 2), to: (10, 12))) // down the screen
    }
}

@Suite @MainActor struct AgentLogoTests {
    @Test func everyAgentHasItsLogo() {
        let agents = ProgramBadge.agents.values.compactMap(\.agent)
        #expect(!agents.isEmpty)
        for agent in agents {
            #expect(AgentLogo.image(agent) != nil, "no logo for \(agent)")
        }
        #expect(AgentLogo.image("not-an-agent") == nil)
    }
}
