import AppKit

/// The Inspector's Git panel (after ELYTerminal's, through the git command
/// line): the branch, staged and unstaged files with their actions (stage,
/// unstage, discard with a confirm, click for the diff), a commit message
/// and Commit, and the recent commits. Refreshes at each prompt, on a
/// directory change and after its own actions.
///
/// Every action runs at the repository's root: that's where git's paths
/// are from, wherever in the tree the pane is.
final class GitPanelView: NSView {
    /// The whole repository's diff (`git diff`).
    var onShowAllChanges: (() -> Void)?
    /// The Git block: history, branches, hunks.
    var onOpenGit: (() -> Void)?
    /// Whether there's a repository to show (outside one the panel hides,
    /// and its section with it).
    var onAvailabilityChange: ((Bool) -> Void)?
    /// A file's diff, written to the URL, to show beside the terminal under
    /// the title. A callback rather than the window controller: the panel
    /// is made before the Inspector knows its controller.
    var onOpenDiff: ((URL, String) -> Void)?

    private let stack = NSStackView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let stagedHeader = GitPanelView.sectionLabel("Staged")
    private let unstagedHeader = GitPanelView.sectionLabel("Changes")
    private let recentHeader = GitPanelView.sectionLabel("Recent")
    private let stagedList = NSStackView()
    private let unstagedList = NSStackView()
    private let recentList = NSStackView()
    private let message = NSTextField()
    private let commitButton = NSButton()

    /// The pane's directory, as last shown.
    private var directory: String?
    /// What the rows on screen were read from: their repository's root and
    /// their changes. Set together with the rows, so an action always
    /// means the repository it was clicked in — even while a refresh for
    /// another pane is still on its way.
    private var root: String?
    private var shownStaged: [GitChange] = []
    private var shownUnstaged: [GitChange] = []
    private var generation = 0
    private var pending: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5

        branchLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        branchLabel.lineBreakMode = .byTruncatingMiddle

