#if LIBERTTY_PROBES
import Foundation
import LiberttyCore

/// `Libertty --layout-store-probe`: liberttyd keeps the window layouts the
/// app hands it (GoRex: the server holds the layout), one per Mac, gives a
/// Mac its own back (or, to one it hasn't seen, the latest any Mac stored for
/// this host — never a Mac's own windows), says it can before anyone relies
/// on it, and carries the layouts across a takeover — when a newer
/// liberttyd replaces the running one, they must come along with the
/// sessions, or windows would come back as loose tabs.
enum LayoutStoreProbe {
    static func run() -> Never {
        Persistence.setUp(wanted: true)
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok    layout-store \(what)" : "FAIL  layout-store \(what)")
            if !ok { failures += 1 }
        }
        func store(_ text: String, as client: String, local: Bool = false) -> Bool {
            let body = Data(text.utf8).withUnsafeBytes { Connection.headed(["client": client, "local": local], body: $0) }
            return DaemonClient.request(.storeLayout, payload: body)?.json["ok"] as? Bool == true
        }
        func load(as client: String, local: Bool = false) -> String? {
            guard let frame = DaemonClient.request(.loadLayout, json: ["client": client, "local": local]),
                  frame.kind == .result, let (_, body) = frame.headerAndBody else { return nil }
            return String(decoding: body, as: UTF8.self)
        }

        check(DaemonClient.hello()?.features.contains("layout") == true, "says it keeps layouts")
        check(load(as: "mac-a") == "", "nothing before the app gives one")
        check(store("A1", as: "mac-a"), "takes a layout")
        check(load(as: "mac-a") == "A1", "gives it back")
        check(store("A2", as: "mac-a") && load(as: "mac-a") == "A2", "keeps a Mac's newest")
        usleep(20_000)
        check(store("B1", as: "mac-b"), "takes another Mac's")
        check(load(as: "mac-a") == "A2", "each Mac gets its own")
        check(load(as: "mac-new") == "B1", "a Mac it hasn't seen gets the latest")
        usleep(20_000)
        check(store("HOME", as: "mac-h", local: true), "takes a Mac's own windows")
        check(load(as: "mac-h", local: true) == "HOME", "gives a Mac its own windows back")
        check(load(as: "mac-new") == "B1", "never gives a Mac's own windows to another")
        check(load(as: "mac-new", local: true) == "", "no own windows for a Mac it hasn't seen")
        check(store("", as: "mac-b") && load(as: "mac-new") == "A2", "an empty layout leaves")
        // A bounded number: the oldest go first.
        for i in 0..<40 { _ = store("X\(i)", as: "mac-x\(i)") }
        check(load(as: "mac-x0") == "X39" && load(as: "mac-x39") == "X39", "keeps the newest so many")
        _ = store("HOME2", as: "mac-h", local: true)

        // What Connect to Host brings back of a kept window: it comes for a
        // session no window shows; one some window shows gets a fresh shell
        // instead of a second window on it; another Mac's documents stay there.
        let kept = SavedWindow(frame: "", sidebar: true, inspector: false, fontSize: nil, selected: 1, tabs: [
            SavedTab(document: "/tmp/notes.md"),
            SavedTab(panes: SavedPane(axis: "h", ratio: 0.5, children: [SavedPane(session: "free"), SavedPane(document: "/tmp/x.md")])),
            SavedTab(panes: SavedPane(session: "shown")),
        ])
        let theirs = kept.forConnect(detached: ["free"], documents: false)
        check(theirs?.tabs.count == 2 && theirs?.tabs[0].panes?.session == "free" && theirs?.tabs[1].panes?.session == nil
              && theirs?.selected == 0, "another Mac's window: its free sessions, fresh shells, no documents")
        let mine = kept.forConnect(detached: ["free"], documents: true)
        check(mine?.tabs.count == 3 && mine?.tabs[1].panes?.children?.count == 2, "this Mac's own window: documents too")
        check(kept.forConnect(detached: ["elsewhere"], documents: true) == nil, "a window with nothing free stays")

