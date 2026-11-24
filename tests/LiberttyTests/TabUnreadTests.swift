import Foundation
import Testing
@testable import LiberttyApp

/// Mark Tab as Unread: a dot on the tab you meant to come back to.
struct TabUnreadTests {
    @Test func theAction() {
        #expect(Action("toggle_tab_unread") == .toggleTabUnread)
        #expect(Action.toggleTabUnread.configString == "toggle_tab_unread")
        #expect(Action.catalog.contains { $0.0 == "toggle_tab_unread" })
        #expect(SettingsShortcuts.groups.flatMap(\.actions).contains { $0.action == "toggle_tab_unread" })
        // The menus and the palette say what choosing it does now.
        #expect(TabNews.markTitle(unread: false) == L10n.t("Mark Tab as Unread"))
        #expect(TabNews.markTitle(unread: true) == L10n.t("Mark Tab as Read"))
    }

    /// Its dot shows whatever the tab's badge says; news of what happened
    /// there shows only when the badge doesn't say it already.
    @Test func showsOverABadge() {
        var tab = SidebarTabInfo(title: "build", status: .done, paneCount: 1)
        tab.news = .attention
        #expect(!tab.showsNews)
        tab.news = .unread
        #expect(tab.showsNews)
        tab.status = nil
        tab.news = .attention
        #expect(tab.showsNews)
        tab.news = .none
        #expect(!tab.showsNews)
    }

    /// The filter for tabs with something to see lists it.
    @Test func listedWithWhatsToSee() {
        var tab = SidebarTabInfo(title: "notes", status: nil, paneCount: 1)
        #expect(!TabActivity.attention.includes(tab))
        tab.news = .unread
        #expect(TabActivity.attention.includes(tab))
        #expect(!TabActivity.waiting.includes(tab))
    }

    /// Saved with the window; a layout saved before there was marking has none.
    @Test func savedWithTheWindow() throws {
        var tab = SavedTab(panes: SavedPane(session: "s1"))
        tab.unread = true
        let data = try JSONEncoder().encode(tab)
        #expect(try JSONDecoder().decode(SavedTab.self, from: data).unread == true)
        let old = try JSONDecoder().decode(SavedTab.self, from: Data(#"{"panes":{"session":"s1"}}"#.utf8))
        #expect(old.unread == nil)
        let plain = try JSONEncoder().encode(SavedTab(panes: SavedPane(session: "s1")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("unread"))
    }
}
