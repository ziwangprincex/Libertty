import AppKit

/// Ghostty's undo for closing: a closed pane, tab or window stays alive for
/// `undo-timeout`, and Edit ▸ Undo Close … (⌘Z) brings it back as it was,
/// programs still running. Every window shares one undo manager, so a
/// closed window can be undone from another one (or with none open).
@MainActor
final class CloseUndo {
    static let shared = CloseUndo()
    let manager = UndoManager()
    private var pending: [Entry] = []

    /// One close waiting to be undone: `undo(_:)` takes it back by itself.
    final class Entry: NSObject {
        fileprivate let expire: () -> Void
        fileprivate var work: DispatchWorkItem?
        /// Reopens it; `redoable`: under Edit ▸ Undo, where Redo can close it again.
        fileprivate var reopen: ((Entry, _ redoable: Bool) -> Void)?
        fileprivate init(expire: @escaping () -> Void) { self.expire = expire }
    }

    var timeout: TimeInterval { ConfigStore.shared.config.undoTimeout }
    var enabled: Bool { timeout > 0 }

    /// Something just closed: `restore` reopens it (and returns a closure
    /// that closes it again, for Redo); `expire` really ends it later.
    @discardableResult
    func closed(_ name: String, restore: @escaping () -> (() -> Void)?, expire: @escaping () -> Void) -> Entry {
        let entry = Entry(expire: expire)
        pending.append(entry)
        entry.reopen = { [weak self] entry, redoable in
            guard let self else { return }
            entry.work?.cancel()
            self.pending.removeAll { $0 === entry }
            // It can't come back (its tab is in another workspace, its
            // window is minimized or gone): its timer is cancelled and
            // nothing else holds it, so what it kept running ends now.
            guard let reclose = restore() else { return entry.expire() }
            guard redoable else { return }
            // Redo closes it again, which registers a fresh undo. The
            // manager doesn't keep its targets, and `pending` let go of
            // this one: the handler keeps it (a freed target crashes Redo).
            self.manager.registerUndo(withTarget: entry) { [entry] _ in
                _ = entry
                MainActor.assumeIsolated { reclose() }
            }
            self.manager.setActionName(name)
        }
        manager.registerUndo(withTarget: entry) { entry in
            MainActor.assumeIsolated { entry.reopen?(entry, true) }
        }
        manager.setActionName(name)
        let work = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.manager.removeAllActions(withTarget: entry)
            self.pending.removeAll { $0 === entry }
            entry.expire()
        }
        entry.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        return entry
    }

    /// Undo `entry`'s close now, whatever closed after it (the Undo a list
    /// leaves where it was): only this one, and not for Redo — a button
    /// isn't the Edit menu's stack. False when it's undone already or
    /// ended with its time.
    @discardableResult
    func undo(_ entry: Entry) -> Bool {
        guard pending.contains(where: { $0 === entry }) else { return false }
        manager.removeAllActions(withTarget: entry)
        entry.reopen?(entry, false)
        return true
    }

    /// `entry` can't be undone any more, and nothing is ended for it (what
    /// it closed was made again, and closed again under a newer entry).
    func discard(_ entry: Entry) {
        entry.work?.cancel()
        manager.removeAllActions(withTarget: entry)
        pending.removeAll { $0 === entry }
    }

    /// Quitting: whatever is waiting to be undone ends now (it mustn't
    /// survive in liberttyd as an orphan).
    func expireAll() {
        for entry in pending {
            entry.work?.cancel()
            manager.removeAllActions(withTarget: entry)
            entry.expire()
        }
        pending = []
    }
}
