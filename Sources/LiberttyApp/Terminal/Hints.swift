import AppKit
import CGhosttyVt

/// Something on screen hint mode labels (kitty's hints, Otty's Hint Mode):
/// a link or a file's path, opened as ⌘-click opens it, or text worth
/// copying (a commit's hash, an address).
struct HintTarget: Equatable {
    enum Kind: Equatable { case link, path, hash, address }
    var kind: Kind
    /// As it's printed.
    var text: String
    /// What choosing it opens; nil: it's only copied.
    var link: TerminalLink?
    /// Its cells in the viewport.
    var spans: [TerminalLink.Span]
    var label = ""
}

extension TerminalSession {
    /// A commit's hash as git and its tools print it, short or whole (with
    /// a digit in it, so a word made of a–f isn't one).
    private static let hashPattern = try! NSRegularExpression(pattern: #"\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b"#)
    /// An IPv4 address, with its port if it has one.
    private static let addressPattern = try! NSRegularExpression(pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b"#)

    /// Everything in the viewport worth a hint, the latest output (the
    /// bottom) first: links (OSC 8 or written out), paths to what exists
    /// (on a host: any path, to copy), hashes, addresses. Lines soft-
    /// wrapped over several rows are read whole.
    func hintTargets() -> [HintTarget] {
        let lines: [(text: String, cells: [(Int, Int)], uris: [String?])] = withTerminal { t in
            var cols: UInt16 = 0, rows: UInt16 = 0
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            func ref(_ x: Int, _ y: Int) -> GhosttyGridRef? {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_VIEWPORT
                point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                var r = GhosttyGridRef()
                return ghostty_terminal_grid_ref(t, point, &r) == GHOSTTY_SUCCESS ? r : nil
            }
            func wraps(_ y: Int) -> Bool {
                guard var r = ref(0, y) else { return false }
                var raw: GhosttyRow = 0
                var wrap = false
                guard ghostty_grid_ref_row(&r, &raw) == GHOSTTY_SUCCESS else { return false }
                _ = ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP, &wrap)
                return wrap
            }
            func uri(_ r: inout GhosttyGridRef) -> String? {
                var len = 0
                guard ghostty_grid_ref_hyperlink_uri(&r, nil, 0, &len) == GHOSTTY_OUT_OF_SPACE, len > 0 else { return nil }
                var buf = [UInt8](repeating: 0, count: len)
                guard ghostty_grid_ref_hyperlink_uri(&r, &buf, len, &len) == GHOSTTY_SUCCESS else { return nil }
                return String(decoding: buf.prefix(len), as: UTF8.self)
            }
            var out: [(String, [(Int, Int)], [String?])] = []
            var scalars = [UInt32](repeating: 0, count: 16)
            var y = 0
            while y < Int(rows) {
                var text = ""
                var cells: [(Int, Int)] = []
                var uris: [String?] = []
                repeat {
                    for x in 0..<Int(cols) {
                        guard var r = ref(x, y) else { continue }
                        var raw: GhosttyCell = 0
                        var wide = GHOSTTY_CELL_WIDE_NARROW
                        var hasLink = false
                        if ghostty_grid_ref_cell(&r, &raw) == GHOSTTY_SUCCESS {
                            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hasLink)
                        }
                        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                        var n = 0
                        var piece = " "
                        if ghostty_grid_ref_graphemes(&r, &scalars, scalars.count, &n) == GHOSTTY_SUCCESS, n > 0 {
                            piece = String(String.UnicodeScalarView(scalars.prefix(n).compactMap(Unicode.Scalar.init)))
                        }
                        let link = hasLink ? uri(&r) : nil
                        for _ in 0..<piece.utf16.count {
                            cells.append((y, x))
                            uris.append(link)
                        }
                        text += piece
                    }
                    y += 1
                } while y < Int(rows) && wraps(y - 1)
                out.append((text, cells, uris))
            }
            return out
        }

        var targets: [HintTarget] = []
        for line in lines.reversed() {
            let ns = line.text as NSString
            var taken = IndexSet()
            func spans(_ range: NSRange) -> [TerminalLink.Span] {
                var out: [TerminalLink.Span] = []
                for i in range.location..<(range.location + range.length) {
                    let (y, x) = line.cells[i]
                    if let last = out.last, last.row == y, last.columns.upperBound >= x - 1 {
                        out[out.count - 1].columns = last.columns.lowerBound...max(last.columns.upperBound, x)
                    } else {
                        out.append(.init(row: y, columns: x...x))
                    }
                }
                return out
            }
            /// Unless an earlier kind already has any of these characters.
            func claim(_ range: NSRange) -> Bool {
                let r = range.location..<(range.location + range.length)
                guard range.length > 0, !taken.intersects(integersIn: r) else { return false }
                taken.insert(integersIn: r)
                return true
            }
            var found: [HintTarget] = []
            // Declared hyperlinks: each run of cells with the same link.
            var i = 0
            while i < line.uris.count {
                guard let declared = line.uris[i] else { i += 1; continue }
                var end = i
                while end + 1 < line.uris.count, line.uris[end + 1] == declared { end += 1 }
                let range = NSRange(location: i, length: end - i + 1)
                if claim(range) {
                    let s = spans(range)
                    found.append(HintTarget(kind: .link, text: declared,
                                            link: TerminalLink(url: declared, spans: s, explicit: true), spans: s))
                }
                i = end + 1
            }
            let whole = NSRange(location: 0, length: ns.length)
            for match in Self.urlPattern.matches(in: line.text, range: whole) {
                let range = Self.trimURL(match.range, in: ns)
                guard claim(range) else { continue }
                let url = ns.substring(with: range), s = spans(range)
                found.append(HintTarget(kind: .link, text: url, link: TerminalLink(url: url, spans: s, explicit: false), spans: s))
            }
            for match in Self.pathPattern.matches(in: line.text, range: whole) {
                let range = Self.trimPath(match.range, in: ns)
                guard range.length > 1 else { continue }
                let text = ns.substring(with: range), s = spans(range)
                if host == nil {
                    // Only what's there: a path pattern finds every word.with.a.dot.
                    guard let link = Self.resolvePath(text, spans: s, in: workingDirectory), claim(range) else { continue }
                    found.append(HintTarget(kind: .path, text: text, link: link, spans: s))
                } else if text.contains("/"), claim(range) {
                    // A host's file can't be opened from here: copied.
                    found.append(HintTarget(kind: .path, text: text, link: nil, spans: s))
                }
            }
            for (pattern, kind) in [(Self.hashPattern, HintTarget.Kind.hash), (Self.addressPattern, .address)] {
                for match in pattern.matches(in: line.text, range: whole) where claim(match.range) {
                    found.append(HintTarget(kind: kind, text: ns.substring(with: match.range), link: nil, spans: spans(match.range)))
                }
            }
            // Right to left in a line, as the lines go bottom to top.
            targets += found.sorted { ($0.spans.first?.row ?? 0, $0.spans.first?.columns.lowerBound ?? 0)
                > ($1.spans.first?.row ?? 0, $1.spans.first?.columns.lowerBound ?? 0) }
        }
        return HintLabels.assign(targets)
    }
}

/// Labels for hints: letters from the home row out, one each while there
/// are few enough, else two each (no label starts another).
enum HintLabels {
    static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm")

    static func assign(_ targets: [HintTarget]) -> [HintTarget] {
        let n = alphabet.count
        let shown = Array(targets.prefix(n * n))
        return shown.enumerated().map { i, target in
            var t = target
            t.label = shown.count <= n ? String(alphabet[i]) : String([alphabet[i / n], alphabet[i % n]])
            return t
        }
    }
}
