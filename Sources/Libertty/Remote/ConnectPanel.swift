import AppKit
import LiberttyCore

/// File ▸ Connect to Host… (⇧⌘K): pick an ssh destination (from
/// ~/.ssh/config, or recent ones, or typed: `devbox`, `me@10.0.0.5`), and
/// Libertty sets the host up and opens a window whose sessions run there.
@MainActor
final class ConnectPanel: NSObject, NSWindowDelegate {
    static let shared = ConnectPanel()

    private var panel: NSPanel?
    private let field = NSComboBox()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private var connecting: String?

    private static let recentKey = "RecentHosts"

    static var recentHosts: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func remember(_ destination: String) {
        var list = recentHosts.filter { $0 != destination }
        list.insert(destination, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: recentKey)
    }

    /// Show it; with `destination`, connect to that right away (`libertty +connect`).
    func show(destination: String? = nil) {
        let panel = self.panel ?? makePanel()
        field.removeAllItems()
        field.addItems(withObjectValues: Self.recentHosts + SSHConfig.hosts().filter { !Self.recentHosts.contains($0) })
        if let destination { field.stringValue = destination } else if field.stringValue.isEmpty {
            field.stringValue = Self.recentHosts.first ?? ""
        }
        if connecting == nil { setStatus("", busy: false) }
        if !panel.isVisible { panel.center() }
        Probe.activateApp()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if destination != nil { connect(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Connect to Host"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let label = NSTextField(labelWithString: "Host:")
        field.placeholderString = "devbox, user@server, or a Host from ~/.ssh/config"
        field.completes = true
        field.numberOfVisibleItems = 12
        let hint = NSTextField(wrappingLabelWithString:
            "Uses your ssh setup. Programs keep running on the host when the connection drops or Libertty quits.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded

        let row = NSStackView(views: [label, field])
        row.spacing = 8
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 6
        statusRow.alignment = .top
        let buttons = NSStackView(views: [NSView(), cancel, connectButton])
        buttons.spacing = 10
        let stack = NSStackView(views: [row, hint, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: row.widthAnchor),
            hint.widthAnchor.constraint(equalTo: row.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        panel.contentView = content
        self.panel = panel
        return panel
    }

    private func setStatus(_ text: String, busy: Bool, error: Bool = false) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connectButton.isEnabled = !busy
        field.isEnabled = !busy
    }

    @objc private func connect(_ sender: Any?) {
        let destination = field.stringValue.trimmingCharacters(in: .whitespaces)
        // An ssh destination, never an option (or anything ssh would read as one).
        guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.contains(where: \.isWhitespace) else {
            return setStatus("Enter a host name, user@host, or a Host from ~/.ssh/config.", busy: false, error: true)
        }
        guard connecting == nil else { return }
        connecting = destination
        setStatus("Connecting to \(destination)…", busy: true)
        let host = RemoteHost.named(destination)
        host.retry()
        let restoreWindows = ConfigStore.shared.config.windowSaveState != .never && !Restoration.isPrivate
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try host.prepare { message in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.setStatus(message, busy: true) } }
            } }
            // The windows its sessions were last shown in (on this Mac or
            // another), and which sessions run there: asked here, off the
            // main thread, while the link is fresh.
            var held = Restoration.Held.unknown
            var sessions: [SessionInfo]?
            if case .success = result, restoreWindows {
                held = Restoration.held(at: host.address, local: false, timeout: 5)
                sessions = DaemonClient.sessions(address: host.address)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(destination, host: host, result: result, held: restoreWindows ? (held, sessions) : nil)
                }
            }
        }
    }

    private func finish(_ destination: String, host: RemoteHost, result: Result<RemoteHost.Info, Error>,
                        held: (Restoration.Held, [SessionInfo]?)?) {
        guard connecting == destination else { return }
        connecting = nil
        switch result {
        case .success:
            setStatus("", busy: false)
            Self.remember(destination)
            panel?.orderOut(nil)
            (NSApp.delegate as? AppDelegate)?.openWindows(on: host, held: held)
        case .failure(let error):
            setStatus((error as? LocalizedError)?.errorDescription ?? "\(error)", busy: false, error: true)
        }
    }

    @objc private func cancel(_ sender: Any?) {
        // A connection under way finishes in the background; nothing opens.
        connecting = nil
        setStatus("", busy: false)
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { connecting = nil }
}

/// Host names from ~/.ssh/config (and the files it includes), for the
/// Connect to Host list. Patterns (`*`, `?`, `!`) aren't hosts one can pick.
enum SSHConfig {
    static func hosts() -> [String] {
        var seen = Set<String>(), result: [String] = []
        var visited = Set<String>()
        func read(_ path: String, depth: Int) {
            guard depth < 5, visited.insert(path).inserted,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#") else { continue }
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                guard let keyword = words.first?.lowercased() else { continue }
                if keyword == "host" {
                    for name in words.dropFirst() where !name.contains(where: { "*?!".contains($0) }) {
                        if seen.insert(name).inserted { result.append(name) }
                    }
                } else if keyword == "include" {
                    for pattern in words.dropFirst() { includes(pattern).forEach { read($0, depth: depth + 1) } }
                }
            }
        }
        read((NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config"), depth: 0)
        return result
    }

    /// An Include argument: relative to ~/.ssh, with shell globs.
    private static func includes(_ pattern: String) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/" + path) }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }
}
