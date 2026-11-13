import Foundation

/// Libertty's Surface Protocol (docs/surface-protocol.md): a program in a
/// terminal asks for native UI — a card in its output, or one over its pane —
/// with OSC 7502, and hears back what was clicked, chosen or typed. After
/// Tern's "any command can draw native UI".
///
///     ESC ] 7502 ; q BEL                 does this terminal draw surfaces? (a reply only when it does)
///     ESC ] 7502 ; s ; {json} BEL        show a surface, or replace the one with its id
///     ESC ] 7502 ; s ; b64:… BEL         the same, the JSON in base64 (any UTF-8, no escaping worries)
///     ESC ] 7502 ; d ; ID BEL            take one away
///     ESC ] 7502 ; c BEL                 take away every live one in the pane
///
/// Events come back as typed input, `ESC ] 7502 ; e ; b64:… BEL`, while the
/// program that drew the surface is still the one in front.
enum SurfaceProtocol {
    static let number = 7502
    static let version = 1
    /// The most bytes of one sequence (`GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES`).
    static let maxSequenceBytes = 256 * 1024
    static let maxSurfaces = 16
    static let maxElements = 200
    static let maxItems = 1000
    static let maxButtons = 12
    static let maxColumns = 12
    static let maxKeyValues = 50
    static let maxLabel = 500
    static let maxText = 20_000
    static let maxDiff = 200_000
    static let maxInlineRows = 40
    static let maxImageBytes = 1 << 20
    static let maxImageFileBytes = 10 << 20
    /// Commands a pane takes in a second; past that, only each surface's latest.
    static let ratePerSecond = 60

    enum Command: Equatable {
        case query
        case set(String)  // the JSON, decoded from base64 when it came so
        case delete(String)
        case clear
    }

    struct ParseError: Error, Equatable, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// One OSC's content, "7502;…" (nil: another OSC, not ours).
    static func command(_ content: String) throws -> Command? {
        let prefix = "\(number);"
        guard content.hasPrefix(prefix) || content == "\(number)" else { return nil }
        let body = content.dropFirst(min(content.count, prefix.count))
        let parts = body.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let verb = parts.first.map(String.init) ?? ""
        let payload = parts.count > 1 ? String(parts[1]) : ""
        switch verb {
        case "q": return .query
        case "c": return .clear
        case "d":
            guard isID(payload) else { throw ParseError("d wants a surface id") }
            return .delete(payload)
        case "s":
            if payload.hasPrefix("b64:") {
                guard let data = Data(base64Encoded: String(payload.dropFirst(4)), options: .ignoreUnknownCharacters),
                      let json = String(data: data, encoding: .utf8) else { throw ParseError("s: bad base64") }
                return .set(json)
            }
            guard payload.hasPrefix("{") else { throw ParseError("s wants JSON or b64:") }
            return .set(payload)
        default:
            throw ParseError("unknown verb \(verb)")
        }
    }

    static func isID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "_.-".unicodeScalars.contains($0)
        }
    }

    /// The query's answer: version, elements, the size limit.
    static var queryReply: Data {
        let elements = Element.Kind.allCases.map(\.rawValue).joined(separator: ",")
        return Data("\u{1b}]\(number);q;v=\(version);elements=\(elements);max=\(maxSequenceBytes)\u{7}".utf8)
    }

    /// An event as the program reads it: base64 JSON, so nothing in it can
    /// be taken for terminal control (an input's text is the user's).
    static func event(_ fields: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Data("\u{1b}]\(number);e;b64:\(json.base64EncodedString())\u{7}".utf8)
    }

    /// What went wrong, told to a program that asked first (`q`): it speaks
    /// the protocol, so it reads these; others never hear them.
    static func errorReply(_ message: String, surface: String?) -> Data {
        var fields: [String: Any] = ["type": "error", "message": message]
        if let surface { fields["surface"] = surface }
        return event(fields)
    }
}

/// A surface as a program described it, checked and trimmed to the limits.
struct SurfaceSpec: Equatable {
    enum Placement: Equatable {
        /// In the output: `rows` rows, the ones just above the cursor
        /// (`above`, the program printed that many lines first) or from the
        /// cursor's row down (`cursor`).
        case inline(rows: Int, fromCursor: Bool)
        /// Over the pane, at `position`, `cols` × `rows` cells (clamped to the pane).
        case overlay(position: Position, cols: Int, rows: Int)
    }

    enum Position: String, CaseIterable { case top, bottom, center, topRight = "top-right", bottomRight = "bottom-right", full }

    var id: String
    var placement: Placement
    var title: String
    var elements: [Element]

    var isInline: Bool { if case .inline = placement { true } else { false } }

    init(id: String, placement: Placement, title: String = "", elements: [Element]) {
        self.id = id
        self.placement = placement
        self.title = title
        self.elements = elements
    }

