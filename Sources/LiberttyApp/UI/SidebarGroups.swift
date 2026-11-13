import AppKit
import CPty
import LiberttyCore

/// How the sidebar groups its tabs (`sidebar-group`, Kero's projects): not
/// at all (one list, as it always was), under the project each tab is in,
/// or under the machine it runs on.
enum SidebarGrouping: String, CaseIterable {
    case none, project, host
}

/// Where a tab is, as grouping sees it: the machine (nil: this Mac) and the
/// project (a repository's root, else a folder; nil: nowhere known).
struct TabPlace: Equatable {
    var host: String?
    var project: String?
}

/// A session a liberttyd keeps that no window here shows — this Mac's, or a
/// connected host's (Kero lists every host's in one sidebar). Its row is
/// fainter than a tab's; a click shows it in a tab.
struct ElsewhereSession: Equatable {
    var id: String
    /// The ssh destination it runs on; nil: this Mac.
    var host: String?
    var title: String
    /// Its folder, as shown ("~/src/api"), and in full.
    var detail: String
    var directory: String? = nil
    /// Its project, for `sidebar-group = project` (a repository's root, else its folder).
    var project: String?
    /// Windows showing it, none of them here (another Mac's, `+attach` in another terminal).
    var clients: Int
}

/// One of the sidebar's groups: what its header says, its tabs (indices
/// into the window's tabs, in their order), and the sessions that belong
/// there but aren't open here.
struct SidebarGroup: Equatable {
    /// Stable across launches (it keeps a group folded): the grouping, host and project.
    var id: String
    var title: String
    var host: String?
    var project: String?
    var tabs: [Int] = []
    var elsewhere: [ElsewhereSession] = []

    /// The group as its tabs make it (what's elsewhere left out).
    var withoutElsewhere: SidebarGroup {
        var g = self
        g.elsewhere = []
        return g
    }
}

/// A row of a grouped sidebar: a tab, a group's header, or a session not open here.
enum SidebarRow: Equatable {
    case tab(Int)
    /// The group's index.
    case header(Int)
    case elsewhere(group: Int, index: Int)
}

enum SidebarGroups {
    /// Posted (on the main queue) when what the groups are made of changed
    /// without a window hearing of it: a folder's repository found, the
    /// sessions not open here read again.
    static let changed = Notification.Name("LiberttySidebarGroupsChanged")
    /// The tabs at `places` (in the window's order), and the sessions not
    /// open here, in groups for `mode`: each group where its first tab is,
    /// then those that have only sessions elsewhere. By host, this Mac comes
    /// first. `.none` has none.
    static func groups(_ mode: SidebarGrouping, places: [TabPlace], elsewhere: [ElsewhereSession],
                       thisMac: String = "This Mac", other: String = "Other", home: String = NSHomeDirectory()) -> [SidebarGroup] {
        guard mode != .none else { return [] }
        var groups: [SidebarGroup] = []
        var index: [String: Int] = [:]
        func group(host: String?, project: String?) -> Int {
            let id = mode == .host ? "host:" + (host ?? "") : "project:" + (host ?? "") + "\u{1F}" + (project ?? "")
            if let i = index[id] { return i }
            let title: String
            if mode == .host {
                title = host.map(shortHost) ?? thisMac
            } else {
                let name = project.map { projectName($0, home: host == nil ? home : nil) }
                switch (host, name) {
                case (let host?, let name?): title = shortHost(host) + " · " + name
                case (let host?, nil): title = shortHost(host)
                case (nil, let name?): title = name
                case (nil, nil): title = other
                }
            }
            groups.append(SidebarGroup(id: id, title: title, host: host, project: mode == .project ? project : nil))
            index[id] = groups.count - 1
            return groups.count - 1
        }
        for (i, place) in places.enumerated() { groups[group(host: place.host, project: place.project)].tabs.append(i) }
        for session in elsewhere { groups[group(host: session.host, project: session.project)].elsewhere.append(session) }
        if mode == .host, let local = groups.firstIndex(where: { $0.host == nil }), local > 0 {
            groups.insert(groups.remove(at: local), at: 0)
        }
        return groups
    }

