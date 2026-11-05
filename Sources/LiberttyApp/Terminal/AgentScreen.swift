import Foundation

/// What a coding agent in a terminal is doing, told from what its screen
/// shows: working, waiting for you (blocked), or idle at its prompt — for
/// agents that report nothing themselves (Codex says nothing as a turn
/// starts; Gemini, OpenCode, Amp… nothing at all).
///
/// The rules are herdr's (github.com/ogulcancelik/herdr, Apache-2.0), one
/// manifest per agent, as Kero reads them: converted by
/// scripts/update-agent-rules.py into Resources/agent-rules/rules.json, and
/// read as herdr's engine reads them — of the rules that match, the one of
/// the highest priority wins; with none, the agent is idle.
enum AgentScreen {
    enum State: String { case idle, working, blocked, unknown }

    /// What the rules read: the screen's text (its rows, as shown), the
    /// terminal's title, and the last OSC 9;4 progress after "9;" ("4;3").
    struct Input {
        var screen: String
        var title = ""
        var progress = ""
    }

    struct Result: Equatable {
        var state: State
        /// The rule that matched, "" when none did.
        var rule = ""
        /// The screen shows the state outright (a prompt box, a permission
        /// dialog, a spinner), not by elimination.
        var visible = false
        /// Keep the state as it was: the screen shows something that tells
        /// nothing, such as a transcript viewer.
        var skip = false
    }

    struct Manifest {
        var id: String
        var aliases: [String]
        var rules: [Rule]
    }

    struct Rule {
        var id: String
        var state: State
        var priority: Int
        var region: String
        var visibleIdle = false, visibleBlocker = false, visibleWorking = false
        var skip = false
        var gate: Gate
    }

    /// A rule's conditions, all of which hold: every needle contained
    /// (ignoring case), every regex matching, every line regex matching a
    /// line, every gate of `all`, one of `any` (when there are any), none of `not`.
    final class Gate {
        var contains: [String] = []
        var regex: [NSRegularExpression] = []
        var lineRegex: [NSRegularExpression] = []
        var all: [Gate] = [], any: [Gate] = [], not: [Gate] = []

        init(_ json: [String: Any]) throws {
            contains = (json["contains"] as? [String] ?? []).map { $0.lowercased() }
            regex = try (json["regex"] as? [String] ?? []).map(AgentScreen.compile)
            lineRegex = try (json["line_regex"] as? [String] ?? []).map(AgentScreen.compile)
            all = try (json["all"] as? [[String: Any]] ?? []).map(Gate.init)
            any = try (json["any"] as? [[String: Any]] ?? []).map(Gate.init)
            not = try (json["not"] as? [[String: Any]] ?? []).map(Gate.init)
        }

