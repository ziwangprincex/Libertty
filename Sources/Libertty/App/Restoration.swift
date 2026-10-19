import AppKit
import LiberttyCore

/// The windows, tabs and splits to bring back at the next launch
/// (`window-save-state`), in ~/Library/Application Support/Libertty/windows.json.
/// Panes name their liberttyd session; a pane whose session is gone gets a new
/// shell in the directory it was in.
struct SavedState: Codable {
    var version = 1
    var windows: [SavedWindow] = []
    /// When it was saved: of two copies (the file, liberttyd's), the newer
    /// one is what the user last saw.
    var savedAt: Double?
}

struct SavedWindow: Codable {
    var frame: String
    var sidebar: Bool
    var inspector: Bool
    var fontSize: Double?
    var selected: Int
    var tabs: [SavedTab]
    /// The ssh destination the window's sessions run on (nil: this Mac).
    var host: String?

    /// Whether any of its panes' sessions is among `live`: a window whose
    /// programs have all ended isn't worth bringing back as fresh shells.
    func livesIn(_ live: Set<String>) -> Bool {
        func walk(_ pane: SavedPane?) -> Bool {
            guard let pane else { return false }
            if let id = pane.session, live.contains(id) { return true }
            return pane.children?.contains(where: walk) ?? false
        }
        return tabs.contains { walk($0.panes) || ($0.parked ?? []).contains { walk($0.pane) } }
    }

    /// What of it Connect to Host brings back: nil unless one of its
    /// sessions runs there with no window showing it (`detached`). A
    /// session some window shows gets a fresh shell in its place rather
    /// than a second window on it; another Mac's documents (`documents`
    /// false) stay on that Mac.
    func forConnect(detached: Set<String>, documents: Bool) -> SavedWindow? {
        guard livesIn(detached) else { return nil }
        var copy = self
        copy.tabs = []
        for (i, tab) in tabs.enumerated() {
            if tab.document != nil, !documents { continue }
            var kept = tab
            if tab.document == nil {
                guard let panes = tab.panes?.keeping(detached, documents: documents) else { continue }
                kept.panes = panes
                // Parked panes come back only if their session is there to attach to.
                kept.parked = tab.parked?.compactMap { entry in
                    entry.pane.keeping(detached, documents: documents).flatMap { $0.session != nil ? SavedParked(pane: $0, anchor: nil, side: entry.side, card: entry.card, corner: entry.corner) : nil }
                }
                // Leaf numbers count the documents that stayed behind.
                if !documents { kept.focused = nil; kept.zoomed = nil }
            }
            if i == selected { copy.selected = copy.tabs.count }
            copy.tabs.append(kept)
        }
        copy.selected = min(copy.selected, max(0, copy.tabs.count - 1))
        return copy.tabs.isEmpty ? nil : copy
    }
}

struct SavedTab: Codable {
    var title: String?
    var paneTitle: String?
    var document: String?
    var panes: SavedPane?
    /// Leaf index (reading order) of the focused / zoomed pane.
    var focused: Int?
    var zoomed: Int?
    /// Panes parked (taken out of the split, running on): where each stood.
    var parked: [SavedParked]?
    /// The workspace (named set of tabs) it belongs to; nil: the only one.
    /// A window's tabs are saved grouped by workspace, in order.
    var workspace: String?
    /// The front tab of its workspace.
    var front: Bool?
}

struct SavedParked: Codable {
    var pane: SavedPane
    /// The leaf (reading order) it stood beside, and on which side.
    var anchor: Int?
    var side: String?
    /// Shown live in a corner of the split, and which corner.
    var card: Bool?
    var corner: String?
}

struct SavedPane: Codable {
    // A leaf: a terminal…
    var session: String?
    var directory: String?
    /// Its own text size (⌘+/⌘− are per pane); nil: the window's.
    var fontSize: Double?
    // …or a document beside one…
    // …or a split.
    var axis: String?
    var ratio: Double?
    var children: [SavedPane]?

    init(session: String? = nil, directory: String? = nil, document: String? = nil,
         axis: String? = nil, ratio: Double? = nil, children: [SavedPane]? = nil) {
        self.session = session
        self.directory = directory
        self.document = document
        self.axis = axis
        self.ratio = ratio
        self.children = children
    }

