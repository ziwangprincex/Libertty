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
}

/// Which tabs the sidebar lists by what their programs are doing (Rex's
/// activity filter): every tab, those at work, those waiting for you, or
/// those with something to see.
enum TabActivity: String, CaseIterable {
    case all, working, waiting, attention

    var title: String {
        switch self {
        case .all: return "All Tabs"
        case .working: return "Working"
        case .waiting: return "Waiting for You"
        case .attention: return "Finished or Failed"
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
        case .ring(let percent, let color):
            track.isHidden = false
            arc.isHidden = false
            track.strokeColor = color.withAlphaComponent(0.25).cgColor
            arc.strokeColor = color.cgColor
            if let percent {
                arc.strokeStart = 0
                arc.strokeEnd = CGFloat(max(3, percent)) / 100
            } else {
                // Indeterminate: a quarter arc going round (still with reduced motion).
                arc.strokeStart = 0
                arc.strokeEnd = 0.28
                if !Motion.reduced {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = -2 * CGFloat.pi
                    spin.duration = 1
                    spin.repeatCount = .infinity
                    arc.add(spin, forKey: "spin")
                }
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

    private let files = FileTreeView()
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

    /// The window's frame color behind the column, opaque over the system
    /// sidebar material (Tern's one surface), translucent with the window.
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

        for v in [tabsRow, tabsScroll, divider, filesRow, files, filter] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        tabsHeight = tabsScroll.heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            tabsRow.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            tabsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            tabsRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabsScroll.topAnchor.constraint(equalTo: tabsRow.bottomAnchor, constant: 6),
            tabsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            tabsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
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
            files.bottomAnchor.constraint(equalTo: filter.topAnchor, constant: -6),
            filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            filter.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            filter.heightAnchor.constraint(equalToConstant: 30),
        ])
        tabsHeight.priority = .defaultHigh
        // With the files folded away the tabs may use nearly the whole column.
        tabsCapWithFiles = tabsScroll.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.45)
        tabsCapAlone = filesRow.bottomAnchor.constraint(lessThanOrEqualTo: filter.topAnchor, constant: -10)
        tabsCapWithFiles.isActive = true
        tabsCapAlone.isActive = true
        tabsSection = [tabsRow, tabsScroll, divider, filter]
        filesBelowTabs = view.constraints.filter {
            ($0.firstItem === filesRow && $0.firstAttribute == .top) || ($0.firstItem === files && $0.firstAttribute == .bottom)
        }
        filesAlone = [filesRow.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
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
        tabsTitle?.stringValue = count > 1 ? name : "Tabs"
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

    /// The tabs the filters leave showing, by index.
    var shownRows: [Int] { tabs.indices.filter { matches(tabs[$0]) } }

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
        tabsTable.noteHeightOfRows(withIndexesChanged: IndexSet(tabs.indices))
        for row in tabs.indices {
            tabsTable.view(atColumn: 0, row: row, makeIfNecessary: false)?.isHidden = !matches(tabs[row])
        }
        fitTabsHeight()
        placeSelectionCard()
    }

    /// Return in the filter: the first tab it shows.
    private func selectFirstMatch() {
        guard let row = tabs.firstIndex(where: matches) else { return }
        controller?.selectTab(at: row)
        controller?.focusTerminal()
    }

    private func fitTabsHeight() {
        let shown = tabs.filter(matches).count
        let folded = tabs.count - shown
        tabsHeight.constant = CGFloat(shown) * (tabsTable.rowHeight + Self.rowSpacing)
            + CGFloat(folded) * (Self.foldedRowHeight + Self.rowSpacing) + 2
        // How many, and how many of them show while filtered: "1/4".
        tabCount.stringValue = folded > 0 ? "\(shown)/\(tabs.count)" : String(tabs.count)
    }

    private static let foldedRowHeight: CGFloat = 0.01

    static func iconButton(_ symbol: String, _ tip: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        return b
    }

    // MARK: Tabs

    func show(tabs: [SidebarTabInfo], selected: Int) {
        if let rename = renaming {
            // A name being typed in place: the other rows update around
            // the field. When the rows themselves change (a tab came, went
            // or moved; another was selected) the name is kept first, and
            // keeping it brings the rows up to date.
            if tabs.count == self.tabs.count, selected == rename.row, rename.cell?.isEditing == true,
               let tab = rename.tab, controller?.tab(at: rename.row) === tab {
                let changed = IndexSet(tabs.indices.filter { $0 != rename.row && tabs[$0] != self.tabs[$0] })
                for i in changed { self.tabs[i] = tabs[i] }
                if !changed.isEmpty {
                    tabsTable.reloadData(forRowIndexes: changed, columnIndexes: [0])
                    // A row may start or stop matching the filter meanwhile.
                    tabsTable.noteHeightOfRows(withIndexesChanged: changed)
                    fitTabsHeight()
                    placeSelectionCard()
                }
                return
            }
            if finishRename() { return }
        }
        if tabs != self.tabs {
            self.tabs = tabs
            tabsTable.reloadData()
            fitTabsHeight()
        }
        if tabsTable.selectedRow != selected {
            tabsTable.selectRowIndexes([selected], byExtendingSelection: false)
        }
        tabsTable.scrollRowToVisible(selected)
        placeSelectionCard()
    }

