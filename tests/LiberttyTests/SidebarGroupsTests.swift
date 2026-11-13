import Foundation
import Testing
@testable import LiberttyApp

/// The sidebar's groups (`sidebar-group`): which tabs go where, in which
/// order, the rows they make, where a dropped tab lands, and a folder's project.
struct SidebarGroupsTests {
    static let home = "/Users/me"

    static func session(_ id: String, host: String? = nil, project: String?) -> ElsewhereSession {
        ElsewhereSession(id: id, host: host, title: id, detail: "", project: project, clients: 0)
    }

    @Test func noneGroupsNothing() {
        #expect(SidebarGroups.groups(.none, places: [TabPlace(host: nil, project: "/a")], elsewhere: []).isEmpty)
        #expect(!SidebarGroups.showsHeaders([], mode: .none))
    }

    /// By project: where each first appears; the tabs keep their order;
    /// a host's projects say the host; nowhere known is "Other".
    @Test func byProject() {
        let places = [
            TabPlace(host: nil, project: "/src/api"), TabPlace(host: nil, project: "/src/web"),
            TabPlace(host: nil, project: "/src/api"), TabPlace(host: "me@devbox", project: "/srv/api"),
            TabPlace(host: nil, project: nil), TabPlace(host: nil, project: Self.home),
        ]
        let groups = SidebarGroups.groups(.project, places: places, elsewhere: [Self.session("s1", project: "/src/web"),
                                                                                Self.session("s2", project: "/src/docs")],
                                          home: Self.home)
        #expect(groups.map(\.title) == ["api", "web", "devbox · api", "Other", "~", "docs"])
        #expect(groups.map(\.tabs) == [[0, 2], [1], [3], [4], [5], []])
        #expect(groups[1].elsewhere.map(\.id) == ["s1"])
        #expect(groups[5].elsewhere.map(\.id) == ["s2"])
        // Ids are stable and distinct: the same folder on another machine is another project.
        #expect(Set(groups.map(\.id)).count == groups.count)
        #expect(groups[0].id != groups[2].id)
        #expect(SidebarGroups.showsHeaders(groups, mode: .project))
        // A lone project keeps its header: its name is news.
        let one = SidebarGroups.groups(.project, places: [TabPlace(host: nil, project: "/src/api")], elsewhere: [])
        #expect(SidebarGroups.showsHeaders(one, mode: .project))
    }

    /// By host: this Mac first, whoever comes first; a lone machine with
    /// nothing elsewhere has no header.
    @Test func byHost() {
        let places = [TabPlace(host: "me@devbox", project: "/srv"), TabPlace(host: nil, project: "/src"),
                      TabPlace(host: "me@devbox", project: "/tmp")]
        let groups = SidebarGroups.groups(.host, places: places, elsewhere: [Self.session("s", host: "pi", project: nil)])
        #expect(groups.map(\.title) == ["This Mac", "devbox", "pi"])
        #expect(groups.map(\.tabs) == [[1], [0, 2], []])
        #expect(groups.allSatisfy { $0.project == nil })
        let alone = SidebarGroups.groups(.host, places: [TabPlace(host: nil, project: "/a"), TabPlace(host: nil, project: "/b")],
                                         elsewhere: [])
        #expect(alone.count == 1 && !SidebarGroups.showsHeaders(alone, mode: .host))
        let waiting = SidebarGroups.groups(.host, places: [TabPlace(host: nil, project: "/a")],
                                           elsewhere: [Self.session("s", project: "/a")])
        #expect(SidebarGroups.showsHeaders(waiting, mode: .host))
    }

    /// The rows: headers, tabs, sessions elsewhere; a folded group keeps the selected tab only.
    @Test func rows() {
        let groups = [SidebarGroup(id: "a", title: "a", tabs: [0, 2], elsewhere: [Self.session("s", project: "/a")]),
                      SidebarGroup(id: "b", title: "b", tabs: [1])]
        #expect(SidebarGroups.rows(tabCount: 3, groups: groups, headers: false, collapsed: [], selected: 0)
                == [.tab(0), .tab(1), .tab(2)])
        #expect(SidebarGroups.rows(tabCount: 3, groups: groups, headers: true, collapsed: [], selected: 0)
                == [.header(0), .tab(0), .tab(2), .elsewhere(group: 0, index: 0), .header(1), .tab(1)])
        #expect(SidebarGroups.rows(tabCount: 3, groups: groups, headers: true, collapsed: ["a"], selected: 2)
                == [.header(0), .tab(2), .header(1), .tab(1)])
        #expect(SidebarGroups.rows(tabCount: 3, groups: groups, headers: true, collapsed: ["a", "b"], selected: 1)
                == [.header(0), .header(1), .tab(1)])
    }

    /// A drop lands after the tab above it in its group, or first in the
    /// group whose header it's under; ungrouped, row N is tab N.
    @Test func dropPlace() {
        let flat: [SidebarRow] = [.tab(0), .tab(1), .tab(2)]
        for row in 0...3 {
            #expect(SidebarGroups.insertionIndex(above: row, rows: flat, groups: [], tabCount: 3) == row)
        }
        // Tabs 0 and 2 in a, 1 in b (a's tabs come first, as the rows list them).
        let groups = [SidebarGroup(id: "a", title: "a", tabs: [0, 2], elsewhere: [Self.session("s", project: nil)]),
                      SidebarGroup(id: "b", title: "b", tabs: [1])]
        let rows = SidebarGroups.rows(tabCount: 3, groups: groups, headers: true, collapsed: [], selected: 0)
        func at(_ row: Int) -> Int { SidebarGroups.insertionIndex(above: row, rows: rows, groups: groups, tabCount: 3) }
        #expect(at(0) == 0)  // above a's header
        #expect(at(1) == 0)  // under it: before a's first tab
        #expect(at(2) == 1)  // after tab 0
        #expect(at(3) == 3)  // after tab 2 (above the session's row)
        #expect(at(4) == 3)  // after the session: still after tab 2
        #expect(at(5) == 1)  // under b's header
        #expect(at(6) == 2)  // after tab 1, the last row
    }

    @Test func names() {
        #expect(SidebarGroups.shortHost("me@devbox.example") == "devbox.example")
        #expect(SidebarGroups.shortHost("devbox") == "devbox")
        #expect(SidebarGroups.projectName("/Users/me", home: "/Users/me") == "~")
        #expect(SidebarGroups.projectName("/", home: nil) == "/")
        #expect(SidebarGroups.projectName("/home/me", home: nil) == "me")
    }

    /// A folder's project: the repository around it — a worktree's main
    /// checkout — found in the file system, else none.
    @Test func repositories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString)").resolvingSymlinksInPath().path
        defer { try? fm.removeItem(atPath: root) }
        let repo = root + "/repo", deep = repo + "/src/app", worktree = root + "/trees/fix", plain = root + "/plain"
        for dir in [repo + "/.git/worktrees/fix", deep, worktree, plain] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try "gitdir: \(repo)/.git/worktrees/fix\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        #expect(SidebarGroups.repository(around: repo) == repo)
        #expect(SidebarGroups.repository(around: deep) == repo)
        #expect(SidebarGroups.repository(around: worktree) == repo)
        #expect(SidebarGroups.repository(around: plain) == nil)
    }
}
