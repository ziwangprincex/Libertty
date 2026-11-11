import AppKit

/// A pane whose program says how it's doing, as Activity lists it by state.
struct ActivityItem: Equatable {
    var paneID: String
    var title: String
    var detail: String
    var state: ProgramStatusStore.State

    /// The states Activity groups by, the most pressing first (Rex's "Group
    /// by priority"), with what each group is called. Idle panes aren't listed.
    static let groups: [(state: ProgramStatusStore.State, name: String)] = [ProgramStatusStore.State.blocked, .error, .working, .done]
        .map { ($0, TerminalWindowController.label(for: $0)) }

    /// `items` under their groups, in that order, each keeping its own; an
    /// empty group is left out.
    static func grouped(_ items: [ActivityItem]) -> [(name: String, state: ProgramStatusStore.State, items: [ActivityItem])] {
        groups.compactMap { group in
            let these = items.filter { $0.state == group.state }
            return these.isEmpty ? nil : (group.name, group.state, these)
        }
    }
}

/// The toolbar's bell: every notification so far (programs that asked,
/// long commands that ended, agents that need you), newest first — or, By
/// State, every pane whose program is waiting for you, failed, working or
/// done right now, under those headings. Clicking one brings its pane forward.
final class InboxViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onReveal: ((String) -> Void)?
    /// The panes of every window, as By State lists them.
    var livePanes: (() -> [ActivityItem])?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl()
    private var entries: [Notifier.Entry] = []
    private var rows: [Row] = []
    private var observer: AnyObject?
    private var refresh: Timer?

    private enum Row: Equatable {
        case entry(Notifier.Entry)
        case heading(String, ProgramStatusStore.State, Int)
        case pane(ActivityItem)
    }

    /// Recent or By State, as it was left (it's the popup's, not the config's).
    static let byStateKey = "ActivityByState"
    /// Chosen for now only (the UI probe's): the user's choice stays theirs.
    private var byStateNow: Bool?
    private var byState: Bool { byStateNow ?? UserDefaults.standard.bool(forKey: Self.byStateKey) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
        mode.segmentCount = 2
        mode.setLabel(L10n.t("Recent"), forSegment: 0)
        mode.setLabel(L10n.t("By State"), forSegment: 1)
        mode.trackingMode = .selectOne
        mode.controlSize = .small
        mode.segmentStyle = .rounded
        mode.selectedSegment = byState ? 1 : 0
        mode.target = self
        mode.action = #selector(modeChanged(_:))
        mode.setAccessibilityLabel(L10n.t("Show Activity"))
        let title = mode
        let clear = NSButton(title: L10n.t("Clear"), target: self, action: #selector(clearAll(_:)))
        clear.bezelStyle = .inline
        clear.controlSize = .small
        let column = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        for v in [title, clear, scroll, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            clear.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(forName: Notifier.inboxChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload(force: true)  // the times ("5 min ago") as of now
        Notifier.shared.markInboxRead()
        // By State follows the panes while it's open.
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.byState == true { self?.reload() } }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refresh?.invalidate()
        refresh = nil
    }

    func reload(force: Bool = false) {
        entries = Notifier.shared.inbox
        let new: [Row]
        if byState {
            new = ActivityItem.grouped(livePanes?() ?? []).flatMap { group in
                [Row.heading(L10n.t(group.name), group.state, group.items.count)] + group.items.map(Row.pane)
            }
            empty.stringValue = L10n.t("Nothing is running")
        } else {
            new = entries.map(Row.entry)
            empty.stringValue = L10n.t("No notifications yet")
        }
        empty.isHidden = !new.isEmpty
        // Unchanged (By State's timer, most seconds): the rows stay put
        // under a click, and keep their hover.
        guard force || new != rows else { return }
        rows = new
        table.reloadData()
    }

    /// What the list shows now, a line a row (the UI probe reads it).
    var shownRows: [String] {
        rows.map {
            switch $0 {
            case .entry(let e): e.title
            case .heading(let name, _, let count): "\(name) (\(count))"
            case .pane(let item): "  \(item.title)" + (item.detail.isEmpty ? "" : " — \(item.detail)")
            }
        }
    }

    @objc private func modeChanged(_ sender: Any?) {
        byStateNow = nil
        UserDefaults.standard.set(mode.selectedSegment == 1, forKey: Self.byStateKey)
        reload()
    }

    /// Recent or By State for now, not remembered (the UI probe switches).
    func show(byState: Bool) {
        byStateNow = byState
        mode.selectedSegment = byState ? 1 : 0
        reload()
    }

    @objc private func clearAll(_ sender: Any?) { Notifier.shared.clearInbox() }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .entry(let e): onReveal?(e.pane)
        case .pane(let item): onReveal?(item.paneID)
        case .heading: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .entry: 46
        case .heading: 24
        case .pane: 40
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .heading = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .entry(let entry):
            let cell = tableView.makeView(withIdentifier: InboxCell.identifier, owner: nil) as? InboxCell ?? InboxCell()
            cell.show(entry)
            return cell
        case .heading(let name, let state, let count):
            let cell = tableView.makeView(withIdentifier: ActivityHeading.identifier, owner: nil) as? ActivityHeading ?? ActivityHeading()
            cell.show(name, count: count, color: TerminalWindowController.color(for: state))
            return cell
        case .pane(let item):
            let cell = tableView.makeView(withIdentifier: ActivityCell.identifier, owner: nil) as? ActivityCell ?? ActivityCell()
            cell.show(item)
            return cell
        }
    }
}

/// A group's heading in By State: its dot, its name, how many.
private final class ActivityHeading: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ActivityHeading")
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = Typeface.ui(11, .semibold)
        label.textColor = .secondaryLabelColor
        for v in [dot, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ name: String, count: Int, color: NSColor) {
        label.stringValue = "\(name.uppercased(with: .current))  \(count)"
        dot.layer?.backgroundColor = color.cgColor
    }
}

/// A pane in By State: its program (or agent), and what it last said.
private final class ActivityCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ActivityCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = Typeface.ui(13, .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = Typeface.ui(11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for v in [title, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 23),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: ActivityItem) {
        title.stringValue = item.title
        detail.stringValue = item.detail
        detail.isHidden = item.detail.isEmpty
    }
}

private final class InboxCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("InboxCell")
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = Typeface.ui(13, .medium)
        title.lineBreakMode = .byTruncatingTail
        body.font = Typeface.ui(12)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byTruncatingTail
        time.font = Typeface.ui(11)
        time.textColor = .tertiaryLabelColor
        for v in [title, body, time] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -8),
            time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ entry: Notifier.Entry) {
        title.stringValue = entry.title
        body.stringValue = entry.body
        time.stringValue = Self.relative.localizedString(for: entry.date, relativeTo: Date())
    }
}