    /// Read a `set`'s JSON (`remote`: the pane's program runs elsewhere, so
    /// a file path names nothing here).
    static func parse(_ json: String, remote: Bool) throws -> SurfaceSpec {
        typealias E = SurfaceProtocol.ParseError
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw E("not a JSON object") }
        guard let id = object["id"] as? String, SurfaceProtocol.isID(id) else { throw E("id: letters, digits, _ . -, at most 64") }
        let placement: Placement
        switch object["placement"] as? String ?? "inline" {
        case "inline":
            let rows = intValue(object["rows"]) ?? 4
            guard (1...SurfaceProtocol.maxInlineRows).contains(rows) else { throw E("rows: 1 to \(SurfaceProtocol.maxInlineRows)") }
            let anchor = object["anchor"] as? String ?? "above"
            guard anchor == "above" || anchor == "cursor" else { throw E("anchor: above or cursor") }
            placement = .inline(rows: rows, fromCursor: anchor == "cursor")
        case "overlay":
            guard let position = Position(rawValue: object["position"] as? String ?? "bottom-right") else {
                throw E("position: " + Position.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let cols = max(10, min(400, intValue(object["cols"]) ?? 60))
            let rows = max(2, min(200, intValue(object["rows"]) ?? 10))
            placement = .overlay(position: position, cols: cols, rows: rows)
        default:
            throw E("placement: inline or overlay")
        }
        guard let list = object["elements"] as? [[String: Any]] else { throw E("elements: a list") }
        guard list.count <= SurfaceProtocol.maxElements else { throw E("more than \(SurfaceProtocol.maxElements) elements") }
        var ids = Set<String>()
        var elements: [Element] = []
        for (i, raw) in list.enumerated() {
            let element = try Element.parse(raw, index: i, remote: remote)
            if let eid = element.id {
                guard ids.insert(eid).inserted else { throw E("element id \(eid) twice") }
            }
            elements.append(element)
        }
        return SurfaceSpec(id: id, placement: placement, title: Element.clean(object["title"], SurfaceProtocol.maxLabel),
                           elements: elements)
    }

    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let d = any as? Double, d.isFinite, abs(d) < 1e9 { return Int(d) }
        return nil
    }
}

/// One thing in a surface.
struct Element: Equatable {
    enum Kind: String, CaseIterable {
        case text, markdown, buttons, list, table, progress, keyvalue, input, image, diff, divider
    }

    struct Item: Equatable {
        var id: String
        var label: String
        var detail = ""
        /// Buttons: primary, default, destructive.
        var style = "default"
        var disabled = false
    }

    enum Selection: String { case none, single, multi }

    enum ImageSource: Equatable {
        case data(Data)
        case file(String)
    }

    var kind: Kind
    var id: String?
    var text = ""
    /// text: title, body, secondary, mono.
    var style = "body"
    var items: [Item] = []
    var columns: [String] = []
    /// Table rows: an id and its cells.
    var rows: [(id: String, cells: [String])] = []
    var selection = Selection.none
    var value: Double?
    var label = ""
    var placeholder = ""
    var pairs: [(String, String)] = []
    var image: ImageSource?
    /// Rows an image (or a list, a table) takes; nil: what fits.
    var height: Int?

    static func == (a: Element, b: Element) -> Bool {
        a.kind == b.kind && a.id == b.id && a.text == b.text && a.style == b.style && a.items == b.items && a.columns == b.columns
            && a.rows.map(\.id) == b.rows.map(\.id) && a.rows.map(\.cells) == b.rows.map(\.cells) && a.selection == b.selection
            && a.value == b.value && a.label == b.label && a.placeholder == b.placeholder
            && a.pairs.map(\.0) == b.pairs.map(\.0) && a.pairs.map(\.1) == b.pairs.map(\.1) && a.image == b.image && a.height == b.height
    }

