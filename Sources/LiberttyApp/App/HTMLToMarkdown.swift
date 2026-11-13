import Foundation

/// Rich text pasted into the composer (a page copied in a browser, a
/// message from a chat app) as Markdown, which coding agents read best:
/// headings, emphasis, code, links, lists, quotes, tables and images
/// (Otty's Composer does the same). What isn't one of those is its text.
enum HTMLToMarkdown {
    /// Whether there's anything Markdown would say that the plain text
    /// doesn't: links, headings, lists, tables, emphasis, code. Code copied
    /// from an editor comes as styled <div>s and <span>s, whose plain text
    /// (with its indentation) is what to paste.
    static func hasStructure(_ html: String) -> Bool {
        html.range(of: #"<(a|h[1-6]|li|table|img|strong|b|em|i|blockquote|pre|code|del|s)[\s>/]"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func convert(_ html: String) -> String {
        guard let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
              let root = doc.rootElement() else { return plain(html) }
        let body = (try? root.nodes(forXPath: "//body").first) ?? root
        var out = Writer()
        out.children(of: body)
        return out.finished()
    }

    /// Tags stripped, for HTML that won't parse.
    private static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Writer {
        private var text = ""
        /// Lists open around what's written, innermost last: ordered ones count.
        private var lists: [(ordered: Bool, count: Int)] = []
        private var quoteDepth = 0
        private var inPre = false

        mutating func finished() -> String {
            // Runs of blank lines down to one, none at the ends, no space after a line.
            var kept: [String] = []
            for raw in text.components(separatedBy: "\n") {
                var line = raw
                while line.last == " " { line.removeLast() }
                let blank = line.isEmpty || line.allSatisfy { $0 == ">" || $0 == " " }
                if blank, kept.last?.isEmpty ?? true { continue }
                kept.append(blank ? "" : line)
            }
            while kept.last?.isEmpty == true { kept.removeLast() }
            return kept.joined(separator: "\n")
        }

        private var linePrefix: String { String(repeating: "> ", count: quoteDepth) }

        private mutating func newline() { text += "\n" + linePrefix }

        /// A block starts on a fresh line, a blank one before it.
        private mutating func block() {
            if text.isEmpty { text = linePrefix; return }
            let trimmed = text.replacingOccurrences(of: "[ >]+$", with: "", options: .regularExpression)
            if trimmed.hasSuffix("\n") || trimmed.isEmpty { text = trimmed + linePrefix; return }
            text = trimmed + "\n\n" + linePrefix
        }

        private mutating func write(_ s: String) { text += s }

        mutating func children(of node: XMLNode) {
            for child in node.children ?? [] { visit(child) }
        }

        private func inline(_ node: XMLNode) -> String {
            var w = Writer()
            w.inPre = inPre
            w.children(of: node)
            return w.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }

        mutating func visit(_ node: XMLNode) {
            switch node.kind {
            case .text:
                let s = node.stringValue ?? ""
                if inPre { write(s); return }
                // Whitespace in HTML is one space.
                let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if collapsed == " ", text.hasSuffix(" ") || text.hasSuffix("\n") || text.isEmpty { return }
                write(collapsed)
            case .element:
                element(node as! XMLElement)
            default:
                break
            }
        }

        private mutating func element(_ e: XMLElement) {
            let name = (e.name ?? "").lowercased()
            switch name {
            case "script", "style", "head", "meta", "title", "noscript": return
            case "h1", "h2", "h3", "h4", "h5", "h6":
                block()
                write(String(repeating: "#", count: Int(String(name.dropFirst())) ?? 1) + " " + inline(e))
                block()
            case "p", "div", "section", "article", "header", "footer", "figure":
                block()
                children(of: e)
                block()
            case "br":
                if inPre { write("\n") } else { newline() }
            case "hr":
                block()
                write("---")
                block()
            case "strong", "b":
                let s = inline(e)
                if !s.isEmpty { write("**\(s)**") }
            case "em", "i":
                let s = inline(e)
                if !s.isEmpty { write("*\(s)*") }
            case "del", "s", "strike":
                let s = inline(e)
                if !s.isEmpty { write("~~\(s)~~") }
            case "code":
                if inPre { children(of: e); return }
                let s = e.stringValue ?? ""
                let fence = s.contains("`") ? "``" : "`"
                write(fence + s + fence)
            case "pre":
                block()
                let language = ((e.elements(forName: "code").first?.attribute(forName: "class")?.stringValue ?? "")
                    .split(separator: " ").first { $0.hasPrefix("language-") }).map { String($0.dropFirst(9)) } ?? ""
                write("```" + language)
                newline()
                let body = (e.stringValue ?? "").trimmingCharacters(in: .newlines)
                write(body.replacingOccurrences(of: "\n", with: "\n" + linePrefix))
                newline()
                write("```")
                block()
            case "a":
                let label = inline(e)
                let href = e.attribute(forName: "href")?.stringValue ?? ""
                if href.isEmpty || href.hasPrefix("javascript:") || label == href { write(label.isEmpty ? href : label) } else {
                    write("[\(label.isEmpty ? href : label)](\(href))")
                }
            case "img":
                let src = e.attribute(forName: "src")?.stringValue ?? ""
                guard !src.isEmpty, !src.hasPrefix("data:") else { return }
                write("![\(e.attribute(forName: "alt")?.stringValue ?? "")](\(src))")
            case "ul", "ol":
                if lists.isEmpty { block() } else { newline() }
                lists.append((name == "ol", 0))
                for child in e.children ?? [] { visit(child) }
                lists.removeLast()
                if lists.isEmpty { block() }
            case "li":
                guard !lists.isEmpty else { children(of: e); return }
                if !(text.hasSuffix("\n" + linePrefix) || text.isEmpty || text == linePrefix) { newline() }
                let indent = String(repeating: "  ", count: lists.count - 1)
                lists[lists.count - 1].count += 1
                let marker = lists[lists.count - 1].ordered ? "\(lists[lists.count - 1].count). " : "- "
                write(indent + marker)
                children(of: e)
            case "blockquote":
                block()
                quoteDepth += 1
                text += "> "
                children(of: e)
                quoteDepth -= 1
                block()
            case "table":
                block()
                table(e)
                block()
            default:
                children(of: e)
            }
        }

        private mutating func table(_ e: XMLElement) {
            let rows = (try? e.nodes(forXPath: ".//tr")) as? [XMLElement] ?? []
            var cells: [[String]] = rows.map { row in
                (row.children ?? []).compactMap { $0 as? XMLElement }.filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                    .map { inline($0).replacingOccurrences(of: "|", with: "\\|") }
            }
            cells.removeAll { $0.isEmpty }
            guard let width = cells.map(\.count).max(), width > 0 else { return }
            cells = cells.map { $0 + Array(repeating: "", count: width - $0.count) }
            write("| " + cells[0].joined(separator: " | ") + " |")
            newline()
            write("|" + Array(repeating: " --- |", count: width).joined())
            for row in cells.dropFirst() {
                newline()
                write("| " + row.joined(separator: " | ") + " |")
            }
        }
    }
}
