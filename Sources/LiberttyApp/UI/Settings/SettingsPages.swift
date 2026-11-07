import AppKit
import LiberttyCore
import SwiftUI

/// SwiftUI's `State` as the property wrapper it is: from macOS 27's SDK `@State`
/// is a macro first, whose plugin only Xcode ships (not the Command Line Tools).
typealias ViewState<Value> = SwiftUI.State<Value>

// MARK: - A page from the registry

/// A page whose controls are all in the registry: its sections in order,
/// each control drawn by its kind (a custom one by its id).
struct SettingsForm: View {
    @ObservedObject var model: SettingsModel
    let page: SettingsPage

    struct Row: Identifiable {
        var items: [SettingsItem]
        var id: String { items[0].id }
    }

    /// The page's sections, in order; side-by-side tiles (Color scheme,
    /// Interface style) share a row.
    static func sections(of page: SettingsPage) -> [(title: String, rows: [Row])] {
        var sections: [(title: String, rows: [Row])] = []
        for item in SettingsRegistry.items(on: page) {
            if sections.last?.title != item.section { sections.append((item.section, [])) }
            if case .tiles = item.kind, let last = sections[sections.count - 1].rows.last?.items.last, case .tiles = last.kind {
                sections[sections.count - 1].rows[sections[sections.count - 1].rows.count - 1].items.append(item)
            } else {
                sections[sections.count - 1].rows.append(Row(items: [item]))
            }
        }
        return sections
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(Self.sections(of: page), id: \.title) { section in
                    Section {
                        ForEach(section.rows) { row in
                            Group {
                                if row.items.count > 1 || row.items[0].isTiles {
                                    TilesRow(model: model, items: row.items)
                                } else {
                                    SettingsRow(model: model, item: row.items[0])
                                }
                            }
                            .modifier(SearchHighlight(on: row.items.contains { $0.id == model.target }))
                            .id(row.id)
                        }
                    } header: {
                        if !section.title.isEmpty { Text(section.title) }
                    } footer: {
                        SectionFooter(model: model, page: page, section: section.title)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { scroll(proxy) }
            .onChange(of: model.target) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = model.target, let row = Self.sections(of: page).flatMap(\.rows)
            .first(where: { $0.items.contains { $0.id == target } }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(row.id, anchor: .center) } }
    }
}

extension SettingsItem {
    var isTiles: Bool {
        if case .tiles = kind { return true }
        return false
    }
}

/// The control a search went to, lit for a moment.
struct SearchHighlight: ViewModifier {
    var on: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(on ? 0.18 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
                .animation(.easeOut(duration: 0.5), value: on))
    }
}

struct SectionFooter: View {
    @ObservedObject var model: SettingsModel
    let page: SettingsPage
    let section: String

