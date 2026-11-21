import Foundation

/// Where focus has been, app-wide: the leaves of every window's tabs it
/// landed on — a terminal pane, a document pane, a document tab — newest
/// first, each once, at most `limit` of them. Focus Back (`focus_back`)
/// walks it: pressed again soon, focus still where it landed, it goes one
/// further back. Focus Recent (`focus_recent`) goes back and forth between
/// where focus is and where it was before. Either goes from pane to pane
/// or from tab to tab. It holds its leaves weakly: a closed pane drops
/// out; one that can't be shown now (a window hidden for Undo Close, a
/// parked pane) is passed over, kept for when it can (`jump`'s `stop` says).
final class FocusHistory {
    static let shared = FocusHistory()
    static let limit = 64
    /// Focus Back pressed again within this long of its last landing goes
    /// one further back; later, it starts again from where focus is.
    static let walkWindow: TimeInterval = 3

    /// From pane to pane, or from tab to tab (landing on the tab's own focused pane).
    enum Level: String, CaseIterable { case pane, tab }

    private final class Ref {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    /// A walk back under way: the places it goes through, newest first, how
    /// far it has gone, and where (and when) its last press landed. Its
    /// landings aren't news until focus moves on from there: walking past a
    /// pane doesn't make it the newest; the one it stops at becomes so.
    private struct Walk {
        let level: Level
        let stops: [Ref]
        var index: Int
        var landed: Ref
        var time: TimeInterval
    }

    private var leaves: [Ref] = []
    private var walk: Walk?
    /// A jump is moving focus: what it passes through on the way isn't news.
    private var jumping = false
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// The leaves still here, newest first.
    var entries: [AnyObject] { leaves.compactMap(\.object) }

    /// Focus landed on `leaf`: it's the newest. Where a walk landed is no
    /// news (focus is still there: the walk may go on); anywhere else ends it.
    func note(_ leaf: AnyObject) {
        guard !jumping else { return }
        if let walk {
            if walk.landed.object === leaf { return }
            endWalk()
        }
        push(leaf)
    }

    /// Focus Back (`walking`) or Focus Recent, from pane to pane or tab to tab.
    /// `current`: the leaf focus is on, when the history keeps one there (it
    /// becomes the newest first); `here`: where focus is at this level (that
    /// leaf, or its tab), passed over. `stop`: what a leaf is at this level —
    /// the leaf, or its tab — or nil when it can't be shown now. `go`: bring
    /// a stop forward and say which leaf focus landed on (nil: it couldn't).
    /// False when there was nowhere to go (nothing has changed then).
    @discardableResult
    func jump(_ level: Level, walking: Bool, current: AnyObject?, here: AnyObject?,
              stop: (AnyObject) -> AnyObject?, go: (AnyObject) -> AnyObject?) -> Bool {
        // Pressed again soon, focus where the last press left it: one further back.
        if walking, let w = walk, w.level == level, let landed = w.landed.object, landed === current,
           clock() - w.time <= Self.walkWindow {
            for i in (w.index + 1)..<w.stops.count {
                guard let leaf = w.stops[i].object, let place = stop(leaf), place !== here,
                      let arrived = land(on: place, go) else { continue }
                walk?.index = i
                walk?.landed = Ref(arrived)
                walk?.time = clock()
                return true
            }
            return false
        }
        // From where focus is now, the newest.
        endWalk()
        if let current { push(current) }
        let stops = self.stops(besides: here, stop: stop)
        for (i, ref) in stops.enumerated() {
            guard let leaf = ref.object, let place = stop(leaf), let arrived = land(on: place, go) else { continue }
            if walking {
                walk = Walk(level: level, stops: stops, index: i, landed: Ref(arrived), time: clock())
            } else {
                push(arrived)
            }
            return true
        }
        return false
    }

    /// Bring `place` forward, what focus passes on the way not noted.
    private func land(on place: AnyObject, _ go: (AnyObject) -> AnyObject?) -> AnyObject? {
        jumping = true
        defer { jumping = false }
        return go(place)
    }

    /// The newest leaf of each place in the history but `here`, newest first.
    private func stops(besides here: AnyObject?, stop: (AnyObject) -> AnyObject?) -> [Ref] {
        var seen: [AnyObject] = here.map { [$0] } ?? []
        var out: [Ref] = []
        for ref in leaves {
            guard let leaf = ref.object, let place = stop(leaf), !seen.contains(where: { $0 === place }) else { continue }
            seen.append(place)
            out.append(ref)
        }
        return out
    }

    /// A walk ends where it stopped: that leaf is the newest now.
    private func endWalk() {
        guard let walk else { return }
        self.walk = nil
        if let landed = walk.landed.object { push(landed) }
    }

    private func push(_ leaf: AnyObject) {
        leaves.removeAll { $0.object == nil || $0.object === leaf }
        leaves.insert(Ref(leaf), at: 0)
        if leaves.count > Self.limit { leaves.removeLast(leaves.count - Self.limit) }
    }
}