    /// The selection card sits behind the rows, over the selected one.
    private lazy var selectionCard: SelectionCard = {
        let card = SelectionCard()
        tabsTable.addSubview(card, positioned: .below, relativeTo: nil)
        return card
    }()

    private func placeSelectionCard() {
        tabsTable.layoutSubtreeIfNeeded()
        let row = tabsTable.selectedRow
        // None for a row the filter folded away.
        let shown = row >= 0 && row < tabsTable.numberOfRows && tabs.indices.contains(row) && matches(tabs[row])
        let rect = shown ? tabsTable.rect(ofRow: row).insetBy(dx: 2, dy: 1) : .zero
        selectionCard.move(to: rect)
        // Keep it under every row view, including ones added since.
        if tabsTable.subviews.first !== selectionCard {
            tabsTable.addSubview(selectionCard, positioned: .below, relativeTo: nil)
        }
    }

    @objc private func tabClicked(_ sender: Any?) {
        let row = tabsTable.clickedRow
        if row >= 0 { controller?.selectTab(at: row) }
    }

    private func tabMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Name", action: #selector(resetTabName(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Duplicate Tab", action: #selector(duplicateTab(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move Up", action: #selector(moveTabUp(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move Down", action: #selector(moveTabDown(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move to New Window", action: #selector(moveTabToNewWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// Rename in place: the row's name becomes an editable field. Return
    /// or clicking away keeps it, Esc goes back, an empty name goes back
    /// to the automatic one (GoRex; Finder's way).
    func beginRename(row: Int) {
        // One at a time: one under way is kept first.
        finishRename()
        guard row >= 0, row < tabs.count, let tab = controller?.tab(at: row),
              let cell = tabsTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabCell else { return }
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
        let row = tabsTable.clickedRow
        guard row >= 0 else { return }
        controller?.selectTab(at: row)
        beginRename(row: row)
    }

    @objc private func renameTab(_ sender: Any?) {
        let row = tabsTable.clickedRow
        guard row >= 0 else { return }
        controller?.selectTab(at: row)
        beginRename(row: row)
    }

    @objc private func resetTabName(_ sender: Any?) {
        let row = tabsTable.clickedRow
        if row >= 0 { controller?.renameTab(at: row, to: "") }
    }

    @objc private func moveTabUp(_ sender: Any?) {
        let row = tabsTable.clickedRow
        if row > 0 { controller?.moveTab(from: row, to: row - 1) }
    }

    @objc private func moveTabDown(_ sender: Any?) {
        let row = tabsTable.clickedRow
        if row >= 0, row < tabs.count - 1 { controller?.moveTab(from: row, to: row + 1) }
    }

    @objc private func moveTabToNewWindow(_ sender: Any?) {
        let row = tabsTable.clickedRow
        guard row >= 0, let tab = controller?.tab(at: row) else { return }
        controller?.moveTabToNewWindow(tab)
    }

    @objc private func duplicateTab(_ sender: Any?) {
        let row = tabsTable.clickedRow
        guard row >= 0 else { return }
        controller?.duplicateTab(at: row)
    }

    @objc fileprivate func closeTab(_ sender: Any?) {
        let row = (sender as? NSButton).map { tabsTable.row(for: $0) } ?? tabsTable.clickedRow
        if row >= 0 { controller?.closeTab(at: row) }
    }

    @objc private func closeOtherTabs(_ sender: Any?) {
        let row = tabsTable.clickedRow
        if row >= 0 { controller?.closeOtherTabs(keeping: row) }
    }

    // MARK: Files

    func show(filesShown shown: Bool) {
        guard shown != filesShown else { return }
        filesShown = shown
        files.isHidden = !shown
        filesButtons.forEach { $0.isHidden = !shown }
        tabsCapWithFiles.isActive = shown && tabsShown
        disclosure.image = NSImage(systemSymbolName: shown ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: shown ? "Hide Files" : "Show Files")
        disclosure.toolTip = shown ? "Hide Files" : "Show Files"
    }

    @objc private func toggleFiles(_ sender: Any?) {
        ConfigStore.shared.set("sidebar-files", filesShown ? "false" : "true")
    }

    func show(directory: String, showHidden: Bool) {
        folderLabel.stringValue = directory == NSHomeDirectory() ? (directory as NSString).lastPathComponent
            : (directory as NSString).lastPathComponent
        folderLabel.toolTip = (directory as NSString).abbreviatingWithTildeInPath
        files.show(root: directory, showHidden: showHidden)
    }

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

    @objc private func follow(_ sender: Any?) { controller?.updateSidebar(force: true) }

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
    static func look(status: ProgramStatusStore.State?, progress: TerminalProgress?) -> Look {
        TabCell.look(status: status, progress: progress)
    }
}

