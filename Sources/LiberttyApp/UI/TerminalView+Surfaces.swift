import AppKit
import CGhosttyVt

/// A pane's surfaces (SurfaceProtocol) and lenses (CommandLenses) as views
/// over it: placed after each frame on the rows they belong to, so they
/// scroll with the output; events go to the program that drew them.
final class SurfaceOverlay {
    private weak var pane: TerminalView?
    private var views: [String: SurfaceView] = [:]
    private var chips: [Int: LensChip] = [:]
    /// When the rows under inline surfaces were last checked, and the
    /// output they were checked against: looked at again only when it moves.
    private var checkedOutput: UInt64 = .max
    private var checkedAt: CFTimeInterval = 0

    init(pane: TerminalView) { self.pane = pane }

    func start() {
        pane?.session.surfaces.onChange = { [weak self] in self?.reload() }
    }

    var isShowing: Bool { !views.isEmpty || !chips.isEmpty }

    /// The store changed: views made, updated, taken away.
    func reload() {
        guard let pane else { return }
        let store = pane.session.surfaces
        let ids = Set(store.surfaces.map(\.spec.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for surface in store.surfaces {
            if let view = views[surface.spec.id] {
                view.update(surface)
                continue
            }
            let view = SurfaceView(surface)
            let id = surface.spec.id
            view.onEvent = { [weak self] fields in self?.tell(id, fields) }
            view.onClose = { [weak pane] in
                guard let pane else { return }
                pane.session.surfaces.remove(id, pane.session)
            }
            view.onOpenLink = { [weak pane] url in
                pane?.open(TerminalLink(url: url.absoluteString, spans: [], explicit: true))
            }
            view.onDone = { [weak pane] in
                guard let pane else { return }
                pane.window?.makeFirstResponder(pane)
            }
            view.isHidden = true
            pane.addSubview(view)
            view.layer?.zPosition = 3
            views[id] = view
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
        let lensIDs = Set(store.lenses.map(\.id))
        for (id, chip) in chips where !lensIDs.contains(id) {
            chip.removeFromSuperview()
            chips[id] = nil
        }
        for lens in store.lenses where chips[lens.id] == nil {
            let chip = LensChip(lens: lens)
            chip.onOpen = { [weak self, weak chip] in
                guard let self, let chip else { return }
                self.showList(lens, from: chip)
            }
            chip.isHidden = true
            pane.addSubview(chip)
            chip.layer?.zPosition = 3
            chips[lens.id] = chip
        }
        checkedOutput = .max
        layout()
    }

    /// Where everything goes now (after a frame, a resize, a scroll).
    func layout() {
        guard let pane, isShowing else { return }
        let session = pane.session
        let cell = pane.cellSizePoints, pad = pane.padding
        // The rows under inline surfaces: looked at again when output came
        // (a tenth of a second at most), not every frame of a scroll.
        let output = session.outputMark.count, now = CACurrentMediaTime()
        let check = output != checkedOutput && now - checkedAt > 0.1
        if check {
            checkedOutput = output
            checkedAt = now
        }
        let placed = session.surfaces.placed(session, checkRows: check)
        var shown = Set<String>()
        let width = max(0, pane.bounds.width - pad.left - pad.right - 6)
        for p in placed {
            guard let view = views[p.surface.spec.id] else { continue }
            shown.insert(p.surface.spec.id)
            let frame: NSRect
            switch p.surface.spec.placement {
            case .inline(let rows, _):
                let y = pad.top + CGFloat(p.row ?? 0) * cell.height - pane.smoothOffset
                frame = NSRect(x: pad.left, y: y, width: width, height: CGFloat(rows) * cell.height)
            case .overlay(let position, let cols, let rows):
                let inset: CGFloat = 8
                let bounds = pane.bounds.insetBy(dx: inset, dy: inset)
                var w = min(CGFloat(cols) * cell.width, bounds.width), h = min(CGFloat(rows) * cell.height, bounds.height)
                if position == .full { w = bounds.width; h = bounds.height }
                let x: CGFloat, y: CGFloat
                switch position {
                case .top: (x, y) = (bounds.midX - w / 2, bounds.minY)
                case .bottom: (x, y) = (bounds.midX - w / 2, bounds.maxY - h)
                case .center: (x, y) = (bounds.midX - w / 2, bounds.midY - h / 2)
                case .topRight: (x, y) = (bounds.maxX - w, bounds.minY)
                case .bottomRight: (x, y) = (bounds.maxX - w, bounds.maxY - h)
                case .full: (x, y) = (bounds.minX, bounds.minY)
                }
                frame = NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
            }
            if view.frame != frame { view.frame = frame }
            view.isHidden = !frame.intersects(pane.bounds)
        }
        for (id, view) in views where !shown.contains(id) { view.isHidden = true }
        // Lenses: at the right end of their command's line, in view.
        var lensShown = Set<Int>()
        for (lens, row) in session.surfaces.placedLenses(session) {
            guard let chip = chips[lens.id] else { continue }
            lensShown.insert(lens.id)
            let size = chip.fittingSize
            let y = pad.top + CGFloat(row) * cell.height - pane.smoothOffset + (cell.height - size.height) / 2
            chip.frame = NSRect(x: pane.bounds.width - pad.right - size.width - 22, y: y.rounded(), width: size.width, height: size.height)
            chip.isHidden = false
        }
        for (id, chip) in chips where !lensShown.contains(id) { chip.isHidden = true }
    }

    /// An event for the program, while it's still the one that drew it.
    private func tell(_ id: String, _ fields: [String: Any]) {
        guard let pane, pane.session.surfaces.mayTell(id, pane.session) else { return }
        pane.session.surfaceInput(SurfaceProtocol.event(fields))
    }

    // MARK: Lenses

    /// A command finished: what it printed, read by the lens for it.
    func commandFinished(_ command: String) {
        guard let pane, pane.session.host == nil else { return }  // a host's paths aren't this Mac's
        let session = pane.session
        // Nor those of a shell reached through ssh in this pane; and paths
        // are read from the command's folder, which must be known.
        let front = session.surfaceProgramName(session.foregroundGroup).lowercased()
        guard !["ssh", "mosh", "mosh-client", "autossh", "et"].contains(front), let directory = session.workingDirectory else { return }
        let enabled = ConfigStore.shared.config.commandLenses
        guard !enabled.isEmpty, CommandLenses.kind(for: command).map(enabled.contains) == true else { return }
        guard let (text, row) = session.surfaces.lastOutput(session) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CommandLenses.lens(command: command, output: text, enabled: enabled)
            DispatchQueue.main.async {
                guard let self, let pane = self.pane else { return }
                guard let result else {
                    if let row { session.withTerminal { _ in ghostty_tracked_grid_ref_free(row) } }
                    return
                }
                session.surfaces.addLens(result, anchor: row, directory: directory, session)
                _ = pane
            }
        }
    }

    private var popover: NSPopover?

    private func showList(_ lens: SurfaceStore.Lens, from chip: NSView) {
        guard let pane else { return }
        popover?.close()
        let list = LensList(lens: lens)
        list.onOpen = { [weak pane] item in
            guard let pane else { return }
            let url = URL(fileURLWithPath: item.path, relativeTo: lens.directory.map { URL(fileURLWithPath: $0, isDirectory: true) })
            pane.open(TerminalLink(url: url.absoluteURL.absoluteString, spans: [], explicit: false, line: item.line, column: item.column))
        }
        list.onShowGit = { [weak pane] in _ = ActionDispatcher.perform(.openGit, in: pane) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = list
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY)
        self.popover = popover
    }

    // MARK: For the UI probe

    var surfaceIDs: [String] { views.keys.sorted() }

    func surfaceView(_ id: String) -> SurfaceView? { views[id] }

    /// Whether the surface `id` is on screen (laid out over its rows, in view).
    func isShown(_ id: String) -> Bool { views[id].map { !$0.isHidden } ?? false }

    var lensChips: [LensChip] { chips.keys.sorted().compactMap { chips[$0] } }
}

/// A lens's chip on its command's line: "3 errors · Open as list".
final class LensChip: NSButton {
    let lens: SurfaceStore.Lens
    var onOpen: (() -> Void)?

    init(lens: SurfaceStore.Lens) {
        self.lens = lens
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Radius.chip
        let symbol = switch lens.result.kind {
        case .gitStatus: "arrow.triangle.branch"
        case .diagnostics: lens.result.items.contains { $0.tag == "error" } ? "exclamationmark.octagon" : "exclamationmark.triangle"
        case .search: "magnifyingglass"
        }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        contentTintColor = .secondaryLabelColor
        attributedTitle = NSAttributedString(string: " " + lens.result.summary + " · " + L10n.t("Open as List") + " ", attributes: [
            .font: Typeface.ui(11, .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        toolTip = lens.result.command
        setAccessibilityLabel(lens.result.summary + ", " + L10n.t("Open as List"))
        target = self
        action = #selector(tapped)
        colorize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorize()
    }

    private func colorize() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }

    var summary: String { lens.result.summary }

    @objc private func tapped() { onOpen?() }
}

/// A lens's items as a list (in a popover from its chip): grouped, each
/// opening where it points; a git status's files can be staged from here.
final class LensList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let lens: SurfaceStore.Lens
    var onOpen: ((CommandLenses.Item) -> Void)?
    var onShowGit: (() -> Void)?

    private enum Row { case group(String), item(CommandLenses.Item) }
    private var rows: [Row] = []
    private let table = NSTableView()
    private var staged: [String: Bool] = [:]

    init(lens: SurfaceStore.Lens) {
        self.lens = lens
        super.init(nibName: nil, bundle: nil)
        var groups: [String] = []
        var byGroup: [String: [CommandLenses.Item]] = [:]
        for item in lens.result.items {
            if byGroup[item.group] == nil { groups.append(item.group) }
            byGroup[item.group, default: []].append(item)
        }
        for group in groups {
            rows.append(.group(group + "  (\(byGroup[group]!.count))"))
            rows += byGroup[group]!.map(Row.item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open(_:))
        table.action = #selector(open(_:))
        table.setAccessibilityLabel(lens.result.summary)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let header = NSTextField(labelWithString: lens.result.command)
        header.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        if lens.result.kind == .gitStatus {
            let git = NSButton(title: L10n.t("Show in Git"), target: self, action: #selector(showGit))
            git.bezelStyle = .rounded
            stack.addArrangedSubview(git)
        }
        let height = min(420, CGFloat(rows.count) * 22 + 8)
        scroll.heightAnchor.constraint(equalToConstant: max(44, height)).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        view = stack
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let label = NSTextField(labelWithString: title)
            label.font = Typeface.ui(11.5, .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .item(let item):
            let box = NSStackView()
            box.orientation = .horizontal
            box.spacing = 8
            let place = item.line.map { "\(item.path):\($0)" + (item.column.map { ":\($0)" } ?? "") } ?? item.path
            let text = NSMutableAttributedString(string: place, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor,
            ])
            if !item.label.isEmpty {
                text.append(NSAttributedString(string: "  " + item.label, attributes: [
                    .font: Typeface.ui(12), .foregroundColor: item.tag == "error" ? NSColor.systemRed : NSColor.secondaryLabelColor,
                ]))
            }
            let label = NSTextField(labelWithAttributedString: text)
            label.lineBreakMode = .byTruncatingTail
            box.addArrangedSubview(label)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if lens.result.kind == .gitStatus, item.tag != "conflict" {
                let staging = staged[item.path] ?? (item.group == L10n.t("Staged"))
                let button = NSButton(title: staging ? L10n.t("Unstage") : L10n.t("Stage"), target: self, action: #selector(stage(_:)))
                button.bezelStyle = .inline
                button.controlSize = .small
                button.tag = row
                box.addArrangedSubview(button)
            }
            box.setAccessibilityLabel(place + " " + item.label)
            return box
        }
    }

    @objc private func open(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, case .item(let item) = rows[row] else { return }
        onOpen?(item)
    }

    @objc private func showGit() { onShowGit?() }

    /// `git add` (or `git restore --staged`) in the command's folder.
    @objc private func stage(_ sender: NSButton) {
        guard case .item(let item) = rows[sender.tag], let dir = lens.directory else { return }
        let staging = !(staged[item.path] ?? (item.group == L10n.t("Staged")))
        let args = staging ? ["add", "--", item.path] : ["restore", "--staged", "--", item.path]
        sender.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitCLI.execute(args, in: dir)
            DispatchQueue.main.async {
                guard let self else { return }
                sender.isEnabled = true
                if case .failure(let why) = result { NSAlert(error: why).runModal(); return }
                self.staged[item.path] = staging
                sender.title = staging ? L10n.t("Unstage") : L10n.t("Stage")
            }
        }
    }
}
