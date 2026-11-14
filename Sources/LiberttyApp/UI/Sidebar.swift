import AppKit

/// What the sidebar shows for one tab.
struct SidebarTabInfo: Equatable {
    var title: String
    /// Where it runs, shown fainter after the name ("…/src/app", an ssh host).
    var detail: String = ""
    var status: ProgramStatusStore.State?
    var paneCount: Int
    /// Panes taken out of the split, still running (Park Pane).
    var parked = 0
    /// One of its panes fills it (the others are there, out of sight).
    var zoomed = false
    var documentURL: URL? = nil
    /// OSC 9;4 or OSC 7501 progress of the tab's busiest pane.
    var progress: TerminalProgress? = nil
    /// The tab's programs as tiles, focused pane's last (Rex's stacked tiles).
    var tiles: [ProgramTile] = []
    /// What the tab did while you weren't looking at it (GoRex).
    var news: TabNews = .none
    /// The row's second line (`sidebar-rows = comfortable`): what its
    /// program reports, else its branch and changes, else its folder.
    var subtitle = ""
    /// A split tab's panes, listed from its pane count.
    var panes: [PaneSummary] = []
}

/// One pane of a split tab, as its row's list shows it.
struct PaneSummary: Equatable {
    var id: String
    var program: String
    /// Its branch and changes, else its folder.
    var place: String
    var status: ProgramStatusStore.State?
    var focused: Bool
}

/// Which tabs the sidebar lists by what their programs are doing (Rex's
/// activity filter): every tab, those at work, those waiting for you, or
/// those with something to see.
enum TabActivity: String, CaseIterable {
    case all, working, waiting, attention

    var title: String {
        switch self {
        case .all: return L10n.t("All Tabs")
        case .working: return L10n.t("Working")
        case .waiting: return L10n.t("Waiting for You")
        case .attention: return L10n.t("Finished or Failed")
        }
    }

    /// As the filter's placeholder says it: "Filter waiting tabs".
    var word: String { self == .attention ? "finished" : rawValue }

    func includes(_ tab: SidebarTabInfo) -> Bool {
        switch self {
        case .all: return true
        case .working: return tab.status == .working || tab.progress != nil
        case .waiting: return tab.status == .blocked
        case .attention: return tab.status == .done || tab.status == .error || tab.news == .attention
        }
    }
}

/// A background tab's news, shown as a small mark beside its title.
enum TabNews: Equatable {
    case none
    /// A program in it printed just now.
    case printing
    /// Something finished or rang the bell there since you last looked.
    case attention
}

/// A tab's state at a glance: a progress ring (determinate or spinning),
/// or a symbol for programs that need you, finished, or failed.
final class StatusBadge: NSView {
    enum Look: Equatable {
        case none
        case ring(percent: Int?, color: NSColor)
        case symbol(String, NSColor)
        case dot(NSColor)
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let image = NSImageView()
    private var look = Look.none

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = 1.8
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        image.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     image.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 13, height: 13) }

    func show(_ new: Look) {
        guard new != look else { return }
        look = new
        arc.removeAllAnimations()
        track.isHidden = true
        arc.isHidden = true
        image.isHidden = true
        switch new {
        case .none:
            break
        case .ring(let percent, _):
            track.isHidden = false
            arc.isHidden = false
            updateRingColors()
            if let percent {
                arc.strokeStart = 0
                arc.strokeEnd = CGFloat(max(3, percent)) / 100
            } else {
                // Indeterminate: a quarter arc going round (still with reduced motion).
                arc.strokeStart = 0
                arc.strokeEnd = 0.28
                spinIfIndeterminate()
            }
        case .symbol(let name, let color):
            image.isHidden = false
            image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image.contentTintColor = color
        case .dot(let color):
            image.isHidden = false
            image.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 6, weight: .regular)
            image.contentTintColor = color
            return
        }
        image.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        needsLayout = true
    }

    /// An indeterminate ring goes round — again after the badge was out of
    /// its window (Core Animation drops the spin then: the top tabs' bar
    /// replaced, a row reused).
    private func spinIfIndeterminate() {
        guard case .ring(nil, _) = look, !Motion.reduced, arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    /// The ring's colors in the badge's own light or dark (a layer's color is resolved once).
    private func updateRingColors() {
        guard case .ring(_, let color) = look else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = color.withAlphaComponent(0.25).cgColor
            arc.strokeColor = color.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { spinIfIndeterminate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRingColors()
    }

    override func layout() {
        super.layout()
        // Each layer covers the badge, rotating about its center (the spin);
        // the circle starts at 12 o'clock and runs clockwise.
        let r = min(bounds.width, bounds.height) / 2 - 1.5
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: r,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, arc] {
            l.bounds = bounds
            l.position = CGPoint(x: bounds.midX, y: bounds.midY)
            l.path = path
        }
    }
}

/// The window's left column, as in Otty and Tern: the tabs of this window,
/// then the files of the focused pane's working directory.
final class SidebarViewController: NSViewController {
    weak var controller: TerminalWindowController?
    /// The tab whose row is being dragged.
    private weak var draggedTab: TerminalTab?

    private let tabsTable = NSTableView()
    private let tabsScroll = NSScrollView()
    private var tabsHeight: NSLayoutConstraint!
    private var tabs: [SidebarTabInfo] = []
    /// The groups the tabs are in (`sidebar-group`; none: one list), whether
    /// they have headers, and those folded away.
    private var groups: [SidebarGroup] = []
    private var headers = false
    private var collapsed: Set<String> = []
    /// The table's rows: the tabs, and with headers the groups' headers and
    /// their sessions not open here. Ungrouped, row N is tab N.
    private var rows: [SidebarRow] = []
    /// Each tab's row in the table; nil while its group is folded away.
    private var tableRows: [Int?] = []
    /// Each tab's place in the list as shown (grouped, not the tabs' own order).
    private var listed: [Int] = []

    private let files = FileTreeView()
    /// The file tree (the UI probe).
    var fileTree: FileTreeView { files }
    private let folderLabel = NSTextField(labelWithString: "")
    private let disclosure = NSButton()
    private var filesButtons: [NSView] = []
    private var tabsCapWithFiles: NSLayoutConstraint!
    private var tabsCapAlone: NSLayoutConstraint!
    private var filesShown = true
    /// The tabs' section (header, rows, filter) and where the files start
    /// and end with it and without it (`tab-bar = top`).
    private var tabsSection: [NSView] = []
    private var filesBelowTabs: [NSLayoutConstraint] = []
    private var filesAlone: [NSLayoutConstraint] = []
    private var tabsShown = true

    /// The column's own color: none now (`opacity` 0), the window's
    /// backdrop shows (Rex's sidebar is the window's surface).
    func apply(frame: RGB, opacity: Double) {
        view.wantsLayer = true
        view.layer?.backgroundColor = frame.nsColor.withAlphaComponent(opacity).cgColor
    }

