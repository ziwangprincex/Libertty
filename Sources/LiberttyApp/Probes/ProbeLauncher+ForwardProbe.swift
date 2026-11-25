#if LIBERTTY_PROBES
import AppKit
import Foundation
import LiberttyCore

extension ProbeLauncher {
    /// `Libertty --forward-probe HOST` (with tests/fixtures/fake-ssh as
    /// LIBERTTY_SSH): the ports a host's connection carries, end to end. A
    /// local web server stands in for the dev server on the host — under
    /// fake-ssh the "host" is this Mac, and the fake's relay stands in for
    /// the listener an ssh master would open — so a forwarded link is
    /// really fetched here, through the forward.
    static func forwardProbe(host destination: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let host = RemoteHost.named(destination)
        let forwarder = PortForwarder.shared
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("libertty-forward-probe-\(getpid())")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Where fake-ssh writes down the forwards it was asked for.
        let book = dir.appendingPathComponent("forwards.txt")
        setenv("FAKE_SSH_FORWARDS", book.path, 1)
        // The "master" ssh says is running: another pid once it dropped.
        let master = book.deletingLastPathComponent().appendingPathComponent("master.pid")
        try? "1001".write(to: master, atomically: true, encoding: .utf8)
        setenv("FAKE_SSH_MASTER", master.path, 1)

        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return done()
        }
        var failed: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("\(name): \(ok)")
            if !ok { failed.append(name) }
        }
        /// What fake-ssh has been asked to carry, as "FLAG SPEC".
        func asked() -> [String] {
            let text = (try? String(contentsOf: book, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        }
        /// The page a forwarded URL answers with, or nil.
        func fetch(_ url: URL) -> String? {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            var body: String?
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, _, _ in
                body = data.flatMap { String(data: $0, encoding: .utf8) }
                done.signal()
            }.resume()
            // The run loop keeps turning: the forwarder posts on the main queue.
            let deadline = Date().addingTimeInterval(8)
            while done.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return body
        }

        // A web server standing in for one running on the host.
        guard let served = PortForward.freePort(preferring: 0) else {
            print("forward-probe: no free port for the stand-in server")
            exit(1)
        }
        try? "dev-server-ok".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-I", "-m", "http.server", "\(served)", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = dir
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        // The stand-in server, the forwards, and the liberttyd `prepare`
        // started on the fake host: none of them outlive the probe.
        func stopServer() {
            PortForwarder.shared.closeAll()
            if server.isRunning { server.terminate() }
            if host.info != nil { _ = DaemonClient.request(.shutdown, address: host.address) }
            try? fm.removeItem(at: dir)
        }
        do {
            try server.run()
        } catch {
            print("forward-probe: \(error.localizedDescription)")
            exit(1)
        }
        guard wait(10, until: { PortForward.isListening(served) }) else {
            print("forward-probe: the stand-in server didn't start")
            stopServer()
            exit(1)
        }

        do {
            _ = try host.prepare { print("progress: \($0)") }

            // A dev server's link in a pane on the host: this Mac's own
            // localhost is some other program, so it's carried over.
            let link = URL(string: "http://localhost:\(served)/index.html?x=1")!
            check("a localhost link is forwarded", PortForward.isLoopback(link))
            check("a named link is not", !PortForward.isLoopback(URL(string: "http://example.com/")!))
            let here = try forwarder.rewrite(link, on: host)
            // The stand-in server holds that number on this Mac, so the
            // forward took another one and the link says so.
            let local = here.port ?? 0
            check("the link opens here", here.host == "localhost" && local != 0 && local != served)
            check("its page and query are kept", here.path == "/index.html" && here.query == "x=1")
            check("ssh was asked for it", asked().contains("-L 127.0.0.1:\(local):localhost:\(served)"))
            check("the forward answers", fetch(here)?.contains("dev-server-ok") == true)
            // ssh's master would close a minute after the last window's
            // session, forwards and all: a session of its own holds it up.
            let keeper = host.keeperProcess
            check("the connection is held up while it carries forwards", keeper.map { kill($0, 0) == 0 } == true)

            // The same link again: the forward it already holds.
            let again = try forwarder.rewrite(link, on: host)
            check("asked twice, forwarded once", again.port == here.port && asked().count == 1)
            let held = forwarder.forwards(on: destination)
            check("listed once", held.count == 1 && held.first?.id == "\(destination):L\(served)")
            check("described both ends", held.first?.summary == "127.0.0.1:\(local) → localhost:\(served) on \(destination)")

            // A port nothing here holds keeps its number, so a dev server
            // that checks the Host header sees the name it expects.
            guard let quiet = PortForward.freePort(preferring: 0) else { throw PortForwarder.Failure.noLocalPort }
            let same = try forwarder.open(remote: quiet, on: host)
            check("the same number when it's free", same.local == quiet)
            check("…and ssh was asked for that", asked().contains("-L 127.0.0.1:\(quiet):localhost:\(quiet)"))

            // A port of this Mac's, listened for on the host (`ssh -R`).
            guard let mine = PortForward.freePort(preferring: 0) else { throw PortForwarder.Failure.noLocalPort }
            let shared = try forwarder.share(local: mine, on: host)
            check("a port shared with the host", shared.id == "\(destination):R\(mine)")
            check("…as a reverse forward", asked().contains("-R 127.0.0.1:\(mine):localhost:\(mine)"))

            // A port the host won't give up: ssh says so, and nothing is kept.
            let refused = PortForward.freePort(preferring: 0) ?? 1
            setenv("FAKE_SSH_FORWARD_FAIL", "\(refused)", 1)
            var complained = false
            do {
                _ = try forwarder.open(remote: refused, on: host)
            } catch {
                complained = ((error as? LocalizedError)?.errorDescription ?? "").contains("forwarding failed")
            }
            unsetenv("FAKE_SSH_FORWARD_FAIL")
            check("a refused port is reported", complained)
            check("…and not kept", !forwarder.forwards(on: destination).contains { $0.remote == refused })

            // The connection dropped and came back: the master that held
            // the forwards is gone, and a new one is asked for them again.
            for line in (try? String(contentsOf: book, encoding: .utf8))?.split(separator: "\n") ?? [] {
                if let pid = line.split(separator: " ").last.flatMap({ Int32($0) }) { kill(pid, SIGTERM) }
            }
            try? "".write(to: book, atomically: true, encoding: .utf8)
            try? "1002".write(to: master, atomically: true, encoding: .utf8)
            check("the forward is down with its master", wait(5) { !PortForward.isListening(local) })
            NotificationCenter.default.post(name: RemoteHost.statusChanged, object: host)
            check("it comes back on reconnect", wait(10) { PortForward.isListening(local) })
            check("…and answers again", fetch(here)?.contains("dev-server-ok") == true)
            check("…and the new connection is held up instead", wait(5) {
                host.keeperProcess.map { $0 != keeper } == true && keeper.map { kill($0, 0) != 0 } == true
            })
            let kept = host.keeperProcess

            // Closing takes the port back from the host's connection.
            check("closed", forwarder.close(id: "\(destination):L\(served)"))
            check("…its port is free again", wait(5) { !PortForward.isListening(local) })
            check("…and it's off the list", !forwarder.forwards(on: destination).contains { $0.remote == served })
            check("closing what isn't there says so", !forwarder.close(id: "\(destination):L1"))

            // The host's last window going closes the rest.
            forwarder.closeAll(on: destination)
            check("every forward closed", forwarder.forwards(on: destination).isEmpty && forwarder.all.isEmpty)
            check("…and their ports are free", wait(5) { !PortForward.isListening(quiet) && !PortForward.isListening(mine) })
            check("…and the connection is let go", host.keeperProcess == nil
                && wait(5) { kept.map { kill($0, 0) != 0 } ?? false })

            // A host slow to answer a forward (a `-R` waits for its far side)
            // holds up only its own: another host's forward is made meanwhile.
            let slow = RemoteHost.named(destination + "-slow")
            _ = try slow.prepare()
            let stall = dir.appendingPathComponent("stall")
            try? slow.destination.write(to: stall, atomically: true, encoding: .utf8)
            setenv("FAKE_SSH_STALL", stall.path, 1)
            let slowDone = DispatchSemaphore(value: 0)
            let slowPort = PortForward.freePort(preferring: 0) ?? 1
            DispatchQueue.global().async {
                _ = try? forwarder.share(local: slowPort, on: slow)
                slowDone.signal()
            }
            _ = wait(5) { fm.fileExists(atPath: stall.path + ".started") }
            let began = Date()
            _ = try forwarder.open(remote: quiet, on: host)
            check("a stalled host holds up no other host's forwards", Date().timeIntervalSince(began) < 3)
            try? fm.removeItem(at: stall)
            unsetenv("FAKE_SSH_STALL")
            check("…and has its own once it answers", slowDone.wait(timeout: .now() + 10) == .success
                && forwarder.forwards(on: slow.destination).contains { $0.local == slowPort })
            forwarder.closeAll()

            stopServer()
            print(failed.isEmpty ? "forward-probe: all passed" : "forward-probe failed: \(failed)")
            exit(failed.isEmpty ? 0 : 1)
        } catch {
            stopServer()
            print("forward-probe: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }
}
#endif
