import Foundation

/// What a setting takes, so a keybind can change it: from the Settings
/// window's own control where the setting has one — its choices, a number's
/// range and the step its stepper moves by — else from what `Config`
/// accepts.
struct SettingShape {
    let key: String
    /// What a switch writes for on and for off.
    var onOff: (on: String, off: String)?
    /// The values a choice cycles through, in the order the control lists them.
    var choices: [String] = []
    /// A number's bounds, and the step the Settings control moves it by.
    var range: ClosedRange<Double>?
    var step: Double?

    var isSwitch: Bool { onOff != nil }
    /// It takes a plain number: a control says so, or its default reads as one.
    var isNumber: Bool { range != nil || step != nil || Double(SettingsModel.defaultValue(key)) != nil }

    init(_ key: String) {
        self.key = key
        switch SettingsRegistry.items.first(where: { $0.key == key })?.kind {
        case .toggle(let on, let off): onOff = (on, off)
        case .segmented(let options), .popup(let options), .tiles(let options): choices = options.map(\.value)
        case .slider(let range, let step, _), .stepper(let range, let step, _): (self.range, self.step) = (range, step)
        case .text, .custom, nil: break
        }
        // A setting with no control of its own is a switch if it takes true
        // and false and holds one of them.
        if onOff == nil, choices.isEmpty, range == nil, Self.takesBool(key) { onOff = ("true", "false") }
    }

    private static func takesBool(_ key: String) -> Bool {
        guard ["true", "false"].contains(SettingsModel.defaultValue(key)) else { return false }
        var probe = Config()
        return probe.set(key, "true") == nil && probe.set(key, "false") == nil
    }

    /// Whether the switch is on now: it is unless its value is the off one,
    /// as the Settings window reads it.
    func isOn(_ value: String) -> Bool {
        guard let onOff else { return false }
        return SettingsModel.normalized(key, value) != SettingsModel.normalized(key, onOff.off)
    }
}

/// The keybindable actions that change a setting and keep it: a switch
/// flipped, a choice cycled, a number stepped, a value set outright, or the
/// setting back to its default.
///
/// Each writes the config file's line in place, the way the command
/// palette's own setting editing does — checked on a copy of the config
/// first — so the change outlives the window and every window follows the
/// reload.
enum SettingActions {
    /// The names `keybind` knows these by.
    static let names = ["toggle_setting", "cycle_setting", "increase_setting", "decrease_setting",
                        "reset_setting", "set_setting"]

    /// What lets a terminal read your signed-in pages, what lets programs
    /// drive Libertty, and another file to read (which could set either):
    /// yours to change, in Settings or the config file. From outside
    /// Libertty — `libertty +action` and `+set`, a request, a script — an
    /// action that changes one is refused; a key you bound yourself still
    /// does it.
    static let guarded: Set<String> = ["browser-automation", "remote-control", "config-file"]

    /// Whether `action` changes a guarded setting, or binds a key that would.
    static func changesGuarded(_ action: Action) -> Bool {
        switch action {
        case .toggleSetting(let key), .cycleSetting(let key, _), .increaseSetting(let key, _),
             .decreaseSetting(let key, _), .resetSetting(let key):
            return guarded.contains(key)
        case .setSetting(let key, let value):
            return guarded.contains(key) || key == "keybind" && bindsGuarded(value)
        default:
            return false
        }
    }

    /// Whether a `keybind` value binds a key to an action that changes a guarded setting.
    static func bindsGuarded(_ keybind: String) -> Bool {
        guard let (_, action, _) = Keybinds.parse(keybind) else { return false }
        return changesGuarded(action)
    }