    var body: some View {
        switch (page, section) {
        case (.integrations, L10n.t("Coding Agents")):
            VStack(alignment: .leading, spacing: 4) {
                Text("Teach Claude Code and Codex how to use Libertty: their tabs say when they work, wait for you or are done.")
                if !model.agentReport.isEmpty { Text(model.agentReport).textSelection(.enabled) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case (.terminal, L10n.t("Shell")):
            Text("The startup command is an executable and its arguments, run through /bin/sh -c; empty runs your login shell.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

/// A control's title, with its help, and why it can't be (or wasn't) changed.
struct RowLabel: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? item.title)
            if !item.help.isEmpty {
                Text(item.help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let file = model.lockedFile(of: item) {
                Text("Set in config file \(file)")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let problem = model.problems[item.id] {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
            if let note = model.notes[item.id] {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

extension SettingsModel {
    /// The file that sets one of the item's keys, so it can't be changed here.
    func lockedFile(of item: SettingsItem) -> String? {
        if item.id.hasPrefix("shortcut:") { return isLocked(shortcut: item.id) ? "(an included file)" : nil }
        return item.keys.lazy.compactMap { self.locked[$0] }.first
    }
}

/// One control, drawn by its kind.
struct SettingsRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem

    var body: some View {
        let locked = model.lockedFile(of: item) != nil
        Group {
            switch item.kind {
            case .toggle(let on, let off):
                // On for anything but `off` — and but nothing: a key with no value (as a theme says) isn't on.
                Toggle(isOn: Binding(get: { let now = model.current(item.key!); return now != off && !now.isEmpty },
                                     set: { model.write(item.key!, $0 ? on : off, item: item.id) })) {
                    RowLabel(model: model, item: item)
                }
                .toggleStyle(.switch)
            case .segmented(let options):
                PickerRow(model: model, item: item, options: options, segmented: true)
            case .popup(let options):
                PickerRow(model: model, item: item, options: options, segmented: false)
            case .tiles:
                TilesRow(model: model, items: [item])
            case .slider(let range, let step, let percent):
                SliderRow(model: model, item: item, range: range, step: step, percent: percent)
            case .stepper(let range, let step, let unit):
                StepperRow(model: model, item: item, range: range, step: step, unit: unit)
            case .text(let placeholder):
                TextRow(model: model, item: item, placeholder: placeholder)
            case .custom:
                CustomRow(model: model, item: item)
            }
        }
        .disabled(locked)
    }
}

struct PickerRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    let options: [SettingsOption]
    let segmented: Bool

    var body: some View {
        let (list, selected) = choices()
        let picker = Picker(selection: Binding(get: { selected }, set: { model.write(item.key!, $0, item: item.id) })) {
            ForEach(list, id: \.value) { option in
                if let symbol = option.symbol {
                    Label(option.label, systemImage: symbol).tag(option.value)
                } else {
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            RowLabel(model: model, item: item)
        }
        if segmented {
            picker.pickerStyle(.segmented).fixedSize()
        } else {
            picker.pickerStyle(.menu)
        }
    }

    /// The options, and the one in use: a value the file has that none of
    /// them is shows as itself.
    private func choices() -> ([SettingsOption], String) {
        let key = item.key!
        if let match = options.first(where: { model.isCurrent($0, of: key) }) { return (options, match.value) }
        let now = model.current(key)
        return (options + [SettingsOption(label: now.isEmpty ? "Default" : now, value: now)], now)
    }
}

struct SliderRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    let range: ClosedRange<Double>
    let step: Double
    let percent: Bool
    @ViewState private var live: Double?

    var body: some View {
        let value = live ?? Double(model.current(item.key!)) ?? range.lowerBound
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { v in
                    live = v
                    if !percent { commit(v) }
                }), in: range, step: step) { editing in
                    if !editing, let v = live { commit(v); live = nil }
                }
                .frame(width: 160)
                .accessibilityLabel(item.title)
                Text(percent ? "\(Int((value * 100).rounded()))%" : SettingsItem.number(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
            }
        } label: {
            RowLabel(model: model, item: item)
        }
    }

    private func commit(_ v: Double) {
        let rounded = (v / step).rounded() * step
        let text = SettingsItem.number((rounded * 1000).rounded() / 1000)
        if text != model.current(item.key!) { model.write(item.key!, text, item: item.id) }
    }
}

struct StepperRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        let value = Binding<Double>(get: { Double(model.current(item.key!)) ?? range.lowerBound },
                                    set: { model.write(item.key!, SettingsItem.number(min(range.upperBound, max(range.lowerBound, $0))), item: item.id) })
        LabeledContent {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .accessibilityLabel(item.title)
                Stepper("", value: value, in: range, step: step).labelsHidden()
                Text(unit).foregroundStyle(.secondary)
            }
        } label: {
            RowLabel(model: model, item: item)
        }
    }
}

/// A value typed in: written on Return or when the field is left.
struct TextRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    let placeholder: String
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            TextField("", text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(item.title)
        } label: {
            RowLabel(model: model, item: item)
        }
        .onAppear { draft = shown }
        .onChange(of: shown) { _, new in draft = new }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    /// The file's value; the placeholder stands for the default.
    private var shown: String {
        let now = model.current(item.key!)
        return now == SettingsModel.defaultValue(item.key!) && now == placeholder ? "" : now
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard text != shown else { return }
        model.write(item.key!, text, item: item.id)
    }
}

// MARK: - Tiles

/// Pictures to pick from, side by side when there are two sets (Rex's
/// Appearance row).
struct TilesRow: View {
    @ObservedObject var model: SettingsModel
    let items: [SettingsItem]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().padding(.horizontal, 18) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 10) {
                        if case .tiles(let options) = item.kind {
                            ForEach(options, id: \.value) { option in
                                TileButton(model: model, item: item, option: option)
                            }
                        }
                    }
                    if let problem = model.problems[item.id] {
                        Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct TileButton: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    let option: SettingsOption

    var body: some View {
        let selected = model.isCurrent(option, of: item.key!)
        Button {
            model.write(item.key!, option.value, item: item.id)
        } label: {
            VStack(spacing: 6) {
                TileArt(key: item.key!, value: option.value)
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(option.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .probeAnchor(option.label, value: selected ? "Selected" : "Not selected")
    }
}

/// A tile's picture: a window on a desktop, light, dark or both; solid or glass.
struct TileArt: View {
    let key: String
    let value: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color(RGB(hex: 0x4b7be0)), Color(RGB(hex: 0x1c3c94))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // Soft bands across the desktop.
            DiagonalBand(offset: 0.15).fill(.white.opacity(0.08))
            DiagonalBand(offset: 0.55).fill(.black.opacity(0.10))
            switch (key, value) {
            case ("window-theme", "light"): MiniWindow(dark: false)
            case ("window-theme", "dark"): MiniWindow(dark: true)
            case ("window-theme", _):
                ZStack {
                    MiniWindow(dark: false)
                    MiniWindow(dark: true).mask(DiagonalHalf())
                }
            case ("interface-style", "glass"): MiniWindow(dark: scheme == .dark, glass: true)
            default: MiniWindow(dark: scheme == .dark)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(width: 68, height: 54)
    }
}

struct MiniWindow: View {
    var dark: Bool
    var glass = false

    var body: some View {
        let frame = glass ? Color.white.opacity(0.2) : Color(white: dark ? 0.1 : 0.97)
        let pane = glass ? Color.white.opacity(0.3) : Color(white: dark ? 0.22 : 0.86)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2.5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 4.5, height: 4.5) }
            }
            RoundedRectangle(cornerRadius: 2).fill(pane).frame(height: 9)
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(pane)
                RoundedRectangle(cornerRadius: 2).fill(pane)
            }
            .frame(height: 9)
        }
        .padding(5)
        .frame(width: 46, height: 38, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(frame))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(glass ? 0.55 : 0.18), lineWidth: 0.5))
    }
}