    var document: String?

    /// This pane with sessions outside `detached` dropped (a fresh shell in
    /// their folder instead), and documents only with `documents`. Nil when
    /// nothing of it is left.
    func keeping(_ detached: Set<String>, documents: Bool) -> SavedPane? {
        if let children {
            let kept = children.compactMap { $0.keeping(detached, documents: documents) }
            guard kept.count == children.count else { return kept.first }
            var copy = self
            copy.children = kept
            return copy
        }
        if document != nil { return documents ? self : nil }
        var copy = self
        if let id = session, !detached.contains(id) { copy.session = nil }
        return copy
    }
}

enum Restoration {
    static var url: URL {
        // Test runs keep their own, so they never replace the user's layout.
        if let path = ProcessInfo.processInfo.environment["LIBERTTY_STATE_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Libertty/windows.json")
    }

    /// Where the layout was saved when Libertty was called Lumen (read once,
    /// until Libertty saves its own).
    private static var earlierURL: URL? {
        guard !isPrivate else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lumen/windows.json")
    }

    private static var lastWritten: Data?

    static func load() -> SavedState? {
        guard let data = (try? Data(contentsOf: url)) ?? earlierURL.flatMap({ try? Data(contentsOf: $0) }) else { return nil }
        lastWritten = data
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    /// This Mac, to a liberttyd that keeps layouts for several: a random
    /// name made once (no hardware identifier leaves the Mac). Kept per
    /// machine (ByHost preferences): a Mac set up from another's backup or by
    /// Migration Assistant makes its own instead of passing for the other.
    static let clientID: String = {
        // A test's own (`LIBERTTY_CLIENT_ID`): a probe never takes this Mac's.
        if let id = ProcessInfo.processInfo.environment["LIBERTTY_CLIENT_ID"], !id.isEmpty { return id }
        let key = "LayoutClientID" as CFString
        let app = (Bundle.main.bundleIdentifier ?? "dev.libertty.terminal") as CFString
        if let id = CFPreferencesCopyValue(key, app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? String {
            return id
        }
        let id = UUID().uuidString
        CFPreferencesSetValue(key, id as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return id
    }()

    /// Write the current layout if it changed since the last write — to the
    /// file, and each machine's windows to that machine's liberttyd too
    /// (GoRex: the server holds the layout): a host's windows then come back
    /// on any Mac that connects to it, and this Mac's after losing the file.
    static func save(_ controllers: [TerminalWindowController]) {
        let windows = controllers.compactMap { $0.savedState() }
        var state = SavedState(windows: windows)
        // The layout without its time, to tell whether anything changed.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let unstamped = try? encoder.encode(state), unstamped != lastUnstamped else { return }
        lastUnstamped = unstamped
        state.savedAt = Date().timeIntervalSince1970
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { lastWritten = data }
        guard !isPrivate else { return }
        var byHost: [String: [SavedWindow]] = [:]
        for window in windows { byHost[window.host ?? "", default: []].append(window) }
        // A machine whose last window closed is told so, once.
        for host in storedHosts where byHost[host] == nil { byHost[host] = [] }
        storedHosts = Set(byHost.filter { !$0.value.isEmpty }.keys)
        // Without session persistence this Mac's liberttyd keeps nothing of
        // its own; a host whose layout couldn't be read keeps what it has.
        if !Persistence.enabled { byHost[""] = nil }
        for host in unreadHosts { byHost[host] = nil }
        for (host, windows) in byHost {
            // The same as last handed over there, its time aside: nothing to send.
            let same = (try? encoder.encode(SavedState(windows: windows))) ?? Data()
            guard same != handedOver[host] else { continue }
            handedOver[host] = same
            // Empty: no windows there any more.
            let payload = windows.isEmpty ? Data()
                : (try? JSONEncoder().encode(SavedState(windows: windows, savedAt: state.savedAt))) ?? Data()
            LayoutStore.shared.store(payload, host: host)
        }
    }

    private static var lastUnstamped: Data?
    /// The machines this app shows windows on: one whose last window closes
    /// is told so.
    private static var storedHosts: Set<String> = []
    /// What each machine was last given, without its time.
    private static var handedOver: [String: Data] = [:]
    /// A machine didn't take what it was given.
    static func notHandedOver(_ host: String) { handedOver[host] = nil }
    /// Hosts whose liberttyd couldn't say what it keeps when this Mac
    /// connected: the windows open here may not be all there are, so what
    /// they keep stays, until a connect reads it.
    static var unreadHosts: Set<String> = []

    /// A test run (`LIBERTTY_STATE_FILE`) keeps its layout to itself: in its
    /// file only, never handed to liberttyd nor taken from it.
    static var isPrivate: Bool { ProcessInfo.processInfo.environment["LIBERTTY_STATE_FILE"] != nil }

    /// What a liberttyd keeps: a layout (`mine`: this Mac's own entry), or
    /// none. `unknown`: it couldn't be asked in time — unlike none, that
    /// mustn't let the windows it may hold be replaced.
    enum Held {
        case layout(SavedState, mine: Bool)
        case none
        case unknown
    }

    /// Ask a liberttyd for this Mac's layout: `local`, this Mac's own
    /// liberttyd and its own windows; else a host's — this Mac's entry there,
    /// or the latest any Mac stored (a host's windows follow you to another
    /// Mac; a Mac's own windows never go to another). Blocks for up to about
    /// twice `timeout`: call it off the main thread for a host.
    static func held(at address: DaemonAddress, local: Bool, timeout: Double) -> Held {
        switch DaemonClient.request(.loadLayout, json: ["client": clientID, "local": local], needing: "layout",
                                    timeout: timeout, address: address) {
        case .unanswered: return .unknown
        // An older liberttyd keeps none.
        case .unsupported: return .none
        case .answered(let frame):
            guard frame.kind == .result, let (header, body) = frame.headerAndBody else { return .unknown }
            guard !body.isEmpty, let state = try? JSONDecoder().decode(SavedState.self, from: body) else { return .none }
            return .layout(state, mine: header["client"] as? String == clientID)
        }
    }
}

/// Hands layouts to liberttyds, one machine at a time and newest last: a
/// slow or unreachable host holds one request at most, never a pile of
/// them, and a store that failed is tried again with the next change.
final class LayoutStore {
    static let shared = LayoutStore()
    private let queue = DispatchQueue(label: "libertty.layout-store", qos: .utility)
    /// Per host: what's waiting to go, and whether a request is out.
    private var waiting: [String: Data] = [:]
    private var busy: Set<String> = []

    func store(_ payload: Data, host: String) {
        queue.async {
            self.waiting[host] = payload
            self.next(host)
        }
    }

    /// On `queue`.
    private func next(_ host: String) {
        guard !busy.contains(host), let payload = waiting.removeValue(forKey: host) else { return }
        busy.insert(host)
        DispatchQueue.global(qos: .utility).async {
            // Not taken (the host out of reach, a takeover under way): it
            // goes again with the next change of the layout.
            if !Self.send(payload, host: host) { DispatchQueue.main.async { Restoration.notHandedOver(host) } }
            self.queue.async {
                self.busy.remove(host)
                // A newer one came meanwhile: that one goes now.
                self.next(host)
            }
        }
    }

    private static func send(_ payload: Data, host: String) -> Bool {
        // This Mac's own windows to its own liberttyd; a host's over a link
        // that's up — a save never starts an ssh login (or a password
        // prompt) of its own.
        let address = host.isEmpty ? DaemonAddress.local : RemoteHost.named(host).quietAddress
        let body = payload.withUnsafeBytes {
            Connection.headed(["client": Restoration.clientID, "local": host.isEmpty], body: $0)
        }
        guard case .answered(let reply) = DaemonClient.request(.storeLayout, payload: body, needing: "layout",
                                                              timeout: 3, address: address) else { return false }
        return reply.json["ok"] as? Bool == true
    }
}

extension TerminalWindowController {
    func savedState() -> SavedWindow? {
        guard let window, !tabs.isEmpty else { return nil }
        syncActiveWorkspace()
        let named = workspaceNames.count > 1 || workspaceNames.first != Self.defaultWorkspaceName
        var selectedIndex = 0
        var saved: [SavedTab] = []
        for (w, workspace) in workspaceTabs.enumerated() {
            for tab in workspace {
                if tab === selectedTab { selectedIndex = saved.count }
                var entry = Self.savedTab(tab)
                if named { entry.workspace = workspaceNames[w] }
                if tab === workspaceFrontTabs[w] { entry.front = true }
                saved.append(entry)
            }
        }
        // Full screen saves the frame it will come back to.
        let frame = window.styleMask.contains(.fullScreen) ? (savedNonFullScreenFrame ?? window.frame) : window.frame
        return SavedWindow(frame: NSStringFromRect(frame), sidebar: isSidebarShown, inspector: isInspectorShown,
                           fontSize: Double(focusedTerminal.fontSize),
                           selected: selectedIndex, tabs: saved, host: host?.destination)
    }

    private static func savedTab(_ tab: TerminalTab) -> SavedTab {
        if let doc = tab.document { return SavedTab(title: tab.titleOverride, document: Self.saved(doc.pageURL)) }
            let leaves = tab.container?.views ?? []
            return SavedTab(title: tab.titleOverride.isEmpty ? nil : tab.titleOverride,
                            paneTitle: tab.paneTitleOverride.isEmpty ? nil : tab.paneTitleOverride,
                            panes: tab.container.map { Self.save($0.root) },
                            focused: tab.focusedLeaf.flatMap { f in leaves.firstIndex { $0 === f } },
                            zoomed: tab.container?.zoomed.flatMap { z in leaves.firstIndex { $0 === z } },
                            parked: tab.parked.isEmpty ? nil : tab.parked.map { entry in
                                SavedParked(pane: Self.save(PaneNode(pane: entry.pane)),
                                            anchor: entry.anchor.flatMap { a in leaves.firstIndex { $0 === a } },
                                            side: entry.side.rawValue,
                                            card: entry.showsCard ? true : nil,
                                            corner: entry.showsCard ? (tab.container?.card?.corner.rawValue ?? entry.cardCorner) : nil)
                            })
    }

    /// A file's path, or a web page's address.
    private static func saved(_ url: URL) -> String { url.isFileURL ? url.path : url.absoluteString }

    /// What a saved document names, if it can still be shown.
    fileprivate static func document(_ saved: String) -> URL? {
        if saved.hasPrefix("http://") || saved.hasPrefix("https://") || saved == "about:blank" { return URL(string: saved) }
        if saved.hasPrefix(Blocks.scheme + "://") { return URL(string: saved).flatMap { DocumentView.canShow($0) ? $0 : nil } }
        let url = URL(fileURLWithPath: saved)
        return FileManager.default.fileExists(atPath: saved) && DocumentView.canShow(url) ? url : nil
    }

    private static func save(_ node: PaneNode) -> SavedPane {
        if let doc = node.pane as? DocumentView { return SavedPane(document: Self.saved(doc.pageURL)) }
        if let pane = node.pane as? TerminalView {
            var saved = SavedPane(session: pane.session.persistentID, directory: pane.session.workingDirectory)
            saved.fontSize = Double(pane.fontSize)
            return saved
        }
        return SavedPane(axis: node.axis == .horizontal ? "h" : "v", ratio: Double(node.ratio),
                         children: node.children.map(save))
    }

    /// A window as it was saved. Panes attach to their liberttyd session when it
    /// is in `live`; others start a new shell (in `start()`). Nil when
    /// nothing in it can be shown any more.
    static func restore(_ saved: SavedWindow, live: Set<String>, config: Config) -> TerminalWindowController? {
        var unstarted: [(TerminalView, String?)] = []
        let windowFontSize = saved.fontSize.map { CGFloat($0) }

        let host = saved.host.map(RemoteHost.named)
        func pane(_ leaf: SavedPane) -> TerminalView? {
            // Its own size if it had one (layouts saved before were per window).
            let fontSize = leaf.fontSize.map { CGFloat($0) } ?? windowFontSize
            if let host {
                // Reattaches when the host answers (or starts a new shell
                // there if it lost the session); never waits for the network here.
                let size = GridSize(cols: UInt16(clamping: config.windowColumns), rows: UInt16(clamping: config.windowRows),
                                    widthPx: 0, heightPx: 0)
                guard let session = try? TerminalSession.reattach(leaf.session ?? Persistence.newSessionID(), host: host,
                                                                  size: size, workingDirectory: leaf.directory, config: config),
                      let view = try? TerminalView(session: session, config: config) else { return nil }
                if let fontSize { view.fontSize = fontSize }
                return view
            }
            if let id = leaf.session, live.contains(id), let session = try? TerminalSession.attach(id, config: config),
               let view = try? TerminalView(session: session, config: config) {
                if let fontSize { view.fontSize = fontSize }
                return view
            }
            guard let view = try? makePane(config: config, cols: config.windowColumns, rows: config.windowRows) else { return nil }
            if let fontSize { view.fontSize = fontSize }
            var dir: ObjCBool = false
            let directory = leaf.directory.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue ? $0 : nil }
            unstarted.append((view, directory))
            return view
        }

        // Saved leaves in order (focused/zoomed index them), nil where one couldn't come back.
        var restored: [NSView?] = []
        func node(_ saved: SavedPane) -> PaneNode? {
            if let children = saved.children, children.count == 2 {
                let a = node(children[0]), b = node(children[1])
                guard let a, let b else { return a ?? b }
                return PaneNode(axis: saved.axis == "v" ? .vertical : .horizontal,
                                ratio: CGFloat(min(0.9, max(0.1, saved.ratio ?? 0.5))), first: a, second: b)
            }
            if let path = saved.document {
                guard let url = TerminalWindowController.document(path) else {
                    restored.append(nil)
                    return nil
                }
                let doc = DocumentView(url: url, theme: config.resolvedTheme, renderMarkdown: config.markdownRendered)
                restored.append(doc)
                return PaneNode(pane: doc)
            }
            let view = pane(saved)
            restored.append(view)
            return view.map { PaneNode(pane: $0) }
        }

        var tabs: [TerminalTab] = []
        var selected = 0
        for (i, t) in saved.tabs.enumerated() {
            if i == saved.selected { selected = tabs.count }
            if let path = t.document {
                guard let url = TerminalWindowController.document(path) else { continue }
                let doc = TerminalTab(document: DocumentView(url: url, theme: config.resolvedTheme,
                                                             renderMarkdown: config.markdownRendered))
                doc.restoredWorkspace = t.workspace
                doc.restoredSelected = t.front == true
                tabs.append(doc)
                continue
            }
            // A split needs a terminal; documents alone don't make a terminal tab.
            restored = []
            guard let root = t.panes.flatMap(node), root.leaves.contains(where: { $0 is TerminalView }) else { continue }
            func leaf(_ i: Int?) -> NSView? { i.flatMap { restored.indices.contains($0) ? restored[$0] : nil } }
            let tab = TerminalTab(root: root, focused: leaf(t.focused))
            tab.titleOverride = t.title ?? ""
            tab.paneTitleOverride = t.paneTitle ?? ""
            tab.restoredWorkspace = t.workspace
            tab.restoredSelected = t.front == true
            for entry in t.parked ?? [] {
                guard entry.pane.session != nil || entry.pane.directory != nil, let view = pane(entry.pane) else { continue }
                view.isParked = true
                tab.parked.append(TerminalTab.Parked(pane: view, anchor: leaf(entry.anchor),
                                                     side: entry.side.flatMap(SplitContainerView.Direction.init(rawValue:)) ?? .right,
                                                     showsCard: entry.card == true, cardCorner: entry.corner))
            }
            if let zoomed = leaf(t.zoomed), root.leaves.count > 1 { tab.container?.toggleZoom(zoomed) }
            tabs.append(tab)
        }
        // A window needs a terminal tab; documents alone don't make one.
        guard tabs.contains(where: \.isTerminal) else { return nil }
        selected = min(selected, tabs.count - 1)

        let frame = NSRectFromString(saved.frame)
        let controller = TerminalWindowController(restoring: tabs, selected: selected, frame: frame.width > 0 ? frame : nil,
                                                  showSidebar: saved.sidebar, showInspector: saved.inspector, config: config)
        controller.markRestored(unstarted: unstarted)
        if let host { controller.bind(to: host) }
        return controller
    }
}