    override func loadView() {
        let view = NSView()

        // "Tabs" and how many (Tern's session header); a new tab comes from
        // the toolbar's +.
        let tabsHeader = Self.header("Tabs")
        tabsTitle = tabsHeader
        tabCount.font = Typeface.hint
        tabCount.textColor = .tertiaryLabelColor
        // The workspace menu: which named set of tabs this is, and the others.
        let workspaces = Self.iconButton("square.stack.3d.up", "Workspaces", target: self, action: #selector(showWorkspaces(_:)))
        // (Rex shows no count: the rows say it.)
        tabCount.isHidden = true
        let tabsRow = NSStackView(views: [tabsHeader, NSView(), tabCount, workspaces])

        tabsTable.headerView = nil
        tabsTable.backgroundColor = .clear
        tabsTable.style = .plain
        tabsTable.rowHeight = Layout.rowHeight
        tabsTable.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tabsTable.selectionHighlightStyle = .regular
        tabsTable.addTableColumn(NSTableColumn(identifier: .init("tab")))
        tabsTable.dataSource = self
        tabsTable.delegate = self
        tabsTable.target = self
        tabsTable.action = #selector(tabClicked(_:))
        // Double-click a tab to rename it in place, as Finder renames a file.
        tabsTable.doubleAction = #selector(renameTabInPlace(_:))
        tabsTable.menu = tabMenu()
        tabsTable.registerForDraggedTypes([.liberttyTab])
        tabsTable.draggingDestinationFeedbackStyle = .gap
        tabsScroll.documentView = tabsTable
        tabsScroll.drawsBackground = false
        tabsScroll.hasVerticalScroller = true
        tabsScroll.autohidesScrollers = true

        // The chevron folds the file tree away (sidebar-files), as Xcode's sections do.
        disclosure.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Hide Files")
        disclosure.isBordered = false
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        disclosure.target = self
        disclosure.action = #selector(toggleFiles(_:))
        disclosure.toolTip = "Hide Files"
        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
        folderIcon.contentTintColor = .secondaryLabelColor
        // A section header like "Tabs" above (Tern's sidebar groups).
        folderLabel.font = Typeface.header
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reveal = Self.iconButton("arrow.up.forward.app", "Reveal in Finder", target: self, action: #selector(revealRoot(_:)))
        let up = Self.iconButton("arrow.turn.left.up", "Enclosing Folder", target: self, action: #selector(goUp(_:)))
        let refresh = Self.iconButton("arrow.clockwise", "Refresh", target: self, action: #selector(refresh(_:)))
        let more = Self.iconButton("ellipsis", "More", target: self, action: #selector(showMore(_:)))
        let filesRow = NSStackView(views: [disclosure, folderIcon, folderLabel, NSView(), up, refresh, reveal, more])
        filesRow.spacing = 6
        filesRowView = filesRow
        filesButtons = [up, refresh, reveal, more]
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleFiles(_:)))
        click.numberOfClicksRequired = 2
        filesRow.addGestureRecognizer(click)

        // Space, not a line, between the sections: the column is one surface.
        let divider = NSView()

        files.onOpenTerminalHere = { [weak self] path in self?.controller?.newTab(workingDirectory: path) }
        files.onInsert = { [weak self] text in self?.controller?.insertInTerminal(text) }
        files.onOpenDocument = { [weak self] url in self?.controller?.openDocument(url) }
        files.onOpenDocumentInSplit = { [weak self] url in self?.controller?.openDocumentInSplit(url) }
        files.onEditDocument = { [weak self] url in self?.controller?.openDocument(url, edit: true) }
        files.onChangeDirectory = { [weak self] path in self?.controller?.changeDirectory(to: path) }

        // Filter the tabs by name (Tern's field at the column's foot).
        filter.onChange = { [weak self] text in self?.filterTabs(text) }
        filter.onSubmit = { [weak self] in self?.selectFirstMatch() }
        filter.onActivity = { [weak self] activity in self?.show(activity: activity) }
        filter.onEscape = { [weak self] in self?.showFilter(false) }

        // The top row (the traffic lights' line): the window's buttons
        // while the sidebar is on the left (`setChrome`); Rex's.
        chromeRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeRow)
        // The foot (Rex's): filter the tabs, a new workspace, connect to a host.
        let filterButton = WindowChrome.button("line.3.horizontal.decrease.circle", "Filter Tabs", self, #selector(toggleFilter(_:)))
        let newWorkspace = WindowChrome.button("square.stack.3d.up.badge.automatic", "New Workspace…", self, #selector(newWorkspace(_:)))
        let connect = WindowChrome.button("network", "Connect to Host…", self, #selector(connectToHost(_:)))
        for b in [filterButton, newWorkspace, connect] { b.symbolConfiguration = .init(pointSize: 13, weight: .regular) }
        foot.addArrangedSubview(filterButton)
        foot.addArrangedSubview(NSView())
        foot.addArrangedSubview(newWorkspace)
        foot.addArrangedSubview(connect)
        foot.orientation = .horizontal
        foot.spacing = 2
        filter.isHidden = true
        for v in [tabsRow, tabsScroll, divider, filesRow, files, filter, foot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        _ = guide
        tabsHeight = tabsScroll.heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            chromeRow.topAnchor.constraint(equalTo: view.topAnchor),
            chromeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeRow.heightAnchor.constraint(equalToConstant: WindowChrome.bandHeight),
            // Rex's session header: 25 high under the top row, then the rows.
            tabsRow.topAnchor.constraint(equalTo: chromeRow.bottomAnchor, constant: 3),
            tabsRow.heightAnchor.constraint(equalToConstant: 25),
            tabsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 19),
            tabsRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabsScroll.topAnchor.constraint(equalTo: tabsRow.bottomAnchor, constant: 1),
            tabsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            tabsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            tabsHeight,
            divider.topAnchor.constraint(equalTo: tabsScroll.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            filesRow.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            filesRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            filesRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            files.topAnchor.constraint(equalTo: filesRow.bottomAnchor, constant: 4),
            files.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            files.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            files.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -6),
            filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            filter.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
            filter.heightAnchor.constraint(equalToConstant: 28),
            foot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            foot.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            foot.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            foot.heightAnchor.constraint(equalToConstant: 28),
        ])
        tabsHeight.priority = .defaultHigh
        // With the files folded away the tabs may use nearly the whole column.
        tabsCapWithFiles = tabsScroll.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.45)
        tabsCapAlone = filesRow.bottomAnchor.constraint(lessThanOrEqualTo: foot.topAnchor, constant: -10)
        tabsCapWithFiles.isActive = true
        tabsCapAlone.isActive = true
        tabsSection = [tabsRow, tabsScroll, divider, foot]
        filesBelowTabs = view.constraints.filter {
            ($0.firstItem === filesRow && $0.firstAttribute == .top) || ($0.firstItem === files && $0.firstAttribute == .bottom)
        }
        filesAlone = [filesRow.topAnchor.constraint(equalTo: chromeRow.bottomAnchor, constant: 3),
                      files.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)]
        self.view = view
    }

    /// The tabs listed here, or along the window's top (`tab-bar = top`):
    /// then the column is the files'.
    func show(tabsShown shown: Bool) {
        guard shown != tabsShown else { return }
        tabsShown = shown
        tabsSection.forEach { $0.isHidden = !shown }
        if shown {
            NSLayoutConstraint.deactivate(filesAlone)
            NSLayoutConstraint.activate(filesBelowTabs + [tabsCapAlone])
            tabsCapWithFiles.isActive = filesShown
        } else {
            NSLayoutConstraint.deactivate(filesBelowTabs + [tabsCapAlone, tabsCapWithFiles])
            NSLayoutConstraint.activate(filesAlone)
            finishRename()
        }
    }

    private weak var filesRowView: NSView?
    private let chromeRow = NSView()
    private let foot = NSStackView()
    private var chromeViews: (leading: NSView?, trailing: NSView?) = (nil, nil)
    private var chromeMid: CGFloat = 23
    private var chromeClearance: CGFloat = 88

    /// The window's buttons on the traffic lights' line (from the top);
    /// nil takes them out. `clearance`: where the leading ones start.
    func setChrome(leading: NSView?, trailing: NSView?, mid: CGFloat, clearance: CGFloat) {
        _ = view
        for old in [chromeViews.leading, chromeViews.trailing] {
            if let old, old !== leading, old !== trailing, old.superview === chromeRow { old.removeFromSuperview() }
        }
        for new in [leading, trailing] {
            guard let new, new.superview !== chromeRow else { continue }
            new.removeFromSuperview()
            new.translatesAutoresizingMaskIntoConstraints = true
            chromeRow.addSubview(new)
        }
        chromeViews = (leading, trailing)
        chromeMid = mid
        chromeClearance = clearance
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let row = chromeRow.bounds
        // The row isn't flipped: its top is maxY.
        let mid = row.height - chromeMid
        if let v = chromeViews.leading {
            let size = v.fittingSize
            v.frame = NSRect(x: chromeClearance, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        if let v = chromeViews.trailing {
            let size = v.fittingSize
            v.frame = NSRect(x: row.width - 9 - size.width, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
        }
    }

    @objc private func toggleFilter(_ sender: Any?) { showFilter(filter.isHidden) }

    /// The field takes the foot's place while the tabs are filtered.
    private func showFilter(_ on: Bool) {
        filter.isHidden = !on
        foot.isHidden = on || !tabsShown
        if on { filter.focus() } else { filter.clear() }
    }

    @objc private func newWorkspace(_ sender: Any?) { _ = ActionDispatcher.perform(.newWorkspace, controller: controller) }
    @objc private func connectToHost(_ sender: Any?) { _ = ActionDispatcher.perform(.connectToHost, controller: controller) }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typeface.header
        label.textColor = .secondaryLabelColor
        return label
    }

    private let tabCount = NSTextField(labelWithString: "")
    private var tabsTitle: NSTextField?

    @objc private func showWorkspaces(_ sender: NSView) { controller?.showWorkspaceMenu(from: sender) }

    /// The header says which workspace these tabs are in, once there are several.
    func show(workspace name: String, of count: Int) {
        // Rex names the session; Libertty's sets of tabs are workspaces.
        tabsTitle?.stringValue = name
    }
    private static let rowSpacing: CGFloat = 2

    // MARK: Filter

    private let filter = TabFilterField()
    /// What the filter field holds, lowercased; empty shows every tab.
    private var filterText = ""
    /// Which tabs show by their programs' state (the field's filter menu).
    private(set) var activity = TabActivity.all

    /// Rows stay in the table when filtered out, folded to no height: a row
    /// is still its tab's index, for every action that takes one.
    private func matches(_ tab: SidebarTabInfo) -> Bool {
        activity.includes(tab) && (filterText.isEmpty || tab.title.lowercased().contains(filterText)
            || tab.detail.lowercased().contains(filterText))
    }

    /// The tabs the filters leave showing, by index (not those in a folded group).
    var shownRows: [Int] { tabs.indices.filter { matches(tabs[$0]) && tableRow(ofTab: $0) != nil } }

    /// Whether the filters show tab `row`.
    func shows(row: Int) -> Bool { tabs.indices.contains(row) && matches(tabs[row]) && tableRow(ofTab: row) != nil }

    /// The headers showing, as they say it (`--ui-probe`): "api · 2 tabs · collapsed · 1 not open here".
    var shownGroups: [String] {
        rows.indices.compactMap { r -> String? in
            guard case .header(let g) = rows[r], shows(tableRow: r) else { return nil }
            let group = groups[g]
            var parts = [group.title, GroupHeaderCell.count(group.tabs.count)]
            if collapsed.contains(group.id) { parts.append("collapsed") }
            if !group.elsewhere.isEmpty { parts.append("\(group.elsewhere.count) not open here") }
            return parts.joined(separator: " · ")
        }
    }

    /// The sessions not open here showing, title and folder (`--ui-probe`).
    var shownElsewhere: [String] {
        rows.indices.compactMap { r -> String? in
            guard case .elsewhere(let g, let k) = rows[r], shows(tableRow: r) else { return nil }
            let s = groups[g].elsewhere[k]
            return [s.title, s.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// Where the row showing `text` is, in the window (`--ui-probe` clicks
    /// it): a header's title, a session's title or folder, a tab's name.
    func windowRect(ofRowShowing text: String) -> NSRect? {
        guard let r = tableRow(showing: text) else { return nil }
        // The whole window laid out first: a row just added grows the
        // table's height constraint, and until the window's next layout
        // the table (and its rows) sit where they were.
        view.window?.contentView?.layoutSubtreeIfNeeded()
        tabsTable.scrollRowToVisible(r)
        tabsTable.layoutSubtreeIfNeeded()
        return tabsTable.convert(tabsTable.rect(ofRow: r), to: nil)
    }

    /// Whether a click at `point` (in the window) would land on the row
    /// showing `text` (`--ui-probe` checks before it clicks).
    func rowShowing(_ text: String, isAt point: NSPoint) -> Bool {
        guard let r = tableRow(showing: text), let content = view.window?.contentView,
              let row = tabsTable.rowView(atRow: r, makeIfNecessary: false),
              let hit = content.hitTest(content.convert(point, from: nil)) else { return false }
        return hit.isDescendant(of: row)
    }

    private func tableRow(showing text: String) -> Int? {
        rows.indices.first { r in
            guard shows(tableRow: r) else { return false }
            switch rows[r] {
            case .header(let g): return groups[g].title == text
            case .elsewhere(let g, let k): return groups[g].elsewhere[k].title == text || groups[g].elsewhere[k].detail == text
            case .tab(let i): return tabs[i].title == text
            }
        }
    }

    /// A session not open here shows with every tab only (it has no
    /// program state to filter by), and when the filter's text is in it.
    private func matches(_ session: ElsewhereSession) -> Bool {
        activity == .all && (filterText.isEmpty || session.title.lowercased().contains(filterText)
            || session.detail.lowercased().contains(filterText))
    }

    /// The rows that aren't tabs' under rows that stay: said again when
    /// their groups changed (a list read again, a group folded), and a
    /// header shown or hidden again when its tabs changed under a filter
    /// (it shows while one of them matches).
    private func refreshOtherRows(groups: [SidebarGroup], collapsed: Set<String>, tabsChanged: Bool) {
        let others = IndexSet(rows.indices.filter { tab(atTableRow: $0) == nil })
        if groups != self.groups || collapsed != self.collapsed {
            self.groups = groups
            self.collapsed = collapsed
            tabsTable.reloadData(forRowIndexes: others, columnIndexes: [0])
            tabsTable.noteHeightOfRows(withIndexesChanged: others)
        } else if tabsChanged, activity != .all || !filterText.isEmpty {
            let headers = IndexSet(others.filter { if case .header = rows[$0] { true } else { false } })
            tabsTable.noteHeightOfRows(withIndexesChanged: headers)
            for r in headers { tabsTable.view(atColumn: 0, row: r, makeIfNecessary: false)?.isHidden = !shows(tableRow: r) }
        } else {
            return
        }
        fitTabsHeight()
    }

    /// Whether the table's row `r` shows: a tab or session the filters
    /// leave, a header with anything left under it (folded or not).
    private func shows(tableRow r: Int) -> Bool {
        guard rows.indices.contains(r) else { return false }
        switch rows[r] {
        case .tab(let i): return tabs.indices.contains(i) && matches(tabs[i])
        case .elsewhere(let g, let k): return matches(groups[g].elsewhere[k])
        case .header(let g):
            return groups[g].tabs.contains { tabs.indices.contains($0) && matches(tabs[$0]) } || groups[g].elsewhere.contains(where: matches)
        }
    }

    /// The tab in the table's row `r`, if it's a tab's.
    private func tab(atTableRow r: Int) -> Int? {
        guard rows.indices.contains(r), case .tab(let i) = rows[r] else { return nil }
        return i
    }

    /// Tab `i`'s row in the table; nil while its group is folded away.
    private func tableRow(ofTab i: Int) -> Int? { tableRows.indices.contains(i) ? tableRows[i] : nil }

    private func height(of row: SidebarRow) -> CGFloat {
        switch row {
        case .tab, .elsewhere: return rowHeight
        case .header: return Self.headerHeight
        }
    }

    private static let headerHeight: CGFloat = 26

    func show(activity: TabActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        filter.show(activity: activity)
        refilter()
    }

    private func filterTabs(_ text: String) {
        filterText = text.trimmingCharacters(in: .whitespaces).lowercased()
        refilter()
    }

    /// The rows again, after a filter changed.
    private func refilter() {
        tabsTable.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
        for row in rows.indices {
            tabsTable.view(atColumn: 0, row: row, makeIfNecessary: false)?.isHidden = !shows(tableRow: row)
        }
        fitTabsHeight()
        placeSelectionCard()
    }

    /// Return in the filter: the first tab it shows (as listed).
    private func selectFirstMatch() {
        guard let row = rows.indices.first(where: { tab(atTableRow: $0) != nil && shows(tableRow: $0) }),
              let i = tab(atTableRow: row) else { return }
        controller?.selectTab(at: i)
        controller?.focusTerminal()
    }

    private func fitTabsHeight() {
        let shown = tabs.filter(matches).count
        let folded = tabs.count - shown
        tabsHeight.constant = rows.indices.reduce(2) { height, r in
            height + (shows(tableRow: r) ? self.height(of: rows[r]) : Self.foldedRowHeight) + Self.rowSpacing
        }
        // How many, and how many of them show while filtered: "1/4".
        tabCount.stringValue = folded > 0 ? "\(shown)/\(tabs.count)" : String(tabs.count)
    }

    private static let foldedRowHeight: CGFloat = 0.01

    /// What a pane listed under a tab's count is picked for.
    enum PaneChoice: String { case focus, zoom, close }

    /// `sidebar-rows`: two lines a row (comfortable), or one (compact).
    private var twoLineRows = true
    private var rowHeight: CGFloat { twoLineRows ? Layout.twoLineRowHeight : Layout.rowHeight }

    func show(twoLineRows on: Bool) {
        guard on != twoLineRows || TabCell.twoLines != on else { return }
        twoLineRows = on
        TabCell.twoLines = on
        tabsTable.rowHeight = rowHeight
        tabsTable.reloadData()
        fitTabsHeight()
        placeSelectionCard()
    }

    static func iconButton(_ symbol: String, _ tip: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        return b
    }

    // MARK: Tabs

    func show(tabs: [SidebarTabInfo], selected: Int, groups: [SidebarGroup] = [], headers: Bool = false, collapsed: Set<String> = []) {
        let layout = SidebarGroups.rows(tabCount: tabs.count, groups: groups, headers: headers, collapsed: collapsed, selected: selected)
        // The same rows in the same places: only what's in them may differ.
        // (A tab may come or go out of sight, in a folded group: then too.)
        let sameRows = layout == rows && headers == self.headers && tabs.count == self.tabs.count
        if let rename = renaming {
            // A name being typed in place: the other rows update around
            // the field. When the rows themselves change (a tab came, went
            // or moved; another was selected) the name is kept first, and
            // keeping it brings the rows up to date. (The groups' headers
            // and sessions changing under the same rows — a list read
            // again, every few seconds — leave the field be; sessions
            // elsewhere coming or going wait for the name, which brings
            // the sidebar up to date as it ends.)
            // The rows and groups the tabs make (a group of sessions elsewhere only comes last).
            func tabsOnly(_ rows: [SidebarRow], _ groups: [SidebarGroup]) -> [SidebarRow] {
                rows.filter {
                    switch $0 {
                    case .elsewhere: return false
                    case .header(let g): return groups.indices.contains(g) && !groups[g].tabs.isEmpty
                    case .tab: return true
                    }
                }
            }
            func tabGroups(_ groups: [SidebarGroup]) -> [SidebarGroup] { groups.filter { !$0.tabs.isEmpty }.map(\.withoutElsewhere) }
            let onlyElsewhereMoved = !sameRows && headers == self.headers && tabs.count == self.tabs.count
                && collapsed == self.collapsed && tabsOnly(layout, groups) == tabsOnly(rows, self.groups)
                && tabGroups(groups) == tabGroups(self.groups)
            if sameRows || onlyElsewhereMoved, selected == rename.row, rename.cell?.isEditing == true,
               let tab = rename.tab, controller?.tab(at: rename.row) === tab {
                let changed = IndexSet(tabs.indices.filter { $0 != rename.row && tabs[$0] != self.tabs[$0] }.compactMap(tableRow(ofTab:)))
                for i in tabs.indices where i != rename.row { self.tabs[i] = tabs[i] }
                if !changed.isEmpty {
                    tabsTable.reloadData(forRowIndexes: changed, columnIndexes: [0])
                    // A row may start or stop matching the filter meanwhile.
                    tabsTable.noteHeightOfRows(withIndexesChanged: changed)
                }
                // (With rows to come or go, the groups stay as the rows are.)
                refreshOtherRows(groups: sameRows ? groups : self.groups, collapsed: collapsed, tabsChanged: !changed.isEmpty)
                if !changed.isEmpty {
                    fitTabsHeight()
                    placeSelectionCard()
                }
                return
            }
            if finishRename() { return }
        }
        if !sameRows {
            // Rows came, went or moved: all of them again (the selection
            // follows below, as the window's, not as a pick).
            self.tabs = tabs
            self.groups = groups
            self.headers = headers
            self.collapsed = collapsed
            rows = layout
            var places = [Int?](repeating: nil, count: tabs.count)
            for (r, row) in layout.enumerated() { if case .tab(let i) = row, places.indices.contains(i) { places[i] = r } }
            tableRows = places
            // Where each tab is as listed (⌘1–⌘9 go by it), folded ones counted.
            listed = Array(repeating: 0, count: tabs.count)
            for (n, i) in (headers ? groups.flatMap(\.tabs) : Array(tabs.indices)).enumerated() where listed.indices.contains(i) {
                listed[i] = n
            }
            syncingSelection = true
            tabsTable.reloadData()
            syncingSelection = false
            fitTabsHeight()
        } else {
            var tabsChanged = false
            if tabs != self.tabs {
                // Only the rows that changed: reloading them all drops the
                // selection, the hover and the rows' spinners.
                let changed = IndexSet(tabs.indices.filter { tabs[$0] != self.tabs[$0] }.compactMap(tableRow(ofTab:)))
                self.tabs = tabs
                tabsTable.reloadData(forRowIndexes: changed, columnIndexes: [0])
                tabsTable.noteHeightOfRows(withIndexesChanged: changed)
                tabsChanged = true
            }
            refreshOtherRows(groups: groups, collapsed: collapsed, tabsChanged: tabsChanged)
            if tabsChanged { fitTabsHeight() }
        }
        let want = tableRow(ofTab: selected) ?? -1
        if tabsTable.selectedRow != want {
            // The window's selection shown, not the user picking a tab: it
            // mustn't select it again (that takes the keyboard to the terminal).
            syncingSelection = true
            if want >= 0 { tabsTable.selectRowIndexes([want], byExtendingSelection: false) } else { tabsTable.deselectAll(nil) }
            syncingSelection = false
        }
        // Brought into view when the selection moves, not at every update
        // (the list scrolled to look for another tab stays where it is).
        if selected != scrolledTo.row || tabs.count != scrolledTo.count {
            scrolledTo = (selected, tabs.count)
            if want >= 0 { tabsTable.scrollRowToVisible(want) }
        }
        placeSelectionCard()
    }

    /// The selection is being set to the window's: no tab to select.
    private var syncingSelection = false
    /// The row last brought into view, and how many there were.
    private var scrolledTo = (row: -1, count: -1)

    /// The selection card sits behind the rows, over the selected one.
    private lazy var selectionCard: SelectionCard = {
        let card = SelectionCard()
        // As wide as the rows when the sidebar's edge is dragged.
        card.autoresizingMask = [.width]
        tabsTable.addSubview(card, positioned: .below, relativeTo: nil)
        return card
    }()

    private func placeSelectionCard() {
        tabsTable.layoutSubtreeIfNeeded()
        let row = tabsTable.selectedRow
        // None for a row the filter folded away.
        let shown = row >= 0 && row < tabsTable.numberOfRows && tab(atTableRow: row) != nil && shows(tableRow: row)
        let rect = shown ? tabsTable.rect(ofRow: row) : .zero
        selectionCard.move(to: rect)
        // Keep it under every row view, including ones added since.
        if tabsTable.subviews.first !== selectionCard {
            tabsTable.addSubview(selectionCard, positioned: .below, relativeTo: nil)
        }
    }

    @objc private func tabClicked(_ sender: Any?) {
        // (A header's and a session's rows take their own clicks.)
        if let i = tab(atTableRow: tabsTable.clickedRow) { controller?.selectTab(at: i) }
    }

    private func tabMenu() -> NSMenu {
        let menu = NSMenu()
        addTabItems(to: menu)
        menu.delegate = self
        return menu
    }

    private func addTabItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Name", action: #selector(resetTabName(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Duplicate Tab", action: #selector(duplicateTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Fork Conversation", action: #selector(forkConversation(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move Up", action: #selector(moveTabUp(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move Down", action: #selector(moveTabDown(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move to New Window", action: #selector(moveTabToNewWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs(_:)), keyEquivalent: "").target = self
    }

    /// A header's menu: fold or unfold it, a tab there, and how to group.
    private func addGroupItems(to menu: NSMenu, _ group: SidebarGroup) {
        let folded = collapsed.contains(group.id)
        menu.addItem(withTitle: L10n.t(folded ? "Expand Group" : "Collapse Group"), action: #selector(toggleMenuGroup(_:)), keyEquivalent: "").target = self
        if controller?.canOpenTab(in: group) == true {
            menu.addItem(withTitle: L10n.t("New Tab Here"), action: #selector(newTabInMenuGroup(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        addGroupingItems(to: menu)
    }

    /// Group Tabs by Project, by Host, or not (`sidebar-group`).
    private func addGroupingItems(to menu: NSMenu) {
        let now = ConfigStore.shared.config.sidebarGroup
        for (mode, title) in [(SidebarGrouping.project, "Group Tabs by Project"), (.host, "Group Tabs by Host"), (.none, "Don't Group Tabs")] {
            let item = menu.addItem(withTitle: L10n.t(title), action: #selector(groupTabs(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == now ? .on : .off
        }
    }

    /// A session's menu: show it here.
    private func addElsewhereItems(to menu: NSMenu) {
        menu.addItem(withTitle: L10n.t("Show in a Tab"), action: #selector(showMenuElsewhere(_:)), keyEquivalent: "").target = self
    }

    /// The header or the session the menu was opened on (as it was then).
    private var menuGroup: SidebarGroup?
    private var menuElsewhere: ElsewhereSession?

    @objc private func toggleMenuGroup(_ sender: Any?) { menuGroup.map { controller?.toggleSidebarGroup($0.id) } }
    @objc private func newTabInMenuGroup(_ sender: Any?) { menuGroup.map { controller?.newTab(in: $0) } }
    @objc private func showMenuElsewhere(_ sender: Any?) { menuElsewhere.map { controller?.showElsewhere($0) } }
    @objc private func groupTabs(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        MainActor.assumeIsolated { _ = SettingsModel.shared.write("sidebar-group", mode) }
    }

    /// The tab the menu was opened on. Its items find its row again when
    /// chosen: tabs may close or move while the menu is open (a program
    /// ending), and the row clicked would then be another tab's.
    private weak var menuTab: TerminalTab?
    private var menuRow: Int {
        guard let tab = menuTab else { return -1 }
        return controller?.tabs.firstIndex { $0 === tab } ?? -1
    }

    /// Rename in place: the row's name becomes an editable field. Return
    /// or clicking away keeps it, Esc goes back, an empty name goes back
    /// to the automatic one (GoRex; Finder's way).
    func beginRename(row: Int) {
        // One at a time: one under way is kept first.
        finishRename()
        guard row >= 0, row < tabs.count, let tab = controller?.tab(at: row), let tableRow = tableRow(ofTab: row),
              let cell = tabsTable.view(atColumn: 0, row: tableRow, makeIfNecessary: true) as? TabCell else { return }
        renameCount += 1
        let token = renameCount
        renaming = Rename(tab: tab, row: row, cell: cell, token: token)
        // The tab itself, not its row: tabs may close or move while the
        // name is being typed.
        cell.beginEditing(current: tab.titleOverride, placeholder: tabs[row].title) { [weak self, weak tab] name, refocus in
            self?.renameEnded(token: token, tab: tab, name: name, refocus: refocus)
        }
    }

    /// The rename under way: whose name, in which row and cell.
    private struct Rename {
        weak var tab: TerminalTab?
        let row: Int
        weak var cell: TabCell?
        let token: Int
    }
    private var renaming: Rename?
    private var renameCount = 0

    /// The field closed with `name` (nil: cancelled). `refocus`: the
    /// keyboard was in it and has nowhere else to go.
    private func renameEnded(token: Int, tab: TerminalTab?, name: String?, refocus: Bool) {
        // One that a newer rename replaced has nothing more to say.
        guard token == renameCount else { return }
        if renaming?.token == token { renaming = nil }
        if let name, let tab { controller?.rename(tab, to: name) }
        controller?.updateSidebar()
        if refocus {
            controller?.focusTerminal()
            return
        }
        // Clicking away put the keyboard somewhere; losing the field any
        // other way (the sidebar folded away) may have left it nowhere.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window, window.firstResponder === window else { return }
            self?.controller?.focusTerminal()
        }
    }

    /// End a rename under way, keeping what was typed. True if there was
    /// one: its end brought the rows up to date.
    @discardableResult
    private func finishRename() -> Bool {
        guard let rename = renaming else { return false }
        guard let cell = rename.cell, cell.isEditing else {
            renaming = nil
            return false
        }
        cell.finishEditing()
        return true
    }

    @objc private func renameTabInPlace(_ sender: Any?) {
        guard let row = tab(atTableRow: tabsTable.clickedRow) else { return }
        controller?.selectTab(at: row)
        beginRename(row: row)
    }

    @objc private func renameTab(_ sender: Any?) {
        let row = menuRow
        guard row >= 0 else { return }
        controller?.selectTab(at: row)
        beginRename(row: row)
    }

    @objc private func resetTabName(_ sender: Any?) {
        let row = menuRow
        if row >= 0 { controller?.renameTab(at: row, to: "") }
    }

    /// The next tab up or down that the filters show, as the rows list
    /// them: Move Up/Down passes the tabs folded away, so the tab moves
    /// where it can be seen — within its group (its project or host is
    /// what puts it there).
    private func shownRow(from row: Int, by step: Int) -> Int? {
        guard row >= 0, var r = tableRow(ofTab: row) else { return nil }
        r += step
        while rows.indices.contains(r) {
            switch rows[r] {
            case .header: return nil
            case .tab(let i) where shows(tableRow: r): return i
            default: r += step
            }
        }
        return nil
    }

    @objc private func moveTabUp(_ sender: Any?) { moveTab(menuRow, by: -1) }

    @objc private func moveTabDown(_ sender: Any?) { moveTab(menuRow, by: 1) }

    /// Tab `i` past the next one shown up or down, among its group's tabs
    /// (their places in the window's order stay theirs: the groups keep
    /// their order).
    private func moveTab(_ i: Int, by step: Int) {
        guard let to = shownRow(from: i, by: step) else { return }
        let group = headers ? groups.first(where: { $0.tabs.contains(i) })?.tabs ?? [] : Array(tabs.indices)
        guard let k = group.firstIndex(of: to) else { return }
        controller?.moveTab(i, within: group, before: step > 0 ? k + 1 : k)
    }

    @objc private func moveTabToNewWindow(_ sender: Any?) {
        let row = menuRow
        guard row >= 0, let tab = controller?.tab(at: row) else { return }
        controller?.moveTabToNewWindow(tab)
    }

    /// The tab's focused pane's agent conversation, carried on in a new pane beside it.
    @objc private func forkConversation(_ sender: Any?) {
        guard let pane = menuTab?.focusedPane else { return }
        controller?.forkConversation(of: pane)
    }

    @objc private func duplicateTab(_ sender: Any?) {
        let row = menuRow
        guard row >= 0 else { return }
        controller?.duplicateTab(at: row)
    }

    @objc fileprivate func closeTab(_ sender: Any?) {
        let row = (sender as? NSButton).map { tab(atTableRow: tabsTable.row(for: $0)) ?? -1 } ?? menuRow
        if row >= 0 { controller?.closeTab(at: row) }
    }

    @objc private func closeOtherTabs(_ sender: Any?) {
        let row = menuRow
        if row >= 0 { controller?.closeOtherTabs(keeping: row) }
    }

    // MARK: Files

    func show(filesShown shown: Bool) {
        guard shown != filesShown else { return }
        filesShown = shown
        files.isHidden = !shown
        filesButtons.forEach { $0.isHidden = !shown }
        // Rex's sidebar is tabs only: with the files off, not even their row.
        filesRowView?.isHidden = !shown
        tabsCapWithFiles.isActive = shown && tabsShown
        disclosure.image = NSImage(systemSymbolName: shown ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: shown ? "Hide Files" : "Show Files")
        disclosure.toolTip = shown ? "Hide Files" : "Show Files"
    }

    @objc private func toggleFiles(_ sender: Any?) {
        ConfigStore.shared.set("sidebar-files", filesShown ? "false" : "true")
    }

    /// The tree follows the focused pane's folder when that changes; a
    /// folder gone up to from it (Enclosing Folder) stays until then, or
    /// until Follow Focused Pane.
    func show(directory: String, showHidden: Bool) {
        guard directory != followed || showHidden != files.showHidden else { return }
        followed = directory
        folderLabel.stringValue = directory == NSHomeDirectory() ? (directory as NSString).lastPathComponent
            : (directory as NSString).lastPathComponent
        folderLabel.toolTip = (directory as NSString).abbreviatingWithTildeInPath
        files.show(root: directory, showHidden: showHidden)
    }

    /// The focused pane's folder, as the tree last followed it.
    private var followed: String?

    /// A prompt in the focused pane: a command may have changed files
    /// anywhere (the tree's watcher sees only the root folder).
    func refreshFilesAtPrompt() { files.refreshAtPrompt() }

    @objc private func revealRoot(_ sender: Any?) {
        guard let root = files.rootPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
    }

    @objc private func goUp(_ sender: Any?) {
        guard let root = files.rootPath, root != "/" else { return }
        files.show(root: (root as NSString).deletingLastPathComponent, showHidden: files.showHidden)
        folderLabel.stringValue = ((files.rootPath ?? "/") as NSString).lastPathComponent
    }

    @objc private func refresh(_ sender: Any?) { files.reload() }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        let hidden = menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHidden(_:)), keyEquivalent: "")
        hidden.target = self
        hidden.state = files.showHidden ? .on : .off
        menu.addItem(withTitle: "Follow Focused Pane", action: #selector(follow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Path", action: #selector(copyRoot(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Tab Here", action: #selector(tabHere(_:)), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleHidden(_ sender: Any?) {
        ConfigStore.shared.set("sidebar-show-hidden-files", files.showHidden ? "false" : "true")
    }

    @objc private func follow(_ sender: Any?) {
        followed = nil
        controller?.updateSidebar(force: true)
    }

    @objc private func copyRoot(_ sender: Any?) {
        guard let root = files.rootPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(root, forType: .string)
    }

    @objc private func tabHere(_ sender: Any?) {
        if let root = files.rootPath { controller?.newTab(workingDirectory: root) }
    }
}

extension NSPasteboard.PasteboardType {
    static let liberttyTab = NSPasteboard.PasteboardType("dev.libertty.terminal.tab")
}

extension StatusBadge {
    /// What a tab's badge shows for its programs' state (sidebar row or top tab).
    static func look(status: ProgramStatusStore.State?, progress: TerminalProgress?, programs: Bool = false) -> Look {
        TabCell.look(status: status, progress: progress, programs: programs)
    }
}

extension SidebarViewController: NSMenuDelegate {
    /// The menu is the clicked row's: a tab's, a header's or a session's.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = tabsTable.clickedRow
        menu.removeAllItems()
        menuTab = nil
        menuGroup = nil
        menuElsewhere = nil
        switch rows.indices.contains(row) ? rows[row] : nil {
        case .header(let g)?:
            menuGroup = groups[g]
            addGroupItems(to: menu, groups[g])
        case .elsewhere(let g, let k)?:
            menuElsewhere = groups[g].elsewhere[k]
            addElsewhereItems(to: menu)
        case .tab(let i)?:
            menuTab = controller?.tab(at: i)
            addTabItems(to: menu)
            // How the tabs are grouped, one level down.
            menu.addItem(.separator())
            let grouping = NSMenu()
            addGroupingItems(to: grouping)
            menu.addItem(withTitle: L10n.t("Group Tabs"), action: nil, keyEquivalent: "").submenu = grouping
        case nil:
            addTabItems(to: menu)
        }
    }
}

extension SidebarViewController: NSMenuItemValidation {
    /// Move Up/Down stop at the ends; Reset Name only for a renamed tab.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let row = menuRow
        switch item.action {
        case #selector(moveTabUp(_:)): return shownRow(from: row, by: -1) != nil
        case #selector(moveTabDown(_:)): return shownRow(from: row, by: 1) != nil
        case #selector(moveTabToNewWindow(_:)): return controller?.tab(at: row).map { controller?.canMoveTabOut($0) == true } ?? false
        case #selector(resetTabName(_:)): return row >= 0 && !(controller?.tabNameOverride(at: row) ?? "").isEmpty
        case #selector(forkConversation(_:)):
            // Only where an agent runs; greyed out, with why, where its conversation isn't known.
            guard let pane = menuTab?.focusedPane, let controller,
                  controller.programs[ObjectIdentifier(pane.session)]?.agent != nil else { item.isHidden = true; return false }
            item.isHidden = false
            let why = controller.whyNotFork(pane)
            item.toolTip = why
            return why == nil
        default: return true
        }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view: NSView
        switch rows[row] {
        case .tab(let i):
            let cell = (tableView.makeView(withIdentifier: TabCell.identifier, owner: self) as? TabCell) ?? TabCell()
            cell.configure(tabs[i], index: listed.indices.contains(i) ? listed[i] : i, count: tabs.count, closeTarget: self)
            cell.onPane = { [weak self] id, choice in self?.controller?.choosePane(id, choice) }
            view = cell
        case .header(let g):
            let group = groups[g]
            let cell = (tableView.makeView(withIdentifier: GroupHeaderCell.identifier, owner: self) as? GroupHeaderCell) ?? GroupHeaderCell()
            cell.configure(group, byHost: ConfigStore.shared.config.sidebarGroup == .host, folded: collapsed.contains(group.id),
                           canAdd: controller?.canOpenTab(in: group) == true)
            cell.onToggle = { [weak self] in self?.controller?.toggleSidebarGroup(group.id) }
            cell.onAdd = { [weak self] in self?.controller?.newTab(in: group) }
            view = cell
        case .elsewhere(let g, let k):
            let cell = (tableView.makeView(withIdentifier: ElsewhereCell.identifier, owner: self) as? ElsewhereCell) ?? ElsewhereCell()
            cell.configure(groups[g].elsewhere[k], twoLines: twoLineRows)
            let session = groups[g].elsewhere[k]
            cell.onOpen = { [weak self] in self?.controller?.showElsewhere(session) }
            view = cell
        }
        view.isHidden = !shows(tableRow: row)
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return rowHeight }
        return shows(tableRow: row) ? height(of: rows[row]) : Self.foldedRowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { TabRowView() }

    /// Only a tab's row is picked; a header's and a session's are clicked.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tab(atTableRow: row) != nil }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tabsTable.selectedRow
        placeSelectionCard()
        guard !syncingSelection, let i = tab(atTableRow: row), controller?.tab(at: i) !== controller?.selectedTab else { return }
        controller?.selectTab(at: i)
    }

    // Drag to reorder; onto another window's tabs to move it there; out of
    // every window for a window of its own (Rex's tear-off).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let i = tab(atTableRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(view.window?.windowNumber ?? 0):\(i)", forType: .liberttyTab)
        return item
    }

    /// A dragged row's window, tab and place there now: the tab itself, as
    /// its sidebar keeps it (tabs may open or close while it's dragged).
    private func source(of info: NSDraggingInfo) -> (TerminalWindowController, TerminalTab, Int)? {
        guard let sidebar = (info.draggingSource as? NSTableView)?.dataSource as? SidebarViewController,
              let controller = sidebar.controller, let tab = sidebar.draggedTab,
              let index = controller.tabs.firstIndex(where: { $0 === tab }) else { return nil }
        return (controller, tab, index)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above, let (from, tab, index) = source(of: info), let controller else { return [] }
        // In this window, only among its group's tabs (its project or host puts it there).
        if from === controller { return dropPlace(above: row, dragged: index) != nil ? .move : [] }
        return controller.canTake(tab, from: from) ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let (from, tab, index) = source(of: info), let controller else { return false }
        if from === controller {
            guard let place = dropPlace(above: row, dragged: index) else { return false }
            controller.moveTab(index, within: place.group, before: place.position)
        } else {
            // Where among the tabs: after the one above the drop in its group.
            controller.take(tab, from: from, at: SidebarGroups.insertionIndex(above: row, rows: rows, groups: groups, tabCount: tabs.count))
        }
        return true
    }

    private func dropPlace(above row: Int, dragged: Int) -> (group: [Int], position: Int)? {
        SidebarGroups.dropPlace(above: row, rows: rows, groups: groups, headers: headers, tabCount: tabs.count, dragged: dragged)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        draggedTab = rowIndexes.first.flatMap(tab(atTableRow:)).flatMap { controller?.tab(at: $0) }
    }

    /// Dropped where nothing took it, outside every Libertty window: a window of its own there.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        defer { draggedTab = nil }
        guard operation == [], NSApp.currentEvent?.type == .leftMouseUp, let tab = draggedTab, let controller,
              !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) else { return }
        controller.moveTabToNewWindow(tab, at: screenPoint)
    }
}

/// One tab: a status dot (OSC 7501), the title, and ⌘N or a close button on hover.
private final class TabCell: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("TabCell")
    /// `sidebar-rows = comfortable`: a second line under the name.
    static var twoLines = true
    private let dot = StatusBadge()
    private let tiles = TileStack()
    /// Rex's 22-point rounded square behind the tab's glyph.
    private let well = NSView()
    private let title = NSTextField(labelWithString: "")
    /// The second line (`sidebar-rows = comfortable`).
    private let subtitle = NSTextField(labelWithString: "")
    /// A split tab's pane count: a click lists its panes (Kero's).
    private let paneCount = NSButton(title: "", target: nil, action: nil)
    private var panes: [PaneSummary] = []
    private var titleCenter: NSLayoutConstraint!
    private var countCenter: NSLayoutConstraint!
    /// Picks one of the listed panes: (pane id, what to do with it).
    var onPane: ((String, SidebarViewController.PaneChoice) -> Void)?
    /// Printing (filled) or news waiting (ring): accent, no other color.
    private let news = CAShapeLayer()
    private let newsView = NSView()
    private let shortcut = NSTextField(labelWithString: "")
    private let close = NSButton()
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = Typeface.row
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = Typeface.hint
        shortcut.textColor = .tertiaryLabelColor
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        close.isHidden = true
        close.toolTip = "Close Tab"
        newsView.wantsLayer = true
        news.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 6, height: 6), transform: nil)
        news.lineWidth = 1.2
        newsView.layer?.addSublayer(news)
        newsView.isHidden = true
        well.wantsLayer = true
        well.layer?.cornerRadius = Radius.chip
        well.layer?.cornerCurve = .continuous
        // Rex shows no key hints on its rows (the menu and ⌘1–9 still work).
        shortcut.alphaValue = 0
        subtitle.font = Typeface.secondary
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.usesSingleLineMode = true
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.isHidden = true
        paneCount.isBordered = false
        paneCount.font = Typeface.secondary
        paneCount.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Panes")
        paneCount.imagePosition = .imageLeading
        paneCount.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        paneCount.contentTintColor = .tertiaryLabelColor
        paneCount.toolTip = L10n.t("List this tab's panes")
        paneCount.target = self
        paneCount.action = #selector(listPanes(_:))
        paneCount.isHidden = true
        paneCount.setContentHuggingPriority(.required, for: .horizontal)
        paneCount.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [well, dot, tiles, title, subtitle, paneCount, newsView, shortcut, close] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: 22), well.heightAnchor.constraint(equalToConstant: 22),
            dot.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 13), dot.heightAnchor.constraint(equalToConstant: 13),
            // The tiles take the badge's own place: only one of them shows.
            tiles.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            tiles.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: paneCount.leadingAnchor, constant: -4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            paneCount.trailingAnchor.constraint(equalTo: newsView.leadingAnchor, constant: -4),
            newsView.widthAnchor.constraint(equalToConstant: 8), newsView.heightAnchor.constraint(equalToConstant: 8),
            newsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            newsView.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -6),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.centerXAnchor.constraint(equalTo: shortcut.centerXAnchor),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        countCenter = paneCount.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([titleCenter, countCenter])
    }

    /// The count's list: each pane, its program, where it is and what it's
    /// doing; a click goes to it, ⌥ zooms it; Close Pane closes one.
    @objc private func listPanes(_ sender: NSButton) {
        let menu = NSMenu()
        func item(_ pane: PaneSummary, _ choice: SidebarViewController.PaneChoice) -> NSMenuItem {
            let status = pane.status.map { " · " + TerminalWindowController.stateWord($0) } ?? ""
            let verb = choice == .zoom ? "Zoom " : ""
            let item = NSMenuItem(title: verb + pane.program + (pane.place.isEmpty ? "" : " — " + pane.place) + status,
                                  action: #selector(pickPane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [pane.id, choice.rawValue]
            item.state = pane.focused && choice == .focus ? .on : .off
            item.image = NSImage(systemSymbolName: Self.symbol(for: pane.status), accessibilityDescription: nil)
            return item
        }
        for pane in panes {
            menu.addItem(item(pane, .focus))
            let zoom = item(pane, .zoom)
            zoom.isAlternate = true
            zoom.keyEquivalentModifierMask = .option
            menu.addItem(zoom)
        }
        menu.addItem(.separator())
        let close = NSMenu()
        for pane in panes { close.addItem(item(pane, .close)) }
        menu.addItem(withTitle: L10n.t("Close Pane"), action: nil, keyEquivalent: "").submenu = close
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pickPane(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let choice = SidebarViewController.PaneChoice(rawValue: pair[1]) else { return }
        onPane?(pair[0], choice)
    }

    private static func symbol(for status: ProgramStatusStore.State?) -> String {
        switch status {
        case .blocked?: "exclamationmark.circle"
        case .error?: "xmark.circle"
        case .done?: "checkmark.circle"
        case .working?: "circle.dotted"
        default: "terminal"
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The selected row's name is the bright one; the others' are muted (Tern's).
    var isSelectedRow = false {
        didSet { if isSelectedRow != oldValue { showTitle() } }
    }

    /// The name, what follows it, and how they truncate, as last configured.
    private var shown: (name: String, detail: String, paragraph: NSParagraphStyle)?

    private func showTitle() {
        guard let shown else { return }
        let text = NSMutableAttributedString(string: shown.name, attributes: [
            .font: Typeface.row, .foregroundColor: isSelectedRow ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: shown.paragraph,
        ])
        if !shown.detail.isEmpty {
            text.append(NSAttributedString(string: "  " + shown.detail, attributes: [
                .font: Typeface.secondary, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: shown.paragraph,
            ]))
        }
        title.attributedStringValue = text
    }

    func configure(_ tab: SidebarTabInfo, index: Int, count: Int, closeTarget: SidebarViewController) {
        // A terminal tab: a glyph for each pane running a program, the
        // focused pane's in front (Rex); while its panes sit at their
        // prompts, just the tab's own glyph. A status badge (OSC 7501,
        // OSC 9;4) replaces both when a program reports one.
        tiles.tiles = tab.tiles
        tiles.fallbackSymbol = tab.documentURL
            .map(DocumentView.symbol(for:)) ?? "apple.terminal"
        tiles.toolTip = tab.tiles.isEmpty ? nil : tab.tiles.map(\.name).joined(separator: ", ")
        // The name, then where it runs, fainter; the pane count last. A
        // path truncates in the middle — the folder at its end says where
        // you are. One line always: an attributed string brings its own
        // paragraph style, so the truncation goes in it too.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = tab.title.hasPrefix("/") || tab.title.hasPrefix("~") || tab.title.hasPrefix("…")
            ? .byTruncatingMiddle : .byTruncatingTail
        var extra: [String] = []
        if !tab.detail.isEmpty { extra.append(tab.detail) }
        if tab.parked > 0 { extra.append("\(tab.parked) parked") }
        shown = (tab.title, extra.joined(separator: " · "), paragraph)
        showTitle()
        let panesText = tab.paneCount > 1 ? (tab.zoomed ? "\(tab.paneCount) panes, zoomed" : "\(tab.paneCount) panes") : ""
        title.toolTip = ([tab.title] + extra + (panesText.isEmpty ? [] : [panesText]) + (tab.subtitle.isEmpty ? [] : [tab.subtitle]))
            .joined(separator: " · ")
        // The pane count, a click from the list of them.
        panes = tab.panes
        paneCount.isHidden = tab.paneCount < 2
        paneCount.title = tab.zoomed ? "\(tab.paneCount) zoomed" : String(tab.paneCount)
        paneCount.setAccessibilityLabel(panesText)
        // The second line.
        subtitle.stringValue = tab.subtitle
        subtitle.isHidden = !Self.twoLines || tab.subtitle.isEmpty
        titleCenter.constant = subtitle.isHidden ? 0 : -8
        countCenter.constant = subtitle.isHidden ? 0 : -8
        // ⌘1–⌘8 select those tabs and ⌘9 the last one, whatever its number.
        shortcut.stringValue = index < 8 ? "⌘\(index + 1)" : index == count - 1 ? "⌘9" : ""
        showNews(tab.news)
        // The only tab's × would close the window: ⌘W says that better.
        closable = count > 1
        close.isHidden = !(closable && hovering)
        shortcut.isHidden = closable && hovering
        close.target = closeTarget
        close.action = #selector(SidebarViewController.closeTab(_:))
        // A status badge (OSC 7501, OSC 9;4) when a program reports one, else a terminal glyph.
        let look = Self.look(status: tab.status, progress: tab.progress, programs: !tab.tiles.isEmpty)
        dot.show(look)
        dot.isHidden = look == .none
        tiles.isHidden = look != .none
        toolTip = tab.status.map { TerminalWindowController.label(for: $0) }
    }

    /// `programs`: the tab has programs to show (their logos or glyphs): a
    /// program that only says it's idle (an agent just started, between
    /// turns) shows as itself, not as a gray dot.
    static func look(status: ProgramStatusStore.State?, progress: TerminalProgress?, programs: Bool = false) -> StatusBadge.Look {
        // Needing you beats everything; then failure, then work in progress.
        switch status {
        case .blocked?: return .symbol("exclamationmark.circle.fill", .systemOrange)
        case .error?: return .symbol("xmark.circle.fill", .systemRed)
        default: break
        }
        if let progress {
            switch progress.state {
            case .error: return .ring(percent: progress.percent ?? 100, color: .systemRed)
            case .paused: return .ring(percent: progress.percent, color: .systemYellow)
            case .indeterminate: return .ring(percent: nil, color: Accent.color)
            case .normal: return .ring(percent: progress.percent, color: Accent.color)
            }
        }
        switch status {
        case .working?: return .ring(percent: nil, color: .systemBlue)
        case .done?: return .symbol("checkmark.circle.fill", .systemGreen)
        case .idle?: return programs ? .none : .dot(.secondaryLabelColor)
        default: return .none
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Whether the pointer is over the row, and whether its × may show.
    private var hovering = false
    private var closable = true

    // MARK: Renaming in place

    private var editor: NSTextField?
    private var finishRename: ((String?, Bool) -> Void)?

    var isEditing: Bool { editor != nil }

    /// The name becomes a field over the title. `done` gets the new name
    /// (empty: back to automatic), or nil when the edit was cancelled, and
    /// whether the keyboard should go back to the terminal.
    func beginEditing(current: String, placeholder: String, done: @escaping (String?, Bool) -> Void) {
        endEditing(keep: true, refocus: false)
        let field = NSTextField(string: current)
        field.placeholderString = placeholder
        field.font = Typeface.ui(13)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: -3),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.isHidden = true
        editor = field
        finishRename = done
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Keep what was typed: the row is about to change under the field.
    func finishEditing() { endEditing(keep: true, refocus: hasKeyboard) }

    private var hasKeyboard: Bool { editor?.currentEditor() != nil }

    /// `later`: the table is busy with its rows; `done` runs after.
    private func endEditing(keep: Bool, refocus: Bool, later: Bool = false) {
        guard let field = editor else { return }
        editor = nil
        let done = finishRename
        finishRename = nil
        let name = keep ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        field.removeFromSuperview()
        title.isHidden = false
        if later { DispatchQueue.main.async { done?(name, refocus) } } else { done?(name, refocus) }
    }

    // Return keeps the name, Esc goes back; the keyboard goes back to the
    // terminal. Clicking away keeps it too, and leaves the keyboard where
    // the click put it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endEditing(keep: true, refocus: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(keep: false, refocus: true); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // (Ended by Esc without asking us first: going back.)
        endEditing(keep: !Self.endedByCancel(obj), refocus: false)
    }

    /// The field's editing ended with Esc (its text movement, as AppKit
    /// reports it when it ends the editing itself).
    static func endedByCancel(_ note: Notification) -> Bool {
        (note.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
    }

    // A cell taken for another row brings no field along, and a hidden one
    // (the sidebar folded away) takes no typing: the name typed so far is kept.
    override func prepareForReuse() {
        super.prepareForReuse()
        endEditing(keep: true, refocus: hasKeyboard, later: true)
    }

    override func viewDidHide() {
        super.viewDidHide()
        endEditing(keep: true, refocus: hasKeyboard, later: true)
    }

    private func showNews(_ value: TabNews) {
        let accent = Accent.color.cgColor
        switch value {
        case .none:
            newsView.isHidden = true
        case .printing:
            newsView.isHidden = false
            news.fillColor = accent
            news.strokeColor = nil
            newsView.toolTip = "Printing"
        case .attention:
            newsView.isHidden = false
            news.fillColor = nil
            news.strokeColor = accent
            newsView.toolTip = "Something happened here since you last looked"
        }
    }

    // The layer's colors are resolved once: follow the accent and the
    // appearance when they change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        well.layer?.backgroundColor = Surfaces.current.raised.nsColor.cgColor
        well.layer?.borderWidth = 0.5
        well.layer?.borderColor = Surfaces.current.stroke.nsColor.cgColor
        if !newsView.isHidden {
            if news.fillColor != nil { news.fillColor = Accent.color.cgColor }
            if news.strokeColor != nil { news.strokeColor = Accent.color.cgColor }
        }
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ on: Bool) {
        hovering = on
        close.isHidden = !(closable && on)
        shortcut.isHidden = closable && on
    }
}

/// The selected tab is a raised card (Otty), not a source-list pill.
/// Rows draw no selection of their own: one card (`SelectionCard`) glides
/// to the selected row instead (Tern's liquid tabs).
private final class TabRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }

    // The selected row's name is the brighter one (Tern's rows).
    override var isSelected: Bool {
        didSet { cell?.isSelectedRow = isSelected }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? TabCell)?.isSelectedRow = isSelected
    }

    private var cell: TabCell? { subviews.lazy.compactMap { $0 as? TabCell }.first }
}

/// A group's header (`sidebar-group`, Kero's projects): a chevron that
/// folds the group away, its name and how many tabs, and + for a new tab
/// there. A click anywhere else on it folds it too.
private final class GroupHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")
    private let chevron = NSButton()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let add = NSButton()
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?

    /// "3 tabs", in the interface's language.
    static func count(_ n: Int) -> String { "\(n) " + L10n.t(n == 1 ? "tab" : "tabs") }

    /// "New Tab in %@" with `name` in it, in the interface's language.
    private static func say(_ english: String, _ name: String) -> String {
        L10n.t(english).replacingOccurrences(of: "%@", with: name)
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        chevron.isBordered = false
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.target = self
        chevron.action = #selector(toggle(_:))
        name.font = Typeface.ui(11.5, .semibold)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = Typeface.hint
        count.textColor = .tertiaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.isBordered = false
        add.contentTintColor = .tertiaryLabelColor
        add.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        add.target = self
        add.action = #selector(addTab(_:))
        for v in [chevron, name, count, add] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            name.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            count.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            count.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -6),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            add.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
        ])
        // One group for VoiceOver: "Project api, 3 tabs, collapsed", its chevron and + in it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle(_ sender: Any?) { onToggle?() }
    @objc private func addTab(_ sender: Any?) { onAdd?() }

    // A click on the header (not on its buttons) folds it, as its chevron
    // does; a ⌃-click is the table's, for the menu.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return super.mouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }

    func configure(_ group: SidebarGroup, byHost: Bool, folded: Bool, canAdd: Bool) {
        name.stringValue = group.title
        name.toolTip = group.project.map { group.host == nil ? ($0 as NSString).abbreviatingWithTildeInPath : $0 } ?? group.host
        count.stringValue = String(group.tabs.count)
        let fold = Self.say(folded ? "Expand %@" : "Collapse %@", group.title)
        chevron.image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: fold)
        chevron.toolTip = fold
        chevron.setAccessibilityLabel(fold)
        let new = Self.say("New Tab in %@", group.title)
        add.toolTip = new
        add.setAccessibilityLabel(new)
        add.isHidden = !canAdd
        var said = [Self.say(byHost ? "Host %@" : "Project %@", group.title), Self.count(group.tabs.count)]
        if !group.elsewhere.isEmpty { said.append("\(group.elsewhere.count) " + L10n.t("not open here")) }
        if folded { said.append(L10n.t("collapsed")) }
        setAccessibilityLabel(said.joined(separator: ", "))
    }
}

