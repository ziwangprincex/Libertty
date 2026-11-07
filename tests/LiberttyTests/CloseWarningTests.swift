import Foundation
import Testing
@testable import LiberttyApp
import LiberttyCore

/// A close's question says what it would end (Rex's "Did you mean to
/// close"): an agent at work or waiting on you by name, else a program.
@MainActor struct CloseWarningTests {
    typealias R = TerminalWindowController.Running

    @Test func agentsByNameAndState() {
        #expect(TerminalWindowController.closeWarning([R(program: "Claude Code", agent: true, state: .working)])
                == "Claude Code is still working. Closing ends it.")
        #expect(TerminalWindowController.closeWarning([R(program: "Codex", agent: true, state: .blocked)])
                == "Codex is waiting for your answer. Closing ends it.")
        #expect(TerminalWindowController.closeWarning([
            R(program: "Claude Code", agent: true, state: .working), R(program: "vim", agent: false, state: nil),
        ]) == "Claude Code is still working. Closing ends it. 1 other program will be ended too.")
        let many = (0..<4).map { R(program: "Agent \($0)", agent: true, state: .working) }
        #expect(TerminalWindowController.closeWarning(many)
                == "Agent 0 is still working. Agent 1 is still working. 2 more agents are working or waiting. Closing ends them.")
    }

    @Test func otherwiseAProgram() {
        // An agent at rest (its prompt) is a program like any other.
        #expect(TerminalWindowController.closeWarning([R(program: "Claude Code", agent: true, state: .idle)])
                == "A program is still running and will be ended.")
        #expect(TerminalWindowController.closeWarning([R(program: "htop", agent: false, state: nil), R(program: "vim", agent: false, state: nil)])
                == "2 programs are still running and will be ended.")
    }
}

/// A downloaded update restarts Libertty on its own (auto-update-restart =
/// idle) only when nobody would notice, and nothing would be lost.
@MainActor struct RestartWhenIdleTests {
    @Test func onlyWhenNobodyWouldNotice() {
        func may(front: Bool = false, kept: Bool = true, programs: Bool = false, unsaved: Bool = false, asking: Bool = false) -> Bool {
            UpdateController.mayRestart(appInFront: front, sessionsKept: kept, programsRunning: programs, unsaved: unsaved, asking: asking)
        }
        #expect(may())
        #expect(!may(front: true))        // you're using it
        #expect(!may(kept: false))        // the shells would end with it
        #expect(!may(programs: true))     // a build, an agent: wait for it
        #expect(!may(unsaved: true))      // an edited document
        #expect(!may(asking: true))       // a sheet waits for an answer
    }
}

@Suite struct PrivacyAccessTests {
    @Test func reportsEveryKindByName() {
        let report = PrivacyAccess.report()
        #expect(Set(report.keys) == Set(PrivacyAccess.kinds))
        #expect(report.values.allSatisfy { PrivacyAccess.Status(rawValue: $0) != nil })
        #expect(report["local-network"] == "unknown")
        #expect(Set(PermissionsCard.kinds.map(\.id)) == Set(PrivacyAccess.kinds))
    }
}