/// The lower right half of a rectangle, cut on a steep diagonal (Auto's dark side).
struct DiagonalHalf: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY))
            p.closeSubpath()
        }
    }
}

struct DiagonalBand: Shape {
    var offset: CGFloat

    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + r.width * offset, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + r.width * (offset + 0.25), y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + r.width * (offset + 0.65), y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + r.width * (offset + 0.4), y: r.minY))
            p.closeSubpath()
        }
    }
}

// MARK: - Custom rows

struct CustomRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem

    var body: some View {
        switch item.id {
        case "daemon":
            DaemonCard(model: model)
        case "permissions":
            PermissionsCard(model: model)
        case "web-access-link":
            LabeledContent {
                Button("Show Link…") { WebAccessPanel.shared.show(nil) }
            } label: {
                RowLabel(model: model, item: item)
            }
        case "font-preview":
            FontPreview(config: model.config)
        case "font-family":
            FontRow(model: model, item: item)
        case "ligatures":
            Toggle(isOn: Binding(get: { model.config.ligatures }, set: { model.setLigatures($0) })) {
                RowLabel(model: model, item: item)
            }
            .toggleStyle(.switch)
        case "agent-setup":
            AgentRow(model: model, item: item)
        case "config-file":
            ConfigFileRows(model: model, item: item)
        case "theme-import":
            ThemeImportRow(model: model, item: item)
        case "global-hotkey", "global-new-window-hotkey", "quick-terminal-hotkey":
            LabeledContent {
                ShortcutRecorder(model: model, id: item.id, title: item.title)
            } label: {
                RowLabel(model: model, item: item)
            }
        default:
            if item.id.hasPrefix("shortcut:") {
                LabeledContent {
                    ShortcutRecorder(model: model, id: item.id, title: item.title)
                } label: {
                    RowLabel(model: model, item: item)
                }
            } else if item.id.hasPrefix("program-state:"),
                      let state = ProgramStatusStore.State(name: String(item.id.dropFirst("program-state:".count))) {
                ProgramStateRow(model: model, state: state)
            } else if item.id.hasPrefix("bell:") {
                let feature = String(item.id.dropFirst(5))
                Toggle(isOn: Binding(get: { model.bell(feature) }, set: { model.setBell(feature, $0) })) {
                    RowLabel(model: model, item: item)
                }
                .toggleStyle(.switch)
            } else {
                EmptyView()
            }
        }
    }
}

