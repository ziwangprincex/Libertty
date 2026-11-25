import Foundation

/// GitHub-flavored Markdown to HTML: everything READMEs and notes use —
/// headings (with GitHub's anchor ids), paragraphs, emphasis, strikethrough,
/// code spans and fenced code (highlighted), block quotes, nested and task
/// lists, tables, thematic breaks, links, images, reference definitions,
/// autolinks, and raw HTML (shown with page JavaScript disabled).
struct MarkdownRenderer {
    /// Highlighting for fenced code blocks; plain escaping when nil.
    var highlight: ((_ code: String, _ language: String) -> String)?
    /// A ```mermaid fence's HTML (the diagram, or what stands in for it);
    /// nil: it's code like any other.
    var diagram: ((_ source: String) -> String)?
    /// The ```mermaid fences' sources, in order, as rendered.
    private(set) var diagrams: [String] = []

    private var refs: [String: (url: String, title: String?)] = [:]
    private var slugs: [String: Int] = [:]

    init(highlight: ((String, String) -> String)? = nil) { self.highlight = highlight }

    mutating func render(_ source: String) -> String {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Self.expandTabs(String($0)) }
        lines = collectReferences(lines)
        return blocks(lines[...], tight: false)
    }

    // MARK: Blocks

    private static let fence = try! NSRegularExpression(pattern: #"^( {0,3})(`{3,}|~{3,})\s*([^`\s]*)[^`]*$"#)
    private static let atx = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    private static let hr = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let listItem = try! NSRegularExpression(pattern: #"^( {0,3})([-*+]|(\d{1,9})[.)])( +|$)(.*)$"#)
    private static let setext = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)[ \t]*$"#)
    private static let tableDelimiter = try! NSRegularExpression(
        pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
    private static let htmlBlock = try! NSRegularExpression(
        pattern: #"^ {0,3}(?:<!--|<\/?(?:address|article|aside|blockquote|center|details|dialog|div|dl|dt|dd|figure|figcaption|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|picture|pre|section|summary|table|tbody|td|tfoot|th|thead|tr|ul|img|a|br|video|source|kbd|sub|sup)(?:\s|\/?>|$))"#,
        options: .caseInsensitive)
    private static let reference = try! NSRegularExpression(
        pattern: #"^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s+["'(](.*)["')])?\s*$"#)

    private func match(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    private static func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var out = "", col = 0
        for c in s {
            if c == "\t" {
                let n = 4 - col % 4
                out += String(repeating: " ", count: n)
                col += n
            } else {
                out.append(c)
                col += 1
            }
        }
        return out
    }

    /// `[label]: url "title"` lines anywhere outside code fences.
    private mutating func collectReferences(_ lines: [String]) -> [String] {
        var out: [String] = []
        var inFence: String?
        for line in lines {
            if let m = match(Self.fence, line), let marker = m[2] {
                if let open = inFence {
                    if marker.first == open.first, marker.count >= open.count, (m[3] ?? "").isEmpty { inFence = nil }
                } else {
                    inFence = marker
                }
                out.append(line)
                continue
            }
            if inFence == nil, let m = match(Self.reference, line), let label = m[1], let url = m[2] {
                let key = label.lowercased()
                if refs[key] == nil { refs[key] = (url, m[3]) }
                continue
            }
            out.append(line)
        }
        return out
    }

    /// Whether `line` starts a block that interrupts a paragraph.
    private func interrupts(_ line: String) -> Bool {
        if match(Self.atx, line) != nil || match(Self.fence, line) != nil || match(Self.hr, line) != nil { return true }
        if line.drop(while: { $0 == " " }).hasPrefix(">"), Self.indent(line) < 4 { return true }
        if match(Self.htmlBlock, line) != nil { return true }
        if let m = match(Self.listItem, line), let content = m[5], !content.isEmpty {
            // Ordered lists interrupt a paragraph only when they start at 1.
            return m[3] == nil || m[3] == "1"
        }
        return false
    }

    private mutating func blocks(_ lines: ArraySlice<String>, tight: Bool) -> String {
        var out = ""
        var i = lines.startIndex
        let end = lines.endIndex
        while i < end {
            let line = lines[i]
            if Self.isBlank(line) { i += 1; continue }

            // Fenced code.
            if let m = match(Self.fence, line), let marker = m[2] {
                let indent = m[1]?.count ?? 0
                let language = (m[3] ?? "").lowercased()
                var body: [String] = []
                i += 1
                while i < end {
                    let l = lines[i]
                    if let c = match(Self.fence, l), let close = c[2], close.first == marker.first,
                       close.count >= marker.count, (c[3] ?? "").isEmpty {
                        i += 1
                        break
                    }
                    var s = Substring(l)
                    var n = indent
                    while n > 0, s.first == " " { s = s.dropFirst(); n -= 1 }
                    body.append(String(s))
                    i += 1
                }
                out += codeBlock(body.joined(separator: "\n"), language: language)
                continue
            }

            // ATX heading.
            if let m = match(Self.atx, line), let hashes = m[1] {
                out += heading(level: hashes.count, text: m[2] ?? "")
                i += 1
                continue
            }

            // Thematic break.
            if match(Self.hr, line) != nil {
                out += "<hr>\n"
                i += 1
                continue
            }

            // Block quote, with lazy continuation lines.
            if Self.indent(line) < 4, line.drop(while: { $0 == " " }).hasPrefix(">") {
                var body: [String] = []
                while i < end {
                    let l = lines[i]
                    let t = l.drop(while: { $0 == " " })
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        body.append(String(rest))
                    } else if !Self.isBlank(l), let last = body.last, !Self.isBlank(last), !interrupts(l) {
                        body.append(l)
                    } else {
                        break
                    }
                    i += 1
                }
                out += "<blockquote>\n" + blocks(body[...], tight: false) + "</blockquote>\n"
                continue
            }

            // HTML block, passed through to the next blank line.
            if match(Self.htmlBlock, line) != nil {
                var body: [String] = []
                while i < end, !Self.isBlank(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                out += body.joined(separator: "\n") + "\n"
                continue
            }

            // List.
            if let m = match(Self.listItem, line) {
                let (html, next) = list(lines, from: i, first: m)
                out += html
                i = next
                continue
            }

            // Indented code.
            if Self.indent(line) >= 4 {
                var body: [String] = []
                while i < end, Self.isBlank(lines[i]) || Self.indent(lines[i]) >= 4 {
                    body.append(String(lines[i].dropFirst(min(4, Self.indent(lines[i])))))
                    i += 1
                }
                while body.last.map(Self.isBlank) == true { body.removeLast() }
                out += codeBlock(body.joined(separator: "\n"), language: "")
                continue
            }

            // Table: a header row, then a delimiter row.
            if line.contains("|"), i + 1 < end, match(Self.tableDelimiter, lines[i + 1]) != nil,
               lines[i + 1].contains("-") {
                let header = Self.cells(line)
                let aligns = Self.cells(lines[i + 1]).map { cell -> String in
                    let c = cell.trimmingCharacters(in: .whitespaces)
                    switch (c.hasPrefix(":"), c.hasSuffix(":")) {
                    case (true, true): return " style=\"text-align:center\""
                    case (false, true): return " style=\"text-align:right\""
                    case (true, false): return " style=\"text-align:left\""
                    default: return ""
                    }
                }
                if header.count == aligns.count {
                    i += 2
                    var html = "<div class=\"table\"><table>\n<thead><tr>"
                    for (c, a) in zip(header, aligns) { html += "<th\(a)>\(inline(c))</th>" }
                    html += "</tr></thead>\n<tbody>\n"
                    while i < end, !Self.isBlank(lines[i]), lines[i].contains("|") || !interrupts(lines[i]) {
                        let row = Self.cells(lines[i])
                        html += "<tr>"
                        for (n, a) in aligns.enumerated() { html += "<td\(a)>\(n < row.count ? inline(row[n]) : "")</td>" }
                        html += "</tr>\n"
                        i += 1
                    }
                    out += html + "</tbody></table></div>\n"
                    continue
                }
            }

            // Paragraph, possibly a setext heading.
            var para: [String] = []
            while i < end {
                let l = lines[i]
                if Self.isBlank(l) { break }
                if !para.isEmpty, let m = match(Self.setext, l), let underline = m[1] {
                    out += heading(level: underline.hasPrefix("=") ? 1 : 2,
                                   text: para.joined(separator: "\n").trimmingCharacters(in: .whitespaces))
                    para.removeAll()
                    i += 1
                    break
                }
                if !para.isEmpty, interrupts(l) { break }
                para.append(l)
                i += 1
            }
            if !para.isEmpty {
                // Leading spaces go; trailing ones stay until inline() reads
                // a two-space hard break from them.
                var joined = para.map { String($0.drop(while: { $0 == " " })) }.joined(separator: "\n")
                while joined.hasSuffix(" ") { joined.removeLast() }
                let text = inline(joined)
                out += tight ? text + "\n" : "<p>\(text)</p>\n"
            }
        }
        return out
    }

    /// One list starting at `start`: its items (each rendered as blocks), and
    /// the index after it. Tight lists (no blank lines between items) keep
    /// their paragraphs unwrapped, as on GitHub.
    private mutating func list(_ lines: ArraySlice<String>, from start: Int, first: [String?]) -> (String, Int) {
        let ordered = first[3] != nil
        let delimiter = first[2]!.last!
        let startNumber = first[3].flatMap { Int($0) } ?? 1
        var items: [[String]] = []
        var loose = false
        var i = start
        let end = lines.endIndex
        var sawBlank = false

        while i < end, let m = match(Self.listItem, lines[i]),
              (m[3] != nil) == ordered, m[2]!.last! == delimiter || !ordered && m[2] == first[2] {
            if sawBlank { loose = true }
            let markerWidth = (m[1]?.count ?? 0) + m[2]!.count
            let spaces = m[4]?.count ?? 0
            // Content indent; more than four spaces after the marker means indented code.
            let contentIndent = markerWidth + (spaces == 0 || spaces > 4 ? 1 : spaces)
            var body = [spaces > 4 ? String(repeating: " ", count: spaces - 1) + (m[5] ?? "") : (m[5] ?? "")]
            i += 1
            sawBlank = false
            while i < end {
                let l = lines[i]
                if Self.isBlank(l) {
                    sawBlank = true
                    body.append("")
                    i += 1
                    continue
                }
                if Self.indent(l) >= contentIndent {
                    if sawBlank, body.count > 1 { loose = loose || !body.dropLast().allSatisfy { !Self.isBlank($0) } }
                    body.append(String(l.dropFirst(contentIndent)))
                    sawBlank = false
                    i += 1
                    continue
                }
                // A lazy continuation of the item's last paragraph.
                if !sawBlank, !interrupts(l), match(Self.listItem, l) == nil {
                    body.append(l.trimmingCharacters(in: .init(charactersIn: " ")))
                    i += 1
                    continue
                }
                break
            }
            // Blank lines inside an item (between its blocks) make the list loose.
            let inner = body.reversed().drop(while: Self.isBlank).reversed()
            if inner.contains(where: Self.isBlank) { loose = true }
            items.append(Array(inner))
            if sawBlank {
                // A blank line ends the list unless another item follows.
                var j = i
                while j < end, Self.isBlank(lines[j]) { j += 1 }
                if j < end, match(Self.listItem, lines[j]) != nil { i = j } else { break }
            }
        }

        let tag = ordered ? "ol" : "ul"
        // A list of only tasks drops its bullets; mixed lists keep them for the rest.
        let allTasks = items.allSatisfy { Self.taskState($0.first ?? "") != nil }
        var html = ordered && startNumber != 1 ? "<ol start=\"\(startNumber)\">\n" : "<\(tag)\(allTasks ? " class=\"tasks\"" : "")>\n"
        for var item in items {
            if let done = Self.taskState(item.first ?? "") {
                item[0] = String(item[0].dropFirst(3)).trimmingCharacters(in: .init(charactersIn: " "))
                html += "<li class=\"task\"><input type=\"checkbox\" disabled\(done ? " checked" : "")> "
            } else {
                html += "<li>"
            }
            html += blocks(item[...], tight: !loose) + "</li>\n"
        }
        return (html + "</\(tag)>\n", i)
    }

    private static func taskState(_ s: String) -> Bool? {
        if s.hasPrefix("[ ] ") || s == "[ ]" { return false }
        if s.hasPrefix("[x] ") || s.hasPrefix("[X] ") || s == "[x]" { return true }
        return nil
    }

    private static func cells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = [], cell = "", escaped = false, inCode = false
        for c in s {
            if escaped { cell.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; cell.append(c); continue }
            if c == "`" { inCode.toggle() }
            if c == "|", !inCode { cells.append(cell); cell = ""; continue }
            cell.append(c)
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }

    private mutating func heading(level: Int, text: String) -> String {
        let html = inline(text)
        let id = slug(text)
        return "<h\(level) id=\"\(id)\"><a class=\"anchor\" href=\"#\(id)\" aria-hidden=\"true\"></a>\(html)</h\(level)>\n"
    }

    /// GitHub's heading anchors: lowercase, punctuation dropped, spaces to
    /// hyphens, repeats numbered.
    private mutating func slug(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: #"`|\*|_{2}|\[|\]\([^)]*\)"#, with: "", options: .regularExpression)
        var s = ""
        for c in plain.lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { s.append(c) } else if c == " " { s.append("-") }
        }
        // Numbered past any id already given ("Example", "Example",
        // "Example 1": example, example-1, example-1-1), as GitHub does.
        var candidate = s
        var n = slugs[s, default: 0]
        if n > 0 { candidate = "\(s)-\(n)" }
        while n > 0, slugs[candidate] != nil {
            n += 1
            candidate = "\(s)-\(n)"
        }
        slugs[s, default: 0] += 1
        if candidate != s { slugs[candidate, default: 0] += 1 }
        return candidate
    }

    private mutating func codeBlock(_ code: String, language: String) -> String {
        if language == "mermaid", let diagram {
            diagrams.append(code)
            return diagram(code)
        }
        let body = highlight?(code, language) ?? Self.escape(code)
        let label = language.isEmpty ? "" : "<div class=\"code-head\"><span>\(Self.escape(language))</span></div>"
        return "<div class=\"code\">\(label)<pre><code\(language.isEmpty ? "" : " class=\"language-\(Self.escape(language))\"")>\(body)</code></pre></div>\n"
    }

    // MARK: Inline

    /// Inline text to HTML. Code spans, links, images, autolinks, HTML tags
    /// and escapes become opaque placeholders first, so emphasis is found
    /// across them but never inside them.
    private func inline(_ text: String) -> String {
        var pieces: [String] = []
        var out = ""
        // A placeholder is two private-use scalars, one from plane 15 and
        // one from plane 16: room for billions of pieces in a paragraph (one
        // scalar ran out at 131,072, a 262 KB paragraph of `\.`). The text's
        // own characters from those planes go in as references, so none is
        // ever read back as one.
        func token(_ html: String) {
            let n = pieces.count
            guard n < 1 << 32, let high = Unicode.Scalar(UInt32(0xF0000 + (n >> 16))),
                  let low = Unicode.Scalar(UInt32(0x100000 + (n & 0xFFFF))) else { return out += html }
            out.unicodeScalars.append(high)
            out.unicodeScalars.append(low)
            pieces.append(html)
        }
        let chars = Array(text)
        // The next ">", "<" and line end after a point, each looked for once
        // however many "<" ask (they ask in order); each "[" its "]" (see
        // link); the backtick runs. A paragraph of thousands of any of them
        // isn't read to its end from each one.
        var nextClose = -1, nextOpen = -1, nextLine = -1
        func next(_ c: Character, after i: Int, _ found: inout Int) -> Int {
            if found <= i { found = chars[(i + 1)...].firstIndex(of: c) ?? chars.count }
            return found
        }
        var brackets: [Int: Int] = [:]
        let ticks = Backticks(chars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\" where i + 1 < chars.count:
                let next = chars[i + 1]
                if next == "\n" {
                    token("<br>\n")
                    i += 2
                    continue
                }
                if next.isASCII, next.isPunctuation || next.isSymbol {
                    token(Self.escape(String(next)))
                    i += 2
                    continue
                }
            case "`":
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let close = ticks.first(run, from: i + run) {
                    var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    token("<code>\(Self.escape(code))</code>")
                    i = close + run
                    continue
                }
                out += String(repeating: "`", count: run)
                i += run
                continue
            case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                if let (html, next) = link(chars, at: i + 1, image: true, brackets: &brackets, ticks: ticks) {
                    token(html)
                    i = next
                    continue
                }
            case "[":
                if let (html, next) = link(chars, at: i, image: false, brackets: &brackets, ticks: ticks) {
                    token(html)
                    i = next
                    continue
                }
            case "<":
                // An autolink or a tag has no "<" inside, and a comment no
                // line break and "--" at its end: anything else isn't one,
                // and isn't read through to see.
                let close = next(">", after: i, &nextClose)
                let comment = chars[(i + 1)...].starts(with: "!--")
                if close < chars.count, comment ? next("\n", after: i, &nextLine) > close && chars[close - 1] == "-" && chars[close - 2] == "-"
                    : next("<", after: i, &nextOpen) > close {
                    let inner = String(chars[(i + 1)..<close])
                    if inner.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]{1,31}:[^\s<>]*$"#, options: .regularExpression) != nil {
                        token("<a href=\"\(Self.escapeAttribute(inner))\">\(Self.escape(inner))</a>")
                        i = close + 1
                        continue
                    }
                    if inner.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil {
                        token("<a href=\"mailto:\(Self.escapeAttribute(inner))\">\(Self.escape(inner))</a>")
                        i = close + 1
                        continue
                    }
                    if inner.range(of: #"^(/?[a-zA-Z][a-zA-Z0-9-]*(\s[^<>]*)?/?|!--.*--)$"#, options: .regularExpression) != nil {
                        token("<\(inner)>")
                        i = close + 1
                        continue
                    }
                }
            case "&":
                if let semi = chars[i...].prefix(12).firstIndex(of: ";") {
                    let entity = String(chars[i...semi])
                    if entity.range(of: #"^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});$"#,
                                    options: .regularExpression) != nil {
                        token(entity)
                        i = semi + 1
                        continue
                    }
                }
            case "\n":
                // Two trailing spaces make a hard break.
                if out.hasSuffix("  ") {
                    while out.hasSuffix(" ") { out.removeLast() }
                    token("<br>\n")
                } else {
                    out.append("\n")
                }
                i += 1
                continue
            case "h", "w":
                // GFM extended autolinks: http(s)://… and www.…
                let atBoundary = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
                // (Not 2 KB copied for each word that starts with h or w.)
                let start = chars[i...].prefix(4)
                if atBoundary, start.elementsEqual("http") || start.elementsEqual("www."), let (url, length) = Self.bareURL(chars, at: i) {
                    let href = url.hasPrefix("www.") ? "http://" + url : url
                    token("<a href=\"\(Self.escapeAttribute(href))\">\(Self.escape(url))</a>")
                    i += length
                    continue
                }
            default:
                break
            }
            if c.unicodeScalars.contains(where: { $0.value >= 0xF0000 }) {
                out += c.unicodeScalars.map { $0.value >= 0xF0000 ? "&#x\(String($0.value, radix: 16, uppercase: true));" : Self.escape(String($0)) }.joined()
            } else {
                out += Self.escape(String(c))
            }
            i += 1
        }

        out = Self.emphasis(out)
        // Put the opaque pieces back.
        var result = ""
        let scalars = Array(out.unicodeScalars)
        var k = 0
        while k < scalars.count {
            let high = scalars[k].value
            if (0xF0000...0xFFFFF).contains(high), k + 1 < scalars.count, scalars[k + 1].value >= 0x100000 {
                let n = Int(high - 0xF0000) << 16 | Int(scalars[k + 1].value - 0x100000)
                if n < pieces.count {
                    result += pieces[n]
                    k += 2
                    continue
                }
            }
            result.unicodeScalars.append(scalars[k])
            k += 1
        }
        return result
    }

    /// A paragraph's runs of backticks, by length: where each starts, in
    /// order. Found in one read, so a closing run is looked up rather than
    /// read for from each opening one.
    private struct Backticks {
        private var starts: [Int: [Int]] = [:]

        init(_ chars: [Character]) {
            var i = 0
            while i < chars.count {
                guard chars[i] == "`" else { i += 1; continue }
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                starts[run, default: []].append(i)
                i += run
            }
        }

        /// The first run of exactly `count` backticks at `start` or after
        /// (`start` not inside a run).
        func first(_ count: Int, from start: Int) -> Int? {
            guard let list = starts[count] else { return nil }
            var low = 0, high = list.count
            while low < high {
                let mid = (low + high) / 2
                if list[mid] < start { low = mid + 1 } else { high = mid }
            }
            return low < list.count ? list[low] : nil
        }
    }

    /// `[text](url "title")`, `[text][ref]`, `[ref]`, and images. Returns the
    /// HTML and the index after the link, or nil when it isn't one.
    /// `brackets`: each "[" read so far and its "]" (-1: none before the
    /// end). A read from one "[" passes over every "[" inside it as a read
    /// from that one would, so it answers for them too, and comes to each
    /// one answered already at its "]" without reading the way again.
    private func link(_ chars: [Character], at open: Int, image: Bool, brackets: inout [Int: Int], ticks: Backticks) -> (String, Int)? {
        if brackets[open] == nil {
            var opened: [Int] = [], i = open
            read: while i < chars.count {
                let c = chars[i]
                if c == "\\" { i += 2; continue }
                if c == "`" {
                    // Past the code span a backtick may start, as reading one
                    // backtick at a time came to: two together are an empty
                    // one; otherwise just past the next lone backtick after
                    // the run, or past the run when there's none.
                    var end = i
                    while end < chars.count, chars[end] == "`" { end += 1 }
                    i = end - i == 2 ? end : ticks.first(1, from: end).map { $0 + 1 } ?? end
                    continue
                }
                if c == "[" {
                    if let known = brackets[i] {
                        // None closes it: nor any "[" before it.
                        if known < 0 { break read }
                        i = known + 1
                        continue
                    }
                    opened.append(i)
                }
                if c == "]", let at = opened.popLast() {
                    brackets[at] = i
                    if opened.isEmpty { break }
                }
                i += 1
            }
            for at in opened { brackets[at] = -1 }
        }
        guard let close = brackets[open], close >= 0 else { return nil }
        let label = String(chars[(open + 1)..<close])
        var url: String?, title: String?, next = close + 1

        if next < chars.count, chars[next] == "(" {
            // Inline destination, allowing balanced parentheses in the URL.
            var j = next + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
            var dest = ""
            if j < chars.count, chars[j] == "<" {
                j += 1
                while j < chars.count, chars[j] != ">" { dest.append(chars[j]); j += 1 }
                j += 1
            } else {
                var parens = 0
                while j < chars.count {
                    let c = chars[j]
                    if c == " " || c == "\n" { break }
                    if c == "(" { parens += 1 }
                    if c == ")" { if parens == 0 { break }; parens -= 1 }
                    dest.append(c)
                    j += 1
                }
            }
            while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
            if j < chars.count, let quote = ["\"": "\"", "'": "'", "(": ")"][String(chars[j])] {
                var t = ""
                j += 1
                while j < chars.count, String(chars[j]) != quote { t.append(chars[j]); j += 1 }
                j += 1
                title = t
                while j < chars.count, chars[j] == " " { j += 1 }
            }
            guard j < chars.count, chars[j] == ")" else { return nil }
            url = dest
            next = j + 1
        } else {
            // Reference: [text][ref], [text][], or [text].
            var key = label
            if next < chars.count, chars[next] == "[", let end = chars[next...].firstIndex(of: "]") {
                let ref = String(chars[(next + 1)..<end])
                if !ref.isEmpty { key = ref }
                next = end + 1
            }
            guard let def = refs[key.lowercased()] else { return nil }
            url = def.url
            title = def.title
        }
        guard let url else { return nil }
        let titleAttr = title.map { " title=\"\(Self.escapeAttribute($0))\"" } ?? ""
        if image {
            return ("<img src=\"\(Self.escapeAttribute(url))\" alt=\"\(Self.escapeAttribute(Self.plain(label)))\"\(titleAttr)>", next)
        }
        return ("<a href=\"\(Self.escapeAttribute(url))\"\(titleAttr)>\(inline(label))</a>", next)
    }

    private static func bareURL(_ chars: [Character], at i: Int) -> (String, Int)? {
        let rest = String(chars[i..<min(chars.count, i + 2048)])
        guard let r = rest.range(of: #"^(https?://|www\.)[^\s<]+"#, options: .regularExpression) else { return nil }
        var url = String(rest[r])
        // Trailing punctuation belongs to the sentence; so does an unbalanced ")".
        while let last = url.last, "?!.,:*_~'\"".contains(last) { url.removeLast() }
        while url.hasSuffix(")"), url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count { url.removeLast() }
        guard url.count > (url.hasPrefix("www.") ? 4 : 8) else { return nil }
        return (url, url.count)
    }

    /// One kind of emphasis: `marker` opens a run whose first character
    /// isn't a space, and the first `marker` after it, on the same line,
    /// whose character before isn't one closes it — what the expression
    /// `marker(?=\S)(.+?)(?<=\S)marker` matches. `single` (`*`, `_`): nor is
    /// either of those characters the marker. `word` (`__`, `_`): no letter
    /// or number just outside (`_` neither, for `_`).
    private struct Emphasis {
        let marker: [Unicode.Scalar], open: String, close: String
        var single = false, word = false

        /// Every run in `s`, left to right, each read once: each opening
        /// asks for the first closing after it, and those (and the line
        /// ends) are found in order, so a line of thousands of unclosed
        /// markers isn't read to its end from each one.
        func apply(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
            let m = marker.count, n = s.count
            func at(_ p: Int) -> Bool { p + m <= n && (0..<m).allSatisfy { s[p + $0] == marker[$0] } }
            func inside(_ u: Unicode.Scalar) -> Bool { !MarkdownRenderer.isSpace(u) && !(single && u == marker[0]) }
            func outside(_ p: Int) -> Bool {
                guard word, p >= 0, p < n else { return true }
                return !(MarkdownRenderer.isWordy(s[p]) || single && s[p] == marker[0])
            }
            var closing = -1, lineEnd = -1
            func firstClosing(from p: Int) -> Int {
                if closing < p {
                    closing = p
                    while closing < n, !(at(closing) && inside(s[closing - 1]) && outside(closing + m)) { closing += 1 }
                }
                return closing
            }
            func firstLineEnd(from p: Int) -> Int {
                if lineEnd < p {
                    lineEnd = p
                    while lineEnd < n, !MarkdownRenderer.endsLine(s[lineEnd]) { lineEnd += 1 }
                }
                return lineEnd
            }
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(n)
            var i = 0
            while i < n {
                if at(i), i + m < n, inside(s[i + m]), outside(i - 1) {
                    let q = firstClosing(from: i + m + 1)
                    if q < n, firstLineEnd(from: i + m) >= q {
                        out += open.unicodeScalars
                        out += s[(i + m)..<q]
                        out += close.unicodeScalars
                        i = q + m
                        continue
                    }
                }
                out.append(s[i])
                i += 1
            }
            return out
        }
    }

    private static let emphasisRules: [Emphasis] = [
        Emphasis(marker: ["*", "*", "*"], open: "<strong><em>", close: "</em></strong>"),
        Emphasis(marker: ["*", "*"], open: "<strong>", close: "</strong>"),
        Emphasis(marker: ["_", "_"], open: "<strong>", close: "</strong>", word: true),
        Emphasis(marker: ["*"], open: "<em>", close: "</em>", single: true),
        Emphasis(marker: ["_"], open: "<em>", close: "</em>", single: true, word: true),
        Emphasis(marker: ["~", "~"], open: "<del>", close: "</del>"),
    ]

    static func emphasis(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        for rule in emphasisRules { scalars = rule.apply(scalars) }
        var out = ""
        out.unicodeScalars.append(contentsOf: scalars)
        return out
    }

    /// `\s` as the expressions had it: tab, line feed, form feed, return, and Unicode's spaces.
    fileprivate static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return [0x09, 0x0A, 0x0C, 0x0D].contains(u.value)
        }
    }

    /// `[\p{L}\p{N}]`: a letter or a number.
    fileprivate static func isWordy(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// What `.` doesn't match: the line terminators.
    fileprivate static func endsLine(_ u: Unicode.Scalar) -> Bool {
        [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(u.value)
    }

    /// Alt text: the label without markup.
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"[*_`~\[\]]"#, with: "", options: .regularExpression)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(c)
            }
        }
        return out
    }

    static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
