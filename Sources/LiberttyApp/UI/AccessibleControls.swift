import AppKit

/// AppKit gives VoiceOver a control's cell, not the control: a label set on
/// an NSButton, NSImageView or NSSegmentedControl itself is never read, and
/// an image view told it's no element is still read by its cell. These set
/// both, for any view.
extension NSView {
    /// What VoiceOver calls it.
    func setAccessibleLabel(_ label: String?) {
        setAccessibilityLabel(label)
        (self as? NSControl)?.cell?.setAccessibilityLabel(label)
    }

    /// A picture that says nothing the words beside it don't: VoiceOver skips it.
    func hideFromAccessibility() {
        setAccessibilityElement(false)
        (self as? NSControl)?.cell?.setAccessibilityElement(false)
    }
}

extension NSImage {
    /// An SF Symbol named for what it does here (VoiceOver reads it on an
    /// icon-only button), not by its look ("Up-right arrow in a square").
    static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }
}

enum AccessibilityNews {
    #if LIBERTTY_PROBES
    /// What was announced, VoiceOver running or not (the UI probe's
    /// `expect-announced`): the latest 200.
    @MainActor static var said: [String] = []
    #endif

    /// When each text deduplicated (`once`) was last said.
    @MainActor private static var lastSaid: [String: Date] = [:]

    /// Said once, now, by VoiceOver (or another assistive app): for a change
    /// on screen it wouldn't otherwise notice. Not for every frame. `once`:
    /// not again if the same words were said less than that many seconds
    /// ago (each pane of a host saying its link dropped, say: it's said once).
    @MainActor static func announce(_ text: String, from element: Any? = nil, high: Bool = false, once: TimeInterval = 0) {
        guard !text.isEmpty else { return }
        if once > 0 {
            let now = Date()
            if let last = lastSaid[text], now.timeIntervalSince(last) < once { return }
            lastSaid = lastSaid.filter { now.timeIntervalSince($0.value) < 60 }
            lastSaid[text] = now
        }
        #if LIBERTTY_PROBES
        said.append(text)
        if said.count > 200 { said.removeFirst(said.count - 200) }
        #endif
        NSAccessibility.post(element: element ?? NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
    }

    /// Whether a view is where the user is: in the key window of Libertty in
    /// front (what's said elsewhere would be about something out of sight).
    @MainActor static func isInFront(_ view: NSView) -> Bool {
        view.window?.isKeyWindow == true && NSApp.isActive
    }
}
