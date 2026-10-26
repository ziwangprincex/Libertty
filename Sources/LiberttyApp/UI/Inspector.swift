import AppKit
import CPty

/// The window's right column (Otty's inspector): the focused pane's working
/// directory with quick actions, its git branch and changes, the processes
/// running under its shell, and the ports they listen on.
final class InspectorViewController: NSViewController {
    weak var controller: TerminalWindowController?

    private let stack = NSStackView()
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let editorButton = NSButton()
    private let gitSection = NSStackView()
    private lazy var gitPanel = GitPanelView()
    private let processList = NSStackView()
    private let portList = NSStackView()
    private let processSection = NSStackView()
    private let portSection = NSStackView()
    private let idleHint = NSTextField(wrappingLabelWithString:
        "Nothing is running in this pane. Programs it starts, and the ports they listen on (a dev server, say), show up here.")
    private var timer: Timer?
    private var directory: String?
    private var shellPID: pid_t?

    /// The window's frame color behind the column, opaque over the system
    /// sidebar material (Tern's one surface), translucent with the window.
    func apply(frame: RGB, opacity: Double) {
        view.wantsLayer = true
        view.layer?.backgroundColor = frame.nsColor.withAlphaComponent(opacity).cgColor
    }

    override func loadView() {
        let view = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 18, right: 14)

        pathLabel.font = .systemFont(ofSize: 13)
        pathLabel.isSelectable = true
        pathLabel.lineBreakMode = .byCharWrapping
        let editor = Self.editor
        editorButton.title = "Open in \(editor?.name ?? "Editor")"
        configureLink(editorButton, symbol: "arrow.up.forward.square", action: #selector(openInEditor(_:)))
        editorButton.isHidden = editor == nil

        gitSection.orientation = .vertical
        gitSection.alignment = .leading
        gitSection.spacing = 6
        gitSection.addArrangedSubview(Self.header("Git"))
        gitPanel.onShowAllChanges = { [weak self] in self?.showChanges(nil) }
        gitPanel.onOpenGit = { [weak self] in self?.controller?.openGit() }
        gitPanel.onOpenDiff = { [weak self] url, title in self?.controller?.openDocumentInSplit(url, displayName: title) }
        // Outside a repository the section goes with the panel: no "Git"
        // header over nothing.
        gitPanel.onAvailabilityChange = { [weak self] available in self?.gitSection.isHidden = !available }
        gitSection.addArrangedSubview(gitPanel)

        for list in [processList, portList, processSection, portSection] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
        }
        processSection.addArrangedSubview(Self.header("Processes"))
        processSection.addArrangedSubview(processList)
        portSection.addArrangedSubview(Self.header("Ports"))
        portSection.addArrangedSubview(portList)
        idleHint.font = .systemFont(ofSize: 12)
        idleHint.textColor = .tertiaryLabelColor

