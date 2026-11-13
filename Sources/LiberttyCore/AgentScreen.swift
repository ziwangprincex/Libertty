#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif

/// What a coding agent in a terminal is doing, told from what its screen
/// shows: working, waiting for you (blocked), or idle at its prompt — for
/// agents that report nothing themselves (Codex says nothing as a turn
/// starts; Gemini, OpenCode, Amp… nothing at all).
///
/// The rules are herdr's (github.com/ogulcancelik/herdr, Apache-2.0), one
/// manifest per agent, as Kero reads them: converted by
/// scripts/update-agent-rules.py into Resources/agent-rules/rules.json (and
/// AgentRulesData.swift, so liberttyd has them on any host), and read as
/// herdr's engine reads them — of the rules that match, the one of the
/// highest priority wins; with none, the agent is idle. Yours, in the same
/// format, come from the config folder's `agents/` (`user`).
///
/// Shared by the app and liberttyd, so on Linux too: Swift's own regexes
/// (no ICU) and no NSString.
public enum AgentScreen {
    public enum State: String, Sendable { case idle, working, blocked, unknown }

    /// What the rules read: the screen's text (its rows, as shown), the
    /// terminal's title, and the last OSC 9;4 progress after "9;" ("4;3").
    public struct Input {
        public var screen: String
        public var title: String
        public var progress: String

        public init(screen: String, title: String = "", progress: String = "") {
            self.screen = screen
            self.title = title
            self.progress = progress
        }
    }

    public struct Result: Equatable {
        public var state: State
        /// The rule that matched, "" when none did.
        public var rule = ""
        /// The screen shows the state outright (a prompt box, a permission
        /// dialog, a spinner), not by elimination.
        public var visible = false
        /// Keep the state as it was: the screen shows something that tells
        /// nothing, such as a transcript viewer.
        public var skip = false

        public init(state: State, rule: String = "", visible: Bool = false, skip: Bool = false) {
            self.state = state
            self.rule = rule
            self.visible = visible
            self.skip = skip
        }
    }

    public struct Manifest {
        public var id: String
        public var aliases: [String]
        public var rules: [Rule]
        /// What it shows as (yours may say; herdr's don't): "My Agent".
        public var name: String?
        /// The process names it runs as, besides its id and aliases (yours).
        public var processes: [String] = []
        /// Where it came from: "" for Libertty's own, else the file's path.
        public var source = ""
    }

    public struct Rule {
        public var id: String
        public var state: State
        public var priority: Int
        public var region: String
        public var visibleIdle = false, visibleBlocker = false, visibleWorking = false
        public var skip = false
        var gate: Gate
    }

    /// A rule's conditions, all of which hold: every needle contained
    /// (ignoring case), every regex matching, every line regex matching a
    /// line, every gate of `all`, one of `any` (when there are any), none of `not`.
    final class Gate {
        var contains: [String] = []
        var regex: [Pattern] = []
        var lineRegex: [Pattern] = []
        var all: [Gate] = [], any: [Gate] = [], not: [Gate] = []

        init(_ json: [String: Any]) throws {
            contains = (json["contains"] as? [String] ?? []).map { $0.lowercased() }
            regex = try (json["regex"] as? [String] ?? []).map(Pattern.init)
            lineRegex = try (json["line_regex"] as? [String] ?? []).map(Pattern.init)
            all = try (json["all"] as? [[String: Any]] ?? []).map(Gate.init)
            any = try (json["any"] as? [[String: Any]] ?? []).map(Gate.init)
            not = try (json["not"] as? [[String: Any]] ?? []).map(Gate.init)
        }

        func matches(_ text: String, lower: String) -> Bool {
            for needle in contains where !lower.contains(needle) { return false }
            for re in regex where !re.matches(text) { return false }
            for re in lineRegex where !AgentScreen.anyLine(text, re) { return false }
            for g in all where !g.matches(text, lower: lower) { return false }
            if !any.isEmpty, !any.contains(where: { $0.matches(text, lower: lower) }) { return false }
            for g in not where g.matches(text, lower: lower) { return false }
            return true
        }
    }

    /// One of the manifests' regexes, written for Rust's regex crate. ICU
    /// reads the same syntax but for \u{…}, which it spells \x{…}; it's what
    /// the Mac uses (several times faster on a full screen). On Linux, where
    /// liberttyd goes without ICU, Swift's own regexes read them alike once
    /// they look at Unicode scalars rather than characters (`.` is one
    /// scalar, as in Rust).
    struct Pattern {
        enum Engine { case icu, swift }
        /// ICU on the Mac; Swift's on Linux (and in a test, on the Mac, that
        /// checks the two agree).
        #if os(Linux)
        nonisolated(unsafe) static var engine = Engine.swift
        #else
        nonisolated(unsafe) static var engine = Engine.icu
        #endif

