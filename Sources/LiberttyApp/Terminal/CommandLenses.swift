import Foundation

/// Command lenses (after Tern's): what a finished command printed, read for
/// what it is — `git status`'s files, a compiler's errors and warnings,
/// `rg`'s matches — and offered as a list on its command line ("5 errors ·
/// Open as list"), the output itself left as it was. Which commands each
/// lens reads, and how, is here; the pane shows them (TerminalView+Surfaces).
enum CommandLenses {
    enum Kind: String, CaseIterable, Hashable {
        case gitStatus = "git-status", diagnostics, search
    }

    struct Item: Equatable {
        /// As printed (relative to the command's folder, usually).
        var path: String
        var line: Int?
        var column: Int?
        /// What it says: an error's message, a file's change, a match's line.
        var label: String
        /// Which list it's in: "Staged", "Errors", the file of a match.
        var group: String
        /// error, warning, note (diagnostics); modified, new file… (git).
        var tag = ""
    }

    struct Result: Equatable {
        var kind: Kind
        var command: String
        var items: [Item]
        /// "3 errors, 2 warnings", as the chip says it.
        var summary: String
    }

    static let maxItems = 2000

    // MARK: The setting (`command-lenses`)

    static func parseSetting(_ value: String) -> Set<Kind>? {
        switch value.lowercased() {
        case "true", "all": return Set(Kind.allCases)
        case "false", "none", "": return []
        default:
            var set = Set<Kind>()
            for part in value.split(separator: ",") {
                guard let kind = Kind(rawValue: part.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
                set.insert(kind)
            }
            return set
        }
    }

    static func settingValue(_ set: Set<Kind>) -> String {
        if set == Set(Kind.allCases) { return "true" }
        if set.isEmpty { return "false" }
        return Kind.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    // MARK: Which lens a command gets

    /// The command's words that say what ran: past `VAR=value`, `env`, `time`,
    /// `command`, `sudo` and the like.
    static func words(_ command: String) -> [String] {
        var words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let wrappers: Set<String> = ["env", "time", "command", "builtin", "nice", "nohup", "sudo", "noglob", "caffeinate"]
        while let first = words.first,
              first.contains("=") && !first.hasPrefix("-") || wrappers.contains((first as NSString).lastPathComponent) {
            words.removeFirst()
        }
        if let first = words.first { words[0] = (first as NSString).lastPathComponent }
        return words
    }

    static func kind(for command: String) -> Kind? {
        // (Through a pipe, what's printed is the last command's: none of these.)
        if command.contains("|") && !command.contains("||") { return nil }
        // `cd repo && git status`: the last command of a list is the one that
        // printed what's read (the others' lines just don't match).
        let last = command.components(separatedBy: "&&").last?.components(separatedBy: "||").last?
            .components(separatedBy: ";").last ?? command
        let w = words(last)
        guard let tool = w.first else { return nil }
        switch tool {
        case "git":
            // Past git's own options (-C DIR, -c KEY=VALUE take a value).
            var rest = w.dropFirst()
            while let word = rest.first, word.hasPrefix("-") {
                rest = rest.dropFirst()
                if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(word) { rest = rest.dropFirst() }
            }
            let sub = rest.first
            if sub == "status" { return .gitStatus }
            if sub == "grep" { return .search }
            return nil
        case "rg", "grep", "egrep", "ag", "ack", "ggrep": return .search
        case "swift", "swiftc", "cargo", "rustc", "tsc", "go", "make", "gmake", "ninja", "cmake", "clang", "clang++", "gcc", "g++",
             "cc", "c++", "xcodebuild", "mypy", "npm", "pnpm", "yarn", "bun", "npx", "deno", "zig", "javac", "kotlinc", "dotnet",
             "pyright", "ruff":
            return .diagnostics
        default: return nil
        }
    }

    /// The lens for a finished command, if it found anything to list.
    static func lens(command: String, output: String, enabled: Set<Kind>) -> Result? {
        guard let kind = kind(for: command), enabled.contains(kind), !output.isEmpty else { return nil }
        let last = command.components(separatedBy: "&&").last?.components(separatedBy: "||").last?
            .components(separatedBy: ";").last ?? command
        let w = words(last)
        let items: [Item]
        switch kind {
        case .gitStatus: items = gitStatus(output, short: w.contains { ["-s", "--short"].contains($0) || $0.hasPrefix("--porcelain") })
        case .diagnostics: items = diagnostics(output, go: w.first == "go")
        case .search: items = search(output)
        }
        guard !items.isEmpty else { return nil }
        return Result(kind: kind, command: command, items: Array(items.prefix(maxItems)), summary: summary(kind, items))
    }

    static func summary(_ kind: Kind, _ items: [Item]) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String {
            n == 1 ? L10n.t(one) : L10n.t(many).replacingOccurrences(of: "%d", with: String(n))
        }
        switch kind {
        case .gitStatus:
            return count(Set(items.map(\.path)).count, "1 file", "%d files")
        case .diagnostics:
            let errors = items.filter { $0.tag == "error" }.count, warnings = items.filter { $0.tag == "warning" }.count
            var parts: [String] = []
            if errors > 0 { parts.append(count(errors, "1 error", "%d errors")) }
            if warnings > 0 { parts.append(count(warnings, "1 warning", "%d warnings")) }
            if parts.isEmpty { parts.append(count(items.count, "1 note", "%d notes")) }
            return parts.joined(separator: L10n.t(", "))
        case .search:
            let files = Set(items.map(\.path)).count
            return count(items.count, "1 match", "%d matches") + " · " + count(files, "1 file", "%d files")
        }
    }

    // MARK: git status

    static func gitStatus(_ output: String, short: Bool) -> [Item] {
        var items: [Item] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if short {
            // XY path (or "XY orig -> path"): X the index, Y the worktree.
            for line in lines where line.count > 3 {
                let x = line[line.startIndex], y = line[line.index(after: line.startIndex)]
                guard line[line.index(line.startIndex, offsetBy: 2)] == " ", "MADRCUT?! ".contains(x), "MADRCUT?! ".contains(y) else { continue }
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                path = unquote(path)
                if x == "?" { items.append(Item(path: path, label: L10n.t("untracked"), group: L10n.t("Untracked"), tag: "untracked")); continue }
                if x == "!" { continue }
                if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                    items.append(Item(path: path, label: L10n.t("conflict"), group: L10n.t("Conflicts"), tag: "conflict"))
                    continue
                }
                if x != " " { items.append(Item(path: path, label: shortName(x), group: L10n.t("Staged"), tag: shortName(x))) }
                if y != " " { items.append(Item(path: path, label: shortName(y), group: L10n.t("Not Staged"), tag: shortName(y))) }
            }
            return items
        }
        var group: String?, tagGroup = ""
        let sections: [(String, String)] = [
            ("Changes to be committed:", "Staged"), ("Changes not staged for commit:", "Not Staged"),
            ("Untracked files:", "Untracked"), ("Unmerged paths:", "Conflicts"),
        ]
        let kinds = ["modified", "new file", "deleted", "renamed", "copied", "typechange", "both modified", "both added", "both deleted",
                     "added by us", "added by them", "deleted by us", "deleted by them"]
        for line in lines {
            if let section = sections.first(where: { line.hasPrefix($0.0) }) {
                group = L10n.t(section.1)
                tagGroup = section.1
                continue
            }
            guard let current = group else { continue }
            // A section's files are indented; its hints are in parentheses.
            guard line.first == " " || line.first == "\t" else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { group = nil }
                continue
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("(") else { continue }
            var tag = tagGroup == "Untracked" ? "untracked" : "modified"
            var path = text
            if let kind = kinds.first(where: { text.hasPrefix($0 + ":") }) {
                tag = kind
                path = String(text.dropFirst(kind.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            // "modified:   a.txt (new commits)" for a submodule.
            if path.hasSuffix(")"), let open = path.range(of: " (", options: .backwards) { path = String(path[..<open.lowerBound]) }
            guard !path.isEmpty else { continue }
            items.append(Item(path: unquote(path), label: L10n.t(tag), group: current, tag: tag))
        }
        return items
    }

    private static func shortName(_ c: Character) -> String {
        switch c {
        case "M": "modified"
        case "A": "new file"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "copied"
        case "T": "typechange"
        default: "changed"
        }
    }

    /// git quotes paths with odd characters: "a b\303\251.txt".
    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var bytes: [UInt8] = []
        let chars = Array(path.dropFirst().dropLast().utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "\\"), i + 1 < chars.count {
                let n = chars[i + 1]
                if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(n), i + 3 < chars.count,
                   let v = UInt8(String(bytes: chars[(i + 1)...(i + 3)], encoding: .ascii) ?? "", radix: 8) {
                    bytes.append(v)
                    i += 4
                    continue
                }
                let map: [UInt8: UInt8] = [UInt8(ascii: "n"): 10, UInt8(ascii: "t"): 9, UInt8(ascii: "\""): 34, UInt8(ascii: "\\"): 92]
                bytes.append(map[n] ?? n)
                i += 2
                continue
            }
            bytes.append(chars[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Diagnostics

    private static let gccStyle = try! NSRegularExpression(
        pattern: #"^([^\s:][^:]*?):(\d+):(?:(\d+):)?\s*(fatal error|error|warning|note|remark)(?:\[[^\]]*\])?:\s*(.*)$"#)
    private static let tscStyle = try! NSRegularExpression(
        pattern: #"^([^\s(][^(]*)\((\d+),(\d+)\):\s*(error|warning)\s+(TS\d+):\s*(.*)$"#)
    private static let rustHead = try! NSRegularExpression(pattern: #"^(error|warning)(?:\[([A-Z]+\d+)\])?:\s*(.*)$"#)
    private static let rustWhere = try! NSRegularExpression(pattern: #"^\s*-->\s*([^:]+):(\d+):(\d+)"#)
    private static let goStyle = try! NSRegularExpression(pattern: #"^([^\s:][^:]*\.go):(\d+):(\d+):\s*(.*)$"#)

    static func diagnostics(_ output: String, go: Bool) -> [Item] {
        var items: [Item] = [], seen = Set<String>()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func add(_ path: String, _ line: Int?, _ column: Int?, _ severity: String, _ message: String) {
            let tag = severity == "fatal error" ? "error" : severity
            let key = "\(path):\(line ?? 0):\(column ?? 0):\(tag):\(message)"
            guard seen.insert(key).inserted, items.count < maxItems else { return }
            let group = tag == "error" ? L10n.t("Errors") : tag == "warning" ? L10n.t("Warnings") : L10n.t("Notes")
            items.append(Item(path: path, line: line, column: column, label: message, group: group, tag: tag))
        }
        for (i, line) in lines.enumerated() {
            let ns = line as NSString, range = NSRange(location: 0, length: ns.length)
            func group(_ m: NSTextCheckingResult, _ n: Int) -> String? {
                let r = m.range(at: n)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let m = gccStyle.firstMatch(in: line, range: range), let path = group(m, 1), let sev = group(m, 4) {
                add(path, group(m, 2).flatMap { Int($0) }, group(m, 3).flatMap { Int($0) }, sev, group(m, 5) ?? "")
            } else if let m = tscStyle.firstMatch(in: line, range: range), let path = group(m, 1), let sev = group(m, 4) {
                add(path, group(m, 2).flatMap { Int($0) }, group(m, 3).flatMap { Int($0) }, sev, "\(group(m, 5) ?? ""): \(group(m, 6) ?? "")")
            } else if let m = rustHead.firstMatch(in: line, range: range), let sev = group(m, 1) {
                // rustc names the place a line or two below: "  --> src/main.rs:2:5".
                for next in lines[(i + 1)..<min(lines.count, i + 4)] {
                    let nns = next as NSString
                    guard let w = rustWhere.firstMatch(in: next, range: NSRange(location: 0, length: nns.length)) else { continue }
                    let message = (group(m, 2).map { "\($0): " } ?? "") + (group(m, 3) ?? "")
                    add(nns.substring(with: w.range(at: 1)), Int(nns.substring(with: w.range(at: 2))),
                        Int(nns.substring(with: w.range(at: 3))), sev, message)
                    break
                }
            } else if go, let m = goStyle.firstMatch(in: line, range: range), let path = group(m, 1) {
                add(path, group(m, 2).flatMap { Int($0) }, group(m, 3).flatMap { Int($0) }, "error", group(m, 4) ?? "")
            }
        }
        // Errors first, then warnings, then the rest; each in the order printed.
        let rank = ["error": 0, "warning": 1]
        return items.enumerated().sorted { (rank[$0.element.tag] ?? 2, $0.offset) < (rank[$1.element.tag] ?? 2, $1.offset) }.map(\.element)
    }

    // MARK: Search results

    private static let flatMatch = try! NSRegularExpression(pattern: #"^([^\s:][^:]*?):(\d+):(?:(\d+):)?(.*)$"#)
    private static let headedMatch = try! NSRegularExpression(pattern: #"^(\d+)(?::(\d+))?:(.*)$"#)

    static func search(_ output: String) -> [Item] {
        var items: [Item] = []
        var heading: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard items.count < maxItems else { break }
            let ns = line as NSString, range = NSRange(location: 0, length: ns.length)
            if line.isEmpty { heading = nil; continue }
            // rg on a terminal: a file's name, then its matches as "LINE:text"
            // (context lines as "LINE-text").
            if let file = heading, let m = headedMatch.firstMatch(in: line, range: range) {
                let col = m.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 2)))
                items.append(Item(path: file, line: Int(ns.substring(with: m.range(at: 1))), column: col,
                                  label: trimmedMatch(ns.substring(with: m.range(at: 3))), group: file))
                continue
            }
            if let m = flatMatch.firstMatch(in: line, range: range) {
                let path = ns.substring(with: m.range(at: 1))
                let col = m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3)))
                items.append(Item(path: path, line: Int(ns.substring(with: m.range(at: 2))), column: col,
                                  label: trimmedMatch(ns.substring(with: m.range(at: 4))), group: path))
                heading = nil
                continue
            }
            // A line that's a path and nothing else: rg's heading.
            if !line.contains(":"), !line.hasPrefix(" "), !line.contains("\t"), line.count < 500 {
                heading = line
            }
        }
        return items
    }

    private static func trimmedMatch(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).prefix(300))
    }
}
