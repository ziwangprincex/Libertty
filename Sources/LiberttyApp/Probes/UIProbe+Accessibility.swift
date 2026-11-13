#if LIBERTTY_PROBES
import AppKit

/// The UI probe's accessibility audit (`expect-unlabeled:N`): every control
/// in the app's windows on screen that VoiceOver would read by its role
/// alone ("button", "image"), found as VoiceOver finds them, through the
/// accessibility tree rather than the views.
extension UIProbe {
    struct Unlabeled {
        var role: String
        /// Its class and a few of its ancestors', what it says on pointing.
        var description: String
        /// In the tab sidebar (counted apart: the sidebar has a test of its own).
        var inSidebar: Bool
    }

    /// The roles that are nothing to VoiceOver without a name.
    private static let namedRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .image, .slider,
        .disclosureTriangle, .incrementor, .colorWell, .textField, .comboBox, .radioGroup,
    ]

    static func unlabeledControls() -> [Unlabeled] {
        var found: [Unlabeled] = []
        var seen = Set<ObjectIdentifier>()
        let dump = ProcessInfo.processInfo.environment["LIBERTTY_PROBE_AX_DUMP"] != nil
        func visit(_ object: Any, depth: Int) {
            guard depth < 80, let object = object as? NSObject, let element = object as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(object)).inserted else { return }
            let role = element.accessibilityRole()
            if dump {
                Swift.print("ax    " + String(repeating: " ", count: depth) + "\(role?.rawValue ?? "-") "
                            + "\((element.accessibilityLabel() ?? element.accessibilityTitle() ?? "").debugDescription) [\(type(of: object))]")
            }
            if let role, namedRoles.contains(role), !isSystemOwn(element) {
                if !isNamed(element, role: role) {
                    found.append(Unlabeled(role: role.rawValue, description: describe(element), inSidebar: isInSidebar(element)))
                } else if let symbol = symbolNamed(element) {
                    // Named only by its image's stock description ("Up-right arrow in a square"): no better than none.
                    found.append(Unlabeled(role: role.rawValue, description: "named by its symbol \(symbol): " + describe(element),
                                           inSidebar: isInSidebar(element)))
                }
            }
            for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            // (A table's rows aren't its children until an assistive app asks: its row views are.)
            if let table = object as? NSTableView {
                let rows = table.rows(in: table.visibleRect)
                for row in rows.location..<(rows.location + rows.length) {
                    if let view = table.rowView(atRow: row, makeIfNecessary: false) { visit(view, depth: depth + 1) }
                }
            }
        }
        let windows = MainActor.assumeIsolated { NSApp.windows.filter { $0.isVisible } }
        for window in windows { visit(window, depth: 0) }
        return found
    }

    /// The window's own buttons (close, minimize, zoom) and a scroller's
    /// parts: AppKit's, named by their subrole.
    private static func isSystemOwn(_ element: NSAccessibilityProtocol) -> Bool {
        let own: Set<NSAccessibility.Subrole> = [.closeButton, .minimizeButton, .zoomButton, .fullScreenButton,
                                                  .incrementArrow, .decrementArrow, .incrementPage, .decrementPage]
        if let subrole = element.accessibilitySubrole(), own.contains(subrole) { return true }
        return (element.accessibilityParent() as? NSAccessibilityProtocol)?.accessibilityRole() == .scrollBar
    }

    /// The SF Symbol whose stock description is all that names the element,
    /// if so (said before a button's title too, it misleads there as well).
    private static func symbolNamed(_ element: NSAccessibilityProtocol) -> String? {
        let image: NSImage? = switch element {
        case let cell as NSButtonCell: cell.image
        case let button as NSButton: button.image
        case let cell as NSImageCell: cell.image
        case let view as NSImageView: view.image
        default: nil
        }
        // (A symbol image's description reads "… symbol = NAME>"; probes only.)
        guard let image, let range = image.description.range(of: "symbol = ") else { return nil }
        let symbol = String(image.description[range.upperBound...].prefix { $0 != ">" && $0 != " " })
        guard let stock = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.accessibilityDescription,
              let label = element.accessibilityLabel() ?? element.accessibilityTitle(), label == stock else { return nil }
        // A stock name its tooltip says too ("Close" for an ×, "Close (Esc)") was meant.
        let view = (element as? NSCell)?.controlView ?? element as? NSView
        if let tip = view?.toolTip, tip.hasPrefix(label) { return nil }
        return symbol
    }

    private static func isNamed(_ element: NSAccessibilityProtocol, role: NSAccessibility.Role) -> Bool {
        func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if has(element.accessibilityLabel()) || has(element.accessibilityTitle()) { return true }
        if element.accessibilityTitleUIElement() != nil { return true }
        // A field says what it's for by its placeholder; a static text field reads its value.
        if role == .textField || role == .comboBox {
            if has(element.accessibilityPlaceholderValue()) { return true }
            if let field = element as? NSTextField, !field.isEditable { return true }
        }
        return false
    }

    private static func describe(_ element: NSAccessibilityProtocol) -> String {
        var chain: [String] = []
        var current: Any? = element
        while let object = current as? NSObject, chain.count < 5 {
            var name = String(describing: type(of: object))
            if let view = object as? NSView {
                if let id = view.identifier?.rawValue, !id.hasPrefix("_") { name += "#\(id)" }
                if let tip = view.toolTip, !tip.isEmpty { name += "(tip: \(tip))" }
                if let button = view as? NSButton, let image = button.image { name += "(image: \(image.name() ?? image.accessibilityDescription ?? "?"))" }
            }
            chain.append(name)
            current = (object as? NSAccessibilityProtocol)?.accessibilityParent()
        }
        return chain.joined(separator: " < ")
    }

    /// In the window's tab sidebar: one of its views, or an element of one.
    private static func isInSidebar(_ element: NSAccessibilityProtocol) -> Bool {
        var current: Any? = element
        var view: NSView?
        while let object = current as? NSObject {
            if let v = object as? NSView { view = v; break }
            current = (object as? NSAccessibilityProtocol)?.accessibilityParent()
        }
        for v in sequence(first: view, next: { $0?.superview }) {
            guard let v else { break }
            if let owner = v.nextResponder as? NSViewController, owner.view === v,
               String(describing: type(of: owner)).contains("Sidebar") { return true }
        }
        return false
    }
}
#endif