    /// Whether the groups get headers: not for a lone machine with nothing
    /// elsewhere (by host, a header saying "This Mac" over every tab says
    /// nothing). A lone project keeps its: its name is news.
    static func showsHeaders(_ groups: [SidebarGroup], mode: SidebarGrouping) -> Bool {
        guard mode != .none, !groups.isEmpty else { return false }
        return !(mode == .host && groups.count == 1 && groups[0].elsewhere.isEmpty)
    }

    /// The sidebar's rows: with headers, each group's header, its tabs and
    /// its sessions elsewhere — a folded group (`collapsed`) only its header,
    /// and the selected tab if it's there (the tab you're in never hides).
    /// Without them, the tabs in order.
    static func rows(tabCount: Int, groups: [SidebarGroup], headers: Bool, collapsed: Set<String>, selected: Int) -> [SidebarRow] {
        guard headers else { return (0..<tabCount).map(SidebarRow.tab) }
        var rows: [SidebarRow] = []
        for (g, group) in groups.enumerated() {
            rows.append(.header(g))
            let folded = collapsed.contains(group.id)
            for tab in group.tabs where !folded || tab == selected { rows.append(.tab(tab)) }
            if !folded { rows += group.elsewhere.indices.map { .elsewhere(group: g, index: $0) } }
        }
        return rows
    }

    /// Where in the window's tabs a tab dropped above `row` goes: after the
    /// tab above it in its group, else first in the group under the header
    /// it was dropped below. (Its group is still its project's or host's: a
    /// drop reorders the tabs, and their groups follow them.)
    static func insertionIndex(above row: Int, rows: [SidebarRow], groups: [SidebarGroup], tabCount: Int) -> Int {
        var r = min(row, rows.count) - 1
        while r >= 0 {
            switch rows[r] {
            case .tab(let i): return i + 1
            case .elsewhere: r -= 1
            case .header(let g): return groups.indices.contains(g) ? groups[g].tabs.first ?? tabCount : tabCount
            }
        }
        return 0
    }

    /// The window's tabs in their new order (each its old index), `tab`
    /// moved to before the `position`th of `group`'s tabs (their indices,
    /// in the window's order; `group.count` is after the last). The group's
    /// tabs trade the places they had in the window's order between them:
    /// no other tab moves, so no group changes places (a group is where its
    /// first tab is). nil: nothing would move.
    static func reorder(count: Int, group: [Int], moving tab: Int, before position: Int) -> [Int]? {
        guard let from = group.firstIndex(of: tab), (0...group.count).contains(position),
              group.allSatisfy({ (0..<count).contains($0) }) else { return nil }
        var list = group
        list.remove(at: from)
        list.insert(tab, at: position > from ? position - 1 : position)
        guard list != group else { return nil }
        var order = Array(0..<count)
        for (slot, i) in zip(group.sorted(), list) { order[slot] = i }
        return order
    }

    /// Where a tab of this window dropped above `row` goes: its group's
    /// tabs and the place among them (`reorder`'s), or nil when the drop is
    /// outside its group — a tab's group is its project's or host's, which
    /// a drag doesn't change. Without headers every tab is in one list.
    static func dropPlace(above row: Int, rows: [SidebarRow], groups: [SidebarGroup], headers: Bool,
                          tabCount: Int, dragged: Int) -> (group: [Int], position: Int)? {
        guard headers else { return (Array(0..<tabCount), max(0, min(row, tabCount))) }
        guard let g = groups.firstIndex(where: { $0.tabs.contains(dragged) }), row > 0, !rows.isEmpty else { return nil }
        let mine = groups[g].tabs
        switch rows[min(row, rows.count) - 1] {
        case .tab(let i): return mine.firstIndex(of: i).map { (mine, $0 + 1) }
        case .header(let h): return h == g ? (mine, 0) : nil
        case .elsewhere(let h, _): return h == g ? (mine, mine.count) : nil
        }
    }