/// A session a liberttyd keeps that no window here shows (Kero's sidebar
/// lists them with the tabs): fainter than a tab, and a click shows it in one.
private final class ElsewhereCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ElsewhereCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var titleCenter: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        for field in [title, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.usesSingleLineMode = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        subtitle.font = Typeface.secondary
        subtitle.textColor = .tertiaryLabelColor
        for v in [icon, title, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // Where a tab's glyph and name are.
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleCenter.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ session: ElsewhereSession, twoLines: Bool) {
        // Shown by another Mac (or an attach elsewhere), or by nothing.
        let state = L10n.t(session.clients > 0 ? "shown elsewhere" : "not open here")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: session.title, attributes: [
            .font: Typeface.row, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
        ])
        let detail = twoLines ? session.detail : [session.detail, state].filter { !$0.isEmpty }.joined(separator: " · ")
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: Typeface.secondary, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
            ]))
        }
        title.attributedStringValue = text
        subtitle.stringValue = state
        subtitle.isHidden = !twoLines
        titleCenter.constant = twoLines ? -8 : 0
        toolTip = L10n.t("Show in a Tab")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([session.title, session.detail, state].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityHelp(L10n.t("Show in a Tab"))
    }

    /// VoiceOver's press: what a click does.
    var onOpen: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return onOpen != nil
    }

    // The row's own click (it isn't a tab's to select): it shows the
    // session; a ⌃-click is the table's, for the menu.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return super.mouseUp(with: event) }
        // (A double click's second half: the first already showed it.)
        if event.clickCount <= 1, bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
}

