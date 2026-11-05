import AppKit

/// New Tab in Worktree… (⌘⌥T, Kero's): a tab on a new branch in a git
/// worktree of its own; closing it (or its window) asks whether the worktree goes too.
extension TerminalWindowController {
    func newTabInWorktree() {
        guard host == nil, let window else { return NSSound.beep() }
        guard let here = focusedTerminal.session.workingDirectory, let root = GitCLI.root(of: here) else {
            let alert = NSAlert()
            alert.messageText = "Not in a git repository"
            alert.informativeText = "New Tab in Worktree… makes a worktree of the repository the pane you're in works in."
            alert.beginSheetModal(for: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "New Tab in Worktree"
        let from = config.worktreeBase == "current" ? "the branch you're on" : (WorkTree.defaultBranch(root: root) ?? "HEAD")
        alert.informativeText = "A new branch, from \(from), checked out in a folder of its own: "
            + (Worktrees.path(root: root, branch: "BRANCH", setting: config.worktreeDir) as NSString).abbreviatingWithTildeInPath
        let field = NSTextField(string: "")
        field.placeholderString = "fix-login"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let branch = field.stringValue.trimmingCharacters(in: .whitespaces)
            self.makeWorktreeTab(root: root, branch: branch, base: self.config.worktreeBase == "current" ? "HEAD" : nil)
        }
    }

    /// The worktree, then a tab in it. Returns the tab.
    @discardableResult
    func makeWorktreeTab(root: String, branch: String, base: String?) -> TerminalTab? {
        switch Worktrees.create(root: root, branch: branch, base: base, setting: config.worktreeDir) {
        case .failure(let why):
            showError(why)
            return nil
        case .success(let path):
            guard let tab = newTab(workingDirectory: path) else { return nil }
            tab.worktree = WorktreeInfo(root: root, path: path, branch: branch)
            onLayoutChange?()
            return tab
        }
    }

    /// The worktree a tab is of: the one it was made in, else one Libertty
    /// made that a pane of it works in (`+new-session --worktree`'s, after
    /// a relaunch).
    func worktree(of tab: TerminalTab, among made: [WorktreeInfo]) -> WorktreeInfo? {
        if let worktree = tab.worktree { return worktree }
        for pane in tab.everyPane {
            if let dir = pane.session.workingDirectory, let w = Worktrees.made(containing: dir, among: made) { return w }
        }
        return nil
    }

    /// Whether a pane of any window but those of `closing` works in it.
    private func inUse(_ worktree: WorktreeInfo, besides closing: [TerminalTab]) -> Bool {
        allControllersForWorktrees.contains { controller in
            controller.everyTab.contains { other in
                !closing.contains { $0 === other } && other.everyPane.contains { pane in
                    pane.session.workingDirectory.map { Worktrees.contains(worktree, $0) } ?? false
                }
            }
        }
    }

    /// Before a tab of a worktree closes: whether the worktree goes too.
    /// Another pane working in it keeps it, unasked; nothing uncommitted in
    /// it makes Remove the default, uncommitted changes Keep. `proceed`
    /// closes the tab (`removing`: the worktree goes once its programs end).
    func confirmWorktree(_ tab: TerminalTab, then proceed: @escaping (_ removing: Bool) -> Void) {
        guard host == nil, let worktree = worktree(of: tab, among: Worktrees.made()), !inUse(worktree, besides: [tab]) else {
            return proceed(false)
        }
        guard !tab.askingAboutWorktree else { return }
        tab.askingAboutWorktree = true
        countUncommitted([worktree]) { [weak self] counted in
            tab.askingAboutWorktree = false
            guard let self else { return }
            // Gone already (removed by hand): nothing to ask.
            guard !counted.isEmpty else {
                Worktrees.forget(worktree)
                return proceed(false)
            }
            self.askAboutWorktrees(counted, cancelled: {}) { removing in
                proceed(removing)
                if removing { self.remove(counted) }
            }
        }
    }

    /// Closing the window: its tabs' worktrees that no other window's pane
    /// works in, asked about once, together; the answer in `worktreesOnClose`,
    /// then `proceed`. Returns false, asking nothing, when there's nothing to ask.
    func confirmWindowWorktrees(cancelled: @escaping () -> Void, then proceed: @escaping () -> Void) -> Bool {
        guard host == nil else { return false }
        let made = Worktrees.made(), tabs = everyTab
        var worktrees: [WorktreeInfo] = []
        for tab in tabs {
            if let w = worktree(of: tab, among: made), !worktrees.contains(where: { $0.path == w.path }), !inUse(w, besides: tabs) {
                worktrees.append(w)
            }
        }
        guard !worktrees.isEmpty else { return false }
        countUncommitted(worktrees) { [weak self] counted in
            guard let self else { return }
            guard !counted.isEmpty else {
                self.worktreesOnClose = []
                return proceed()
            }
            self.askAboutWorktrees(counted, cancelled: cancelled) { removing in
                self.worktreesOnClose = removing ? counted.map { ($0.0, force: $0.1 > 0) } : []
                proceed()
            }
        }
        return true
    }

    /// The window closed for good: the worktrees it was asked to remove go.
    func removeWorktreesOnClose() {
        guard let list = worktreesOnClose, !list.isEmpty else { return }
        worktreesOnClose = nil
        remove(list.map { ($0.0, $0.force ? 1 : 0) })
    }

    /// How many files each has uncommitted, read off the main thread (git
    /// status in a big tree takes a while); those no longer there are left
    /// out. `done` on the main queue.
    private func countUncommitted(_ worktrees: [WorktreeInfo], done: @escaping ([(WorktreeInfo, Int)]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let counted = worktrees.filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { ($0, Worktrees.uncommitted($0.path)) }
            DispatchQueue.main.async { done(counted) }
        }
    }

    /// Remove or keep: one sheet for one worktree or several. Keep is the
    /// default when any has uncommitted changes, which removing would lose.
    /// Kept, a worktree is yours: Libertty doesn't ask about it again.
    private func askAboutWorktrees(_ counted: [(WorktreeInfo, Int)], cancelled: @escaping () -> Void,
                                   then decided: @escaping (_ removing: Bool) -> Void) {
        guard let window else { return decided(false) }
        let losing = counted.map(\.1).reduce(0, +)
        func describe(_ w: WorktreeInfo, _ n: Int) -> String {
            let place = (w.path as NSString).abbreviatingWithTildeInPath
            return n > 0 ? "\(place), on \(w.branch), has \(n) file\(n == 1 ? "" : "s") with uncommitted changes"
                : "\(place), on \(w.branch), has nothing uncommitted"
        }
        let alert = NSAlert()
        if counted.count == 1, let (w, n) = counted.first {
            alert.messageText = "Remove the worktree too?"
            alert.informativeText = describe(w, n) + (n > 0 ? ", which removing it would lose."
                : ". Its branch goes too once it's merged; otherwise it stays, with its commits.")
        } else {
            alert.messageText = "Remove this window's \(counted.count) worktrees too?"
            alert.informativeText = counted.map { "• " + describe($0.0, $0.1) + "." }.joined(separator: "\n")
                + (losing > 0 ? "\nRemoving them would lose those changes." : "")
                + "\nEach branch goes too once it's merged; otherwise it stays, with its commits."
        }
        if losing > 0 {
            alert.addButton(withTitle: "Keep Worktree" + (counted.count > 1 ? "s" : ""))
            alert.addButton(withTitle: "Remove Worktree" + (counted.count > 1 ? "s" : "")).hasDestructiveAction = true
        } else {
            alert.addButton(withTitle: "Remove Worktree" + (counted.count > 1 ? "s" : ""))
            alert.addButton(withTitle: "Keep Worktree" + (counted.count > 1 ? "s" : ""))
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let first = response == .alertFirstButtonReturn, second = response == .alertSecondButtonReturn
            guard first || second else { return cancelled() }
            let removing = losing > 0 ? second : first
            if !removing { counted.forEach { Worktrees.forget($0.0) } }
            decided(removing)
        }
    }

    /// Once their programs have ended (they hold their folders).
    private func remove(_ counted: [(WorktreeInfo, Int)]) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            for (worktree, uncommitted) in counted {
                if case .failure(let why) = Worktrees.remove(worktree, force: uncommitted > 0) {
                    DispatchQueue.main.async { [weak self] in self?.showError(why) }
                }
            }
        }
    }

    private var allControllersForWorktrees: [TerminalWindowController] {
        var all = (NSApp.delegate as? AppDelegate)?.allControllers ?? []
        if !all.contains(where: { $0 === self }) { all.append(self) }
        return all
    }
}