/// Rex's Server card: liberttyd, whether it runs, and its sessions.
struct DaemonCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("liberttyd").font(.system(size: 13, weight: .semibold))
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Keeps your shells and programs running while Libertty is closed, updated or restarted.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Show Log") { NSWorkspace.shared.open(URL(fileURLWithPath: Persistence.logPath)) }
        }
        .padding(.vertical, 4)
        .onAppear { model.refreshDaemon() }
    }

    private var status: String {
        switch model.daemon {
        case .unknown: "…"
        case .notPersisting: "Not in use: shells end when Libertty quits (Advanced ▸ Sessions)"
        case .running(let n): "Running · \(n) session\(n == 1 ? "" : "s")"
        case .stopped: "Not running"
        }
    }
}

/// Rex's System Permissions: what macOS lets the programs in your terminals
/// get at. They run under liberttyd, so it's liberttyd that macOS asks
/// about: each permission with its status, a button to its list in System
/// Settings, and liberttyd's icon to drag into that list.
struct PermissionsCard: View {
    @ObservedObject var model: SettingsModel

    struct Kind: Identifiable {
        var id: String
        var title: String
        var detail: String
        var symbol: String
        /// Its list in System Settings ▸ Privacy & Security.
        var anchor: String
    }

    static let kinds: [Kind] = [
        Kind(id: "full-disk", title: "Full Disk Access",
             detail: "Lets programs in your terminals open files in protected folders and other apps' data.",
             symbol: "externaldrive.fill", anchor: "Privacy_AllFiles"),
        Kind(id: "screen", title: "Screen & System Audio Recording",
             detail: "Lets programs and agents in your terminals capture the screen, windows and system audio.",
             symbol: "rectangle.dashed.badge.record", anchor: "Privacy_ScreenCapture"),
        Kind(id: "camera", title: "Camera", detail: "Lets programs and agents in your terminals use the camera.",
             symbol: "camera.fill", anchor: "Privacy_Camera"),
        Kind(id: "microphone", title: "Microphone", detail: "Lets programs and agents in your terminals record from the microphone.",
             symbol: "mic.fill", anchor: "Privacy_Microphone"),
        Kind(id: "local-network", title: "Local Network",
             detail: "Lets programs and agents in your terminals reach devices on your local network.",
             symbol: "network", anchor: "Privacy_LocalNetwork"),
    ]

    /// What answers to macOS for the programs: liberttyd, or Libertty itself.
    private var holder: String { Persistence.enabled ? "liberttyd" : "Libertty" }
    private var holderPath: String? { Persistence.enabled ? Persistence.daemonExecutable : Bundle.main.bundlePath }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .onDrag { holderPath.flatMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) } ?? NSItemProvider() }
                    .help(L10n.t("Drag into the list in System Settings to grant access."))
                    .accessibilityLabel("\(holder) icon")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Programs in your terminals ask macOS as \(holder), so these are \(holder)'s permissions."))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t("Drag this icon into a list in System Settings to grant access. Some take effect once \(holder) restarts."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.permissions == .tooOld {
                Text(L10n.t("This liberttyd is too old to report its permissions. You can still grant them; their status shows once it updates."))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Self.kinds) { kind in
                HStack(spacing: 10) {
                    Image(systemName: kind.symbol)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t(kind.title)).font(.system(size: 12, weight: .medium))
                        Text(L10n.t(kind.detail)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    let status = status(of: kind.id)
                    Text(L10n.t(status.label))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(status.color)
                        .accessibilityLabel(kind.title)
                        .accessibilityValue(status.label)
                        .probeAnchor(kind.title, value: status.label)
                    Button(L10n.t("Open")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.anchor)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Open \(kind.title) in System Settings")
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { model.refreshPermissions() }
        // Back from System Settings to this: what changed there. (Its window
        // closed, the view lives on: then nothing.)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let front = NSApp.keyWindow?.windowController
            if front is SettingsWindowController || front is WelcomeWindowController { model.refreshPermissions() }
        }
    }

    private func status(of kind: String) -> (label: String, color: Color) {
        guard case .report(let access) = model.permissions else { return ("", .secondary) }
        switch access[kind].flatMap(PrivacyAccess.Status.init(rawValue:)) {
        case .granted?: return ("Granted", .green)
        case .denied?: return ("Not granted", .secondary)
        case .notAsked?: return ("Not asked yet", .secondary)
        case .unknown?, nil: return (kind == "local-network" ? "macOS doesn't say" : "Unknown", .secondary)
        }
    }
}