/// The selected tab's white card. It moves between rows with a stretch:
/// the edge it travels toward leads, the other follows, so it flows like
/// liquid instead of jumping.
final class SelectionCard: NSView {
    private var target: NSRect?

    /// A raised card (the sidebar's rows) or a flat tint (the top tabs, Tern's).
    var flat = false { didSet { updateColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.panel
        layer?.cornerCurve = .continuous
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        // Rex's selected row: the text color over the canvas, faintly; no shadow.
        layer?.backgroundColor = Surfaces.current.selected.cgColor
        layer?.shadowColor = NSColor.clear.cgColor
    }

    /// Be at `rect` at once (a drag, a scroll), whatever was under way.
    func place(_ rect: NSRect) {
        target = rect
        isHidden = rect.isEmpty
        frame = rect
    }

    /// Glide to `rect`; jump there when it's the first placement or motion is reduced.
    func move(to rect: NSRect) {
        guard rect != target else { return }
        let from = target
        target = rect
        isHidden = rect.isEmpty
        guard let from, !from.isEmpty, !rect.isEmpty, Motion.duration(Motion.card) > 0 else {
            frame = rect
            return
        }
        // Stretch to cover both rows (the leading edge arrives first), then
        // let the trailing edge catch up.
        let union = from.union(rect)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.small * 0.55
            ctx.timingFunction = Motion.ease
            animator().frame = union
        }, completionHandler: { [weak self] in
            guard let self, self.target == rect else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.card * 0.7
                ctx.timingFunction = Motion.out
                self.animator().frame = rect
            }
        })
    }
}

