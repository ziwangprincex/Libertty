import Foundation
import Testing
@testable import LiberttyApp

/// The login shell's PATH (what git's hooks run with) is read with a
/// deadline that holds whatever the shell does: one that hangs in its rc
/// files ignoring SIGTERM, as an interactive shell does, or one that leaves
/// a program running with the pipe open. Before, either hung every git call.
struct LoginShellTests {
    private func shell(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)").path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func itsPathAsItSaysIt() throws {
        // As the real one: run the -c command the shell is given (a chatty rc first).
        let sh = try shell("echo 'Welcome!'\nPATH=/opt/tools/bin:/usr/bin\nshift 3\neval \"$1\"")
        defer { try? FileManager.default.removeItem(atPath: sh) }
        #expect(LoginShell.read(shell: sh, timeout: 5) == "/opt/tools/bin:/usr/bin")
    }

    @Test func aShellThatHangsIgnoringSIGTERM() throws {
        let sh = try shell("trap '' TERM\nsleep 30")
        defer { try? FileManager.default.removeItem(atPath: sh) }
        let start = Date()
        #expect(LoginShell.read(shell: sh, timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func aProgramLeftHoldingThePipe() throws {
        // Its rc files start something that outlives the shell, its stdout the pipe.
        let sh = try shell("sleep 30 &\nPATH=/x/bin\nshift 3\neval \"$1\"")
        defer { try? FileManager.default.removeItem(atPath: sh) }
        let start = Date()
        #expect(LoginShell.read(shell: sh, timeout: 5) == "/x/bin")
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
