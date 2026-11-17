import AppKit
import Testing
@testable import LiberttyApp

/// Undo for closing: Edit ▸ Undo takes back the last close, and the Undo a
/// list leaves where something was (a closed forward's) takes back that
/// one alone, without touching the rest or leaving a Redo.
@MainActor
struct CloseUndoTests {
    /// Each close in its own group, as each comes in an event of its own in
    /// the app (a test has no run loop to close the group of its "event").
    private func closing(_ undo: CloseUndo, _ body: () -> CloseUndo.Entry) -> CloseUndo.Entry {
        undo.manager.groupsByEvent = false
        undo.manager.beginUndoGrouping()
        defer { undo.manager.endUndoGrouping() }
        return body()
    }

    @Test func oneCloseUndoneByItself() {
        let undo = CloseUndo()
        var reopened: [String] = []
        let first = closing(undo) { undo.closed("Close A", restore: { reopened.append("a"); return {} }, expire: {}) }
        _ = closing(undo) { undo.closed("Close B", restore: { reopened.append("b"); return {} }, expire: {}) }
        #expect(undo.undo(first))
        #expect(reopened == ["a"])
        // Once: it's back already.
        #expect(!undo.undo(first))
        // The later close is still Edit ▸ Undo's, and the button left no Redo.
        #expect(undo.manager.undoActionName == "Close B")
        #expect(!undo.manager.canRedo)
        undo.manager.undo()
        #expect(reopened == ["a", "b"])
        // Edit ▸ Undo's own can be redone.
        #expect(undo.manager.canRedo)
    }

    /// Made again and closed again: the older close can't be undone any
    /// more, and nothing is ended for it.
    @Test func aDiscardedCloseIsGone() {
        let undo = CloseUndo()
        var reopened = 0, ended = 0
        let entry = closing(undo) { undo.closed("Close Forward", restore: { reopened += 1; return {} }, expire: { ended += 1 }) }
        undo.discard(entry)
        #expect(!undo.manager.canUndo)
        #expect(!undo.undo(entry))
        undo.expireAll()
        #expect(reopened == 0 && ended == 0)
    }
}