// MARK: - File tree

/// A folder's contents, loaded when first expanded (Tern's sidebar).
final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var loaded: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    func children(showHidden: Bool) -> [FileNode] {
        if let loaded { return loaded }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        let nodes = urls.map { u -> FileNode in
            let values = try? u.resourceValues(forKeys: Set(keys))
            // App bundles and other packages are files, as in Finder.
            return FileNode(url: u, isDirectory: (values?.isDirectory ?? false) && !(values?.isPackage ?? false))
        }
        loaded = nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return loaded!
    }

    func invalidate() { loaded = nil }
}

final class FileTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    var onOpenTerminalHere: ((String) -> Void)?
    var onInsert: ((String) -> Void)?
    var onChangeDirectory: ((String) -> Void)?
    var onOpenDocument: ((URL) -> Void)?
    /// ⌥-click / Open Beside Terminal: a pane next to the focused terminal.
    var onOpenDocumentInSplit: ((URL) -> Void)?
    /// Edit in Libertty: a text file in the editor, whatever it opens as.
    var onEditDocument: ((URL) -> Void)?
    private(set) var rootPath: String?
    private(set) var showHidden = true

    private let outline = FileOutlineView()
    private var root: FileNode?
    private var watcher: DispatchSourceFileSystemObject?

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.addTableColumn(NSTableColumn(identifier: .init("name")))
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Finder's files dropped on a folder (or the tree's own, moved).
        outline.registerForDraggedTypes([.fileURL])
        outline.onKey = { [weak self] event in self?.keyDown(in: event) ?? false }
        outline.setAccessibilityLabel(L10n.t("Files"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        documentView = outline
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(root path: String, showHidden: Bool) {
        guard path != rootPath || showHidden != self.showHidden else { return }
        rootPath = path
        self.showHidden = showHidden
        root = FileNode(url: URL(fileURLWithPath: path, isDirectory: true), isDirectory: true)
        outline.reloadData()
        outline.scroll(.zero)
        watch(path)
        refreshGitStatus()
    }

    func reload() {
        guard let rootPath else { return }
        // Not under a name being typed (its field would go): after it.
        if renaming != nil { reloadAfterRename = true; return }
        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }
            .filter { outline.isItemExpanded($0) }.map(\.url)
        // Where the reader was: the file picked, and how far down.
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        let scrolled = contentView.bounds.origin
        root = FileNode(url: URL(fileURLWithPath: rootPath, isDirectory: true), isDirectory: true)
        outline.reloadData()
        // Re-open what was open.
        func expand(_ nodes: [FileNode]) {
            for n in nodes where n.isDirectory && expanded.contains(n.url) {
                outline.expandItem(n)
                expand(n.children(showHidden: showHidden))
            }
        }
        expand(root?.children(showHidden: showHidden) ?? [])
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? FileNode)?.url == selected }) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        contentView.scroll(to: scrolled)
        reflectScrolledClipView(contentView)
        refreshGitStatus()
    }

    // MARK: Git marks

    /// Changed files by path, for coloring their names (ELYTerminal's cue).
    /// Re-read with the tree, and at each prompt in the focused pane: a
    /// command may change files anywhere, and the watcher above sees only
    /// the root folder.
    private var gitMarks: [String: Character] = [:]
    private var gitGeneration = 0
    private var promptReload: DispatchWorkItem?

    func refreshAtPrompt() {
        guard rootPath != nil else { return }
        promptReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        promptReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func refreshGitStatus() {
        guard let rootPath else { return }
        gitGeneration += 1
        let generation = gitGeneration
        let root = rootPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let marks = GitCLI.marks(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.gitGeneration, marks != self.gitMarks else { return }
                self.gitMarks = marks
                for row in 0..<self.outline.numberOfRows {
                    guard let node = self.outline.item(atRow: row) as? FileNode,
                          let cell = self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                    else { continue }
                    cell.textField?.textColor = Self.nameColor(for: node, gitMarks: marks)
                }
            }
        }
    }

    private static func nameColor(for node: FileNode, gitMarks: [String: Character]) -> NSColor {
        if let mark = gitMarks[node.url.path] {
            switch mark {
            case "A", "?": return .systemGreen     // added, new
            case "D", "U": return .systemRed       // deleted, in conflict
            default: return .systemOrange          // modified, renamed
            }
        }
        return node.name.hasPrefix(".") ? .secondaryLabelColor : .labelColor
    }

    /// Refresh when something is added to or removed from the root folder.
    private func watch(_ path: String) {
        watcher?.cancel()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        var pending: DispatchWorkItem?
        source.setEventHandler { [weak self] in
            pending?.cancel()
            let work = DispatchWorkItem { self?.reload() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    deinit { watcher?.cancel() }

    // MARK: Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root)?.children(showHidden: showHidden).count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root)!.children(showHidden: showHidden)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView(), text = NSTextField(labelWithString: "")
            text.font = Typeface.ui(13)
            text.lineBreakMode = .byTruncatingMiddle
            for v in [image, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = Self.nameColor(for: node, gitMarks: gitMarks)
        cell.imageView?.image = NSImage(systemSymbolName: Self.symbol(for: node), accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.toolTip = (node.url.path as NSString).abbreviatingWithTildeInPath
        return cell
    }

    private static func symbol(for node: FileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch node.url.pathExtension.lowercased() {
        case "swift", "c", "h", "m", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx", "zig", "rb", "java", "kt", "sh", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "json", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
        case "app": return "app"
        case "zip", "gz", "tar", "xz", "dmg": return "doc.zipper"
        default: return "doc"
        }
    }

    // Drag files into a terminal (or anywhere) as file URLs.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    // MARK: Actions

    /// The row clicked (or right-clicked), else the selected one — not when
    /// the menu was opened on the tree's empty space: that's the top folder's.
    private var target: FileNode? {
        if outline.clickedRow >= 0 { return outline.item(atRow: outline.clickedRow) as? FileNode }
        if menuOnEmpty { return nil }
        return outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? FileNode : nil
    }
    private var menuOnEmpty = false

    /// One click opens a text file in a tab (Tern's preview_click), ⌥-click
    /// beside the terminal; other files open with their app on double-click.
    @objc private func clicked(_ sender: Any?) {
        guard outline.clickedRow >= 0, let node = target, !node.isDirectory, DocumentView.canShow(node.url) else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { onOpenDocumentInSplit?(node.url) } else { onOpenDocument?(node.url) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = target else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else if !DocumentView.canShow(node.url) {
            NSWorkspace.shared.open(node.url)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let event = NSApp.currentEvent
        menuOnEmpty = outline.clickedRow < 0 && (event?.type == .rightMouseDown
            || event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: L10n.t(title), action: action, keyEquivalent: "").target = self
        }
        // Where nothing is clicked: the folder at the top.
        guard let node = target else {
            guard rootPath != nil else { return }
            add("New File…", #selector(newFile(_:)))
            add("New Folder…", #selector(newFolder(_:)))
            return
        }
        if node.isDirectory {
            add("New Tab Here", #selector(newTabHere(_:)))
            add("cd Here in Focused Pane", #selector(cdHere(_:)))
        } else {
            if DocumentView.canShow(node.url) {
                add("Open in Libertty", #selector(openInLibertty(_:)))
                add("Open Beside Terminal", #selector(openInSplit(_:)))
            }
            // Markdown opens rendered, other text files may not open at all: edit them anyway.
            if !DocumentView.wantsEditor(node.url, renderMarkdown: ConfigStore.shared.config.markdownRendered),
               EditorAssets.page != nil, EditorAssets.canEdit(node.url) {
                add("Edit in Libertty", #selector(editInLibertty(_:)))
            }
            add("Open with Default App", #selector(openItem(_:)))
        }
        add("Reveal in Finder", #selector(reveal(_:)))
        menu.addItem(.separator())
        // In this folder, or the file's.
        add("New File…", #selector(newFile(_:)))
        add("New Folder…", #selector(newFolder(_:)))
        menu.addItem(.separator())
        add("Copy Path", #selector(copyPath(_:)))
        add("Insert Path in Terminal", #selector(insertPath(_:)))
        menu.addItem(.separator())
        add("Rename", #selector(renameItem(_:)))
        add("Duplicate", #selector(duplicateItem(_:)))
        add("Move to Trash", #selector(trashItem(_:)))
    }

    @objc private func openItem(_ sender: Any?) { if let target { NSWorkspace.shared.open(target.url) } }
    @objc private func openInLibertty(_ sender: Any?) { if let target { onOpenDocument?(target.url) } }
    @objc private func openInSplit(_ sender: Any?) { if let target { onOpenDocumentInSplit?(target.url) } }
    @objc private func editInLibertty(_ sender: Any?) { if let target { onEditDocument?(target.url) } }
    @objc private func reveal(_ sender: Any?) {
        if let target { NSWorkspace.shared.activateFileViewerSelecting([target.url]) }
    }
    @objc private func newTabHere(_ sender: Any?) { target.map { onOpenTerminalHere?($0.url.path) } }
    @objc private func cdHere(_ sender: Any?) { target.map { onChangeDirectory?($0.url.path) } }
    @objc private func insertPath(_ sender: Any?) { target.map { onInsert?(ShellQuote.quote($0.url.path) + " ") } }

    @objc private func copyPath(_ sender: Any?) {
        guard let node = target else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    // MARK: Changing files (Kero's Files): FileOperations, each undoable

    @objc private func newFile(_ sender: Any?) { promptNew(isFolder: false) }
    @objc private func newFolder(_ sender: Any?) { promptNew(isFolder: true) }
    @objc private func renameItem(_ sender: Any?) { if let target { beginRename(target) } }

    @objc private func duplicateItem(_ sender: Any?) {
        guard let node = target else { return }
        do { afterChange(selecting: [try FileOperations.duplicate(node.url)]) } catch { show(error) }
    }

    @objc private func trashItem(_ sender: Any?) { if let target { trash(target) } }

    private func trash(_ node: FileNode) {
        FileOperations.trash([node.url]) { [weak self] result in
            if case .failure(let error) = result { self?.show(error) }
            self?.reload()
        }
    }

    /// Where something new goes: the folder clicked, the clicked file's, or the top.
    private var folderForNew: URL? {
        if let node = target { return node.isDirectory ? node.url : node.url.deletingLastPathComponent() }
        return rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func promptNew(isFolder: Bool) {
        guard let folder = folderForNew, let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t(isFolder ? "New Folder" : "New File")
        alert.informativeText = String(format: L10n.t("In %@. A slash makes the folders on the way: docs/notes.md."),
                                       (folder.path as NSString).abbreviatingWithTildeInPath)
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = isFolder ? L10n.t("untitled folder") : "untitled.txt"
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("Create"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? field.placeholderString ?? "" : field.stringValue
            do {
                let made = try FileOperations.create(typed, in: folder, isFolder: isFolder)
                self.afterChange(selecting: [made])
                // A new text file opens in the editor, to be written.
                if !isFolder, EditorAssets.page != nil, EditorAssets.canEdit(made) { self.onEditDocument?(made) }
            } catch {
                // Once the name's sheet has gone.
                DispatchQueue.main.async { self.show(error) }
            }
        }
    }

    private func show(_ error: Error) {
        guard let window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = L10n.t("Couldn't do that")
        alert.informativeText = error.localizedDescription
        if window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { NSSound.beep() }
    }

    /// What a change made, shown and selected: the folders down to it opened.
    private func afterChange(selecting urls: [URL]) {
        reload()
        let rows = IndexSet(urls.compactMap(row(showing:)))
        guard let first = rows.first else { return }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        outline.scrollRowToVisible(first)
    }

    /// Opens the folders down to `url`; its row, if the tree has it.
    private func row(showing url: URL) -> Int? {
        guard let root, let rootPath else { return nil }
        let base = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        var nodes = root.children(showHidden: showHidden)
        var current = base
        for part in path.dropFirst(base.count + 1).split(separator: "/") {
            current += "/" + part
            guard let node = nodes.first(where: { $0.url.standardizedFileURL.path == current }) else { return nil }
            if current == path {
                let row = outline.row(forItem: node)
                return row >= 0 ? row : nil
            }
            outline.expandItem(node)
            nodes = node.children(showHidden: showHidden)
        }
        return nil
    }

    // MARK: Renaming in place

    private var renaming: (node: FileNode, field: NSTextField, cancelled: Bool)?
    /// The field editor's own undo, while it holds a name.
    private var editorUndo: Bool?
    /// The tree changed while a name was being typed: read again after.
    private var reloadAfterRename = false

    /// The name becomes a field, its stem selected (as Finder does);
    /// Return renames, Esc leaves it.
    func beginRename(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0, let window else { return }
        if renaming != nil { window.makeFirstResponder(outline) }
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes([row], byExtendingSelection: false)
        guard let field = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        renaming = (node, field, false)
        guard window.makeFirstResponder(field) else {
            endRename(field)
            return
        }
        // Its typing isn't the windows' undo (Edit ▸ Undo is the rename's, once done).
        if let editor = field.currentEditor() as? NSTextView {
            editorUndo = editor.allowsUndo
            editor.allowsUndo = false
        }
        let name = node.name as NSString
        let stem = node.isDirectory || name.pathExtension.isEmpty ? name.length : (name.deletingPathExtension as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
    }

    /// The name being typed (the UI probe).
    var renameField: NSTextField? { renaming?.field }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let renaming, control === renaming.field else { return false }
        // Esc, as the field editor may name it (complete: is NSTextView's Esc
        // for word completion, which a name has no use for).
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) {
            self.renaming?.cancelled = true
            window?.makeFirstResponder(outline)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, field === renaming?.field else { return }
        // Esc that AppKit ended the editing with itself, not through doCommandBy.
        if TabCell.endedByCancel(note) { renaming?.cancelled = true }
        endRename(field)
    }

    private func endRename(_ field: NSTextField) {
        guard let (node, _, cancelled) = renaming else { return }
        renaming = nil
        if let editorUndo, let editor = field.currentEditor() as? NSTextView ?? window?.fieldEditor(false, for: field) as? NSTextView {
            editor.allowsUndo = editorUndo
        }
        editorUndo = nil
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        let typed = field.stringValue
        field.stringValue = node.name
        // Once the field editor is through with its own ending.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !cancelled, typed != node.name {
                do { self.afterChange(selecting: [try FileOperations.rename(node.url, to: typed)]) } catch { self.show(error) }
            }
            if self.reloadAfterRename {
                self.reloadAfterRename = false
                self.reload()
            }
        }
    }

    // MARK: Keys

    /// ⌘⌫ moves the selected file to the Trash, Return renames it (Finder's keys).
    private func keyDown(in event: NSEvent) -> Bool {
        guard renaming == nil, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 51 where flags == .command:  // ⌘⌫
            trash(node)
            return true
        case 36 where flags.isEmpty, 76 where flags.isEmpty:  // Return, Enter
            beginRename(node)
            return true
        default:
            return false
        }
    }

    // MARK: Dropping files in

    /// Files from the Finder are copied in (⌘ moves them), the tree's own
    /// moved (⌥ copies them), into the folder they're dropped on — or a
    /// file's folder, or the top.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard rootPath != nil, !Self.droppedFiles(info).isEmpty else { return [] }
        var folder = item as? FileNode
        if let node = folder, !node.isDirectory { folder = outline.parent(forItem: node) as? FileNode }
        outline.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return dropMoves(info) ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = (item as? FileNode)?.url ?? rootPath.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return false }
        return drop(Self.droppedFiles(info), into: folder, move: dropMoves(info))
    }

    /// Copies (or moves) `urls` into `folder` and shows them there (the UI probe drops this way too).
    @discardableResult
    func drop(_ urls: [URL], into folder: URL, move: Bool) -> Bool {
        do {
            let placed = try FileOperations.drop(urls, into: folder, move: move)
            afterChange(selecting: placed)
            return !placed.isEmpty
        } catch {
            reload()
            show(error)
            return false
        }
    }

    private func dropMoves(_ info: NSDraggingInfo) -> Bool {
        let mask = info.draggingSourceOperationMask
        return (info.draggingSource as AnyObject?) === outline ? mask != .copy : !mask.contains(.copy)
    }

    private static func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: The UI probe

    /// The rows shown, each its path under the top folder (a folder's with a slash).
    var shownPaths: [String] {
        guard let rootPath else { return [] }
        let base = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }.map { node in
            String(node.url.standardizedFileURL.path.dropFirst(base.count + 1)) + (node.isDirectory ? "/" : "")
        }
    }

    /// Selects the row showing `path` (under the top folder), the tree taking the keyboard.
    @discardableResult
    func select(path: String) -> Bool {
        guard let rootPath, let row = row(showing: URL(fileURLWithPath: rootPath).appendingPathComponent(path)) else { return false }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        window?.makeFirstResponder(outline)
        return true
    }

    /// The selected row's menu item titled `title`, chosen.
    func chooseMenuItem(_ title: String) -> Bool {
        guard let menu = outline.menu else { return false }
        menuNeedsUpdate(menu)
        guard let item = menu.items.first(where: { $0.title == title || $0.title == L10n.t(title) }), let action = item.action
        else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }
}

/// The file tree's outline, telling its keys first to the tree.
final class FileOutlineView: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

enum ShellQuote {
    /// Single-quoted for POSIX shells: 'it'\''s'.
    static func quote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// "Filter tabs" at the sidebar's foot (Tern's): a magnifier and a field on
/// a soft fill. Esc clears it; Return goes to the first tab it shows. The
/// button at its end filters by activity (Rex's), filled while it does.
final class TabFilterField: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onActivity: ((TabActivity) -> Void)?
    var onEscape: (() -> Void)?
    private let field = NSTextField()
    private let activityButton = NSButton()
    private var activity = TabActivity.all

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.control
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        field.font = Typeface.row
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Filter tabs")
        activityButton.isBordered = false
        activityButton.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        activityButton.target = self
        activityButton.action = #selector(showActivityMenu(_:))
        for v in [icon, field, activityButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: activityButton.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            activityButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(activity: .all)
        updateColors()
    }

    /// The button and the placeholder say which tabs show.
    func show(activity: TabActivity) {
        self.activity = activity
        let filtering = activity != .all
        let symbol = filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        activityButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Show Tabs")
        activityButton.contentTintColor = filtering ? .labelColor : .tertiaryLabelColor
        activityButton.toolTip = filtering ? "Showing: \(activity.title)" : "Show Tabs by Activity"
        let placeholder = filtering ? "Filter \(activity.word) tabs" : L10n.t("Filter tabs")
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: Typeface.row, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    @objc private func showActivityMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (i, activity) in TabActivity.allCases.enumerated() {
            if i == 1 { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: activity.title, action: #selector(pickActivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = activity.rawValue
            item.state = activity == self.activity ? .on : .off
        }
        // As a pop-up button's: the checked one over the button.
        let checked = menu.items.first { $0.state == .on }
        menu.popUp(positioning: checked, at: NSPoint(x: 0, y: sender.isFlipped ? 0 : sender.bounds.maxY), in: sender)
    }

    @objc private func pickActivity(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let activity = TabActivity(rawValue: raw) else { return }
        show(activity: activity)
        onActivity?(activity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = Surfaces.current.hover.cgColor
    }

    func focus() { window?.makeFirstResponder(field) }

    func clear() {
        guard !field.stringValue.isEmpty else { return }
        field.stringValue = ""
        onChange?("")
    }

    // A click anywhere on it reaches the field.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onEscape?() }
            field.stringValue = ""
            onChange?("")
            return true
        default:
            return false
        }
    }
}
