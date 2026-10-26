#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --git-probe`: which git Libertty runs for the current folder,
    /// and what it gets from it — on a Mac without developer tools (try
    /// `DEVELOPER_DIR=/nonexistent`) never /usr/bin/git, Apple's stub.
    static func gitProbe() -> Never {
        let directory = FileManager.default.currentDirectoryPath
        print("git: \(GitCLI.executable ?? "none")")
        print("root: \(GitCLI.root(of: directory) ?? "none")")
        switch GitCLI.execute(["status", "--porcelain"], in: directory) {
        case .success: print("status: ok")
        case .failure(let why): print("status: \(why.message)")
        }
        switch GitDiff.write(directory: directory) {
        case .success: print("diff: ok")
        case .failure(let why): print("diff: \(why.message)")
        }
        exit(0)
    }
}
#endif
