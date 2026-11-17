import Foundation
import Testing
@testable import LiberttyCore

/// What liberttyd makes of the ports a session's programs listen on: Linux's
/// /proc/net tables (read here from the text a Linux host would give), the
/// name a program goes by, and the watch's cadence.
struct PortsTests {
    // MARK: /proc/net/tcp and tcp6

    /// A table as Linux writes it: the header, a listener, a connection
    /// (state 01, not ours to report) and a listener on every address.
    private let tcp = """
        sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
         0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 847263 1 0000000000000000 100 0 0 10 0
         1: 0100007F:1F90 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 847299 1 0000000000000000 20 4 30 10 -1
         2: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 851004 1 0000000000000000 100 0 0 10 0

        """

    @Test func readsLinuxListeners() {
        let rows = PortScan.listeningRows(tcp, ipv6: false)
        #expect(rows.count == 2)
        #expect(rows[847263] == PortScan.Socket(port: 8080, address: "127.0.0.1"))
        #expect(rows[851004] == PortScan.Socket(port: 3000, address: "0.0.0.0"))
        // The connected socket isn't listening, and its inode stays out.
        #expect(rows[847299] == nil)
    }

    @Test func readsLinuxIPv6Listeners() {
        let tcp6 = """
            sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
             0: 00000000000000000000000000000000:170C 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 902311 1 0000000000000000 100 0 0 10 0
             1: 00000000000000000000000001000000:1F91 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 902400 1 0000000000000000 100 0 0 10 0

            """
        let rows = PortScan.listeningRows(tcp6, ipv6: true)
        #expect(rows[902311] == PortScan.Socket(port: 5900, address: "::"))
        #expect(rows[902400] == PortScan.Socket(port: 8081, address: "::1"))
    }

    @Test func refusesTablesThatAreNotOne() {
        #expect(PortScan.listeningRows("", ipv6: false).isEmpty)
        #expect(PortScan.listeningRows("nonsense\nrows here\n", ipv6: false).isEmpty)
        // A row cut short, and one whose address isn't hex at all.
        #expect(PortScan.listeningRows(" 0: 0100007F:1F90 00000000:0000 0A\n", ipv6: false).isEmpty)
        #expect(PortScan.listeningRows(
            " 0: ZZZZZZZZ:1F90 00000000:0000 0A 0:0 00:0 0 1000 0 12345\n", ipv6: false).isEmpty)
    }

    @Test func readsAddresses() {
        // The words come as the machine holds them (little-endian).
        #expect(PortScan.address(hex: "0100007F", ipv6: false) == "127.0.0.1")
        #expect(PortScan.address(hex: "00000000", ipv6: false) == "0.0.0.0")
        #expect(PortScan.address(hex: "0101A8C0", ipv6: false) == "192.168.1.1")
        #expect(PortScan.address(hex: "0000000000000000FFFF00000100007F", ipv6: true) == "::ffff:127.0.0.1")
        // Neither an IPv4 nor an IPv6 address.
        #expect(PortScan.address(hex: "0100007", ipv6: false) == nil)
        #expect(PortScan.address(hex: "0100007F", ipv6: true) == nil)
    }

    // MARK: What a program is called

    @Test func namesTheScriptARuntimeRuns() {
        #expect(PortScan.script(in: "/home/me/app/node_modules/vite/bin/vite.js --host") == "vite")
        #expect(PortScan.script(in: "/home/me/app/node_modules/.bin/next dev") == "next")
        // A generic file name: the package it's in says more.
        #expect(PortScan.script(in: "/opt/app/node_modules/@scope/tool/dist/cli.js") == "tool")
        #expect(PortScan.script(in: "/opt/app/node_modules/serve-it/index.mjs") == "serve-it")
        #expect(PortScan.script(in: "-m http.server 8000") == "http.server")
        // Not a JavaScript file: its own extension reads better.
        #expect(PortScan.script(in: "manage.py runserver") == "manage.py")
        #expect(PortScan.script(in: "") == "")
        #expect(PortScan.script(in: "--port 3000") == "")
    }

    @Test func aProcessWithNothingToScanHasNoPorts() {
        // No such process: nothing listed, and nothing hidden either.
        let (ports, partial) = PortScan.look(shell: .max, at: 0)
        #expect(ports.isEmpty)
        #expect(!partial)
        // Not a process at all.
        #expect(PortScan.look(shell: 0, at: 0).partial)
    }

    // MARK: The watch

    @Test func sleepsOnceThereIsNothingToFind() {
        let watch = PortWatch(id: "test", shell: .max, busy: { false }, tell: { _ in })
        defer { watch.stop() }
        // The first look is after output (the session just started), so it
        // stays on the clock; the one after it has nothing left to wait for.
        watch.look()
        #expect(watch.dueAt.isFinite)
        watch.look()
        #expect(watch.dueAt == .infinity)
        // Output: it looks again.
        watch.noteOutput()
        #expect(watch.dueAt.isFinite)
    }

    @Test func aBusySessionKeepsItsCadence() {
        let watch = PortWatch(id: "test", shell: .max, busy: { true }, tell: { _ in })
        defer { watch.stop() }
        watch.look()
        watch.look()
        let afterTwo = watch.dueAt
        #expect(afterTwo.isFinite)
        // Nothing changed twice over: the next look is further off (Rex backs
        // off the same way), and never past the ceiling.
        watch.look()
        #expect(watch.dueAt > afterTwo)
        for _ in 0..<12 { watch.look() }
        #expect(watch.dueAt - PortWatch.seconds() <= PortWatch.ceiling + 1)
        // A command starting puts it back on the short cadence.
        watch.commandBoundary()
        #expect(watch.dueAt - PortWatch.seconds() <= PortWatch.afterCommand + 1)
    }

    @Test func tellsNobodyWhenThereIsNothingToTell() {
        var told: [SessionPorts] = []
        let watch = PortWatch(id: "test", shell: .max, busy: { false }, tell: { told.append($0) })
        defer { watch.stop() }
        let answer = watch.look()
        #expect(answer.id == "test")
        #expect(answer.ports.isEmpty)
        #expect(told.isEmpty)
    }
}
