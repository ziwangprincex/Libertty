import AppKit
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

    /// Its panel has no close button, yet ⌘W on its last pane, Close Tab
    /// and Close Window close it, asking its delegate first as a window's
    /// close does (AppKit's own performClose only beeps there).
    @Test func itsPanelClosesAsAWindowDoes() {
        final class Delegate: NSObject, NSWindowDelegate {
            var allow = false, asked = 0, closed = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { asked += 1; return allow }
            func windowWillClose(_ notification: Notification) { closed += 1 }
        }
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let delegate = Delegate()
        panel.delegate = delegate
        panel.performClose(nil)
        #expect(delegate.asked == 1 && delegate.closed == 0)
        delegate.allow = true
        panel.performClose(nil)
        #expect(delegate.asked == 2 && delegate.closed == 1)
    }
}
