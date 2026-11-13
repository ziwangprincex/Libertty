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
    /// What was announced, VoiceOver running or not (the UI probe's `expect-announced`).
    @MainActor static var said: [String] = []
    #endif

    /// Said once, now, by VoiceOver (or another assistive app): for a change
    /// on screen it wouldn't otherwise notice. Not for every frame.
    @MainActor static func announce(_ text: String, from element: Any? = nil, high: Bool = false) {
        #if LIBERTTY_PROBES
        if !text.isEmpty { said.append(text) }
        #endif
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: element ?? NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
    }
}
