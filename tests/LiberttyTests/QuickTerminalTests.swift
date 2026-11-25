import Foundation
import Testing
@testable import LiberttyApp

/// The Quick Terminal's liberttyd session from last time is its own before
/// it first comes down: launch's window of orphans, the palette's Show
/// Session rows and the sidebar's sessions elsewhere leave it out by this.
@MainActor
struct QuickTerminalTests {
    @Test func itsSessionIsItsOwnBeforeItComesDown() {
        // In the registration domain: in memory only, put back as it was.
        let defaults = UserDefaults.standard
        let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain) }
        #expect(QuickTerminal().sessionToAttach == nil)
        defaults.register(defaults: ["QuickTerminalSession": "quick-1"])
        #expect(QuickTerminal().sessionToAttach == "quick-1")
    }
}