        message.placeholderString = "Commit message"
        message.font = .systemFont(ofSize: 12)
        message.target = self
        message.action = #selector(commit(_:))
        commitButton.title = "Commit"
        commitButton.bezelStyle = .smallSquare
        commitButton.font = .systemFont(ofSize: 11, weight: .medium)
        commitButton.controlSize = .small
        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        commitButton.toolTip = "Commit the staged changes"
        let commitRow = NSStackView(views: [message, commitButton])
        commitRow.spacing = 6
        commitRow.alignment = .centerY
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for list in [stagedList, unstagedList, recentList] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 2
        }

        for view in [branchLabel, stagedHeader, stagedList, unstagedHeader, unstagedList,
                     link("Stage All", "plus.square", #selector(stageAll(_:))), commitRow,
                     recentHeader, recentList, link("Show Changes", "plusminus", #selector(showAll(_:))),
                     link("Open Git", "arrow.triangle.branch", #selector(openGit(_:)))] {
            stack.addArrangedSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The focused pane's directory changed (or its pane did).
    func show(directory: String?) {
        self.directory = directory
        pending?.cancel()
        refresh()
    }

    /// A prompt arrived in the focused pane: what the command did shows now.
    func refreshSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: Reading git

    private struct State {
        var root: String
        var branch: String
        var staged: [GitChange]
        var unstaged: [GitChange]
        var recent: [String]
    }

    private func refresh() {
        generation += 1
        let generation = self.generation
        guard let directory else { return apply(nil) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = GitPanelView.read(directory)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.apply(state)
            }
        }
    }

    private static func read(_ directory: String) -> State? {
        guard let root = GitCLI.root(of: directory), let changes = GitCLI.changes(in: root) else { return nil }
        // The branch — also before the first commit, when HEAD names a
        // branch that doesn't exist yet; a detached HEAD by its commit.
        var branch = GitCLI.run(["branch", "--show-current"], in: root) ?? ""
        if branch.isEmpty {
            branch = GitCLI.run(["rev-parse", "--short", "HEAD"], in: root).map { "detached at \($0)" } ?? "—"
        }
        let staged = changes.filter { $0.index != " " && $0.index != "?" }
        let unstaged = changes.filter { $0.worktree != " " }
        // Nothing to log before the first commit: no Recent section.
        let recent = GitCLI.run(["log", "-5", "--pretty=format:%h %s"], in: root)?
            .split(separator: "\n").map(String.init) ?? []
        return State(root: root, branch: branch, staged: staged, unstaged: unstaged, recent: recent)
    }

    private func apply(_ state: State?) {
        onAvailabilityChange?(state != nil)
        guard let state else {
            isHidden = true
            root = nil
            return
        }
        isHidden = false
        root = state.root
        branchLabel.stringValue = "⎇ \(state.branch)"
        if state.staged != shownStaged { setRows(stagedList, state.staged, staged: true) }
        if state.unstaged != shownUnstaged { setRows(unstagedList, state.unstaged, staged: false) }
        shownStaged = state.staged
        shownUnstaged = state.unstaged
        stagedHeader.isHidden = state.staged.isEmpty
        stagedList.isHidden = state.staged.isEmpty
        unstagedHeader.isHidden = state.unstaged.isEmpty
        unstagedList.isHidden = state.unstaged.isEmpty
        commitButton.isEnabled = !state.staged.isEmpty
        recentHeader.isHidden = state.recent.isEmpty
        recentList.isHidden = state.recent.isEmpty
        let rows = recentList.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        if rows != state.recent {
            recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for line in state.recent {
                let label = NSTextField(labelWithString: line)
                label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingMiddle
                recentList.addArrangedSubview(label)
            }
        }
    }

    private func setRows(_ list: NSStackView, _ changes: [GitChange], staged: Bool) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for change in changes {
            list.addArrangedSubview(row(change, staged: staged))
        }
    }

    /// One file: its mark, its name (click for the diff), and its actions.
    /// Every control carries the file's path as its identifier.
    private func row(_ change: GitChange, staged: Bool) -> NSStackView {
        let row = NSStackView()
        row.spacing = 4
        row.alignment = .centerY

        let markChar = staged ? change.index : (change.isUntracked ? "?" : change.worktree)
        let mark = NSTextField(labelWithString: String(markChar))
        mark.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        mark.textColor = markChar == "?" || markChar == "A" ? .systemGreen
            : (markChar == "D" || markChar == "U" ? .systemRed : .systemOrange)
        mark.widthAnchor.constraint(equalToConstant: 10).isActive = true

        // A new folder is one entry: it has no diff to show.
        let title = (change.path as NSString).lastPathComponent + (change.isDirectory ? "/" : "")
        let name = NSButton(title: title, target: self, action: #selector(openDiff(_:)))
        name.isBordered = false
        name.font = .systemFont(ofSize: 12)
        name.alignment = .left
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = change.path
        name.identifier = NSUserInterfaceItemIdentifier(change.path)
        name.tag = staged ? 1 : 0
        name.isEnabled = !change.isDirectory
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(mark)
        row.addArrangedSubview(name)
        // Tooltips name the file: hovering says what a click will do, and
        // VoiceOver reads the same.
        let file = Self.displayName(change)
        if staged {
            row.addArrangedSubview(iconButton("minus.circle", "Unstage \(file)", #selector(unstage(_:)), change.path))
        } else {
            row.addArrangedSubview(iconButton("plus.circle", "Stage \(file)", #selector(stage(_:)), change.path))
            row.addArrangedSubview(iconButton("arrow.uturn.backward.circle", "Discard changes to \(file)",
                                              #selector(discard(_:)), change.path))
        }
        return row
    }

    // MARK: Actions (each runs git at the root, then refreshes)

    private func act(_ args: [String], failing what: String) {
        guard let root else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitCLI.execute(args, in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let why) = result { self.report(what, why) }
                self.refresh()
            }
        }
    }

    /// Git said no: say so, with what git said.
    private func report(_ what: String, _ why: GitCLI.Failure) {
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = why.message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func shownChange(_ sender: NSControl) -> GitChange? {
        guard let path = sender.identifier?.rawValue else { return nil }
        return (shownUnstaged + shownStaged).first { $0.path == path }
    }

    private static func displayName(_ change: GitChange) -> String {
        (change.path as NSString).lastPathComponent
    }

    @objc private func stage(_ sender: NSControl) {
        guard let change = shownChange(sender) else { return }
        act(["add", "--", change.path], failing: "Couldn't stage \(Self.displayName(change))")
    }

    @objc private func unstage(_ sender: NSControl) {
        guard let change = shownChange(sender) else { return }
        act(["restore", "--staged", "--", change.path], failing: "Couldn't unstage \(Self.displayName(change))")
    }

    @objc private func discard(_ sender: NSControl) {
        guard let change = shownChange(sender) else { return }
        // An edit goes back to the index; something new is deleted (ELN).
        // Ask first.
        let alert = NSAlert()
        alert.messageText = "Discard changes in \(Self.displayName(change))\(change.isDirectory ? "/" : "")?"
        alert.informativeText = change.isDirectory ? "The folder is new: it and everything in it will be deleted."
            : change.isUntracked ? "The file is new: it will be deleted." : "Its changes go back to the index."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // -d: a new folder is one entry, and clean leaves folders alone without it.
        act(change.isUntracked ? ["clean", "-f", "-d", "--", change.path] : ["checkout", "--", change.path],
            failing: "Couldn't discard \(Self.displayName(change))")
    }

    @objc private func stageAll(_ sender: Any?) {
        act(["add", "-A"], failing: "Couldn't stage the changes")
    }

    @objc private func commit(_ sender: Any?) {
        // Return in the message field gets here too.
        guard commitButton.isEnabled, let root else { NSSound.beep(); return }
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { window?.makeFirstResponder(message); return }
        commitButton.isEnabled = false  // once, while git runs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitCLI.execute(["commit", "-m", text], in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.message.stringValue = ""
                // The message stays, for another try (a hook said no, no
                // user.email…).
                case .failure(let why): self.report("Couldn't commit", why)
                }
                self.refresh()
            }
        }
    }

    /// This file's diff, beside the terminal: staged against HEAD, unstaged
    /// against the index, a new file against nothing.
    @objc private func openDiff(_ sender: NSButton) {
        guard let change = shownChange(sender), let root else { return }
        let staged = sender.tag == 1
        let arguments = staged ? ["--cached", "--", change.path]
            : change.isUntracked ? ["--no-index", "--", "/dev/null", change.path]
            : ["--", change.path]
        let file = Self.displayName(change)
        let title = staged ? "diff — \(file) (staged)" : "diff — \(file)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitDiff.write(directory: root, arguments: arguments,
                                       name: (staged ? "staged/" : "") + change.path, literal: true)
            DispatchQueue.main.async {
                switch result {
                case .success(let url): self?.onOpenDiff?(url, title)
                case .failure(let why): self?.report("Couldn't show the diff of \(file)", .init(message: why.message))
                }
            }
        }
    }

    @objc private func showAll(_ sender: Any?) { onShowAllChanges?() }
    @objc private func openGit(_ sender: Any?) { onOpenGit?() }

    // MARK: Pieces

    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func link(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.isBordered = false
        b.font = .systemFont(ofSize: 12)
        b.contentTintColor = Accent.color
        return b
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, _ path: String) -> NSButton {
        let b: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            b = NSButton(image: image, target: self, action: action)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        } else {
            b = NSButton(title: tip, target: self, action: action)
        }
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.identifier = NSUserInterfaceItemIdentifier(path)
        return b
    }
}