extension SidebarViewController: NSMenuItemValidation {
    /// Move Up/Down stop at the ends; Reset Name only for a renamed tab.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let row = tabsTable.clickedRow
        switch item.action {
        case #selector(moveTabUp(_:)): return row > 0
        case #selector(moveTabDown(_:)): return row >= 0 && row < tabs.count - 1
        case #selector(moveTabToNewWindow(_:)): return controller?.tab(at: row).map { controller?.canMoveTabOut($0) == true } ?? false
        case #selector(resetTabName(_:)): return row >= 0 && !(controller?.tabNameOverride(at: row) ?? "").isEmpty
        default: return true
        }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: TabCell.identifier, owner: self) as? TabCell) ?? TabCell()
        cell.configure(tabs[row], index: row, count: tabs.count, closeTarget: self)
        cell.isHidden = !matches(tabs[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tabs.indices.contains(row) && !matches(tabs[row]) ? Self.foldedRowHeight : Layout.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { TabRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tabsTable.selectedRow
        placeSelectionCard()
        if row >= 0 { controller?.selectTab(at: row) }
    }

    // Drag to reorder; onto another window's tabs to move it there; out of
    // every window for a window of its own (Rex's tear-off).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(view.window?.windowNumber ?? 0):\(row)", forType: .liberttyTab)
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
        guard op == .above, let (from, tab, _) = source(of: info), let controller else { return [] }
        return from === controller || controller.canTake(tab, from: from) ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let (from, tab, index) = source(of: info), let controller else { return false }
        if from === controller {
            controller.moveTab(from: index, to: index < row ? row - 1 : row)
        } else {
            controller.take(tab, from: from, at: row)
        }
        return true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        draggedTab = rowIndexes.first.flatMap { controller?.tab(at: $0) }
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
    private let dot = StatusBadge()
    private let tiles = TileStack()
    private let title = NSTextField(labelWithString: "")
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
        for v in [dot, tiles, title, newsView, shortcut, close] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 13), dot.heightAnchor.constraint(equalToConstant: 13),
            // The tiles take the badge's own place: only one of them shows.
            tiles.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            tiles.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: tiles.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: newsView.leadingAnchor, constant: -4),
            newsView.widthAnchor.constraint(equalToConstant: 8), newsView.heightAnchor.constraint(equalToConstant: 8),
            newsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            newsView.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -6),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.centerXAnchor.constraint(equalTo: shortcut.centerXAnchor),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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
        if tab.paneCount > 1 { extra.append(tab.zoomed ? "\(tab.paneCount) panes, zoomed" : "\(tab.paneCount) panes") }
        if tab.parked > 0 { extra.append("\(tab.parked) parked") }
        shown = (tab.title, extra.joined(separator: " · "), paragraph)
        showTitle()
        title.toolTip = ([tab.title] + extra).joined(separator: " · ")
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
        let look = Self.look(status: tab.status, progress: tab.progress)
        dot.show(look)
        dot.isHidden = look == .none
        tiles.isHidden = look != .none
        toolTip = tab.status.map { TerminalWindowController.label(for: $0) }
    }

    static func look(status: ProgramStatusStore.State?, progress: TerminalProgress?) -> StatusBadge.Look {
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
            case .indeterminate: return .ring(percent: nil, color: .controlAccentColor)
            case .normal: return .ring(percent: progress.percent, color: .controlAccentColor)
            }
        }
        switch status {
        case .working?: return .ring(percent: nil, color: .systemBlue)
        case .done?: return .symbol("checkmark.circle.fill", .systemGreen)
        case .idle?: return .dot(.secondaryLabelColor)
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
        field.font = .systemFont(ofSize: 13)
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

    func controlTextDidEndEditing(_ obj: Notification) { endEditing(keep: true, refocus: false) }

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
        let accent = NSColor.controlAccentColor.cgColor
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
        if !newsView.isHidden {
            if news.fillColor != nil { news.fillColor = NSColor.controlAccentColor.cgColor }
            if news.strokeColor != nil { news.strokeColor = NSColor.controlAccentColor.cgColor }
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
        layer?.cornerRadius = Radius.control
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Dark: a faint lift, no shadow; light: a white card (Tern's rows),
        // or a faint shade when flat (its top tabs).
        let fill: NSColor = flat ? (dark ? .white.withAlphaComponent(0.06) : .black.withAlphaComponent(0.045))
            : dark ? .white.withAlphaComponent(0.08) : .white
        layer?.backgroundColor = fill.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(dark || flat ? 0 : 0.10).cgColor
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

final class FileTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
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

    private let outline = NSOutlineView()
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
        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }
            .filter { outline.isItemExpanded($0) }.map(\.url)
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
            text.font = .systemFont(ofSize: 13)
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

    private var target: FileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

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
        guard let node = target else { return }
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
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
        add("Copy Path", #selector(copyPath(_:)))
        add("Insert Path in Terminal", #selector(insertPath(_:)))
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
        let placeholder = filtering ? "Filter \(activity.word) tabs" : "Filter tabs"
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
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)).cgColor
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
            field.stringValue = ""
            onChange?("")
            return true
        default:
            return false
        }
    }
}