        func matches(_ text: String, lower: String) -> Bool {
            for needle in contains where !lower.contains(needle) { return false }
            let ns = text as NSString
            for re in regex where re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) == nil { return false }
            for re in lineRegex where !AgentScreen.anyLine(text, re) { return false }
            for g in all where !g.matches(text, lower: lower) { return false }
            if !any.isEmpty, !any.contains(where: { $0.matches(text, lower: lower) }) { return false }
            for g in not where g.matches(text, lower: lower) { return false }
            return true
        }
    }

    struct LoadError: Error, CustomStringConvertible {
        var description: String
    }

    // MARK: Loading

    /// The manifests by agent name: each one's id and aliases.
    static func load(_ data: Data) throws -> [String: Manifest] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["manifests"] as? [[String: Any]] else { throw LoadError(description: "no manifests") }
        var byName: [String: Manifest] = [:]
        for m in list {
            guard let id = m["id"] as? String else { throw LoadError(description: "a manifest without an id") }
            var rules: [Rule] = []
            for r in m["rules"] as? [[String: Any]] ?? [] {
                let ruleID = r["id"] as? String ?? ""
                do {
                    rules.append(Rule(
                        id: ruleID, state: State(rawValue: r["state"] as? String ?? "") ?? .unknown,
                        priority: r["priority"] as? Int ?? 0, region: r["region"] as? String ?? "whole_recent",
                        visibleIdle: r["visible_idle"] as? Bool ?? false,
                        visibleBlocker: r["visible_blocker"] as? Bool ?? false,
                        visibleWorking: r["visible_working"] as? Bool ?? false,
                        skip: r["skip_state_update"] as? Bool ?? false, gate: try Gate(r)))
                } catch {
                    throw LoadError(description: "\(id): rule \(ruleID): \(error)")
                }
            }
            let manifest = Manifest(id: id, aliases: m["aliases"] as? [String] ?? [], rules: rules)
            byName[id] = manifest
            for alias in manifest.aliases { byName[alias.lowercased()] = manifest }
        }
        return byName
    }

    /// Libertty's own: Resources/agent-rules/rules.json.
    static let bundled: [String: Manifest] = {
        guard let url = AppResources.url("agent-rules/rules.json"), let data = try? Data(contentsOf: url) else { return [:] }
        do { return try load(data) } catch {
            assertionFailure("agent-rules: \(error)")
            return [:]
        }
    }()

    /// Agents whose process goes by another name than their manifest's.
    private static let processNames = ["omp": "pi"]

    /// The rules for an agent, by its name (a process name, a manifest's id or alias).
    static func manifest(for agent: String, in manifests: [String: Manifest] = bundled) -> Manifest? {
        let name = agent.lowercased()
        return manifests[processNames[name] ?? name]
    }

    // MARK: Detecting

    /// What the agent is doing, by its manifest's rules.
    static func detect(_ manifest: Manifest, _ input: Input) -> Result {
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

    /// The manifests' regexes are written for Rust's regex crate; ICU reads
    /// the same syntax but for \u{…}, which it spells \x{…}.
    static func compile(_ pattern: String) throws -> NSRegularExpression {
        var p = pattern
        if let braced = try? NSRegularExpression(pattern: #"\\u\{([0-9A-Fa-f]+)\}"#) {
            p = braced.stringByReplacingMatches(in: p, range: NSRange(location: 0, length: (p as NSString).length),
                                                withTemplate: #"\\x{$1}"#)
        }
        return try NSRegularExpression(pattern: p)
    }

    static func anyLine(_ text: String, _ re: NSRegularExpression) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line.hasSuffix("\r") ? line.dropLast() : line)
            if re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil { return true }
        }
        return false
    }

    // MARK: Regions: the parts of the screen a rule reads

    static func region(_ input: Input, _ spec: String) -> String {
        let s = input.screen
        let spec = spec.trimmingCharacters(in: .whitespaces)
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
            return ls.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        case "after_last_horizontal_rule":
            let ls = lines(s)
            if let i = ls.lastIndex(where: horizontalRule) { return join(ls[(i + 1)...]) }
            return s
        default: break
        }
        if let n = count(spec, "bottom_lines") {
            let ls = lines(s)
            return join(ls[max(0, ls.count - n)...])
        }
        if let n = count(spec, "bottom_non_empty_lines") {
            let ls = lines(s)
            var left = n
            for i in ls.indices.reversed() where !ls[i].trimmingCharacters(in: .whitespaces).isEmpty {
                left -= 1
                if left == 0 { return join(ls[i...]) }
            }
            return s
        }
        if let n = count(spec, "top_non_empty_lines") {
            let ls = lines(s)
            var end = 0, left = n
            for i in ls.indices where !ls[i].trimmingCharacters(in: .whitespaces).isEmpty {
                end = i + 1
                left -= 1
                if left == 0 { break }
            }
            return join(ls[..<end])
        }
        return ""
    }

    private static func count(_ spec: String, _ name: String) -> Int? {
        guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
        guard let n = Int(spec.dropFirst(name.count + 1).dropLast()), n > 0 else { return nil }
        return n
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
        let t = l.trimmingCharacters(in: .whitespaces)
        let n = t.prefix { $0 == "─" }.count
        guard n > 0 else { return false }
        return t.dropFirst(n).trimmingCharacters(in: .whitespaces).isEmpty || n >= 3
    }
}