        stack.addArrangedSubview(Self.header("Working Directory"))
        stack.addArrangedSubview(pathLabel)
        stack.setCustomSpacing(10, after: pathLabel)
        stack.addArrangedSubview(link("Copy Path", "doc.on.doc", #selector(copyPath(_:))))
        stack.addArrangedSubview(link("Reveal in Finder", "folder", #selector(revealInFinder(_:))))
        stack.addArrangedSubview(editorButton)
        stack.addArrangedSubview(spacer(14))
        stack.addArrangedSubview(gitSection)
        stack.addArrangedSubview(spacer(14))
        stack.addArrangedSubview(portSection)
        stack.addArrangedSubview(processSection)
        stack.addArrangedSubview(idleHint)
        stack.setCustomSpacing(18, after: portSection)

        let scroll = NSScrollView()
        let document = FlippedView()
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            gitPanel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            idleHint.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
        ])
        self.view = view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        timer?.invalidate()
        // Processes and ports change on their own; poll gently while shown.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshProcesses() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    /// The focused pane changed, or its directory did.
    func show(directory: String?, shellPID: pid_t?) {
        let moved = directory != self.directory
        self.directory = directory
        self.shellPID = shellPID
        guard isViewLoaded, view.window != nil else { return }
        if moved { refresh() } else { refreshProcesses() }
    }

    private func refresh() {
        pathLabel.stringValue = directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "—"
        refreshGit()
        refreshProcesses()
    }

    /// A prompt in the focused pane: what the command did shows now.
    func refreshGitAtPrompt() {
        gitPanel.refreshSoon()
    }

    // MARK: Git

    private func refreshGit() {
        gitSection.isHidden = directory == nil
        gitPanel.show(directory: directory)
    }

    // MARK: Processes and ports

    private var processGeneration = 0

    private func refreshProcesses() {
        processGeneration += 1
        guard let shellPID else {
            processSection.isHidden = true
            portSection.isHidden = true
            idleHint.isHidden = false
            return
        }
        // Every process under the shell, its name and its sockets: kernel
        // calls by the dozen for a busy pane (Claude Code and its tools), so
        // not on the main thread. The newest scan wins.
        let generation = processGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.scan(shellPID)
            DispatchQueue.main.async {
                guard let self, self.processGeneration == generation else { return }
                self.show(processes: found.processes, ports: found.ports)
            }
        }
    }

    private static func scan(_ shellPID: pid_t) -> (processes: [String], ports: [(UInt16, String)]) {
        var pids = [pid_t](repeating: 0, count: 256)
        let n = Int(libertty_proc_descendants(shellPID, &pids, Int32(pids.count)))
        var processes: [String] = []
        var ports: [(UInt16, String)] = []
        for pid in [shellPID] + pids.prefix(n) {
            let name = Self.name(of: pid)
            if pid != shellPID, !name.isEmpty { processes.append("\(name)  \(pid)") }
            var buf = [UInt16](repeating: 0, count: 32)
            let count = Int(libertty_proc_listening_ports(pid, &buf, Int32(buf.count)))
            for port in buf.prefix(count) where !ports.contains(where: { $0.0 == port }) { ports.append((port, name)) }
        }
        return (processes, ports)
    }

    private func show(processes: [String], ports: [(UInt16, String)]) {
        // Only what exists: an idle shell shows one quiet line, not empty headers.
        setRows(processList, processes)
        processSection.isHidden = processes.isEmpty
        portSection.isHidden = ports.isEmpty
        idleHint.isHidden = !processes.isEmpty || !ports.isEmpty
        let shown = portList.arrangedSubviews.map(\.tag)
        let sorted = ports.sorted { $0.0 < $1.0 }
        if shown != sorted.map({ Int($0.0) }) {
            portList.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (port, name) in sorted {
                let b = link("localhost:\(port)  ·  \(name)", "network", #selector(openPort(_:)))
                b.tag = Int(port)
                b.toolTip = "Open http://localhost:\(port) beside the terminal (⌥-click: in your browser)"
                portList.addArrangedSubview(b)
            }
        }
    }

    private static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        libertty_proc_name(pid, &buf, Int32(buf.count))
        return String(cString: buf)
    }

    private func setRows(_ list: NSStackView, _ rows: [String], dim: Bool = false) {
        let current = list.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        guard current != rows else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.forEach { list.addArrangedSubview(Self.row($0, dim: dim)) }
    }

    // MARK: Actions

    @objc private func copyPath(_ sender: Any?) {
        guard let directory else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory, forType: .string)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let directory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
    }

    @objc private func openInEditor(_ sender: Any?) {
        guard let directory, let editor = Self.editor else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openPort(_ sender: NSButton) {
        guard let url = URL(string: "http://localhost:\(sender.tag)") else { return }
        // The page beside the terminal that serves it; ⌥: the browser.
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true || controller == nil {
            NSWorkspace.shared.open(url)
        } else {
            controller?.openDocumentInSplit(url)
        }
    }

    /// The focused pane's repository changes (`git diff`), beside it.
    @objc private func showChanges(_ sender: Any?) {
        guard let directory else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitDiff.write(directory: directory)
            DispatchQueue.main.async {
                switch result {
                case .success(let file): self?.controller?.openDocumentInSplit(file, displayName: "git diff")
                case .failure(let why): NSAlert(error: why).runModal()
                }
            }
        }
    }

    /// The first code editor installed, for "Open in …".
    private static let editor: (name: String, url: URL)? = {
        let candidates = [("com.microsoft.VSCode", "VS Code"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
                          ("dev.zed.Zed", "Zed"), ("com.sublimetext.4", "Sublime Text"), ("com.apple.dt.Xcode", "Xcode")]
        for (id, name) in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (name, url) }
        }
        return nil
    }()

    // MARK: Pieces

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func row(_ text: String, dim: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = dim ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = dim ? .tertiaryLabelColor : .labelColor
        return label
    }

    private func link(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.title = title
        configureLink(b, symbol: symbol, action: action)
        return b
    }

    private func configureLink(_ b: NSButton, symbol: String, action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.isBordered = false
        b.font = .systemFont(ofSize: 13)
        b.contentTintColor = Accent.color
        b.target = self
        b.action = action
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
