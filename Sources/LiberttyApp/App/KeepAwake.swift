import AppKit
import IOKit.pwr_mgt

/// `keep-awake` (Kero's Keep computer awake): the Mac doesn't go to sleep
/// while you're away — always, or while a coding agent in a pane works.
/// The display still sleeps; only idle system sleep is held off.
final class KeepAwake {
    static let shared = KeepAwake()

    enum Mode: String, CaseIterable {
        case never, always, agents
    }

    private var assertion: IOPMAssertionID = 0
    /// Whether sleep is held off now.
    private(set) var holding = false

    /// What `mode` asks, given whether any agent works now.
    static func wants(_ mode: Mode, agentsWorking: Bool) -> Bool {
        mode == .always || (mode == .agents && agentsWorking)
    }

    /// A pane whose agent works: a working record of a coding agent's (its
    /// hooks', its screen's), or of any program in a pane an agent fronts.
    static func agentWorks(status: ProgramStatusStore, tileAgent: String?) -> Bool {
        status.records.values.contains { record in
            record.state == .working && (tileAgent != nil || ProgramBadge.agentKey(status.effectiveApp(of: record)) != nil)
        }
    }

    func update(mode: Mode, agentsWorking: Bool) {
        let want = Self.wants(mode, agentsWorking: agentsWorking)
        guard want != holding else { return }
        if want {
            let reason = (mode == .always ? "keep-awake = always" : "A coding agent is working") as CFString
            holding = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            holding = false
        }
    }
}