struct FontRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem
    @ViewState private var choosing = false

    var body: some View {
        let family = model.config.fontFamily.isEmpty ? FontRegistry.bundledFamily : model.config.fontFamily
        LabeledContent {
            HStack(spacing: 10) {
                Text(family)
                    .font(Font(SettingsFonts.font(family, 13)))
                    .lineLimit(1)
                Button("Choose…") { choosing = true }
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        FontChooser(model: model) { choosing = false }
                    }
            }
        } label: {
            RowLabel(model: model, item: item)
        }
    }
}

/// The monospaced families, each in its own face, to search and pick.
struct FontChooser: View {
    @ObservedObject var model: SettingsModel
    var done: () -> Void
    @ViewState private var filter = ""
    private static var families: [String]?

    var body: some View {
        let all = Self.families ?? {
            let list = [FontRegistry.bundledFamily] + FontSet.monospacedFamilies().filter { $0 != FontRegistry.bundledFamily }
            Self.families = list
            return list
        }()
        let shown = filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
        let current = model.config.fontFamily.isEmpty ? FontRegistry.bundledFamily : model.config.fontFamily
        VStack(spacing: 0) {
            TextField("Search Fonts", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(shown, id: \.self) { family in
                Button {
                    model.write("font-family", family == FontRegistry.bundledFamily ? "" : family, item: "font-family")
                    done()
                } label: {
                    HStack {
                        Text(family).font(Font(SettingsFonts.font(family, 13)))
                        if family == FontRegistry.bundledFamily { Text("bundled").foregroundStyle(.secondary) }
                        Spacer()
                        if family == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 320, height: 380)
    }
}

enum SettingsFonts {
    static func font(_ family: String, _ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        FontRegistry.registerBundledFonts()
        var font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}

/// A few lines of a terminal in the font, size and theme in use.
struct FontPreview: View {
    let config: Config

    var body: some View {
        let t = config.resolvedTheme
        let size = CGFloat(min(max(config.fontSize, 10), 16))
        let family = config.fontFamily.isEmpty ? FontRegistry.bundledFamily : config.fontFamily
        let fg = Color(t.foreground)
        VStack(alignment: .leading, spacing: 3) {
            Text("~/libertty").foregroundColor(Color(t.ansi[4])) + Text(" main").foregroundColor(Color(t.ansi[5]))
                + Text(" $ swift build && swift test").foregroundColor(fg)
            Text("main.swift:4: ").foregroundColor(fg) + Text("warning:").foregroundColor(Color(t.ansi[3]))
                + Text(" 'run() -> Bool' is deprecated").foregroundColor(fg)
            Text("Build complete!").font(Font(SettingsFonts.font(family, size, bold: true))).foregroundColor(Color(t.ansi[2]))
                + Text(" (1.24 sec)").font(Font(SettingsFonts.font(family, size, italic: true))).foregroundColor(fg)
        }
        .font(Font(SettingsFonts.font(family, size)))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(t.background)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typography preview: regular, bold, and italic terminal text.")
    }
}

struct AgentRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem

    var body: some View {
        Toggle(isOn: Binding(get: { model.agents == .installed },
                             set: { model.setAgents($0, in: SettingsWindowController.shared.window) })) {
            HStack(spacing: 8) {
                RowLabel(model: model, item: item)
                if model.agents == .busy || model.agents == .unknown { ProgressView().controlSize(.small) }
            }
        }
        .toggleStyle(.switch)
        .disabled(model.agents == .busy || model.agents == .unknown)
        .onAppear { if model.agents == .unknown { model.refreshAgents() } }
    }
}

struct ConfigFileRows: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem

    var body: some View {
        LabeledContent {
            HStack {
                Button("Open Config File") { AppDelegate.openConfigFile() }
                Button("Reload") { ConfigStore.shared.reloadByRequest() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text((ConfigStore.shared.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        if !model.warnings.isEmpty {
            LabeledContent {
                Button("Show") { ConfigurationErrorsController.shared.update(model.warnings) }
            } label: {
                Text(model.warnings.count == 1 ? "1 problem in the config" : "\(model.warnings.count) problems in the config")
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct ThemeImportRow: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsItem

    var body: some View {
        LabeledContent {
            Button("Import…") {
                let panel = NSOpenPanel()
                panel.message = "Ghostty theme files, or iTerm2 color presets (.itermcolors)"
                panel.allowsMultipleSelection = true
                guard let window = SettingsWindowController.shared.window else { return }
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK else { return }
                    MainActor.assumeIsolated { model.importThemes(panel.urls) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text("Themes are copied to \((ConfigStore.directory.appendingPathComponent("themes").path as NSString).abbreviatingWithTildeInPath) and listed with your own.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.themeStatus.isEmpty {
                    Text(model.themeStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcuts

/// A shortcut, and the button that records another (Rex's 160×24).
struct ShortcutRecorder: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let title: String

    var body: some View {
        let recording = model.recording == id
        let shortcut = model.trigger(for: id)
        Button {
            if recording { model.stopRecording() } else { model.startRecording(id) }
        } label: {
            Text(recording ? "Type Shortcut…" : shortcut.map(Self.spaced) ?? "Record Shortcut")
                .font(.system(size: 13, weight: shortcut == nil || recording ? .regular : .medium))
                .foregroundStyle(shortcut == nil && !recording ? .secondary : .primary)
                .frame(width: 160, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(shortcut == nil && !recording ? 0.04 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut == nil ? "Click to record a shortcut." : "Click to record a different shortcut. Delete removes it.")
        .accessibilityLabel(shortcut == nil ? "Record a shortcut for \(title)" : "Change the shortcut for \(title)")
        .accessibilityValue(shortcut ?? "")
        .contextMenu {
            Button("Remove Shortcut") { model.clearShortcut(id) }.disabled(shortcut == nil)
        }
    }

    /// `⌃⌘F` as Rex shows it: a hair of space after each modifier.
    static func spaced(_ text: String) -> String {
        var out = ""
        for ch in text {
            out.append(ch)
            if "⌃⌥⇧⌘".contains(ch) { out.append("\u{2009}") }
        }
        return out
    }
}

struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter Shortcuts…", text: $model.shortcutFilter)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter Shortcuts")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .padding(.horizontal, 20)
            .padding(.top, 10)
            ScrollViewReader { proxy in
                Form {
                    Section {
                    } header: {
                        Text("A shortcut recorded here is written to the config file as a keybind line. Search for a key, such as cmd+k, to see what it does. Delete removes a shortcut; Esc stops recording.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                SettingsRow(model: model, item: item)
                                    .modifier(SearchHighlight(on: model.target == item.id))
                                    .id(item.id)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .onAppear { scroll(proxy) }
                .onChange(of: model.target) { scroll(proxy) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = model.target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(target, anchor: .center) } }
    }

    /// The page's sections, with only what the filter finds: by name, or by
    /// key (`cmd+k`, `⌘K`).
    private var sections: [(title: String, items: [SettingsItem])] {
        let query = model.shortcutFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let asKey = Trigger(query)?.displayString
        var out: [(title: String, items: [SettingsItem])] = []
        for item in SettingsRegistry.items(on: .shortcuts) {
            if !query.isEmpty {
                let shown = model.trigger(for: item.id)
                let matches = item.title.lowercased().contains(query) || item.section.lowercased().contains(query)
                    || shown.map { $0.lowercased() == query || $0 == asKey } == true
                if !matches { continue }
            }
            if out.last?.title != item.section { out.append((item.section, [])) }
            out[out.count - 1].items.append(item)
        }
        return out
    }
}

// MARK: - Themes

struct ThemesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ThemeModeSection(model: model, dark: false)
                ThemeModeSection(model: model, dark: true)
                ForEach(["Extended Palette", "Import Theme"], id: \.self) { title in
                    Section(title) {
                        ForEach(SettingsRegistry.items(on: .themes).filter { $0.section == title }) { item in
                            SettingsRow(model: model, item: item)
                                .modifier(SearchHighlight(on: model.target == item.id))
                                .id(item.id)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.target) { _, target in
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(target, anchor: .top) } }
            }
        }
        .onAppear { model.loadThemes() }
    }
}

/// Light Mode or Dark Mode: the themes for that appearance, by where they
/// come from; choosing one writes only that half of `theme`.
struct ThemeModeSection: View {
    @ObservedObject var model: SettingsModel
    let dark: Bool

    var body: some View {
        let selected = dark ? model.config.theme.dark : model.config.theme.light
        let id = dark ? "themes-dark" : "themes-light"
        Section {
            ForEach(model.themeGroups) { group in
                let choices = group.choices.filter { $0.theme.isDark == dark || $0.name.caseInsensitiveCompare(selected) == .orderedSame }
                if !choices.isEmpty {
                    ThemeGroupView(model: model, title: group.title, choices: choices, selected: selected, dark: dark)
                }
            }
            if model.themeGroups.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            if let problem = model.problems[id] {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(dark ? "Dark Mode" : "Light Mode")
                    + Text(model.darkIsActive == dark ? " — Active" : "").foregroundColor(.secondary).fontWeight(.regular)
                Spacer()
                Button { ThemeEditor.shared.show(nil) } label: {
                    Label("New", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .fontWeight(.regular)
                .accessibilityLabel(dark ? "New Dark Theme" : "New Light Theme")
            }
        }
        .id(id)
        .modifier(SearchHighlight(on: model.target == id))
    }
}

struct ThemeGroupView: View {
    @ObservedObject var model: SettingsModel
    let title: String
    let choices: [SettingsModel.ThemeChoice]
    let selected: String
    let dark: Bool
    @ViewState private var expanded = false
    @ViewState private var filter = ""

    /// Past this many, a collection is folded away and searched.
    static let foldAt = 24
    static let shownAtMost = 48

    var body: some View {
        if choices.count > Self.foldAt {
            let found = filter.isEmpty ? choices : choices.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            // The theme in use first, so it's there to see.
            let ordered = found.filter { isSelected($0) } + found.filter { !isSelected($0) }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search \(choices.count) themes", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    ThemeGrid(model: model, choices: Array(ordered.prefix(Self.shownAtMost)), selected: selected, dark: dark)
                    if found.count > Self.shownAtMost {
                        Text("\(found.count - Self.shownAtMost) more: search to find them")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if found.isEmpty {
                        Text("No theme is called that.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Text("· \(choices.count) themes").foregroundStyle(.secondary)
                    if let inUse = choices.first(where: isSelected) {
                        Text("· \(inUse.name) in use").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ThemeGrid(model: model, choices: choices, selected: selected, dark: dark)
            }
            .padding(.vertical, 2)
        }
    }

    private func isSelected(_ choice: SettingsModel.ThemeChoice) -> Bool {
        choice.name.caseInsensitiveCompare(selected) == .orderedSame
    }
}

struct ThemeGrid: View {
    @ObservedObject var model: SettingsModel
    let choices: [SettingsModel.ThemeChoice]
    let selected: String
    let dark: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 112), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            ForEach(choices) { choice in
                ThemeCard(choice: choice, selected: choice.name.caseInsensitiveCompare(selected) == .orderedSame) {
                    model.chooseTheme(choice.name, dark: dark)
                }
            }
        }
    }
}

/// A theme as a little terminal in its colors (Rex's theme card): text, a
/// prompt's folder, the cursor, and its eight colors.
struct ThemeCard: View {
    let choice: SettingsModel.ThemeChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ThemeSwatch(theme: choice.theme)
                    .frame(width: 106, height: 61)
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(choice.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 112, height: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.name)
        .accessibilityLabel("\(choice.name) theme")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .probeAnchor("\(choice.name) theme", value: selected ? "Selected" : "Not selected")
    }
}

struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        let t = theme
        let fg = Color(t.foreground)
        let blue = Color(t.ansi[4])
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(t.background))
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(fg.opacity(0.16), lineWidth: 1)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text("Aa").font(.system(size: 17)).foregroundStyle(fg)
                    Spacer(minLength: 0)
                    Text("~/")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(blue)
                        .padding(.horizontal, 3)
                        .frame(height: 19)
                        .background(RoundedRectangle(cornerRadius: 3).fill(blue.opacity(0.2)))
                    RoundedRectangle(cornerRadius: 2).fill(Color(t.cursor)).frame(width: 7, height: 17)
                }
                HStack(spacing: -3) {
                    ForEach(0..<8, id: \.self) { i in
                        Circle()
                            .fill(Color(t.ansi[i]))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(t.background), lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 9)
        }
    }
}

// MARK: - Notifications

struct ProgramStateIcon: View {
    let state: ProgramStatusStore.State
    var size: CGFloat = 26

    var body: some View {
        let (symbol, color): (String, RGB) = switch state {
        case .working: ("ellipsis", RGB(hex: 0x3b82f6))
        case .blocked: ("nosign", RGB(hex: 0xff9f0a))
        case .error: ("exclamationmark.triangle", RGB(hex: 0xff453a))
        case .done: ("checkmark", RGB(hex: 0x30d158))
        case .idle: ("moon.zzz", RGB(hex: 0x8e8e93))
        }
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(color).opacity(0.85), Color(color)], startPoint: .top, endPoint: .bottom))
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A program state on the Notifications page: what it does, and its page.
struct ProgramStateRow: View {
    @ObservedObject var model: SettingsModel
    let state: ProgramStatusStore.State

    var body: some View {
        let summary = model.summary(of: state)
        Button {
            model.go(.programState(state))
        } label: {
            HStack(spacing: 10) {
                ProgramStateIcon(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(state.title), \(summary)")
        .help("Opens \(state.title) settings")
    }
}

/// One program state's own page: each way it may get your attention.
struct ProgramStatePage: View {
    @ObservedObject var model: SettingsModel
    let state: ProgramStatusStore.State

    var body: some View {
        let id = "program-state:\(state.name)"
        Form {
            Section {
                toggle("Show activity in tabs", "program-status-indicator", help: "The tab's mark, and the window's subtitle.")
                toggle("Show system notifications", "program-status-notify",
                       help: "While you're elsewhere (with Terminal notifications on); the pane's edge lights up too.")
                toggle("Badge Dock icon", "program-status-dock-badge", help: "Counted in the badge on Libertty's Dock icon.")
                Toggle(isOn: Binding(get: { model.sound(for: state) != nil }, set: { model.setSound(state, $0 ? "" : nil) })) {
                    Text("Play a sound")
                    Text("As it begins, while you're elsewhere.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                if let sound = model.sound(for: state) {
                    Picker("Sound", selection: Binding(get: { sound }, set: { model.setSound(state, $0) })) {
                        Text("The alert sound").tag("")
                        ForEach(SettingsModel.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if let problem = model.problems[id] {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                }
            } header: {
                HStack(spacing: 10) {
                    ProgramStateIcon(state: state, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.title)
                        Text(description).font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
    }

    private var description: String {
        switch state {
        case .working: "A program or agent is busy."
        case .blocked: "It waits for you: an approval, a question, a sign-in."
        case .error: "It failed."
        case .done: "It finished."
        case .idle: "It's idle."
        }
    }

    private func toggle(_ title: String, _ key: String, help: String) -> some View {
        Toggle(isOn: Binding(get: { model.states(key).contains(state) }, set: { model.setState(state, in: key, $0) })) {
            Text(title)
            Text(help).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .disabled(model.locked[key] != nil)
    }
}

// MARK: - Remote Hosts

struct RemoteHostsPage: View {
    @ObservedObject var model: SettingsModel
    @ViewState private var hosts: [String] = []

    var body: some View {
        Form {
            Section {
                if hosts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No Remote Hosts").font(.system(size: 15, weight: .semibold))
                        Text("Connect to a host over ssh: its sessions run there, and keep running when the connection drops.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    ForEach(hosts, id: \.self) { host in
                        LabeledContent {
                            Button("Connect") { ConnectPanel.shared.show(destination: host) }
                        } label: {
                            Label(host, systemImage: "globe")
                        }
                    }
                }
            } header: {
                if !hosts.isEmpty { Text("Hosts You Connected To") }
            } footer: {
                HStack {
                    Spacer()
                    Button("Connect to Host…") { ConnectPanel.shared.show() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { hosts = ConnectPanel.recentHosts }
    }
}

// MARK: - For the UI probe

/// Where a control drawn by SwiftUI alone is, named as VoiceOver names it,
/// with its value (a probe can't reach SwiftUI's own accessibility in its
/// process): `settings:press:LABEL` clicks it there, `expect-settings`
/// reads its value. An empty view the control's size that no click hits;
/// only in builds with the probes.
struct ProbeAnchor: NSViewRepresentable {
    let label: String
    let value: String

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("probe-anchor")
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
    }
}

extension View {
    @ViewBuilder func probeAnchor(_ label: String, value: String = "") -> some View {
        #if LIBERTTY_PROBES
        background(ProbeAnchor(label: label, value: value))
        #else
        self
        #endif
    }
}
