import AppKit

/// Forward Port… and Share a Port with HOST…, the palette's two pages for
/// the ports a host's window carries (`PortForwarder`). Only a window whose
/// panes run on a host has them: on this Mac there is nothing to carry.
extension CommandPalette {
    /// A port on the host, reachable here: type a port, a `host:port` the
    /// host can reach, or a URL one of its panes printed. The forwards it
    /// already holds are listed below, and Return closes one.
    static func forwardPage(on host: RemoteHost, controller: TerminalWindowController?) -> Page {
        let asked = L10n.t("Which port on %@: a number, a host:port it reaches, or a URL")
        // The window is held weakly, as `items()` holds it: a row runs
        // once the palette is gone.
        return Page(placeholder: asked.replacingOccurrences(of: "%@", with: host.destination)) { [weak controller] typed in
            var items: [Item] = []
            let text = typed.trimmingCharacters(in: .whitespaces)
            if let target = PortForward.target(text) {
                let what = PortForward.on("\(target.remoteHost):\(target.remote)", host.destination)
                items.append(Item(title: L10n.t("Forward %@").replacingOccurrences(of: "%@", with: what),
                                  subtitle: L10n.t(target.url == nil ? "Reachable on this Mac afterwards."
                                                   : "Opens here once it's forwarded."),
                                  symbol: "arrow.left.arrow.right") {
                    open(text, on: host, controller: controller)
                })
            } else if !text.isEmpty {
                items.append(Item(title: L10n.t("Not a port, a host:port or a URL"),
                                  subtitle: L10n.t("Try 5173, db:5432, or a link one of its panes printed"),
                                  symbol: "exclamationmark.triangle", kind: .option, inert: true) {})
            }
            items += closingRows(on: host, controller: controller)
            if items.isEmpty {
                items.append(Item(title: L10n.t("Nothing is forwarded yet."),
                                  subtitle: L10n.t("A port on the host, open on this Mac while this window is."),
                                  symbol: "", kind: .option, inert: true) {})
            }
            return items
        }
    }

    /// A port of this Mac's, reachable on the host under the same number
    /// (`ssh -R`): what a program there needs from a server running here.
    static func sharePage(on host: RemoteHost, controller: TerminalWindowController?) -> Page {
        let asked = L10n.t("A port on this Mac to share with %@").replacingOccurrences(of: "%@", with: host.destination)
        return Page(placeholder: asked) { [weak controller] typed in
            var items: [Item] = []
            let text = typed.trimmingCharacters(in: .whitespaces)
            if let port = Int(text), (1...65535).contains(port) {
                items.append(Item(title: L10n.t("Share port %@").replacingOccurrences(of: "%@", with: text),
                                  subtitle: PortForward.on("\(port)", host.destination) + " → 127.0.0.1:\(port)",
                                  symbol: "arrow.up.arrow.down") {
                    share(port, on: host, controller: controller)
                })
            } else if !text.isEmpty {
                items.append(Item(title: L10n.t("Not a port"), subtitle: L10n.t("A number from 1 to 65535"),
                                  symbol: "exclamationmark.triangle", kind: .option, inert: true) {})
            }
            items += closingRows(on: host, controller: controller)
            if items.isEmpty {
                items.append(Item(title: L10n.t("Nothing is shared yet."),
                                  subtitle: L10n.t("A port on this Mac, open on the host while this window is."),
                                  symbol: "", kind: .option, inert: true) {})
            }
            return items
        }
    }

    /// The host's forwards, each a row that closes it, and those closed a
    /// moment ago, each a row that opens it again (Edit ▸ Undo does too).
    private static func closingRows(on host: RemoteHost, controller: TerminalWindowController?) -> [Item] {
        let window = controller?.window
        let closing = PortForwarder.shared.forwards(on: host.destination).map { forward in
            var item = Item(title: L10n.t("Close") + " " + forward.title, subtitle: forward.localizedSummary, symbol: "xmark.circle") { [weak window] in
                MainActor.assumeIsolated { ForwardClosing.close(forward, window: window) }
            }
            item.manualOnly = true
            return item
        }
        // (Pages are made and run on the main thread.)
        let undoing = MainActor.assumeIsolated { ForwardClosing.undoable(on: host.destination) }.map { forward in
            var item = Item(title: L10n.t("Undo Close") + " " + forward.title, subtitle: forward.localizedSummary,
                            symbol: "arrow.uturn.backward") {
                MainActor.assumeIsolated { ForwardClosing.undo(forward.id) }
            }
            item.manualOnly = true
            return item
        }
        return closing + undoing
    }

    /// ssh is asked off the main thread; the page it leads to opens here,
    /// and what went wrong is a sheet on the window that asked.
    private static func open(_ target: String, on host: RemoteHost, controller: TerminalWindowController?) {
        work(on: controller) {
            let (_, url) = try PortForwarder.shared.open(target: target, on: host)
            if let url { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
    }

    private static func share(_ port: Int, on host: RemoteHost, controller: TerminalWindowController?) {
        work(on: controller) { _ = try PortForwarder.shared.share(local: port, on: host) }
    }

    /// The window is held weakly: it may have closed while ssh answered,
    /// and then there is nobody to tell.
    private static func work(on controller: TerminalWindowController?, _ body: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak controller] in
            do {
                try body()
            } catch {
                DispatchQueue.main.async { controller?.showError(error) }
            }
        }
    }
}