        private let swift: Regex<AnyRegexOutput>?
        #if !os(Linux)
        private let icu: NSRegularExpression?
        #endif

        init(_ pattern: String) throws {
            do {
                #if os(Linux)
                swift = try Regex(pattern).matchingSemantics(.unicodeScalar)
                #else
                if Self.engine == .swift {
                    swift = try Regex(pattern).matchingSemantics(.unicodeScalar)
                    icu = nil
                } else {
                    icu = try NSRegularExpression(pattern: Self.icu(pattern))
                    swift = nil
                }
                #endif
            } catch {
                throw LoadError(description: "a regex that doesn't compile: \(pattern)")
            }
        }

        func matches(_ text: String) -> Bool {
            #if !os(Linux)
            if let icu { return icu.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil }
            #endif
            return swift.map { text.firstMatch(of: $0) != nil } ?? false
        }

        #if !os(Linux)
        private static let braced = try? NSRegularExpression(pattern: #"\\u\{([0-9A-Fa-f]+)\}"#)

        static func icu(_ pattern: String) -> String {
            guard let braced else { return pattern }
            return braced.stringByReplacingMatches(in: pattern, range: NSRange(location: 0, length: (pattern as NSString).length),
                                                   withTemplate: #"\\x{$1}"#)
        }
        #endif
    }

    public struct LoadError: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: Loading

    /// The manifests by agent name: each one's id, aliases and process names.
    /// Either `{"manifests": [...]}` (Libertty's file) or one manifest as an
    /// object (herdr's TOML read as JSON, or a file of your own).
    public static func load(_ data: Data, source: String = "") throws -> [String: Manifest] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError(description: "not a JSON object")
        }
        return try load(root, source: source)
    }

    public static func load(_ root: [String: Any], source: String = "", defaultID: String? = nil) throws -> [String: Manifest] {
        let list = root["manifests"] as? [[String: Any]] ?? [root]
        var byName: [String: Manifest] = [:]
        for m in list {
            guard let id = m["id"] as? String ?? (list.count == 1 ? defaultID : nil), !id.isEmpty else {
                throw LoadError(description: "a manifest without an id")
            }
            guard let ruleList = m["rules"] as? [[String: Any]] else {
                throw LoadError(description: "\(id): no rules")
            }
            var rules: [Rule] = []
            for r in ruleList {
                let ruleID = r["id"] as? String ?? ""
                // A rule that keeps the state as it was (skip_state_update) needs none.
                let state = State(rawValue: r["state"] as? String ?? "") ?? .unknown
                if !source.isEmpty, state == .unknown, r["skip_state_update"] as? Bool != true {
                    throw LoadError(description: "\(id): rule \(ruleID): state is idle, working or blocked")
                }
                do {
                    rules.append(Rule(
                        id: ruleID, state: state,
                        priority: r["priority"] as? Int ?? 0, region: r["region"] as? String ?? "whole_recent",
                        visibleIdle: r["visible_idle"] as? Bool ?? false,
                        visibleBlocker: r["visible_blocker"] as? Bool ?? false,
                        visibleWorking: r["visible_working"] as? Bool ?? false,
                        skip: r["skip_state_update"] as? Bool ?? false, gate: try Gate(r)))
                } catch {
                    throw LoadError(description: "\(id): rule \(ruleID): \(error)")
                }
                // (Yours are checked: a region misspelled would read nothing, silently.)
                let region = trimmed(rules[rules.count - 1].region)
                if !source.isEmpty, !regionNames.contains(region), countedRegion(region) == nil {
                    throw LoadError(description: "\(id): rule \(ruleID): no region named \(region)")
                }
            }
            var manifest = Manifest(id: id, aliases: m["aliases"] as? [String] ?? [], rules: rules)
            manifest.name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            manifest.processes = m["processes"] as? [String] ?? []
            manifest.source = source
            for name in [id] + manifest.aliases + manifest.processes { byName[name.lowercased()] = manifest }
        }
        return byName
    }

    /// Libertty's own (AgentRulesData.swift, from Resources/agent-rules/rules.json).
    public static let bundled: [String: Manifest] = {
        do { return try load(Data(AgentRulesData.json.utf8)) } catch {
            assertionFailure("agent-rules: \(error)")
            return [:]
        }
    }()

