import AppKit

/// Jump to the Pane That Needs You (⌘J, Kero's): the panes of every window
/// whose program waits for you first, then those that failed, then those
/// that finished, then those with something unseen (a bell, a long command
/// done out of sight); each press goes on to the next.
enum AttentionJump {
    /// How much a pane needs you, lower first; nil for not at all.
    static func rank(status: ProgramStatusStore.State?, unseen: Bool) -> Int? {
        switch status {
        case .blocked: return 0
        case .error: return 1
        case .done: return 2
        default: return unseen ? 3 : nil
        }
    }

    /// The candidate to go to from `current`: the one after it, by rank and
    /// then by place (window, tab, pane), round again past the last; nil
    /// when there's nowhere else. `current` may need nothing anymore — a
    /// pane that failed or finished is seen once you're there — so it
    /// stands where it was when it was gone to (`was`); with no `was`, the
    /// first candidate is next.
    static func next<T: AnyObject>(_ candidates: [(item: T, rank: Int, place: Int)], after current: T?,
                                   was: (rank: Int, place: Int)? = nil) -> T? {
        let ordered = candidates.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.place < $1.place }
        guard let first = ordered.first else { return nil }
        if let current, let i = ordered.firstIndex(where: { $0.item === current }) {
            return ordered.count > 1 ? ordered[(i + 1) % ordered.count].item : nil
        }
        guard let was else { return first.item }
        return ordered.first { ($0.rank, $0.place) > (was.rank, was.place) }?.item ?? first.item
    }

    /// The pane gone to last, and where it stood then.
    private static weak var last: TerminalView?
    private static var lastKey: (rank: Int, place: Int)?

    /// Bring forward the next pane that needs you among `controllers`'
    /// windows (and the Quick Terminal's). Returns false (and beeps) when none does.
    @discardableResult
    static func go(from current: TerminalView?, in controllers: [TerminalWindowController]) -> Bool {
        var candidates: [(item: TerminalView, rank: Int, place: Int)] = []
        var owner: [ObjectIdentifier: TerminalWindowController] = [:]
        var place = 0
        var currentPlace: Int?
        for controller in controllers {
            for pane in controller.allPanes {
                place += 1
                if pane === current { currentPlace = place }
                let unseen = controller.attention.contains(ObjectIdentifier(pane))
                if let rank = rank(status: pane.session.programStatus.headline?.state, unseen: unseen) {
                    candidates.append((pane, rank, place))
                    owner[ObjectIdentifier(pane)] = controller
                }
            }
        }
        let was = current != nil && current === last ? lastKey.map { ($0.rank, currentPlace ?? $0.place) } : nil
        guard let pane = next(candidates, after: current, was: was), let controller = owner[ObjectIdentifier(pane)],
              let chosen = candidates.first(where: { $0.item === pane }) else {
            NSSound.beep()
            return false
        }
        last = pane
        lastKey = (chosen.rank, chosen.place)
        if controller === QuickTerminal.shared.windowController { QuickTerminal.shared.show() }
        return controller.reveal(paneID: pane.paneID)
    }
}
