import Foundation
import IOKit.pwr_mgt
import Testing
@testable import LiberttyApp

/// keep-awake: when it holds off sleep, and that it really does.
struct KeepAwakeTests {
    @Test func whenItHolds() {
        #expect(!KeepAwake.wants(.never, agentsWorking: true))
        #expect(KeepAwake.wants(.always, agentsWorking: false))
        #expect(KeepAwake.wants(.agents, agentsWorking: true))
        #expect(!KeepAwake.wants(.agents, agentsWorking: false))
    }

    @Test func whichPanesCountAsAnAgentWorking() {
        let store = ProgramStatusStore()
        #expect(!KeepAwake.agentWorks(status: store, tileAgent: "codex"))
        store.apply(.init(clear: false, state: .working, kind: .none, progress: nil, id: "build", app: "cargo", title: "", message: ""))
        #expect(!KeepAwake.agentWorks(status: store, tileAgent: nil))  // a build, not an agent
        #expect(KeepAwake.agentWorks(status: store, tileAgent: "codex"))  // in an agent's pane
        store.apply(.init(clear: false, state: .working, kind: .none, progress: nil, id: "turn", app: "claude-code", title: "", message: ""))
        #expect(KeepAwake.agentWorks(status: store, tileAgent: nil))  // Claude Code's hooks, over ssh
        store.clear(id: "")
        store.apply(.init(clear: false, state: .blocked, kind: .none, progress: nil, id: "turn", app: "claude-code", title: "", message: ""))
        #expect(!KeepAwake.agentWorks(status: store, tileAgent: "claude"))  // waiting for you isn't working
    }

    @Test func holdsAndLetsGo() throws {
        let awake = KeepAwake()
        awake.update(mode: .always, agentsWorking: false)
        #expect(awake.holding)
        #expect(ours() >= 1)
        awake.update(mode: .agents, agentsWorking: false)
        #expect(!awake.holding)
        #expect(ours() == 0)
    }

    /// This process's assertions against idle sleep.
    private func ours() -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return -1 }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.filter { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertPreventUserIdleSystemSleep }.count
    }
}

/// The menu bar icon's menu (not shown: a test puts nothing in the menu bar).
@MainActor
struct MenuBarIconTests {
    @Test func itsMenu() {
        let icon = MenuBarIcon.shared
        #expect(!icon.isShown)
        icon.update(waiting: 0)
        #expect(icon.menuTitles.contains("Nothing waiting for you"))
        #expect(!icon.menuTitles.contains("Jump to Pane Needing You"))
        icon.update(waiting: 2)
        let titles = icon.menuTitles
        #expect(titles.first == "2 waiting for you")
        for title in ["Jump to Pane Needing You", "Quick Terminal", "Keep Mac Awake", "Settings…"] {
            #expect(titles.contains(title), "\(title)")
        }
        icon.update(waiting: 0)
    }
}