    /// Yours: every `*.toml` (herdr's manifest format, one agent a file, its
    /// id the file's name unless it says) and `*.json` in `directory`, by
    /// agent name, and what couldn't be read, by file. A manifest of yours
    /// takes the place of Libertty's of the same name.
    public static func user(in directory: String) -> (manifests: [String: Manifest], errors: [String: String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return ([:], [:]) }
        var manifests: [String: Manifest] = [:], errors: [String: String] = [:]
        for name in names.sorted() where name.hasSuffix(".toml") || name.hasSuffix(".json") {
            let path = directory.appendingPath(name)
            do {
                guard let data = FileManager.default.contents(atPath: path) else { throw LoadError(description: "unreadable") }
                let id = String(name.dropLast(5))
                let found: [String: Manifest]
                if name.hasSuffix(".toml") {
                    found = try load(try TOML.parse(String(decoding: data, as: UTF8.self)), source: path, defaultID: id)
                } else {
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard let root else { throw LoadError(description: "not a JSON object") }
                    found = try load(root, source: path, defaultID: id)
                }
                manifests.merge(found) { _, new in new }
            } catch {
                errors[path] = "\(error)"
            }
        }
        return (manifests, errors)
    }

    /// The config folder's `agents/`: `$XDG_CONFIG_HOME/libertty/agents`, else
    /// `~/.config/libertty/agents` (on a remote host, that host's).
    public static var userDirectory: String {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHomeDirectory().appendingPath(".config")
        return base.appendingPath("libertty/agents")
    }

    /// Libertty's rules with yours over them, read again when a file in
    /// your folder changes (checked at most every few seconds).
    public static func current() -> [String: Manifest] { UserRules.shared.manifests() }

    /// What `current` couldn't read in your folder, by file.
    public static func userErrors() -> [String: String] { UserRules.shared.errors() }

    /// Agents whose process goes by another name than their manifest's.
    private static let processNames = ["omp": "pi"]

    /// The rules for an agent, by its name (a process name, a manifest's id or alias).
    public static func manifest(for agent: String, in manifests: [String: Manifest]? = nil) -> Manifest? {
        let name = agent.lowercased()
        let all = manifests ?? current()
        return all[processNames[name] ?? name]
    }

    // MARK: Detecting

    /// What the agent is doing, by its manifest's rules.
    public static func detect(_ manifest: Manifest, _ input: Input) -> Result {
        var won: Rule?
        for rule in manifest.rules {
            if let won, won.priority >= rule.priority { continue }
            let text = region(input, rule.region)
            if rule.gate.matches(text, lower: text.lowercased()) { won = rule }
        }
        guard let won else { return Result(state: .idle) }
        var result = Result(state: won.state, rule: won.id, skip: won.skip)
        switch won.state {
        case .idle: result.visible = won.visibleIdle
        case .blocked: result.visible = won.visibleBlocker
        case .working: result.visible = won.visibleWorking
        case .unknown: break
        }
        return result
    }

