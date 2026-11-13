import AppKit
import LiberttyCore

/// The sidebar's groups (`sidebar-group`, Kero's): the tabs under the
/// project each is in, or the machine it runs on — and with them the
/// sessions there that no window here shows (every connected host's in one
/// sidebar), a click from a tab.
extension TerminalWindowController {
    /// How the sidebar groups the tabs (none while they're along the top).
    var sidebarGrouping: SidebarGrouping { config.tabBar.inSidebar && !isQuick ? config.sidebarGroup : .none }

    /// Whether this window lists sessions not open here: its sidebar is
    /// grouped and on screen (`ElsewhereSessions` reads while one is).
    var wantsElsewhereSessions: Bool { sidebarGrouping != .none && window?.isVisible == true }

    /// Where a tab is: the machine its focused pane runs on (an ssh in it
    /// counts), and the project — the repository around its folder, else
    /// the folder (a host's folder as it is: its repositories aren't
    /// this Mac's to look into).
    func place(of tab: TerminalTab) -> TabPlace {
        if let doc = tab.document {
            // A document is this Mac's file, whichever window shows it.
            guard doc.url.isFileURL else { return TabPlace(host: nil, project: nil) }
            return TabPlace(host: nil, project: localProject(doc.url.deletingLastPathComponent().path))
        }
        guard let pane = tab.focusedPane else { return TabPlace(host: host?.destination, project: nil) }
        if let remote = pane.session.host?.destination ?? host?.destination {
            return TabPlace(host: remote, project: pane.session.workingDirectory)
        }
        if let ssh = programs[ObjectIdentifier(pane.session)]?.host { return TabPlace(host: ssh, project: nil) }
        return TabPlace(host: nil, project: pane.session.workingDirectory.map(localProject))
    }

    private func localProject(_ directory: String) -> String { ProjectRoots.shared.project(of: directory) }

    /// The tabs in their groups, with the sessions elsewhere in theirs; none ungrouped.
    func sidebarGroups() -> [SidebarGroup] {
        let mode = sidebarGrouping
        guard mode != .none else { return [] }
        if groupsObserver == nil {
            groupsObserver = NotificationCenter.default.addObserver(forName: SidebarGroups.changed, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.updateSidebar() }
            }
        }
        var windows = (NSApp.delegate as? AppDelegate)?.allControllers ?? []
        if !windows.contains(where: { $0 === self }) { windows.append(self) }
        let elsewhere = ElsewhereSessions.shared.sessions(shownIn: windows, for: self)
        return SidebarGroups.groups(mode, places: tabs.map(place(of:)), elsewhere: elsewhere,
                                    thisMac: L10n.t("This Mac"), other: L10n.t("Other"))
    }

    /// Fold a group away, or bring it back (kept with the window's layout).
    func toggleSidebarGroup(_ id: String) {
        if collapsedGroups.remove(id) == nil { collapsedGroups.insert(id) }
        updateSidebar()
    }

    /// The tabs as a grouped sidebar lists them (a folded group's too), else
    /// in their order: ⌘1–⌘9 and the next and previous tab go by what you see.
    var tabsAsListed: [TerminalTab] {
        let mode = sidebarGrouping
        guard mode != .none else { return tabs }
        return SidebarGroups.groups(mode, places: tabs.map(place(of:)), elsewhere: []).flatMap(\.tabs).map { tabs[$0] }
    }

    /// Whether a group's + can open a tab there: on this window's machine,
    /// and somewhere (a host reached by an ssh in a pane, or "Other", isn't).
    func canOpenTab(in group: SidebarGroup) -> Bool {
        guard group.host == host?.destination else { return false }
        return sidebarGrouping == .host || group.project != nil
    }

    /// A group's +: a new tab in its project's folder (by host: where new tabs open).
    func newTab(in group: SidebarGroup) {
        guard canOpenTab(in: group) else { return }
        newTab(workingDirectory: sidebarGrouping == .project ? group.project : nil)
    }

    /// A session not open here, shown: a tab here when it runs on this
    /// window's machine; otherwise in a window on its machine (a new one if
    /// there's none) — every tab of a window runs where the window does.
    func showElsewhere(_ session: ElsewhereSession) {
        // Its folder as the list read it, for a program that never says
        // (its tab then groups where its row was).
        func attach(in controller: TerminalWindowController) {
            controller.attachTab(session.id)
            guard let dir = session.directory, let pane = controller.selectedTab.focusedPane,
                  pane.session.persistentID == session.id else { return }
            pane.session.assumeWorkingDirectory(dir)
            controller.updateSidebar()
        }
        if session.host == host?.destination { return attach(in: self) }
        let app = NSApp.delegate as? AppDelegate
        if let there = app?.windowControllers.first(where: { $0.host?.destination == session.host }) {
            attach(in: there)
            there.window?.makeKeyAndOrderFront(nil)
            return
        }
        app?.openWindow(showing: session.id, on: session.host, directory: session.directory)
    }

    /// What each group's header says, as shown (`--ui-probe`): "api · 2 tabs · collapsed · 1 not open here".
    var sidebarGroupSummary: [String] { sidebar.shownGroups }
    /// The rows of sessions not open here, as shown (`--ui-probe`).
    var sidebarElsewhereRows: [String] { sidebar.shownElsewhere }
}
