import Foundation
import Testing
@testable import LiberttyApp

/// Mute Tab: what a muted tab still does, and what it no longer does.
struct TabMuteTests {
    /// Its bell shows (the pane's edge, the tab's mark) but makes no sound
    /// and doesn't bounce the Dock icon; an unmuted tab's is as it was.
    @Test func theBell() {
        let all: Set<String> = ["system", "audio", "attention", "title", "border"]
        #expect(TabMute.bellFeatures(all, muted: true) == ["title", "border"])
        #expect(TabMute.bellFeatures(all, muted: false) == all)
        #expect(TabMute.bellFeatures(["attention", "title"], muted: true) == ["title"])
    }

    /// The Dock badge and the menu bar's icon leave a muted tab's panes out.
    @Test func theBadgeCount() {
        func store(_ state: ProgramStatusStore.State?) -> ProgramStatusStore {
            let store = ProgramStatusStore()
            if let state {
                store.apply(.init(clear: false, state: state, kind: .none, progress: nil, id: "", app: "probe", title: "", message: ""))
            }
            return store
        }
        let waiting = store(.blocked), alsoWaiting = store(.blocked), working = store(.working), idle = store(nil)
        let counted: Set<ProgramStatusStore.State> = [.blocked]
        #expect(TabMute.badgeCount([(waiting, false), (alsoWaiting, false), (working, false), (idle, false)], counting: counted) == 2)
        #expect(TabMute.badgeCount([(waiting, true), (alsoWaiting, false), (working, false)], counting: counted) == 1)
        #expect(TabMute.badgeCount([(waiting, true), (alsoWaiting, true)], counting: counted) == 0)
        // What the setting counts still decides, muted or not.
        #expect(TabMute.badgeCount([(working, false)], counting: [.working]) == 1)
        #expect(TabMute.badgeCount([(working, true)], counting: [.working]) == 0)
    }

    /// A muted tab's notification is kept in Activity, already read, and no
    /// banner goes out; an unmuted one's is as before.
    @Test func notificationsGoQuietly() {
        let notifier = Notifier()
        notifier.post(title: "Waiting for you: probe", body: "", pane: "muted-pane", quietly: true)
        #expect(notifier.inbox.count == 1)
        #expect(notifier.unread == 0)
        #expect(notifier.posted == 0)
        notifier.post(title: "Waiting for you: probe", body: "", pane: "other-pane")
        #expect(notifier.inbox.count == 2)
        #expect(notifier.unread == 1)
        #expect(notifier.posted == 1)
        #expect(notifier.inbox.map(\.pane) == ["other-pane", "muted-pane"])
    }

    @Test func theAction() {
        #expect(Action("toggle_tab_mute") == .toggleTabMute)
        #expect(Action.toggleTabMute.configString == "toggle_tab_mute")
        #expect(Action.catalog.contains { $0.0 == "toggle_tab_mute" })
        #expect(SettingsShortcuts.groups.flatMap(\.actions).contains { $0.action == "toggle_tab_mute" })
        // The menus and the palette say what choosing it does now.
        #expect(TabMute.title(muted: false) == L10n.t("Mute Tab"))
        #expect(TabMute.title(muted: true) == L10n.t("Unmute Tab"))
    }

    /// Saved with the window; a layout saved before there was muting has none.
    @Test func savedWithTheWindow() throws {
        var tab = SavedTab(panes: SavedPane(session: "s1"))
        tab.muted = true
        let data = try JSONEncoder().encode(tab)
        #expect(try JSONDecoder().decode(SavedTab.self, from: data).muted == true)
        let old = try JSONDecoder().decode(SavedTab.self, from: Data(#"{"panes":{"session":"s1"}}"#.utf8))
        #expect(old.muted == nil)
        // Not muted: nothing written for it.
        let plain = try JSONEncoder().encode(SavedTab(panes: SavedPane(session: "s1")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("muted"))
    }
}
