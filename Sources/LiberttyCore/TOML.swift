/// TOML 1.0, as far as configuration files need it: tables and arrays of
/// tables, dotted and quoted keys, strings of all four kinds, integers,
/// floats, booleans, arrays and inline tables. Dates and times aren't read
/// (an error says so). For herdr's agent manifests (AgentScreen.user), on
/// the Mac and on Linux, without Foundation.
///
/// The result is plain values: String, Int, Double, Bool, [Any] and
/// [String: Any].
public enum TOML {
    public struct ParseError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    public static func parse(_ text: String) throws -> [String: Any] {
        var parser = Parser(Array(text.unicodeScalars))
        return try parser.document().plain
    }

    // While parsing: tables are objects, so a path into them can be followed
    // and filled in place.
    private final class Table {
        var entries: [String: Node] = [:]
        /// Made by a [header] (or a key path) already: another can't say it again.
        var defined = false
        /// Made implicitly, by a dotted key or as a header's parent.
        var implicit = false
        /// An inline table, closed for good.
        var frozen = false
        var plain: [String: Any] { entries.mapValues(\.plain) }
    }

    private indirect enum Node {
        case value(Any)
        case table(Table)
        case array([Node])
        /// Made by [[headers]]: tables can be added to it.
        case tables([Table])

        var plain: Any {
            switch self {
            case .value(let v): v
            case .table(let t): t.plain
            case .array(let a): a.map(\.plain)
            case .tables(let ts): ts.map(\.plain)
            }
        }
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1

        init(_ s: [Unicode.Scalar]) { self.s = s }

        func fail(_ message: String) -> ParseError { ParseError(line: line, message: message) }

        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        func peek(_ k: Int) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }

        mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        mutating func skipComment() {
            guard peek == "#" else { return }
            while let c = peek, c != "\n" { advance() }
        }

        /// Spaces, then a comment, then the line's end (or the file's).
        mutating func endOfLine() throws {
            skipSpaces()
            skipComment()
            if atEnd { return }
            if peek == "\r", peek(1) == "\n" { advance() }
            guard peek == "\n" else { throw fail("expected the end of the line") }
            advance()
        }