    static func anyLine(_ text: String, _ re: Pattern) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if re.matches(l) { return true }
        }
        return false
    }

    // MARK: Regions: the parts of the screen a rule reads

    static let regionNames: Set<String> = [
        "osc_title", "osc_progress", "whole_recent", "after_last_prompt_marker", "before_current_prompt_marker",
        "whole_recent_without_current_prompt_marker", "current_prompt_block_marker", "after_current_prompt_block_marker",
        "prompt_box_body", "above_prompt_box", "last_non_empty_above_prompt_box", "after_last_horizontal_rule",
    ]

    public static func region(_ input: Input, _ spec: String) -> String {
        let s = input.screen
        let spec = trimmed(spec)
        switch spec {
        case "osc_title": return input.title
        case "osc_progress": return input.progress
        case "whole_recent": return s
        case "after_last_prompt_marker":
            let ls = lines(s)
            if let i = ls.lastIndex(where: promptLine) { return join(ls[(i + 1)...]) }
            return s
        case "before_current_prompt_marker":
            let ls = lines(s)
            if let i = currentPrompt(ls) { return join(ls[..<i]) }
            return s
        case "whole_recent_without_current_prompt_marker":
            return currentPrompt(lines(s)) != nil ? "" : s
        case "current_prompt_block_marker":
            let ls = lines(s)
            if let i = currentPrompt(ls), let j = ls[..<i].lastIndex(where: blockLine) { return ls[j] }
            return ""
        case "after_current_prompt_block_marker":
            let ls = lines(s)
            if let i = currentPrompt(ls), let j = ls[..<i].lastIndex(where: blockLine) { return join(ls[j...]) }
            return ""
        case "prompt_box_body":
            let ls = lines(s)
            guard let top = promptBoxTop(ls) else { return "" }
            let end = ls[(top + 1)...].firstIndex(where: horizontalRule) ?? ls.count
            return join(ls[(top + 1)..<end])
        case "above_prompt_box":
            return abovePromptBox(s)
        case "last_non_empty_above_prompt_box":
            let ls = lines(abovePromptBox(s))
            return ls.last(where: { !trimmed($0).isEmpty }) ?? ""
        case "after_last_horizontal_rule":
            let ls = lines(s)
            if let i = ls.lastIndex(where: horizontalRule) { return join(ls[(i + 1)...]) }
            return s
        default: break
        }
        guard let (name, n) = countedRegion(spec) else { return "" }
        let ls = lines(s)
        switch name {
        case "bottom_lines":
            return join(ls[max(0, ls.count - n)...])
        case "bottom_non_empty_lines":
            var left = n
            for i in ls.indices.reversed() where !trimmed(ls[i]).isEmpty {
                left -= 1
                if left == 0 { return join(ls[i...]) }
            }
            return s
        default:  // top_non_empty_lines
            var end = 0, left = n
            for i in ls.indices where !trimmed(ls[i]).isEmpty {
                end = i + 1
                left -= 1
                if left == 0 { break }
            }
            return join(ls[..<end])
        }
    }

    /// "bottom_lines(5)" → ("bottom_lines", 5).
    static func countedRegion(_ spec: String) -> (String, Int)? {
        for name in ["bottom_lines", "bottom_non_empty_lines", "top_non_empty_lines"] {
            guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { continue }
            guard let n = Int(spec.dropFirst(name.count + 1).dropLast()), n > 0 else { return nil }
            return (name, n)
        }
        return nil
    }

    static func trimmed(_ s: String) -> String {
        guard let first = s.firstIndex(where: { !$0.isWhitespace || $0.isNewline }) else { return "" }
        let last = s.lastIndex(where: { !$0.isWhitespace || $0.isNewline })!
        return String(s[first...last])
    }

    static func lines(_ s: String) -> [String] {
        let t = s.hasSuffix("\n") ? String(s.dropLast()) : s
        return t.isEmpty ? [] : t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func join<C: Collection>(_ ls: C) -> String where C.Element == String {
        ls.isEmpty ? "" : ls.joined(separator: "\n") + "\n"
    }

    /// Codex's prompt: "›" at the start of a line.
    static func promptLine(_ l: String) -> Bool { l == "›" || l.hasPrefix("› ") }

    /// The start of one of Codex's transcript blocks.
    static func blockLine(_ l: String) -> Bool {
        l.hasPrefix("•") || l.hasPrefix("■") || l.hasPrefix("✗") || l.hasPrefix("✓")
    }

    /// Codex's prompt line, unless a block comes after it.
    static func currentPrompt(_ ls: [String]) -> Int? {
        guard let i = ls.lastIndex(where: promptLine) else { return nil }
        return ls[(i + 1)...].contains(where: blockLine) ? nil : i
    }

    /// The prompt box's top border: the second rule from the bottom.
    static func promptBoxTop(_ ls: [String]) -> Int? {
        var n = 0
        for i in ls.indices.reversed() where horizontalRule(ls[i]) {
            n += 1
            if n == 2 { return i }
        }
        return nil
    }

    static func abovePromptBox(_ s: String) -> String {
        let ls = lines(s)
        if let top = promptBoxTop(ls) { return join(ls[..<top]) }
        return s
    }

    /// A line of "─", or one starting with three, as a box's border with a label.
    static func horizontalRule(_ l: String) -> Bool {
        let t = trimmed(l)
        let n = t.prefix { $0 == "─" }.count
        guard n > 0 else { return false }
        return trimmed(String(t.dropFirst(n))).isEmpty || n >= 3
    }
}

/// Your folder of rules, read again when it changes: its files' names,
/// sizes and modification times are looked at every few seconds at most.
final class UserRules: @unchecked Sendable {
    static let shared = UserRules()
    private let lock = NSLock()
    private var merged = AgentScreen.bundled
    private var failures: [String: String] = [:]
    private var stamp = ""
    private var checked: UInt64 = 0
    private static let every: UInt64 = 3_000_000_000

    func manifests() -> [String: AgentScreen.Manifest] {
        refreshIfDue()
        return lock.withLock { merged }
    }

    func errors() -> [String: String] {
        refreshIfDue()
        return lock.withLock { failures }
    }

    private func refreshIfDue() {
        let now = monotonicNanos()
        let due: Bool = lock.withLock {
            guard checked == 0 || now - checked >= Self.every else { return false }
            checked = now
            return true
        }
        guard due else { return }
        let dir = AgentScreen.userDirectory
        let seen = Self.stamp(of: dir)
        guard seen != lock.withLock({ stamp }) else { return }
        let (yours, errors) = AgentScreen.user(in: dir)
        lock.withLock {
            stamp = seen
            merged = AgentScreen.bundled.merging(yours) { _, new in new }
            failures = errors
        }
    }

    /// What changes when a file in the folder does.
    private static func stamp(of dir: String) -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return "" }
        return names.sorted().map { name -> String in
            var st = stat()
            guard stat(dir.appendingPath(name), &st) == 0 else { return name }
            #if os(Linux)
            return "\(name):\(st.st_size):\(st.st_mtim.tv_sec).\(st.st_mtim.tv_nsec)"
            #else
            return "\(name):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            #endif
        }.joined(separator: "/")
    }
}
