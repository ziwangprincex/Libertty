import AppKit

/// The toolbar's bell: every notification so far (programs that asked,
/// long commands that ended, agents that need you), newest first. Clicking
/// one brings its pane forward.
final class InboxViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onReveal: ((String) -> Void)?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "No notifications yet")
    private var entries: [Notifier.Entry] = []
    private var observer: AnyObject?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
        let title = NSTextField(labelWithString: "Notifications")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll(_:)))
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
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
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
            self?.reload()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        Notifier.shared.markInboxRead()
    }

    private func reload() {
        entries = Notifier.shared.inbox
        empty.isHidden = !entries.isEmpty
        table.reloadData()
    }

    @objc private func clearAll(_ sender: Any?) { Notifier.shared.clearInbox() }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        onReveal?(entries[row].pane)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: InboxCell.identifier, owner: nil) as? InboxCell ?? InboxCell()
        cell.show(entries[row])
        return cell
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
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byTruncatingTail
        time.font = .systemFont(ofSize: 11)
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