        /// Blank lines, comments and the space between values in an array.
        mutating func skipBlank() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() } else if c == "#" { skipComment() } else { break }
            }
        }

        // MARK: The document

        mutating func document() throws -> Table {
            let root = Table()
            var current = root
            while true {
                skipBlank()
                guard let c = peek else { break }
                if c == "[" {
                    let array = peek(1) == "["
                    advance()
                    if array { advance() }
                    skipSpaces()
                    let path = try key()
                    skipSpaces()
                    guard peek == "]" else { throw fail("expected ]") }
                    advance()
                    if array {
                        guard peek == "]" else { throw fail("expected ]]") }
                        advance()
                    }
                    try endOfLine()
                    current = array ? try appendTable(root, path) : try defineTable(root, path)
                } else {
                    try keyValue(into: current)
                    try endOfLine()
                }
            }
            return root
        }

        /// The table a dotted path leads to, made (implicitly) where missing;
        /// through an array of tables, its last.
        func descend(_ table: Table, _ path: ArraySlice<String>) throws -> Table {
            var t = table
            for k in path {
                switch t.entries[k] {
                case nil:
                    let next = Table()
                    next.implicit = true
                    t.entries[k] = .table(next)
                    t = next
                case .table(let next)?:
                    if next.frozen { throw fail("\(k) is an inline table: it can't be added to") }
                    t = next
                case .tables(let list)?:
                    t = list[list.count - 1]
                default:
                    throw fail("\(k) is already a value, not a table")
                }
            }
            return t
        }

        func defineTable(_ root: Table, _ path: [String]) throws -> Table {
            let parent = try descend(root, path.dropLast())
            let k = path[path.count - 1]
            switch parent.entries[k] {
            case nil:
                let t = Table()
                t.defined = true
                parent.entries[k] = .table(t)
                return t
            case .table(let t)?:
                guard !t.defined, !t.frozen else { throw fail("[\(path.joined(separator: "."))] is defined twice") }
                t.defined = true
                t.implicit = false
                return t
            default:
                throw fail("\(k) is already a value, not a table")
            }
        }

        func appendTable(_ root: Table, _ path: [String]) throws -> Table {
            let parent = try descend(root, path.dropLast())
            let k = path[path.count - 1]
            let t = Table()
            t.defined = true
            switch parent.entries[k] {
            case nil: parent.entries[k] = .tables([t])
            case .tables(let list)?: parent.entries[k] = .tables(list + [t])
            default: throw fail("\(k) is already a value, not an array of tables")
            }
            return t
        }

        mutating func keyValue(into table: Table) throws {
            let path = try key()
            skipSpaces()
            guard peek == "=" else { throw fail("expected = after the key") }
            advance()
            skipSpaces()
            let v = try value()
            let parent = try descend(table, path.dropLast())
            let k = path[path.count - 1]
            guard parent.entries[k] == nil else { throw fail("\(path.joined(separator: ".")) is set twice") }
            parent.entries[k] = v
        }

        // MARK: Keys

        /// A dotted key: bare or quoted parts.
        mutating func key() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let c = peek else { throw fail("expected a key") }
                if c == "\"" {
                    advance()
                    parts.append(try basicString())
                } else if c == "'" {
                    advance()
                    parts.append(try literalString())
                } else {
                    var k = String.UnicodeScalarView()
                    while let c = peek, Self.isBare(c) {
                        k.append(c)
                        advance()
                    }
                    guard !k.isEmpty else { throw fail("expected a key") }
                    parts.append(String(k))
                }
                skipSpaces()
                guard peek == "." else { return parts }
                advance()
            }
        }

        static func isBare(_ c: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
        }

        // MARK: Values

        mutating func value() throws -> Node {
            guard let c = peek else { throw fail("expected a value") }
            switch c {
            case "\"":
                if peek(1) == "\"", peek(2) == "\"" {
                    i += 3
                    return .value(try multilineBasicString())
                }
                advance()
                return .value(try basicString())
            case "'":
                if peek(1) == "'", peek(2) == "'" {
                    i += 3
                    return .value(try multilineLiteralString())
                }
                advance()
                return .value(try literalString())
            case "[":
                advance()
                return try array()
            case "{":
                advance()
                return try inlineTable()
            case "t", "f":
                if match("true") { return .value(true) }
                if match("false") { return .value(false) }
                throw fail("expected a value")
            default:
                return .value(try number())
            }
        }

        mutating func match(_ word: String) -> Bool {
            let w = Array(word.unicodeScalars)
            guard i + w.count <= s.count, Array(s[i..<(i + w.count)]) == w else { return false }
            if let next = peek(w.count), Self.isBare(next) { return false }
            i += w.count
            return true
        }

        mutating func array() throws -> Node {
            var items: [Node] = []
            while true {
                skipBlank()
                if peek == "]" {
                    advance()
                    return .array(items)
                }
                items.append(try value())
                skipBlank()
                if peek == "," {
                    advance()
                } else if peek == "]" {
                    advance()
                    return .array(items)
                } else {
                    throw fail("expected , or ] in an array")
                }
            }
        }

        mutating func inlineTable() throws -> Node {
            let t = Table()
            skipSpaces()
            if peek == "}" {
                advance()
                t.frozen = true
                return .table(t)
            }
            while true {
                try keyValue(into: t)
                skipSpaces()
                if peek == "," {
                    advance()
                } else if peek == "}" {
                    advance()
                    t.frozen = true
                    return .table(t)
                } else {
                    throw fail("expected , or } in an inline table")
                }
            }
        }

        // MARK: Strings

        mutating func basicString() throws -> String {
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek, c != "\n" else { throw fail("a string without its closing \"") }
                advance()
                if c == "\"" { return String(out) }
                if c == "\\" { out.append(try escape()) } else { out.append(c) }
            }
        }

        mutating func multilineBasicString() throws -> String {
            var out = String.UnicodeScalarView()
            // A newline right after the opening quotes isn't part of it.
            if peek == "\r", peek(1) == "\n" { advance() }
            if peek == "\n" { advance() }
            while true {
                guard let c = peek else { throw fail("a string without its closing \"\"\"") }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    // """" or """"": the quotes before the last three are the string's.
                    var q = 0
                    while peek(q) == "\"" { q += 1 }
                    for _ in 0..<min(2, q - 3) { out.append("\"") }
                    i += q
                    return String(out)
                }
                advance()
                if c == "\\" {
                    // A backslash at the end of a line trims the line break and the space after it.
                    var j = i
                    while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                    if j < s.count, s[j] == "\n" || s[j] == "\r" {
                        while let w = peek, w == " " || w == "\t" || w == "\n" || w == "\r" { advance() }
                    } else {
                        out.append(try escape())
                    }
                } else {
                    out.append(c)
                }
            }
        }

        mutating func literalString() throws -> String {
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek, c != "\n" else { throw fail("a string without its closing '") }
                advance()
                if c == "'" { return String(out) }
                out.append(c)
            }
        }

        mutating func multilineLiteralString() throws -> String {
            var out = String.UnicodeScalarView()
            if peek == "\r", peek(1) == "\n" { advance() }
            if peek == "\n" { advance() }
            while true {
                guard let c = peek else { throw fail("a string without its closing '''") }
                if c == "'", peek(1) == "'", peek(2) == "'" {
                    var q = 0
                    while peek(q) == "'" { q += 1 }
                    for _ in 0..<min(2, q - 3) { out.append("'") }
                    i += q
                    return String(out)
                }
                advance()
                out.append(c)
            }
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let c = peek else { throw fail("a string ending in \\") }
            advance()
            switch c {
            case "b": return "\u{8}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{c}"
            case "r": return "\r"
            case "e": return "\u{1b}"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U":
                let n = c == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<n {
                    guard let h = peek, h.properties.isASCIIHexDigit else { throw fail("\\\(c) wants \(n) hex digits") }
                    hex.unicodeScalars.append(h)
                    advance()
                }
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { throw fail("\\\(c)\(hex) isn't a character") }
                return scalar
            default:
                throw fail("\\\(c) isn't an escape")
            }
        }

        // MARK: Numbers

        mutating func number() throws -> Any {
            var text = String.UnicodeScalarView()
            while let c = peek, Self.isBare(c) || c == "+" || c == "." || c == ":" {
                text.append(c)
                advance()
            }
            let t = String(text)
            guard !t.isEmpty else { throw fail("expected a value") }
            if t.contains(":") || (t.count >= 10 && t.dropFirst(4).first == "-" && t.first?.isNumber == true) {
                throw fail("dates and times aren't read here: \(t)")
            }
            switch t {
            case "inf", "+inf": return Double.infinity
            case "-inf": return -Double.infinity
            case "nan", "+nan", "-nan": return Double.nan
            default: break
            }
            let digits = t.replacingUnderscores
            for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
                guard let v = Int(digits.dropFirst(2), radix: radix) else { throw fail("not a number: \(t)") }
                return v
            }
            if let v = Int(digits) { return v }
            if digits.contains(".") || digits.lowercased().contains("e"), let v = Double(digits) { return v }
            throw fail("not a value: \(t)")
        }
    }
}

private extension String {
    var replacingUnderscores: String { String(unicodeScalars.filter { $0 != "_" }) }
}
