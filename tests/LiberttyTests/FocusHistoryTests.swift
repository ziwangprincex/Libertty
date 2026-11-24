import Foundation
import Testing
@testable import LiberttyApp

/// Focus history: where focus has been, newest first, each place once;
/// Back walks it and Forward retraces the walk, as a browser's buttons do;
/// Recent goes back and forth; closed panes drop out, ones that can't be
/// shown are passed over.
struct FocusHistoryTests {
    final class Tab {}
    final class Leaf {
        let name: String
        let tab: Tab
        /// It can be shown now (not parked, not in a window hidden for undo).
        var shown = true
        init(_ name: String, in tab: Tab) { self.name = name; self.tab = tab }
    }

    /// Panes in tabs, and focus moving the way the app moves it: each
    /// landing tells the history, jumps' own landings too.
    final class World {
        let history = FocusHistory()
        private(set) var focused: Leaf?
        /// Each tab's own focused pane: what a jump to the tab lands on.
        private var tabFocus: [ObjectIdentifier: Leaf] = [:]

        func focus(_ leaf: Leaf) {
            focused = leaf
            tabFocus[ObjectIdentifier(leaf.tab)] = leaf
            history.note(leaf)
        }

        func back(_ level: FocusHistory.Level = .pane) -> Bool { jump(level, .back) }
        func forward(_ level: FocusHistory.Level = .pane) -> Bool { jump(level, .forward) }
        func recent(_ level: FocusHistory.Level = .pane) -> Bool { jump(level, .recent) }

        private func jump(_ level: FocusHistory.Level, _ move: FocusHistory.Move) -> Bool {
            history.jump(level, move, current: focused, here: level == .pane ? focused : focused?.tab,
                         stop: { object in
                             let leaf = object as! Leaf
                             if level == .tab { return leaf.tab }
                             return leaf.shown ? leaf : nil
                         }, go: { stop in
                             guard let leaf = (stop as? Leaf) ?? (stop as? Tab).flatMap({ self.tabFocus[ObjectIdentifier($0)] }) else { return nil }
                             self.focus(leaf)
                             return leaf
                         })
        }

        var names: [String] { history.entries.map { ($0 as! Leaf).name } }
    }