    /// The tab to show when tab `closing` closes: the next as listed
    /// (`listed`: the tabs' indices as the sidebar lists them), else the
    /// one before.
    static func successor(of closing: Int, in listed: [Int]) -> Int? {
        guard let k = listed.firstIndex(of: closing) else { return nil }
        if k + 1 < listed.count { return listed[k + 1] }
        return k > 0 ? listed[k - 1] : nil
    }

    /// "me@devbox.example" as a header says it: "devbox.example".
    static func shortHost(_ destination: String) -> String {
        destination.split(separator: "@", maxSplits: 1).last.map(String.init) ?? destination
    }

    /// A project's name: its folder's ("api"); home is "~" (this Mac's,
    /// `home`), the top "/".
    static func projectName(_ path: String, home: String?) -> String {
        if let home, path == home { return "~" }
        if path == "/" { return "/" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The project a folder is in: the repository around it — a worktree's
    /// main checkout, so a repository's worktrees group together — else nil.
    /// Reads the file system (a `.git` folder, or a worktree's `.git` file),
    /// never runs git; off the main thread (`ProjectRoots`).
    static func repository(around directory: String, fileManager fm: FileManager = .default) -> String? {
        var dir = (directory as NSString).standardizingPath
        while true {
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                // A worktree's: "gitdir: /repo/.git/worktrees/NAME".
                if let text = try? String(contentsOfFile: git, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let absolute = gitDir.hasPrefix("/") ? gitDir : (dir as NSString).appendingPathComponent(gitDir)
                    if let r = absolute.range(of: "/.git/worktrees/") { return String(absolute[..<r.lowerBound]) }
                }
                return dir
            }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}

/// Each folder's project (`SidebarGroups.repository`), looked up off the
/// main thread once a minute at most; asked on the main thread.
final class ProjectRoots {
    static let shared = ProjectRoots()
    static let freshFor: TimeInterval = 60

    private var known: [String: (root: String?, at: Date)] = [:]
    private var reading: Set<String> = []
    private let queue = DispatchQueue(label: "libertty.project-roots", qos: .utility)

    /// The project `directory` is in — the repository around it, else the
    /// folder itself (also while that isn't known yet: `SidebarGroups.changed`
    /// is posted once it is, if it's another).
    func project(of directory: String) -> String {
        let now = Date()
        let entry = known[directory]
        if entry.map({ now.timeIntervalSince($0.at) > Self.freshFor }) ?? true, !reading.contains(directory) {
            reading.insert(directory)
            queue.async { [weak self] in
                let root = SidebarGroups.repository(around: directory)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reading.remove(directory)
                    let before = self.known[directory]
                    self.known[directory] = (root, Date())
                    // Folders not asked about for a while go (a long-lived app visits many).
                    if self.known.count > 512 {
                        let now = Date()
                        self.known = self.known.filter { now.timeIntervalSince($0.value.at) < Self.freshFor * 10 }
                    }
                    if before == nil ? root != nil : before?.root != root {
                        NotificationCenter.default.post(name: SidebarGroups.changed, object: nil)
                    }
                }
            }
        }
        return entry?.root ?? directory
    }
}

/// Sessions the liberttyds keep that no window here shows, for a grouped
/// sidebar's rows: this Mac's, and those of the hosts a window here is on
/// (only over their shared ssh link while it's up — a host whose link is
/// down is never dialed, and one with no window here isn't asked: asking
/// would keep its link up for good). Read off the main thread every few
/// seconds while a grouped sidebar is in front of you (shown, in a visible
/// window, the app active); a liberttyd that doesn't answer in time just
/// has none listed.
final class ElsewhereSessions {
    static let shared = ElsewhereSessions()
    static let every: TimeInterval = 4
    /// Hosts are asked less often than this Mac: each is an ssh channel.
    static let hostsEvery: TimeInterval = 12

    /// Every liberttyd's sessions not shown here as last read, as rows: by
    /// host (nil: this Mac); and when each of those readings began.
    private var read: [String?: [ElsewhereSession]] = [:]
    private var readStarted: [String?: Date] = [:]
    private var askingLocal = false, askingHosts = false
    private var hostsAskedAt = Date.distantPast
    private var timer: Timer?
    /// The windows whose sidebars asked (kept weakly): reading goes on while one still wants it.
    private let askers = NSHashTable<TerminalWindowController>.weakObjects()
    private let queue = DispatchQueue(label: "libertty.elsewhere-sessions", qos: .utility)
    private let hostQueue = DispatchQueue(label: "libertty.elsewhere-sessions.hosts", qos: .utility)
    /// Folders' projects as this Mac's rows found them (on `queue` only).
    private var roots: [String: (root: String?, at: Date)] = [:]

    private init() {
        // Back in front (the app active again, a window uncovered): reading
        // goes on, as the sidebar would ask at its next update.
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.resume() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: resume)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main, using: resume)
    }