        // A parked pane is a session too: it makes its window worth keeping,
        // and comes back only while its session is there.
        var withParked = SavedTab(panes: SavedPane(session: "shown"))
        withParked.parked = [SavedParked(pane: SavedPane(session: "away"), anchor: 0, side: "right"),
                             SavedParked(pane: SavedPane(session: "gone"), anchor: 0, side: "down")]
        let parkedWindow = SavedWindow(frame: "", sidebar: true, inspector: false, fontSize: nil, selected: 0, tabs: [withParked])
        check(parkedWindow.livesIn(["away"]), "a window whose only live session is parked is kept")
        let reconnected = parkedWindow.forConnect(detached: ["away"], documents: true)
        check(reconnected?.tabs.first?.parked?.count == 1 && reconnected?.tabs.first?.parked?.first?.pane.session == "away",
              "parked panes come back only with their session")

        // Workspaces ride in the tabs: grouped by name, a front tab each. The
        // file is read back as it was written, and an old one (no names)
        // still decodes.
        var a1 = SavedTab(panes: SavedPane(session: "w1a")); a1.workspace = "Default"
        var a2 = SavedTab(panes: SavedPane(session: "w1b")); a2.workspace = "Default"; a2.front = true
        var b1 = SavedTab(panes: SavedPane(session: "w2a")); b1.workspace = "Build"; b1.front = true
        let multi = SavedWindow(frame: "", sidebar: true, inspector: false, fontSize: nil, selected: 2, tabs: [a1, a2, b1])
        if let data = try? JSONEncoder().encode(SavedState(windows: [multi])),
           let back = try? JSONDecoder().decode(SavedState.self, from: data) {
            let t = back.windows.first?.tabs ?? []
            check(t.map { $0.workspace ?? "-" } == ["Default", "Default", "Build"] && t.map { $0.front == true } == [false, true, true]
                  && back.windows.first?.selected == 2, "workspace names and front tabs survive the file")
        } else {
            check(false, "workspaces: the layout didn't round-trip")
        }
        let oldFile = Data(#"{"version":1,"windows":[{"frame":"","sidebar":true,"inspector":false,"selected":0,"tabs":[{"panes":{"session":"x"}}]}]}"#.utf8)
        check((try? JSONDecoder().decode(SavedState.self, from: oldFile))?.windows.first?.tabs.first?.workspace == nil,
              "a layout from before workspaces still loads")
        check(multi.livesIn(["w2a"]), "a window whose live session is in another workspace is kept")
        let multiNew = multi.forConnect(detached: ["w2a"], documents: true)
        check(multiNew?.tabs.map { $0.workspace ?? "-" }.contains("Build") == true, "Connect keeps a workspace with a free session")

        // A session keeps the daemon from leaving while it's replaced.
        let session = try? TerminalSession(size: GridSize(cols: 40, rows: 5, widthPx: 400, heightPx: 100))
        try? session?.start(command: "sleep 30")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = DaemonClient.hello()?.pid
        guard let exe = Persistence.daemonExecutable else {
            print("layout-store: no liberttyd to take over with")
            exit(1)
        }
        // The takeover: a fresh liberttyd asks the running one for everything.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--takeover"]
        var env = ProcessInfo.processInfo.environment
        env["LIBERTTY_DAEMON_SOCKET"] = Wire.socketPath
        p.environment = env
        p.standardError = FileHandle.nullDevice
        try? p.run()
        var after: pid_t?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let pid = DaemonClient.hello(timeout: 0.5)?.pid, pid != before { after = pid; break }
            usleep(50_000)
        }
        check(after != nil && after != before, "a newer liberttyd took over")
        check(load(as: "mac-x39") == "X39" && load(as: "mac-h", local: true) == "HOME2" && load(as: "mac-new") == "X39",
              "the layouts came along, each still its kind")
        session?.terminate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        _ = DaemonClient.request(.shutdown)
        print(failures == 0 ? "layout-store: all passed" : "layout-store: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
