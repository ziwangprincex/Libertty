import AppKit
import LiberttyCore

/// Where the Settings window is: a page, or a page under one (a program
/// state's, under Notifications).
enum SettingsLocation: Hashable {
    case page(SettingsPage)
    case programState(ProgramStatusStore.State)

    /// The sidebar's row for it.
    var page: SettingsPage {
        switch self {
        case .page(let page): page
        case .programState: .notifications
        }
    }

    var title: String {
        switch self {
        case .page(let page): page.title
        case .programState(let state): state.title
        }
    }
}

/// What the Settings window shows and does: the config as its files say
/// (`ConfigStore.savedConfig`, followed live), each change checked by
/// `Config.set` on a copy first and written as one line in place
/// (`ConfigStore.set`; an empty value, the default, removes the line).
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published private(set) var config = Config()
    @Published private(set) var keybinds = Keybinds(entries: [])
    @Published private(set) var warnings: [String] = []
    /// Keys an included file sets (by its path): a line in the main file
    /// wouldn't count, so the window doesn't offer to change them.
    @Published private(set) var locked: [String: String] = [:]
    /// Actions and triggers (`trigger:cmd+d`) an included file binds.
    @Published private(set) var lockedShortcuts: Set<String> = []
    /// Why a control's last change wasn't written, by item id.
    @Published var problems: [String: String] = [:]
    /// What a change did besides (a key taken from another action), by item id.
    @Published var notes: [String: String] = [:]

    @Published private(set) var location = SettingsLocation.page(.interface)
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var query = ""
    @Published var shortcutFilter = ""
    /// The control Search went to: scrolled to, and lit for a moment.
    @Published var target: String?
    /// The shortcut recorder listening for a key, by item id.
    @Published private(set) var recording: String?

    enum DaemonStatus: Equatable { case unknown, notPersisting, running(sessions: Int), stopped }
    @Published private(set) var daemon = DaemonStatus.unknown

    /// What macOS lets the programs in your terminals get at, as liberttyd
    /// (or, without it, Libertty) reports it: kind → `PrivacyAccess.Status`.
    enum PermissionsStatus: Equatable { case unknown, tooOld, unanswered, report([String: String]) }
    @Published private(set) var permissions = PermissionsStatus.unknown

    enum AgentStatus: Equatable { case unknown, installed, notInstalled, busy }
    @Published private(set) var agents = AgentStatus.unknown
    /// What `+agent-setup` said last.
    @Published private(set) var agentReport = ""
    /// What `+import-ghostty` said last (the welcome guide's).
    @Published private(set) var ghosttyReport = ""

    struct ThemeChoice: Identifiable {
        var name: String
        var theme: Theme
        var id: String { name }
    }

    /// The themes of one source: Libertty's own, yours, an installed app's.
    struct ThemeGroup: Identifiable {
        var id: String
        var title: String
        var choices: [ThemeChoice]
    }

    @Published private(set) var themeGroups: [ThemeGroup] = []
    @Published var themeStatus = ""

    private var backStack: [SettingsLocation] = []
    private var forwardStack: [SettingsLocation] = []
    private var observation: AnyObject?
    private var keyMonitor: Any?
    private var themesWanted = false
    private var themeSignature = ""

    private init() {
        observation = ConfigStore.shared.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let store = ConfigStore.shared
        config = store.savedConfig
        keybinds = store.keybinds
        warnings = store.warnings
        refreshLocks()
        if themesWanted { loadThemes() }
    }

    // MARK: Reading and writing

    /// A key's value as the files say, in config syntax.
    func current(_ key: String) -> String { config.values(of: key).first ?? "" }

    /// `value` as `Config` would write it back: "" and the default's other
    /// spellings become the default's, `sidebar` is `left`, `1m` is `60s`.
    nonisolated static func normalized(_ key: String, _ value: String) -> String {
        var c = Config()
        guard c.set(key, value) == nil else { return value }
        return c.values(of: key).first ?? ""
    }

    nonisolated static func defaultValue(_ key: String) -> String { Config().values(of: key).first ?? "" }

    /// Whether `option` is the value the key has now.
    func isCurrent(_ option: SettingsOption, of key: String) -> Bool { Self.matches(option, current(key), of: key) }

    /// Whether `option` means `value` (as `values(of:)` gives it).
    nonisolated static func matches(_ option: SettingsOption, _ value: String, of key: String) -> Bool {
        option.value == value || option.also.contains(value) || normalized(key, option.value) == value
    }

    /// Set `key` to `value` in the config file, its line changed in place (or
    /// added; an empty value removes it) — once `Config.set` has taken
    /// it on a copy. A problem shows under the control (`item`, else the key).
    @discardableResult
    func write(_ key: String, _ value: String, item: String? = nil) -> Bool {
        let id = item ?? key
        if let file = locked[key] {
            problems[id] = "Set in \(file)"
            return false
        }
        let (check, problem) = Self.expected(key, value, in: ConfigStore.shared.savedConfig)
        if let problem {
            problems[id] = problem
            return false
        }
        problems[id] = nil
        notes[id] = nil
        let store = ConfigStore.shared
        store.set(key, value.isEmpty ? nil : value)
        guard store.savedConfig.values(of: key) == check.values(of: key) else {
            problems[id] = "Couldn't change \((store.url.path as NSString).abbreviatingWithTildeInPath)"
            return false
        }
        return true
    }

    /// `config` as the file will make it once `key` is written as `value`
    /// (ConfigStore.set), or why it can't be. The font is the first
    /// `font-family`, its fallbacks kept: a `set` would add it after them.
    static func expected(_ key: String, _ value: String, in config: Config) -> (config: Config, problem: String?) {
        var check = config
        if key == "font-family" {
            check.setPrimaryFont(value)
            return (check, nil)
        }
        return (check, check.set(key, value))
    }

    /// Keys set by an included file (`config-file`), which the main file's
    /// line can't change; ligatures turned off by a `font-feature` line that
    /// sets other features too.
    private func refreshLocks() {
        let store = ConfigStore.shared
        var keys: [String: String] = [:]
        var shortcuts = Set<String>()
        for file in Config.load(store.url).files.dropFirst() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = (file.path as NSString).abbreviatingWithTildeInPath
            for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                guard let key = ConfigStore.key(of: line) else { continue }
                if key == "keybind" {
                    if let (trigger, action, _) = Keybinds.parse(ConfigStore.value(of: line)) {
                        shortcuts.insert(action.configString)
                        shortcuts.insert("trigger:" + trigger.configString)
                    }
                } else {
                    keys[key] = name
                }
            }
        }
        if keys["font-feature"] == nil, !config.ligatures {
            let own = ((try? String(contentsOf: store.url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
                .map(String.init).filter { ConfigStore.key(of: $0) == "font-feature" }.map(ConfigStore.value(of:))
            var without = Config()
            for line in own where !Self.onlyLigatures(line) { _ = without.set("font-feature", line) }
            if !without.ligatures { keys["font-feature"] = (store.url.path as NSString).abbreviatingWithTildeInPath }
        }
        if keys != locked { locked = keys }
        if shortcuts != lockedShortcuts { lockedShortcuts = shortcuts }
    }

    // MARK: Pages

    var title: String { location.title }

    func go(_ to: SettingsLocation) {
        guard to != location else { return }
        backStack.append(location)
        forwardStack = []
        location = to
        updateHistory()
    }

    func goBack() {
        guard let last = backStack.popLast() else { return }
        forwardStack.append(location)
        location = last
        updateHistory()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        location = next
        updateHistory()
    }

    private func updateHistory() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        stopRecording()
        if location.page == .liberttyd { refreshDaemon() }
        if location.page == .integrations, agents == .unknown { refreshAgents() }
    }

    var results: [SettingsItem] { SettingsRegistry.search(query) }

    /// To the control a search found: its page, scrolled to it, lit.
    func jump(to item: SettingsItem) {
        go(.page(item.page))
        target = item.id
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated { if self?.target == id { self?.target = nil } }
        }
    }

    /// Return in the search field: the first result.
    func jumpToFirstResult() {
        if let first = results.first { jump(to: first) }
    }

    // MARK: liberttyd

    func refreshDaemon() {
        guard Persistence.enabled else { daemon = .notPersisting; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = DaemonClient.sessions()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.daemon = sessions.map { .running(sessions: $0.count) } ?? .stopped }
            }
        }
    }

    /// Ask again (Settings opened, or you came back from System Settings).
    /// Programs run under liberttyd ask macOS as liberttyd; without it, as Libertty.
    func refreshPermissions() {
        guard Persistence.enabled else { permissions = .report(PrivacyAccess.report()); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status: PermissionsStatus
            switch DaemonClient.request(.permissions, needing: "permissions", timeout: 3) {
            case .answered(let frame): status = (frame.json["access"] as? [String: String]).map { .report($0) } ?? .unanswered
            case .unsupported: status = .tooOld
            case .unanswered: status = .unanswered
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if self?.permissions != status { self?.permissions = status } }
            }
        }
    }

    // MARK: Themes

    /// The dark half (or the light) is the one in use now.
    var darkIsActive: Bool {
        switch config.windowTheme {
        case .dark: true
        case .light: false
        case .auto, .system: SystemAppearance.isDark
        }
    }

    /// Libertty's themes at once, then each source's, a run-loop turn apart (an
    /// installed Ghostty has hundreds); again when themes come or go. Each is
    /// read as the library reads it, whatever its source keeps it in.
    func loadThemes() {
        themesWanted = true
        let entries = ThemeLibrary.shared.entries.filter { !$0.name.contains(",") && Theme.builtIn($0.name) == nil }
        let signature = entries.map { "\($0.source)/\($0.name)" }.joined(separator: "\n")
        guard signature != themeSignature || themeGroups.isEmpty else { return }
        themeSignature = signature
        var groups = [ThemeGroup(id: "built-in", title: "Built-in", choices: Theme.all.map { ThemeChoice(name: $0.name, theme: $0) })]
        themeGroups = groups
        var sources: [String] = []
        for entry in entries where !sources.contains(entry.source) { sources.append(entry.source) }
        // Yours first, then the smaller collections before the larger.
        let counts = Dictionary(entries.map { ($0.source, 1) }, uniquingKeysWith: +)
        sources.sort { a, b in a == "user" || (b != "user" && counts[a]! < counts[b]!) }
        func next(_ rest: ArraySlice<String>) {
            guard let source = rest.first else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.themeSignature == signature else { return }
                    let choices = entries.filter { $0.source == source }
                        .compactMap { e in ThemeLibrary.shared.load(e.name).map { ThemeChoice(name: e.name, theme: $0) } }
                    if !choices.isEmpty {
                        groups.append(ThemeGroup(id: source, title: source == "user" ? "Your Themes" : source, choices: choices))
                        self.themeGroups = groups
                    }
                    next(rest.dropFirst())
                }
            }
        }
        next(sources[...])
    }

    /// Choose `name` for one appearance: only that half of `theme = light:…,dark:…`.
    func chooseTheme(_ name: String, dark: Bool) {
        var spec = config.theme
        if dark { spec.dark = name } else { spec.light = name }
        write("theme", spec.configString, item: dark ? "themes-dark" : "themes-light")
    }

    /// Theme files (Ghostty's, or iTerm2's `.itermcolors`) into themes/, as
    /// Ghostty theme files of their own.
    func importThemes(_ urls: [URL]) {
        let folder = ConfigStore.directory.appendingPathComponent("themes")
        var imported: [String] = [], refused: [String] = []
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ",", with: " ")
            guard let theme = Self.readTheme(url, name: stem) else { refused.append(url.lastPathComponent); continue }
            var name = stem, n = 2
            while Theme.exists(name) { name = "\(stem) \(n)"; n += 1 }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.ghosttyText(theme).write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                imported.append(name)
            } catch {
                refused.append(url.lastPathComponent)
            }
        }
        ThemeLibrary.shared.invalidate()
        ConfigStore.shared.reload(force: true)
        loadThemes()
        themeStatus = (imported.isEmpty ? "" : "Imported \(imported.joined(separator: ", ")). ")
            + (refused.isEmpty ? "" : "No colors Libertty can read in \(refused.joined(separator: ", ")).")
    }

    /// A Ghostty theme file, or an `.itermcolors` property list.
    static func readTheme(_ url: URL, name: String) -> Theme? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "itermcolors" {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            func rgb(_ key: String) -> RGB? {
                guard let d = plist[key] as? [String: Any] else { return nil }
                func c(_ k: String) -> UInt8 { UInt8((min(max((d[k] as? Double) ?? 0, 0), 1) * 255).rounded()) }
                return RGB(c("Red Component"), c("Green Component"), c("Blue Component"))
            }
            guard let bg = rgb("Background Color"), let fg = rgb("Foreground Color") else { return nil }
            var t = Theme.all[0]
            t.name = name
            t.background = bg
            t.foreground = fg
            t.cursor = rgb("Cursor Color") ?? fg
            t.selection = rgb("Selection Color") ?? t.selection
            for i in 0..<16 { if let c = rgb("Ansi \(i) Color") { t.ansi[i] = c } }
            return t
        }
        guard let text = String(data: data, encoding: .utf8),
              text.split(whereSeparator: \.isNewline).contains(where: { ["background", "foreground", "palette"].contains(ConfigStore.key(of: String($0))) })
        else { return nil }
        return Theme.parse(name: name, text: text)
    }

    static func ghosttyText(_ t: Theme) -> String {
        var lines = ["# \(t.name), imported by Libertty's Settings."]
        lines += t.ansi.enumerated().map { "palette = \($0.offset)=\($0.element.hexString)" }
        lines += ["background = \(t.background.hexString)", "foreground = \(t.foreground.hexString)",
                  "cursor-color = \(t.cursor.hexString)", "selection-background = \(t.selection.hexString)"]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Ligatures

    /// A `font-feature` line that does nothing but turn ligatures off.
    nonisolated static func onlyLigatures(_ line: String) -> Bool {
        let items = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !items.isEmpty else { return false }
        var c = Config()
        c.fontFeatures = [line]
        return !c.ligatures && items.allSatisfy { item in
            let tag = item.trimmingCharacters(in: CharacterSet(charactersIn: "+-")).split(whereSeparator: { $0 == "=" || $0 == " " }).first
            return tag == "calt" || tag == "liga"
        }
    }

    func setLigatures(_ on: Bool) {
        if let file = locked["font-feature"] { problems["ligatures"] = "Set in \(file)"; return }
        problems["ligatures"] = nil
        if on {
            ConfigStore.shared.unset("font-feature") { Self.onlyLigatures($0) }
        } else {
            ConfigStore.shared.add("font-feature", "-calt, -liga")
        }
    }

    // MARK: Program states and the bell

    func states(_ key: String) -> Set<ProgramStatusStore.State> {
        switch key {
        case "program-status-indicator": config.programStatusIndicator
        case "program-status-notify": config.programStatusNotify
        case "program-status-dock-badge": config.programStatusDockBadge
        default: []
        }
    }

    func setState(_ state: ProgramStatusStore.State, in key: String, _ on: Bool) {
        var set = states(key)
        if on { set.insert(state) } else { set.remove(state) }
        write(key, Config.statesString(set), item: "program-state:\(state.name)")
    }

    /// The sound a state plays: nil for none, "" for the alert sound.
    func sound(for state: ProgramStatusStore.State) -> String? { config.programStatusSound[state] }

    func setSound(_ state: ProgramStatusStore.State, _ name: String?) {
        var c = config
        c.programStatusSound[state] = name
        write("program-status-sound", c.values(of: "program-status-sound").first ?? "", item: "program-state:\(state.name)")
    }

    /// What a state does, as its row says: "Tabs, Notifications, Dock Badge, Sound".
    func summary(of state: ProgramStatusStore.State) -> String {
        let parts = [("Tabs", config.programStatusIndicator.contains(state)), ("Notifications", config.programStatusNotify.contains(state)),
                     ("Dock Badge", config.programStatusDockBadge.contains(state)), ("Sound", config.programStatusSound[state] != nil)]
            .filter(\.1).map(\.0)
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }

    static let sounds: [String] = {
        let names = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"].flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { ($0 as NSString).deletingPathExtension }
        }
        return Array(Set(names)).filter { !$0.hasPrefix(".") }.sorted()
    }()

    func bell(_ feature: String) -> Bool { config.bellFeatures.contains(feature) }

    func setBell(_ feature: String, _ on: Bool) {
        var set = config.bellFeatures
        if on { set.insert(feature) } else { set.remove(feature) }
        let value: String
        if set.isEmpty {
            // (An empty value would be the default: each of its features turned off instead.)
            value = Config().bellFeatures.sorted().map { "no-" + $0 }.joined(separator: ",")
        } else {
            var c = config
            c.bellFeatures = set
            value = c.values(of: "bell-features").first ?? ""
        }
        write("bell-features", value, item: "bell:\(feature)")
    }

    // MARK: Shortcuts

    func trigger(for id: String) -> String? {
        if id.hasPrefix("shortcut:") {
            return Action(String(id.dropFirst(9))).flatMap { keybinds.trigger(for: $0) }?.displayString
        }
        let value = current(id)
        return value.isEmpty ? nil : (Shortcut(value)?.displayString ?? value)
    }

    func isLocked(shortcut id: String) -> Bool {
        if id.hasPrefix("shortcut:") {
            let action = String(id.dropFirst(9))
            guard let parsed = Action(action) else { return true }
            let trigger = keybinds.trigger(for: parsed)
            return lockedShortcuts.contains(parsed.configString) || trigger.map { lockedShortcuts.contains("trigger:" + $0.configString) } == true
        }
        return locked[id] != nil
    }

    func startRecording(_ id: String) {
        problems[id] = nil
        recording = id
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // (A monitor runs on the main thread, with the event of this moment.)
                nonisolated(unsafe) let pressed = event
                let taken = MainActor.assumeIsolated { self?.record(pressed) ?? false }
                return taken ? nil : event
            }
        }
    }

    func stopRecording() {
        recording = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
    }

    /// A key pressed while a recorder listens: Esc gives up, Delete clears
    /// the shortcut, anything else (with a modifier, or a key that types
    /// nothing) becomes it. Whether the key was taken.
    private func record(_ event: NSEvent) -> Bool {
        guard let id = recording, event.window === SettingsWindowController.shared.window else { return false }
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.keyCode == 53, mods.isEmpty { stopRecording(); return true }
        let clearing = (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty
        if id.hasPrefix("shortcut:") {
            guard let action = Action(String(id.dropFirst(9))) else { stopRecording(); return true }
            let old = keybinds.trigger(for: action)
            if clearing {
                rebind(action, from: old, to: nil, item: id)
            } else {
                guard let trigger = Trigger(event: event), !mods.isEmpty || trigger.keyName.isSpecial,
                      !["tab", "space", "enter"].contains(trigger.key) || !mods.isEmpty else {
                    problems[id] = "Hold ⌃, ⌥, ⇧ or ⌘ with the key"
                    return true
                }
                rebind(action, from: old, to: trigger, item: id)
            }
        } else if clearing {
            write(id, "")
        } else {
            guard let shortcut = Shortcut(event: event) else {
                problems[id] = "Hold ⌃, ⌥, ⇧ or ⌘ with the key, or use an F-key"
                return true
            }
            write(id, shortcut.configString)
        }
        stopRecording()
        return true
    }

    func clearShortcut(_ id: String) {
        if id.hasPrefix("shortcut:") {
            guard let action = Action(String(id.dropFirst(9))) else { return }
            rebind(action, from: keybinds.trigger(for: action), to: nil, item: id)
        } else {
            write(id, "")
        }
    }

    private func rebind(_ action: Action, from old: Trigger?, to new: Trigger?, item id: String) {
        if lockedShortcuts.contains(action.configString) || new.map({ lockedShortcuts.contains("trigger:" + $0.configString) }) == true {
            problems[id] = "Set in an included config file"
            return
        }
        let taken = new.flatMap { t in keybinds.local.first { $0.trigger == t && $0.action != action } }
        ConfigStore.shared.rebind(action, from: old, to: new)
        notes[id] = taken.map { binding in
            let title = SettingsShortcuts.groups.flatMap(\.actions).first { $0.action == binding.action.configString }?.title
            return "Was \(title ?? binding.action.configString)’s"
        }
    }

    // MARK: Coding agents

    /// Ask `+agent-setup --dry-run` whether it has anything to do.
    func refreshAgents() {
        agents = .busy
        Self.runCLI(["+agent-setup", "--dry-run"]) { [weak self] status, output in
            self?.agents = status == 0 && !output.contains("--dry-run: nothing written") ? .installed : .notInstalled
        }
    }

    /// Set up (or remove) Libertty's hooks and skill, after showing what
    /// changes, as `libertty +agent-setup` does on a terminal.
    func setAgents(_ on: Bool, in window: NSWindow?) {
        let mode = on ? [] : ["--remove"]
        agents = .busy
        Self.runCLI(["+agent-setup", "--dry-run"] + mode) { [weak self] _, plan in
            guard let self else { return }
            guard plan.contains("--dry-run: nothing written") else {
                self.agentReport = plan.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshAgents()
                return
            }
            let alert = NSAlert()
            alert.messageText = on ? "Set up coding agents for Libertty?" : "Remove Libertty from coding agents?"
            alert.informativeText = plan.replacingOccurrences(of: "(--dry-run: nothing written)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            alert.addButton(withTitle: on ? "Set Up" : "Remove")
            alert.addButton(withTitle: "Cancel")
            let go = { (response: NSApplication.ModalResponse) in
                guard response == .alertFirstButtonReturn else { return self.refreshAgents() }
                Self.runCLI(["+agent-setup", "--yes"] + mode) { _, output in
                    self.agentReport = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
                    self.refreshAgents()
                }
            }
            if let window { alert.beginSheetModal(for: window) { r in MainActor.assumeIsolated { go(r) } } } else { go(alert.runModal()) }
        }
    }

    /// The `libertty` command line (this very executable), its output back on the main thread.
    /// Ghostty's settings into the config (`+import-ghostty`): what it would
    /// add, asked first, then added.
    func importGhostty(in window: NSWindow?) {
        Self.runCLI(["+import-ghostty", "--dry-run"]) { [weak self] status, plan in
            guard let self else { return }
            guard status == 0, plan.contains("--dry-run: nothing written") else {
                self.ghosttyReport = plan.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
                return
            }
            let alert = NSAlert()
            alert.messageText = "Bring over your Ghostty settings?"
            alert.informativeText = plan.replacingOccurrences(of: "(--dry-run: nothing written)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            let go = { (response: NSApplication.ModalResponse) in
                guard response == .alertFirstButtonReturn else { return }
                Self.runCLI(["+import-ghostty", "--yes"]) { _, output in
                    self.ghosttyReport = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
                }
            }
            if let window { alert.beginSheetModal(for: window) { r in MainActor.assumeIsolated { go(r) } } } else { go(alert.runModal()) }
        }
    }

    private static func runCLI(_ args: [String], then: @escaping @MainActor (Int32, String) -> Void) {
        guard let exe = Bundle.main.executableURL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            var text = "", status: Int32 = -1
            if (try? p.run()) != nil {
                text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                status = p.terminationStatus
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { then(status, text) } }
        }
    }
}

/// A setting's choice on a menu item (View ▸ Customize View).
final class SettingChoice: NSObject {
    let key: String
    let option: SettingsOption
    init(key: String, option: SettingsOption) { (self.key, self.option) = (key, option) }
}
