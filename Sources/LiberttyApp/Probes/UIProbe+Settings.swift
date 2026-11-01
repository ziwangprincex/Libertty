#if LIBERTTY_PROBES
import AppKit

/// The UI probe's side of Libertty ▸ Settings…: its controls found and
/// pressed through accessibility, as VoiceOver presses them, so a step goes
/// through the very binding a click does; the config file watched line by line.
extension UIProbe {
    /// The config file's lines at the last `settings:mark` (or the last
    /// change `expect-config-change` saw).
    private static var configMark: [String]?

    struct SettingsElement {
        var role: String
        var label: String
        var value: String
        var object: NSObject
    }

    /// Every element of the Settings window's content, depth first.
    static func settingsElements() -> [SettingsElement] {
        guard let content = MainActor.assumeIsolated({ SettingsWindowController.shared.openWindow?.contentView?.superview }) else { return [] }
        var found: [SettingsElement] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let object = object as? NSObject, let element = object as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(object)).inserted else { return }
            let label = element.accessibilityLabel() ?? element.accessibilityTitle() ?? ""
            let value = element.accessibilityValue().map { "\($0)" } ?? ""
            let role = element.accessibilityRole()?.rawValue ?? ""
            found.append(SettingsElement(role: role, label: label, value: value, object: object))
            for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            // (A hosting view of an AppKit control, a split view, may list none: its views do.)
            for view in (object as? NSView)?.subviews ?? [] { visit(view, depth: depth + 1) }
        }
        visit(content, depth: 0)
        return found
    }

    /// `settings:COMMAND`: open, close, page:NAME, press:LABEL, search:TEXT,
    /// mark, dump. Nil when done, else why not.
    static func settings(_ command: String) -> String? {
        let (verb, arg): (String, String) = {
            let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }()
        switch verb {
        case "open":
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
            pump(0.6)
        case "close":
            MainActor.assumeIsolated { SettingsWindowController.shared.window?.close() }
            pump(0.3)
        case "page":
            guard let page = SettingsPage(named: arg) else { return "no page \(arg)" }
            MainActor.assumeIsolated { SettingsModel.shared.go(.page(page)) }
            pump(0.6)
        case "press":
            // What's on the page now (a section folded away isn't).
            let deadline = Date().addingTimeInterval(3)
            var target: SettingsElement?
            repeat {
                target = settingsElements().first { $0.label == arg }
                if target == nil { pump(0.1) }
            } while target == nil && Date() < deadline
            guard let target, let element = target.object as? NSAccessibilityProtocol else { return "nothing is labeled \(arg.debugDescription)" }
            if let anchor = target.object as? NSView, anchor.identifier?.rawValue == "probe-anchor" {
                // SwiftUI's own: clicked where it is.
                guard let window = anchor.window, let content = window.contentView else { return "\(arg.debugDescription) isn't in a window" }
                let frame = anchor.convert(anchor.bounds, to: nil)  // (the window's, from its bottom-left)
                if let table = sequence(first: anchor, next: \.superview).first(where: { $0 is NSTableView }) as? NSTableView {
                    // A list's row (the sidebar's): selected as a click selects it. (A list
                    // takes no click while its window isn't key, and a probe's never is.)
                    let row = table.row(for: anchor)
                    guard row >= 0 else { return "\(arg.debugDescription) isn't in a row of its list" }
                    Swift.print("select row \(row) of \(type(of: table))")
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: table)
                } else {
                    click(x: frame.midX, y: content.bounds.height - frame.midY, in: window)
                }
            } else {
                // (A segment says false whether or not it took the press: what it did is for the expectations.)
                _ = element.accessibilityPerformPress()
            }
            pump(0.5)
        case "search":
            // Typed into Search Settings, then Return: the first result.
            guard let window = MainActor.assumeIsolated({ SettingsWindowController.shared.openWindow }) else { return "Settings isn't open" }
            guard let field = searchField(in: window.contentView?.superview ?? window.contentView) else { return "no search field" }
            window.makeFirstResponder(field)
            pump(0.2)
            for character in arg { _ = press(String(character), in: window) }
            pump(0.3)
            _ = press("enter", in: window)
            pump(0.6)
        case "mark":
            configMark = configLines()
        case "dump":
            for e in settingsElements() where !e.label.isEmpty || !e.value.isEmpty {
                Swift.print("ax    \(e.role) \(e.label.debugDescription) = \(e.value.debugDescription)")
            }
        default:
            return "no settings:\(verb)"
        }
        return nil
    }

    /// `expect-settings:`: `page=NAME` (the page in front), `LABEL=VALUE`
    /// (a control's value as VoiceOver reads it), or `LABEL` (it's shown).
    static func expectSettings(_ want: String) -> String? {
        if want.hasPrefix("page=") {
            let name = String(want.dropFirst(5))
            let shown = MainActor.assumeIsolated { SettingsModel.shared.title }
            let open = MainActor.assumeIsolated { SettingsWindowController.shared.openWindow != nil }
            return open && shown == name ? nil : open ? "the page is \(shown)" : "Settings isn't open"
        }
        let elements = settingsElements()
        guard let eq = want.lastIndex(of: "=") else {
            return elements.contains { $0.label == want } ? nil : "nothing is labeled \(want.debugDescription)"
        }
        let label = String(want[..<eq]), value = String(want[want.index(after: eq)...])
        let matches = elements.filter { $0.label == label }
        if matches.contains(where: { $0.value == value }) { return nil }
        return matches.isEmpty ? "nothing is labeled \(label.debugDescription)"
            : "\(label.debugDescription) is \(matches.map(\.value.debugDescription).joined(separator: ", "))"
    }

    /// `expect-config-change:LINE`: since the mark, the config file changed by
    /// one line — an existing line rewritten in place, or one added — which
    /// now reads LINE; the rest as it was. The mark moves on.
    static func expectConfigChange(_ line: String) -> String? {
        let now = configLines()
        guard let before = configMark else { configMark = now; return "no settings:mark before it" }
        let diff = now.difference(from: before)
        let added = diff.insertions.compactMap { if case .insert(_, let l, _) = $0 { l } else { nil } }
        let removed = diff.removals.compactMap { if case .remove(_, let l, _) = $0 { l } else { nil } }
        guard added == [line], removed.count <= 1 else {
            return "changed: removed \(removed), added \(added); wanted one line, \(line.debugDescription)"
        }
        // In place: where the line it replaces was.
        if let gone = removed.first, let at = before.firstIndex(of: gone), now.firstIndex(of: line) != at {
            return "\(line.debugDescription) is at line \((now.firstIndex(of: line) ?? -1) + 1), not \(at + 1) where \(gone.debugDescription) was"
        }
        configMark = now
        return nil
    }

    private static func configLines() -> [String] {
        ((try? String(contentsOf: ConfigStore.shared.url, encoding: .utf8)) ?? "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap(searchField(in:)).first
    }
}
#endif