    /// One of them from a `keybind` action's name and argument, or, failing
    /// that, what's wrong with it in words that say what to do instead.
    static func parse(_ name: String, _ arg: String?) -> (action: Action?, problem: String?) {
        func bad(_ problem: String) -> (Action?, String?) { (nil, problem) }
        let arg = arg?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !arg.isEmpty else {
            return bad("\(name) needs a setting, e.g. \(name):\(name == "set_setting" ? "font-size=16" : "copy-on-select")")
        }
        // `set_setting:KEY=VALUE`; the rest take `KEY` and may take one more
        // thing after a second colon.
        var key = arg, rest: String?
        if name == "set_setting" {
            guard let eq = arg.firstIndex(of: "=") else {
                return bad("set_setting needs KEY=VALUE, e.g. set_setting:font-size=16")
            }
            key = String(arg[..<eq]).trimmingCharacters(in: .whitespaces)
            rest = String(arg[arg.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        } else if let colon = arg.firstIndex(of: ":") {
            key = String(arg[..<colon]).trimmingCharacters(in: .whitespaces)
            rest = String(arg[arg.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !key.isEmpty, Config.documentation.contains(where: { $0.key == key }) else {
            return bad("no setting called “\(key)”")
        }
        let shape = SettingShape(key)
        switch name {
        case "toggle_setting":
            guard rest == nil else { return bad("toggle_setting takes a setting only, e.g. toggle_setting:\(key)") }
            guard shape.isSwitch else { return bad(notA(key, "a switch", shape)) }
            return (.toggleSetting(key), nil)
        case "cycle_setting":
            let given = (rest ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if rest != nil, given.count < 2 {
                return bad("cycle_setting needs two values or more, e.g. cycle_setting:\(key):a,b")
            }
            let choices = given.isEmpty ? shape.choices : given
            guard choices.count > 1 else {
                guard !shape.isSwitch else { return bad("“\(key)” is on or off: use toggle_setting:\(key)") }
                return bad("“\(key)” has no set of values to cycle: name them, e.g. cycle_setting:\(key):a,b")
            }
            if let wrong = given.first(where: { value in var probe = Config(); return probe.set(key, value) != nil }) {
                return bad(doesNotTake(key, wrong))
            }
            return (.cycleSetting(key, given), nil)
        case "increase_setting", "decrease_setting":
            guard shape.isNumber else { return bad(notA(key, "a number", shape)) }
            var by: Double?
            if let rest {
                guard let n = Double(rest), n > 0, n.isFinite else { return bad("a step is a positive number, not “\(rest)”") }
                by = n
            }
            return (name == "increase_setting" ? .increaseSetting(key, by) : .decreaseSetting(key, by), nil)
        case "reset_setting":
            guard rest == nil else { return bad("reset_setting takes a setting only, e.g. reset_setting:\(key)") }
            return (.resetSetting(key), nil)
        case "set_setting":
            let value = rest ?? ""
            var probe = Config()
            if !value.isEmpty, probe.set(key, value) != nil { return bad(doesNotTake(key, value)) }
            return (.setSetting(key, value), nil)
        default: return (nil, nil)
        }
    }

    /// "“font-size” isn't a switch: it needs a value, or increase, decrease,
    /// or reset" — what the setting isn't, said by what it can take instead.
    private static func notA(_ key: String, _ what: String, _ shape: SettingShape) -> String {
        var verbs: [String] = []
        if shape.isSwitch { verbs.append("toggle") }
        if !shape.choices.isEmpty { verbs.append("cycle") }
        if shape.isNumber { verbs += ["increase", "decrease"] }
        verbs.append("reset")
        let instead = verbs.count > 1 ? verbs.dropLast().joined(separator: ", ") + ", or " + verbs[verbs.count - 1]
            : verbs.joined()
        return "“\(key)” isn't \(what): it needs a value, or \(instead)"
    }

    private static func doesNotTake(_ key: String, _ value: String) -> String {
        var probe = Config()
        let says = probe.set(key, value) ?? ""
        return "“\(key)” doesn't take “\(value)”" + (says.isEmpty ? "" : " (\(says))")
    }

    /// What the action would write, given the config as it stands, or nil
    /// when there's nothing to write (a number already at the end of its
    /// range, a cycle with one value).
    static func next(_ action: Action, in config: Config) -> (key: String, value: String)? {
        func current(_ key: String) -> String { config.values(of: key).first ?? "" }
        switch action {
        case .toggleSetting(let key):
            let shape = SettingShape(key)
            guard let onOff = shape.onOff else { return nil }
            return (key, shape.isOn(current(key)) ? onOff.off : onOff.on)
        case .cycleSetting(let key, let given):
            let choices = given.isEmpty ? SettingShape(key).choices : given
            guard choices.count > 1 else { return nil }
            let now = SettingsModel.normalized(key, current(key))
            let at = choices.firstIndex { SettingsModel.normalized(key, $0) == now }
            return (key, choices[((at ?? -1) + 1) % choices.count])
        case .increaseSetting(let key, let by): return stepped(key, current(key), by: by, up: true)
        case .decreaseSetting(let key, let by): return stepped(key, current(key), by: by, up: false)
        case .resetSetting(let key): return (key, "")
        case .setSetting(let key, let value): return (key, value)
        default: return nil
        }
    }

    /// A number moved by `by`, or by the step its Settings control uses, and
    /// held inside that control's range.
    private static func stepped(_ key: String, _ current: String, by: Double?, up: Bool) -> (key: String, value: String)? {
        let shape = SettingShape(key)
        let now = Double(current) ?? Double(SettingsModel.defaultValue(key)) ?? 0
        let step = by ?? shape.step ?? 1
        var next = now + (up ? step : -step)
        if let range = shape.range { next = min(max(next, range.lowerBound), range.upperBound) }
        // A number past what any setting takes says nothing: nothing to write.
        guard next.isFinite, next != now else { return nil }
        return (key, SettingsItem.number(next))
    }

    /// Change the setting and keep it. False when there was nothing to
    /// write, or the config file wouldn't take it.
    @discardableResult
    static func perform(_ action: Action) -> Bool {
        guard let (key, value) = next(action, in: ConfigStore.shared.savedConfig) else { return false }
        var probe = ConfigStore.shared.savedConfig
        guard probe.set(key, value) == nil else { return false }
        ConfigStore.shared.set(key, value.isEmpty ? nil : value)
        return true
    }

    /// How the action reads where actions are listed: "Toggle Cursor Blink",
    /// "Font Size: Bigger", by the Settings window's name for the setting
    /// where it has one, else by its config key.
    static func title(_ action: Action) -> String? {
        func named(_ key: String) -> String {
            guard let title = SettingsRegistry.items.first(where: { $0.key == key })?.title else { return key }
            return L10n.t(title)
        }
        switch action {
        case .toggleSetting(let key): return L10n.t("Toggle") + " " + named(key)
        case .cycleSetting(let key, _): return L10n.t("Cycle") + " " + named(key)
        case .increaseSetting(let key, _): return named(key) + ": " + L10n.t("Bigger")
        case .decreaseSetting(let key, _): return named(key) + ": " + L10n.t("Smaller")
        case .resetSetting(let key): return L10n.t("Reset") + " " + named(key)
        case .setSetting(let key, let value): return named(key) + ": " + value
        default: return nil
        }
    }
}
