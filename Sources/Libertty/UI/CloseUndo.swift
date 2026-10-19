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

    private final class Entry: NSObject {
        let expire: () -> Void
        var work: DispatchWorkItem?
        init(expire: @escaping () -> Void) { self.expire = expire }
    }

    var timeout: TimeInterval { ConfigStore.shared.config.undoTimeout }
    var enabled: Bool { timeout > 0 }

    /// Something just closed: `restore` reopens it (and returns a closure
    /// that closes it again, for Redo); `expire` really ends it later.
    func closed(_ name: String, restore: @escaping () -> (() -> Void)?, expire: @escaping () -> Void) {
        let entry = Entry(expire: expire)
        pending.append(entry)
        manager.registerUndo(withTarget: entry) { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self else { return }
                entry.work?.cancel()
                self.pending.removeAll { $0 === entry }
                if let reclose = restore() {
                    // Redo closes it again, which registers a fresh undo.
                    self.manager.registerUndo(withTarget: entry) { _ in MainActor.assumeIsolated { reclose() } }
                    self.manager.setActionName(name)
                }
            }
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
