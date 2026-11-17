import AppKit

/// Closing a forward by hand (Settings, the palette's pages), undoably: it
/// closes at once — a port shared with the host mustn't stay open after
/// Close — and for `undo-timeout` Edit ▸ Undo, or the Undo its list leaves
/// in its place, asks the host for it again. `libertty +forward close` and
/// a host's last window going close for good.
@MainActor
enum ForwardClosing {
    /// Closed lately and not undone: what the lists offer to undo, oldest first.
    private(set) static var recent: [PortForward] = []
    private static var entries: [String: CloseUndo.Entry] = [:]
    /// Closes and reopens, in the order they were asked: a Redo right after
    /// an Undo closes what the Undo made, not nothing.
    private static let work = DispatchQueue(label: "dev.libertty.forward-closing")

    /// What a list offers to undo: closed lately, and not made again since
    /// (a link clicked opens it again).
    static var undoable: [PortForward] {
        let up = Set(PortForwarder.shared.all.map(\.id))
        return recent.filter { !up.contains($0.id) }
    }

    static func undoable(on destination: String) -> [PortForward] {
        undoable.filter { $0.destination == destination }
    }

    /// Close `forward`: ssh is asked off the main thread, and the undo is
    /// there once it's gone. A sheet on `window` says why undoing failed.
    static func close(_ forward: PortForward, window: NSWindow?) {
        work.async { [weak window] in
            guard PortForwarder.shared.close(id: forward.id) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { closed(forward, window: window) } }
        }
    }

    /// Undo the close of the forward `id` names, from its list's Undo.
    static func undo(_ id: String) {
        guard let entry = entries[id] else { return }
        CloseUndo.shared.undo(entry)
    }

    private static func closed(_ forward: PortForward, window: NSWindow?) {
        // Nothing to undo into with none of its host's windows up (one made
        // by `+forward`, or the last one closing): Undo could only fail.
        guard CloseUndo.shared.enabled, hostIsShown(forward.destination) else { return }
        // Made again and closed again before its last undo ended: the
        // newer close is the one to undo.
        if let older = entries[forward.id] { CloseUndo.shared.discard(older) }
        forget(forward.id)
        let entry = CloseUndo.shared.closed(L10n.t("Close Forward"), restore: { [weak window] in
            forget(forward.id)
            reopen(forward, window: window)
            return { [weak window] in close(forward, window: window) }
        }, expire: { forget(forward.id) })
        entries[forward.id] = entry
        recent.append(forward)
        announce()
    }

    private static func forget(_ id: String) {
        guard entries.removeValue(forKey: id) != nil || recent.contains(where: { $0.id == id }) else { return }
        recent.removeAll { $0.id == id }
        announce()
    }

    /// Asked for again off the main thread. With its host's windows gone
    /// it isn't, and if they go meanwhile it's taken back: a forward is for
    /// those panes, and nothing else would close it.
    private static func reopen(_ forward: PortForward, window: NSWindow?) {
        guard hasWindows(forward.destination) else {
            // (Not inside Edit ▸ Undo: a modal alert there runs the undo stack's timers mid-undo.)
            return DispatchQueue.main.async {
                MainActor.assumeIsolated { failed(forward, L10n.t("Its host's windows are closed."), window: window) }
            }
        }
        work.async { [weak window] in
            do {
                let made = try PortForwarder.shared.reopen(forward)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !hasWindows(forward.destination) else { return }
                        work.async { _ = PortForwarder.shared.close(id: made.id) }
                    }
                }
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DispatchQueue.main.async { MainActor.assumeIsolated { failed(forward, why, window: window) } }
            }
        }
    }

    /// One of the host's windows is up (a probe has no app's list: its own is).
    private static func hostIsShown(_ destination: String) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return true }
        return app.allControllers.contains { $0.host?.destination == destination && $0.window?.isVisible == true }
    }

    /// The host still has a window, shown or kept for Undo Close.
    private static func hasWindows(_ destination: String) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return true }
        return app.allControllers.contains { $0.host?.destination == destination }
    }

    private static func failed(_ forward: PortForward, _ why: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(format: L10n.t("Couldn't forward %@ again"), forward.title)
        alert.informativeText = why
        if let window, window.isVisible, window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// The lists follow the forwarder's own notification.
    private static func announce() {
        NotificationCenter.default.post(name: PortForwarder.changed, object: nil)
    }
}