    /// Untrusted text, as shown: no controls, no bidirectional overrides
    /// (they'd let a label read as something else), at most `limit` characters.
    static func clean(_ any: Any?, _ limit: Int) -> String {
        guard let s = any as? String else { return "" }
        let banned: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C]
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if banned.contains(scalar.value) { continue }
            if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
            if (0x7F...0x9F).contains(scalar.value) { continue }
            out.append(scalar)
        }
        return String(String(out).prefix(limit))
    }

    static func parse(_ raw: [String: Any], index: Int, remote: Bool) throws -> Element {
        typealias E = SurfaceProtocol.ParseError
        guard let name = raw["type"] as? String, let kind = Kind(rawValue: name) else {
            throw E("element \(index): type is one of " + Kind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        var e = Element(kind: kind)
        if let id = raw["id"] {
            guard let id = id as? String, SurfaceProtocol.isID(id) else { throw E("element \(index): a bad id") }
            e.id = id
        }
        e.height = SurfaceSpec.intValue(raw["height"]).map { max(1, min(SurfaceProtocol.maxInlineRows, $0)) }
        func items(_ limit: Int) throws -> [Item] {
            guard let list = raw["items"] as? [Any] else { throw E("element \(index): items, a list") }
            guard list.count <= limit else { throw E("element \(index): more than \(limit) items") }
            var seen = Set<String>()
            return try list.enumerated().map { j, any in
                let o = any as? [String: Any] ?? ["label": any as? String ?? ""]
                let id = (o["id"] as? String) ?? String(j)
                guard SurfaceProtocol.isID(id), seen.insert(id).inserted else { throw E("element \(index): item \(j): a bad or repeated id") }
                return Item(id: id, label: clean(o["label"], SurfaceProtocol.maxLabel), detail: clean(o["detail"], SurfaceProtocol.maxLabel),
                            style: ["primary", "destructive"].contains(o["style"] as? String) ? o["style"] as! String : "default",
                            disabled: o["disabled"] as? Bool ?? false)
            }
        }
        func select() -> Selection { Selection(rawValue: raw["select"] as? String ?? "single") ?? .single }
        switch kind {
        case .text:
            e.text = clean(raw["text"], SurfaceProtocol.maxText)
            e.style = ["title", "secondary", "mono"].contains(raw["style"] as? String) ? raw["style"] as! String : "body"
        case .markdown:
            e.text = clean(raw["text"], SurfaceProtocol.maxText)
        case .buttons:
            e.items = try items(SurfaceProtocol.maxButtons)
        case .list:
            e.items = try items(SurfaceProtocol.maxItems)
            e.selection = select()
        case .table:
            guard let columns = raw["columns"] as? [Any], (1...SurfaceProtocol.maxColumns).contains(columns.count) else {
                throw E("element \(index): columns, 1 to \(SurfaceProtocol.maxColumns)")
            }
            e.columns = columns.map { clean($0, SurfaceProtocol.maxLabel) }
            guard let rows = raw["rows"] as? [Any], rows.count <= SurfaceProtocol.maxItems else {
                throw E("element \(index): rows, at most \(SurfaceProtocol.maxItems)")
            }
            var seen = Set<String>()
            e.rows = try rows.enumerated().map { j, any in
                let o = any as? [String: Any]
                let cells = (o?["cells"] as? [Any] ?? any as? [Any] ?? []).prefix(e.columns.count).map { clean($0, SurfaceProtocol.maxLabel) }
                let id = (o?["id"] as? String) ?? String(j)
                guard SurfaceProtocol.isID(id), seen.insert(id).inserted else { throw E("element \(index): row \(j): a bad or repeated id") }
                return (id, cells + Array(repeating: "", count: max(0, e.columns.count - cells.count)))
            }
            e.selection = select()
        case .progress:
            if let v = raw["value"] as? Double { e.value = max(0, min(1, v)) } else if let v = raw["value"] as? Int { e.value = max(0, min(1, Double(v))) }
            e.label = clean(raw["label"], SurfaceProtocol.maxLabel)
        case .keyvalue:
            guard let list = raw["items"] as? [Any], list.count <= SurfaceProtocol.maxKeyValues else {
                throw E("element \(index): items, at most \(SurfaceProtocol.maxKeyValues) pairs")
            }
            e.pairs = list.map { any in
                let pair = any as? [Any] ?? []
                return (clean(pair.first, SurfaceProtocol.maxLabel), clean(pair.dropFirst().first, SurfaceProtocol.maxLabel))
            }
        case .input:
            guard e.id != nil else { throw E("element \(index): an input needs an id (its value is told by it)") }
            e.label = clean(raw["label"], SurfaceProtocol.maxLabel)
            e.placeholder = clean(raw["placeholder"], SurfaceProtocol.maxLabel)
            e.text = String(clean(raw["value"], 4096).filter { $0 != "\n" })
        case .image:
            if let b64 = raw["data"] as? String {
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                    throw E("element \(index): data, base64")
                }
                guard data.count <= SurfaceProtocol.maxImageBytes else { throw E("element \(index): an image over 1 MB") }
                e.image = .data(data)
            } else if let path = raw["path"] as? String {
                // A path names a file where the program runs: on another machine, nothing here.
                guard !remote else { throw E("element \(index): a file path from another machine") }
                guard path.hasPrefix("/") else { throw E("element \(index): path, absolute") }
                e.image = .file(path)
            } else {
                throw E("element \(index): an image wants data or path")
            }
            e.label = clean(raw["label"], SurfaceProtocol.maxLabel)
        case .diff:
            e.text = clean(raw["text"], SurfaceProtocol.maxDiff)
        case .divider:
            break
        }
        return e
    }
}
