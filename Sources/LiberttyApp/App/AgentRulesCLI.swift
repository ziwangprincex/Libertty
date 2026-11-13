import Foundation
import LiberttyCore

/// `libertty +agents [--check]`: the coding agents Libertty knows by name
/// and reads the screens of (AgentScreen) — its own, and yours from the
/// config folder's `agents/` (herdr's manifest format, TOML or JSON, one
/// agent a file) — and, with --check, what of yours couldn't be read.
enum AgentRulesCLI {
    static func run(_ args: [String]) -> Int32 {
        let check = args.contains("--check")
        if let bad = args.first(where: { $0 != "--check" }) {
            FileHandle.standardError.write(Data("libertty: +agents takes --check, not \(bad)\n".utf8))
            return 2
        }
        let all = AgentScreen.current()
        let errors = AgentScreen.userErrors()
        let directory = (AgentScreen.userDirectory as NSString).abbreviatingWithTildeInPath
        if !check {
            // One line an agent (its manifest once, though its names are many).
            var seen = Set<String>()
            let manifests = all.values.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
            for m in manifests {
                let names = Set([m.id] + m.aliases + m.processes).sorted()
                let from = m.source.isEmpty ? "Libertty" : (m.source as NSString).abbreviatingWithTildeInPath
                let title = m.name ?? ProgramBadge.agents[m.id]?.name ?? m.id
                print("\(m.id)\t\(title)\t\(m.rules.count) rules\t\(names.joined(separator: ","))\t\(from)")
            }
            print("yours: \(directory)/NAME.toml or NAME.json (herdr's format); libertty +agents --check")
        }
        for (path, error) in errors.sorted(by: { $0.key < $1.key }) {
            print("\((path as NSString).abbreviatingWithTildeInPath): \(error)")
        }
        if check, errors.isEmpty { print("\(directory): fine") }
        return errors.isEmpty ? 0 : 1
    }
}