    /// A session's key among those shown: its machine and ID.
    private static func key(_ host: String?, _ id: String) -> String { (host ?? "") + "\u{1F}" + id }

    /// The sessions the panes of `windows` show, by key.
    private static func shown(in windows: [TerminalWindowController]) -> Set<String> {
        var shown = Set<String>()
        for controller in windows {
            for pane in controller.allPanes {
                guard let id = pane.session.persistentID else { continue }
                shown.insert(key(pane.session.host?.destination ?? controller.host?.destination, id))
            }
        }
        return shown
    }

    /// The sessions not shown by any pane of `windows` (those of every
    /// window here), as rows; keeps reading while asked for.
    func sessions(shownIn windows: [TerminalWindowController], for asker: TerminalWindowController) -> [ElsewhereSession] {
        askers.add(asker)
        if asker.wantsElsewhereSessions { keepReading() }
        // Shown now, or until a moment ago: a tab just closed ends its
        // session, and a list read before that would bring it back as a row.
        let now = Date()
        let shown = Self.shown(in: windows)
        for key in shownBefore.subtracting(shown) { goneAt[key] = now }
        for key in shown { goneAt[key] = nil }
        goneAt = goneAt.filter { now.timeIntervalSince($0.value) < Self.keepGone }
        shownBefore = shown
        // (A closed tab's session lives on while its close can be undone.)
        let forget = Self.forgetAfter + max(0, ConfigStore.shared.config.undoTimeout)
        // This Mac's first, then the hosts' by name.
        return read.keys.sorted { ($0 ?? "") < ($1 ?? "") }.flatMap { host in
            let started = readStarted[host] ?? .distantPast
            return (read[host] ?? []).filter {
                let key = Self.key(host, $0.id)
                // Gone from here since a moment before its list was read
                // (a slow host's round may end well after it began).
                if let gone = goneAt[key], started.timeIntervalSince(gone) < forget { return false }
                return !shown.contains(key)
            }
        }
    }

    /// The sessions panes here showed at the last asking, and when those
    /// that stopped showing did (kept long enough for any reading begun
    /// before then to have been replaced).
    private var shownBefore = Set<String>()
    private var goneAt: [String: Date] = [:]
    private static let keepGone: TimeInterval = 15 * 60
    /// Long enough for a session ended here to be gone from its liberttyd's next list.
    static let forgetAfter: TimeInterval = 10

