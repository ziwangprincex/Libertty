import AppKit
import SwiftUI

/// Libertty ▸ Settings… (⌘,, `open_settings`): Rex's Settings window. A list
/// of pages with a search field on the left, back and forward and the page's
/// name above, the page's settings in a grouped form; every change goes to
/// the config file as one line (see `SettingsModel`). The file stays the
/// truth: Libertty ▸ Open Config File opens it.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let window = SettingsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 572),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // The page's canvas up to the top, as in Rex: no bar across it.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentMinSize = NSSize(width: 740, height: 420)
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: SettingsView(model: .shared))
        // The page's toolbar (back, forward, its name) is the window's.
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.setContentSize(NSSize(width: 740, height: 572))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The window while it's open (the UI probe's shots).
    var openWindow: NSWindow? { window?.isVisible == true ? window : nil }

    /// Show it, on `page` when given.
    func show(_ page: SettingsPage? = nil) {
        let model = SettingsModel.shared
        if let page { model.go(.page(page)) }
        if model.location.page == .liberttyd || window?.isVisible != true { model.refreshDaemon() }
        guard let window else { return }
        // A probe's: off every screen, as its windows are.
        if Probe.running {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.setFrameOrigin(NSPoint(x: -20000, y: -25000))
            window.alphaValue = 1
            return
        }
        Probe.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        SettingsModel.shared.stopRecording()
    }
}

/// ⌘W closes it: File ▸ Close is a terminal's (it closes a pane), so the menu leaves it be here.
final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - The window's content

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // In the theme's colors, as Rex's Settings are: the page on its canvas,
        // the list on its background.
        let theme = model.config.resolvedTheme
        let surfaces = theme.surfaces
        NavigationSplitView {
            SettingsSidebar(model: model)
                .scrollContentBackground(.hidden)
                .background(Color(theme.background))
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(215)
        } detail: {
            SettingsDetail(model: model)
                .scrollContentBackground(.hidden)
                .background(Color(surfaces.canvas))
                .toolbarBackground(.hidden, for: .windowToolbar)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                                .disabled(!model.canGoBack)
                                .help("Go to the previous Settings page")
                                .accessibilityLabel("Back")
                            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                                .disabled(!model.canGoForward)
                                .help("Go to the next Settings page")
                                .accessibilityLabel("Forward")
                        }
                        .controlGroupStyle(.navigation)
                    }
                    ToolbarItem(placement: .navigation) {
                        Text(model.title)
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityLabel("Settings page")
                            .accessibilityValue(model.title)
                    }
                }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search Settings")
        .onSubmit(of: .search) { model.jumpToFirstResult() }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .tint(model.config.accent(with: theme).map { Color($0) })
        .frame(minWidth: 740, minHeight: 420)
    }
}

/// The pages, in groups with a gap between; while searching, what matches.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        List(selection: selection) {
            if model.query.isEmpty {
                ForEach(0..<4) { group in
                    Section {
                        ForEach(SettingsPage.allCases.filter { $0.group == group }) { page in
                            SidebarPageRow(page: page, daemon: model.daemon).tag("page:" + page.id)
                                .probeAnchor(page.title, value: model.location.page == page ? "Selected" : "")
                        }
                    }
                }
            } else {
                let results = model.results
                if results.isEmpty {
                    Text("No Results").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(results) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        Text(item.section.isEmpty ? item.page.title : "\(item.page.title) › \(item.section)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag("item:" + item.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<String?> {
        Binding {
            if model.query.isEmpty { return "page:" + model.location.page.id }
            return model.target.map { "item:" + $0 }
        } set: { tag in
            guard let tag else { return }
            if tag.hasPrefix("page:"), let page = SettingsPage(rawValue: String(tag.dropFirst(5))) {
                model.go(.page(page))
            } else if tag.hasPrefix("item:"), let item = SettingsRegistry.item(String(tag.dropFirst(5))) {
                model.jump(to: item)
            }
        }
    }
}

struct SidebarPageRow: View {
    let page: SettingsPage
    let daemon: SettingsModel.DaemonStatus

    var body: some View {
        if page == .liberttyd {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title).font(.system(size: 13, weight: .medium))
                    Text(daemonSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 9) {
                SettingsIcon(page: page)
                Text(page.title).font(.system(size: 13))
            }
            .frame(height: 24)
        }
    }

    private var daemonSummary: String {
        switch daemon {
        case .unknown: " "
        case .notPersisting: "Off"
        case .running: "Running"
        case .stopped: "Not running"
        }
    }
}

/// A page's icon: Libertty's own picture of it (`FeatureIcon`), else, as Rex draws
/// its own, a symbol on a rounded square of color.
struct SettingsIcon: View {
    let page: SettingsPage
    var size: CGFloat = 22

    var body: some View {
        if let image = FeatureIcon.image(for: page) {
            // The picture keeps room for its shadow round the icon: it spills past the frame.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size * FeatureIcon.bleed, height: size * FeatureIcon.bleed)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            tile
        }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            switch page {
            case .interface:
                VStack(spacing: size * 0.08) {
                    HStack(spacing: size * 0.07) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: size * 0.16) }
                    }
                    HStack(spacing: size * 0.08) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.85))
                        RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.85))
                    }
                    .frame(width: size * 0.62, height: size * 0.32)
                }
            case .terminal:
                Text(">_")
                    .font(.system(size: size * 0.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.36, green: 0.88, blue: 0.5))
            default:
                Image(systemName: page.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        func c(_ hex: UInt32) -> Color { Color(RGB(hex: hex)) }
        switch page {
        case .liberttyd: return [c(0x5e5ce6), c(0x3634a3)]
        case .interface: return [c(0x3a3a3c), c(0x1c1c1e)]
        case .themes: return [c(0xff6482), c(0xffb340), c(0x30d158), c(0x40c8e0)]
        case .terminal: return [c(0x2c2c2e), c(0x161618)]
        case .shortcuts: return [c(0x98989d), c(0x636366)]
        case .integrations: return [c(0xbf5af2), c(0xff375f)]
        case .notifications: return [c(0xff6961), c(0xff3b30)]
        case .remoteHosts: return [c(0xc77dff), c(0x8944ab)]
        case .advanced: return [c(0xaeaeb2), c(0x6c6c70)]
        }
    }
}

/// The page in front.
struct SettingsDetail: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch model.location {
            case .page(.themes): ThemesPage(model: model)
            case .page(.shortcuts): ShortcutsPage(model: model)
            case .page(.remoteHosts): RemoteHostsPage(model: model)
            case .programState(let state): ProgramStatePage(model: model, state: state)
            case .page(let page): SettingsForm(model: model, page: page)
            }
        }
        // Each page from its top, as a page of its own.
        .id(model.location)
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(nsColor: rgb.nsColor) }
}
