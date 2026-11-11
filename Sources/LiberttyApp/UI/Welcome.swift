import AppKit
import SwiftUI

/// Get Started with Libertty (Rex's onboarding): shown once on a Mac that
/// has never run Libertty, and from Help any time. Four short pages — the
/// look, the permissions programs need, agents and the config you had
/// elsewhere, and a few keys worth knowing — each change written to the
/// config as Settings writes it.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    /// Shown once: set when it first opens.
    static let shownKey = "WelcomeShown"
    /// Which page shows (the UI probe turns them).
    let state = WelcomeState()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = L10n.t("Get Started with Libertty")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(model: .shared, state: state) { [weak window] in window?.performClose(nil) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The window while it's open (the UI probe looks).
    var openWindow: NSWindow? { window?.isVisible == true ? window : nil }

    func show() {
        guard let window else { return }
        // A probe's: off every screen, as its windows are (and remembered by no one).
        if Probe.running {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.setFrameOrigin(NSPoint(x: -20000, y: -26000))
            window.alphaValue = 1
            return
        }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        if !window.isVisible {
            state.page = 0
            window.center()
        }
        Probe.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// At launch: once, on a Mac where Libertty has no config and no saved
    /// windows yet (someone who has used it before isn't shown it after an
    /// update) — not for a test's private liberttyd.
    static func showIfNew(hadUsedBefore: Bool) {
        guard !hadUsedBefore, !UserDefaults.standard.bool(forKey: shownKey),
              ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_SOCKET"] == nil else { return }
        shared.show()
    }
}

final class WelcomeState: ObservableObject {
    @Published var page = 0
}

struct WelcomeView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var state: WelcomeState
    let close: () -> Void
    private var page: Int { state.page }

    struct Page {
        var title: String
        var subtitle: String
    }

    static let pages: [Page] = [
        Page(title: "Get Started with Libertty",
             subtitle: "Take a moment to choose how Libertty looks. You can change any of this later in Settings."),
        Page(title: "Grant System Permissions",
             subtitle: "Programs and agents in your terminals need these for some of what they do."),
        Page(title: "Agents and Your Old Config",
             subtitle: "Let coding agents drive Libertty, and bring over what you had set up elsewhere."),
        Page(title: "A Few Keys Worth Knowing",
             subtitle: "From your keymap, as it is now."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                Text(L10n.t(Self.pages[page].title)).font(.system(size: 20, weight: .semibold))
                Text(L10n.t(Self.pages[page].subtitle))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 34)
            .padding(.horizontal, 40)
            ScrollView {
                Group {
                    switch page {
                    case 0: appearance
                    case 1: PermissionsCard(model: model)
                    case 2: agents
                    default: keys
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<Self.pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(Self.pages.count)")
                Spacer()
                if page > 0 {
                    Button(L10n.t("Back")) { state.page -= 1 }
                }
                if page < Self.pages.count - 1 {
                    Button(L10n.t("Skip")) { close() }
                    Button(L10n.t("Continue")) { state.page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.t("Get Started")) { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 540)
    }

    // MARK: Pages

    private func registryItem(_ key: String) -> SettingsItem? {
        SettingsRegistry.items.first { $0.key == key }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            TilesRow(model: model, items: ["window-theme", "interface-style"].compactMap(registryItem))
            if let tabs = registryItem("tab-bar"), case .segmented(let options) = tabs.kind {
                PickerRow(model: model, item: tabs, options: options, segmented: true)
            }
            if let border = registryItem("active-border") {
                SettingsRow(model: model, item: border)
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(symbol: "sparkles", title: "Let coding agents drive Libertty",
                 detail: "Installs Libertty's skill and status hooks for Claude Code, Codex and the other agents on this Mac "
                    + "(libertty +agent-setup), so they can open panes, read them and tell you when they need you.") {
                if model.agents == .installed {
                    Label(L10n.t("Set up"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(L10n.t("Set Up…")) { model.setAgents(true, in: WelcomeWindowController.shared.window) }
                        .disabled(model.agents == .busy || model.agents == .unknown)
                }
            }
            if !GhosttyImport.ghosttyFiles.isEmpty {
                step(symbol: "square.and.arrow.down", title: "Bring over your Ghostty settings",
                     detail: "Adds the Ghostty settings Libertty knows to your config; what you've set in Libertty stays. "
                        + "Says what it adds first.") {
                    Button(L10n.t("Import…")) { model.importGhostty(in: WelcomeWindowController.shared.window) }
                }
            }
            step(symbol: "keyboard", title: "Migrate your keybindings with an agent",
                 detail: "Copies a prompt for a coding agent in Libertty: it reads your keybindings from Ghostty, iTerm2 or "
                    + "tmux and adds them to your config. Themes, fonts and other settings aren't migrated.") {
                Button(L10n.t("Copy Prompt")) { MigrationPrompt.copy() }
            }
            if !model.ghosttyReport.isEmpty {
                Text(model.ghosttyReport).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { if model.agents == .unknown { model.refreshAgents() } }
    }

    private func step(symbol: String, title: String, detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title)).font(.system(size: 13, weight: .medium))
                Text(L10n.t(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
    }

    /// The keys, as bound now; one unbound isn't listed.
    static let keyTips: [(label: String, action: Action)] = [
        ("Command Palette", .toggleCommandPalette), ("New Tab", .newTab), ("Split Right", .newSplit(.right)),
        ("Split Down", .newSplit(.down)), ("Zoom the Focused Pane", .toggleSplitZoom),
        ("Jump to the Pane That Needs You", .gotoAttention), ("Show or Hide the Sidebar", .toggleSidebar),
        ("Quick Terminal", .toggleQuickTerminal), ("Settings", .openSettings),
    ]

    static func boundTips(_ keybinds: Keybinds) -> [(label: String, keys: String)] {
        keyTips.compactMap { tip in keybinds.keys(for: tip.action).map { (tip.label, $0) } }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.boundTips(ConfigStore.shared.keybinds).enumerated()), id: \.offset) { _, tip in
                HStack {
                    Text(L10n.t(tip.label)).font(.system(size: 13))
                    Spacer()
                    Text(tip.keys)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                }
            }
            if ConfigStore.shared.config.trackpadGestures {
                let swipe: String = switch ConfigStore.shared.config.sidebarSwipe {
                case .option: " Option-swipe sideways to show or hide the sidebar."
                case .swipe: " Swipe sideways to show or hide the sidebar."
                case .off: ""
                }
                Text(L10n.t("On a trackpad: spread two fingers over a pane to zoom it, pinch to restore it.") + L10n.t(swipe))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }
}
