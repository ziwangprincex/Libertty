import Foundation

/// Mute Tab (`toggle_tab_mute`): a muted tab goes on working and showing
/// what it does — its badge and ring, the pane's edge lighting up, its
/// entries in Activity — but nothing of it interrupts you: no bell or
/// program state's sound, no notification, no Dock bounce (for its bell or
/// a script's question), no count on the Dock's badge or the menu bar's
/// icon, nothing VoiceOver is told of it from another pane. Each place that
/// would asks the one question, `TerminalWindowController.isMuted(_:)`;
/// what a muted tab keeps is here.
enum TabMute {
    /// What the bell (`bell-features`) does in a tab muted or not: muted,
    /// its sound and the Dock's bounce go; the pane's edge and the tab's
    /// mark stay.
    static func bellFeatures(_ features: Set<String>, muted: Bool) -> Set<String> {
        muted ? features.subtracting(["system", "audio", "attention"]) : features
    }

    /// How many panes the Dock badge and the menu bar's icon count: those
    /// whose program is in a state they count (`program-status-dock-badge`),
    /// in tabs that aren't muted.
    static func badgeCount(_ panes: [(status: ProgramStatusStore, muted: Bool)],
                           counting states: Set<ProgramStatusStore.State>) -> Int {
        panes.filter { !$0.muted && $0.status.headline(among: states) != nil }.count
    }

    /// The tab menus' item and the palette's command: what choosing it does now.
    static func title(muted: Bool) -> String { L10n.t(muted ? "Unmute Tab" : "Mute Tab") }

    /// The glyph a muted tab shows beside its name (monochrome, as its words are).
    static let symbol = "speaker.slash"
}
