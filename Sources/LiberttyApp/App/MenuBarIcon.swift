import AppKit

/// Libertty in the menu bar (`menu-bar-icon`, Kero's tray): what needs you
/// at a glance — the icon fills while a program waits for you, and says how
/// many — and a menu to go to it, drop the Quick Terminal down, keep the
/// Mac awake, or open Settings.
@MainActor
final class MenuBarIcon: NSObject, NSMenuDelegate {
    static let shared = MenuBarIcon()

    private var item: NSStatusItem?
    /// The panes needing you, as last counted.
    private var waiting = 0

    func apply(_ shown: Bool) {
        if shown, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            update(waiting: waiting)
        } else if !shown, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// How many panes wait for you: the icon fills, with the count beside it.
    func update(waiting count: Int) {
        waiting = count
        guard let button = item?.button else { return }
        let image = NSImage(systemSymbolName: count > 0 ? "terminal.fill" : "terminal", accessibilityDescription: "Libertty")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = count > 0 ? "\(count) waiting for you" : "Libertty"
        // Not "Libertty, 2": what the 2 is.
        button.setAccessibleLabel(count > 0 ? "Libertty, " + L10n.t("%d waiting for you").replacingOccurrences(of: "%d", with: String(count))
                                            : "Libertty")
    }

    /// The menu, as things are when it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Box(action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
            return item
        }
        let header = NSMenuItem(title: waiting > 0 ? "\(waiting) waiting for you" : "Nothing waiting for you", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if waiting > 0 {
            _ = add("Jump to Pane Needing You", "exclamationmark.bubble") {
                NSApp.activate(ignoringOtherApps: true)
                ActionDispatcher.perform(.gotoAttention)
            }
        }
        menu.addItem(.separator())
        _ = add("Open Libertty", "macwindow") {
            NSApp.activate(ignoringOtherApps: true)
            let app = NSApp.delegate as? AppDelegate
            if app?.frontController == nil { app?.newWindow(nil) } else { app?.frontController?.window?.makeKeyAndOrderFront(nil) }
        }
        _ = add("Quick Terminal", "rectangle.topthird.inset.filled") { ActionDispatcher.perform(.toggleQuickTerminal) }
        let awake = NSMenu()
        let mode = ConfigStore.shared.config.keepAwake
        for (value, title) in [(KeepAwake.Mode.never, "Never"), (.agents, "While Agents Work"), (.always, "Always")] {
            let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.state = value == mode ? .on : .off
            item.representedObject = Box { _ = SettingsModel.shared.write("keep-awake", value.rawValue) }
            awake.addItem(item)
        }
        let awakeItem = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
        awakeItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        awakeItem.submenu = awake
        menu.addItem(awakeItem)
        menu.addItem(.separator())
        _ = add("Settings…", "gearshape") {
            NSApp.activate(ignoringOtherApps: true)
            ActionDispatcher.perform(.openSettings)
        }
        _ = add("Quit Libertty", "power") { NSApp.terminate(nil) }
    }

    private final class Box {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.run()
    }

    /// The menu's titles, as it would open now (the UI probe).
    var menuTitles: [String] {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }
    var isShown: Bool { item != nil }
}