    /// A session's row (on `queue` or `hostQueue`: its folder and project
    /// are looked up in the file system, a local one's program in the kernel).
    private func row(_ s: SessionInfo, host: String?) -> ElsewhereSession {
        var dir = SessionInfo.directory(fromPwd: s.workingDirectory)
        var program = ""
        if host == nil {
            // This Mac's: what runs in front there, and where (a program
            // that never said its folder, as a shell does, still has one).
            var buf = [CChar](repeating: 0, count: 1024)
            let fg = libertty_proc_tty_pgid(s.pid)
            libertty_proc_name(fg > 0 ? fg : s.pid, &buf, Int32(buf.count))
            program = String(cString: buf)
            if dir == nil {
                buf = [CChar](repeating: 0, count: 1024)
                libertty_proc_cwd(fg > 0 ? fg : s.pid, &buf, Int32(buf.count))
                let cwd = String(cString: buf)
                if !cwd.isEmpty { dir = cwd }
            }
        } else {
            // Another machine's processes: what its liberttyd says it runs.
            program = ((s.command.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let detail = dir.map { host == nil ? ($0 as NSString).abbreviatingWithTildeInPath : $0 } ?? ""
        let title = s.label.flatMap { $0.isEmpty ? nil : $0 } ?? (s.title.isEmpty ? (program.isEmpty ? s.id : program) : s.title)
        let project = dir.map { host == nil ? localProject($0) : $0 }
        return ElsewhereSession(id: s.id, host: host, title: title, detail: detail, directory: dir, project: project, clients: s.clients)
    }

    /// The repository around a folder of this Mac's, else the folder; looked
    /// up again once a minute at most (on `queue`).
    private func localProject(_ dir: String) -> String {
        let now = Date()
        if let known = roots[dir], now.timeIntervalSince(known.at) < ProjectRoots.freshFor { return known.root ?? dir }
        let root = SidebarGroups.repository(around: dir)
        if roots.count > 512 { roots = roots.filter { now.timeIntervalSince($0.value.at) < ProjectRoots.freshFor } }
        roots[dir] = (root, now)
        return root ?? dir
    }

    /// Read again every few seconds while a grouped sidebar is in front of
    /// you; the timer stops once none is (the next asking, or the app or a
    /// window coming back in front, starts it again).
    private func keepReading() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func resume() {
        guard timer == nil, askers.allObjects.contains(where: \.wantsElsewhereSessions) else { return }
        keepReading()
    }

    private func tick() {
        let wanting = askers.allObjects.filter(\.wantsElsewhereSessions)
        guard !wanting.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        let windows = (NSApp.delegate as? AppDelegate)?.allControllers ?? []
        // Those shown here are left out before their rows are made (and
        // before a reading is compared with the last: their changes are
        // their tabs', not the list's).
        let shown = Self.shown(in: windows + wanting)
        // This Mac's liberttyd answers at once; the hosts' are read apart,
        // so one slow to answer holds up no other list.
        if !askingLocal {
            askingLocal = true
            let local = Persistence.enabled
            let started = Date()
            queue.async { [weak self] in
                guard let self else { return }
                // nil: no answer, so none listed.
                let mine = local ? DaemonClient.sessions().map {
                    $0.filter { !shown.contains(Self.key(nil, $0.id)) }.map { self.row($0, host: nil) }
                } : nil
                DispatchQueue.main.async {
                    self.askingLocal = false
                    var next = self.read
                    // A folder as a tab's row says it: "…/repos/beta".
                    next[nil] = mine?.map { s in
                        var s = s
                        s.detail = TerminalWindowController.shortDirectory(s.directory)
                        return s
                    }
                    self.readStarted[nil] = started
                    self.take(next)
                }
            }
        }
        // The hosts a window here is on (their links are up for those
        // windows anyway). Over the link only: `quietAddress` dials only
        // while the host is set up and its shared connection up, never
        // logging in.
        let now = Date()
        guard !askingHosts, now.timeIntervalSince(hostsAskedAt) >= Self.hostsEvery else { return }
        hostsAskedAt = now
        askingHosts = true
        var hosts: [String] = []
        for controller in windows + wanting {
            if let host = controller.host?.destination, !hosts.contains(host) { hosts.append(host) }
        }
        hostQueue.async { [weak self] in
            guard let self else { return }
            // nil: no answer, or not asked (not linked), so none listed.
            let theirs: [(String, [ElsewhereSession]?)] = hosts.map { destination in
                let address = RemoteHost.named(destination).quietAddress
                let list = DaemonClient.sessions(address: address)?.filter { !shown.contains(Self.key(destination, $0.id)) }
                return (destination, list?.map { self.row($0, host: destination) })
            }
            DispatchQueue.main.async {
                self.askingHosts = false
                // Hosts no longer here list nothing any more.
                var next = self.read.filter { $0.key == nil }
                for (host, rows) in theirs {
                    next[host] = rows
                    self.readStarted[host] = now
                }
                self.take(next)
            }
        }
    }

    /// A new reading: the windows hear when it differs.
    private func take(_ next: [String?: [ElsewhereSession]]) {
        guard next != read else { return }
        read = next
        NotificationCenter.default.post(name: SidebarGroups.changed, object: nil)
    }
}