    @Test func newestFirstEachOnce() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab)
        for leaf in [a, b, c, b] { world.focus(leaf) }
        #expect(world.names == ["b", "c", "a"])
    }

    @Test func keepsAtMostSixtyFour() {
        let world = World(), tab = Tab()
        let leaves = (0..<70).map { Leaf("\($0)", in: tab) }
        leaves.forEach(world.focus)
        #expect(world.names.count == FocusHistory.limit)
        #expect(world.names.first == "69")
        #expect(world.names.last == "6")
    }

    @Test func closedPanesDropOut() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), c = Leaf("c", in: tab)
        world.focus(a)
        do {
            let b = Leaf("b", in: tab)
            world.focus(b)
            #expect(world.names == ["b", "a"])
        }
        world.focus(c)
        #expect(world.names == ["c", "a"])
        // Back from c is to a: b is gone.
        #expect(world.back())
        #expect(world.focused === a)
    }

    @Test func backWalksFurtherEachPress() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab), d = Leaf("d", in: tab)
        for leaf in [a, b, c, d] { world.focus(leaf) }
        #expect(world.back())
        #expect(world.focused === c)
        #expect(world.back())
        #expect(world.focused === b)
        #expect(world.back())
        #expect(world.focused === a)
        // The oldest: nowhere further, and nothing changes.
        #expect(!world.back())
        #expect(world.focused === a)
        // Walked past, c and b didn't become the newest; where it stopped does
        // once focus moves on.
        #expect(world.names == ["d", "c", "b", "a"])
        world.focus(c)
        #expect(world.names == ["c", "a", "d", "b"])
    }

    @Test func forwardRetracesTheWalk() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab), d = Leaf("d", in: tab)
        for leaf in [a, b, c, d] { world.focus(leaf) }
        // No walk back: nowhere forward.
        #expect(!world.forward())
        #expect(world.focused === d)
        for leaf in [c, b, a] {
            #expect(world.back())
            #expect(world.focused === leaf)
        }
        for leaf in [b, c, d] {
            #expect(world.forward())
            #expect(world.focused === leaf)
        }
        // Back where the walk began: no further forward; back walks it again.
        #expect(!world.forward())
        #expect(world.focused === d)
        #expect(world.back())
        #expect(world.focused === c)
        #expect(world.forward())
        #expect(world.focused === d)
        // Walked through, none of it became the newest.
        #expect(world.names == ["d", "c", "b", "a"])
    }

    @Test func focusElsewhereEndsTheWayForward() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab), d = Leaf("d", in: tab)
        for leaf in [a, b, c, d] { world.focus(leaf) }
        #expect(world.back())
        #expect(world.back())
        #expect(world.focused === b)
        // A click somewhere else: where the walk stopped is the newest before it.
        world.focus(a)
        #expect(!world.forward())
        #expect(world.focused === a)
        #expect(world.names == ["a", "b", "d", "c"])
        // Recent ends a walk too.
        #expect(world.back())
        #expect(world.focused === b)
        #expect(world.recent())
        #expect(world.focused === a)
        #expect(!world.forward())
    }

    @Test func forwardPassesOverWhatCantBeShown() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab), d = Leaf("d", in: tab)
        for leaf in [a, b, c, d] { world.focus(leaf) }
        for _ in 0..<3 { #expect(world.back()) }
        #expect(world.focused === a)
        c.shown = false
        #expect(world.forward())
        #expect(world.focused === b)
        #expect(world.forward())
        #expect(world.focused === d)
    }

    @Test func forwardOnlyAtTheWalksLevel() {
        let world = World(), one = Tab(), two = Tab()
        let a1 = Leaf("a1", in: one), b1 = Leaf("b1", in: two), b2 = Leaf("b2", in: two)
        for leaf in [a1, b1, b2] { world.focus(leaf) }
        #expect(world.back(.pane))
        #expect(world.focused === b1)
        // Not a walk from tab to tab: nowhere to go, and the pane walk goes on.
        #expect(!world.forward(.tab))
        #expect(world.focused === b1)
        #expect(world.forward(.pane))
        #expect(world.focused === b2)
    }

    @Test func focusElsewhereEndsTheWalk() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab), d = Leaf("d", in: tab)
        for leaf in [a, b, c, d] { world.focus(leaf) }
        #expect(world.back())
        #expect(world.focused === c)
        // A click somewhere else, then back at once: from there, not further on.
        world.focus(a)
        #expect(world.back())
        #expect(world.focused === c)
        // Focus clicked back onto where it landed changes nothing: it walks on.
        world.focus(c)
        #expect(world.back())
        #expect(world.focused === d)
    }

    @Test func recentGoesBackAndForth() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab)
        for leaf in [a, b, c] { world.focus(leaf) }
        #expect(world.recent())
        #expect(world.focused === b)
        #expect(world.recent())
        #expect(world.focused === c)
        #expect(world.recent())
        #expect(world.focused === b)
        #expect(world.names == ["b", "c", "a"])
    }

    @Test func recentAfterAWalkReturnsToWhereItBegan() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab), d = Leaf("d", in: tab)
        for leaf in [a, b, c, d] { world.focus(leaf) }
        #expect(world.back())
        #expect(world.back())
        #expect(world.focused === b)
        #expect(world.recent())
        #expect(world.focused === d)
        #expect(world.recent())
        #expect(world.focused === b)
    }

    @Test func passesOverWhatCantBeShown() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab), c = Leaf("c", in: tab)
        for leaf in [a, b, c] { world.focus(leaf) }
        b.shown = false  // parked, or its window hidden for Undo Close
        #expect(world.recent())
        #expect(world.focused === a)
        // Kept all the same: back once it can be shown again.
        b.shown = true
        #expect(world.names == ["a", "c", "b"])
        #expect(world.back())
        #expect(world.back())
        #expect(world.focused === b)
    }

    @Test func nothingToGoTo() {
        let world = World(), tab = Tab()
        #expect(!world.back())
        #expect(!world.recent())
        let a = Leaf("a", in: tab)
        world.focus(a)
        #expect(!world.back())
        #expect(!world.recent(.tab))
        #expect(world.focused === a)
    }

    @Test func tabsWalkTabByTabLandingOnTheirOwnPane() {
        let world = World(), one = Tab(), two = Tab(), three = Tab()
        let a1 = Leaf("a1", in: one), b1 = Leaf("b1", in: two), b2 = Leaf("b2", in: two), c1 = Leaf("c1", in: three)
        for leaf in [a1, c1, b1, b2] { world.focus(leaf) }
        // Walking back from pane to pane passes b1 (tab two's own pane now) and stops at c1.
        #expect(world.back())
        #expect(world.focused === b1)
        #expect(world.back())
        #expect(world.focused === c1)
        // Tab by tab from there: tab two lands on its own focused pane, b1,
        // not on b2 (its newest in the history); then tab one.
        #expect(world.back(.tab))
        #expect(world.focused === b1)
        #expect(world.back(.tab))
        #expect(world.focused === a1)
        #expect(!world.back(.tab))
        #expect(world.focused === a1)
    }

    @Test func tabsPassOverTheCurrentTabsPanes() {
        let world = World(), one = Tab(), two = Tab()
        let a1 = Leaf("a1", in: one), a2 = Leaf("a2", in: one), b1 = Leaf("b1", in: two)
        for leaf in [b1, a1, a2] { world.focus(leaf) }
        // a1 is in this tab: the tab before is two's.
        #expect(world.recent(.tab))
        #expect(world.focused === b1)
        #expect(world.recent(.tab))
        #expect(world.focused === a2)
        #expect(world.names == ["a2", "b1", "a1"])
    }

    @Test func anotherLevelStartsAgain() {
        let world = World(), one = Tab(), two = Tab()
        let a1 = Leaf("a1", in: one), a2 = Leaf("a2", in: one), b1 = Leaf("b1", in: two)
        for leaf in [b1, a1, a2] { world.focus(leaf) }
        #expect(world.back(.pane))
        #expect(world.focused === a1)
        // From a1 (now the newest), the tab before this one.
        #expect(world.back(.tab))
        #expect(world.focused === b1)
    }

    /// From somewhere it doesn't keep (the Quick Terminal): to the newest.
    @Test func fromNowhereToTheNewest() {
        let world = World(), tab = Tab()
        let a = Leaf("a", in: tab), b = Leaf("b", in: tab)
        world.focus(a)
        world.focus(b)
        var landed: AnyObject?
        let went = world.history.jump(.pane, .back, current: nil, here: nil, stop: { $0 }, go: { landed = $0; return $0 })
        #expect(went)
        #expect(landed === b)
    }

    @Test func actionsParse() throws {
        #expect(Action("focus_back:pane") == .focusBack(.pane))
        #expect(Action("focus_back:tab") == .focusBack(.tab))
        #expect(Action("focus_recent:pane") == .focusRecent(.pane))
        #expect(Action("focus_forward:tab") == .focusForward(.tab))
        #expect(Action("focus_forward") == .focusForward(.pane))
        #expect(Action("focus_recent: tab") == .focusRecent(.tab))
        #expect(Action("focus_back") == .focusBack(.pane))
        #expect(Action("focus_back:window") == nil)
        for text in ["focus_back:pane", "focus_back:tab", "focus_forward:pane", "focus_forward:tab", "focus_recent:pane", "focus_recent:tab"] {
            let action = try #require(Action(text))
            #expect(action.configString == text)
            #expect(Action.catalog.contains { $0.0.hasPrefix(text.split(separator: ":")[0] + ":") })
        }
        // Not bound by default: the keys they'd want are taken.
        #expect(!Keybinds.defaults.contains { $0.contains("focus_back") || $0.contains("focus_forward") || $0.contains("focus_recent") })
    }
}
