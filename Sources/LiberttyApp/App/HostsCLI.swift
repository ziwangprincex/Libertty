import Foundation
import LiberttyCore

/// `libertty +hosts`: the hosts you keep (Settings ▸ Remote Hosts), as Rex's
/// `rex hosts` does.
///   +hosts [list]        in your order
///   +hosts add HOST      at the end (an ssh destination: a Host from ~/.ssh/config, user@server)
///   +hosts remove HOST
///   +hosts check HOST    connect (setting Libertty up there if needed) and say how it went
enum HostsCLI {
    static func run(_ args: [String]) -> Int32 {
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            SavedHosts.all.forEach { print($0) }
            return CLI.ExitCode.ok
        case "add", "remove", "check":
            guard rest.count == 1, let host = rest.first else { return usage() }
            guard SavedHosts.isValid(host) else { return fail("not an ssh destination: \(host)", CLI.ExitCode.usage) }
            switch sub {
            case "add":
                if !SavedHosts.add(host) { print("\(host) is there already") }
                return CLI.ExitCode.ok
            case "remove":
                return SavedHosts.remove(host) ? CLI.ExitCode.ok : fail("no host \(host)", CLI.ExitCode.notFound)
            default:
                let remote = RemoteHost.named(host)
                do {
                    let info = try remote.prepare { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
                    print("\(host): connected (\(info.os) \(info.arch)), liberttyd at \(info.liberttyd)")
                    return CLI.ExitCode.ok
                } catch {
                    var why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    switch SSHRecovery.diagnose(remote.lastSSHErrors) {
                    case .changedHostKey(let name, _, _, _)?:
                        why += "\nIts key changed. If you know why (it was set up again): ssh-keygen -R \(name), then connect."
                    case .keysNotLoaded(let keys)?:
                        why += "\nssh-agent has no keys: ssh-add --apple-use-keychain \(keys.joined(separator: " "))"
                    case nil: break
                    }
                    return fail("\(host): \(why)", CLI.ExitCode.unreachable)
                }
            }
        default:
            return usage()
        }
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("libertty: \(message)\n".utf8))
        return status
    }

    private static func usage() -> Int32 {
        fail("usage: libertty +hosts [list] | add HOST | remove HOST | check HOST", CLI.ExitCode.usage)
    }
}
