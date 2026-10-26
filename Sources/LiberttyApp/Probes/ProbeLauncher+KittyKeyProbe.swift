#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --kitty-key-probe`: a program enables the kitty keyboard
    /// protocol at each level and echoes what it receives (`cat -v`), then
    /// the probe presses Shift+2 the way the view does. Legacy and
    /// disambiguate modes must deliver plain "@" (the kitty spec keeps
    /// shift+key out of CSI u, and programs like tclaude mis-decode it);
    /// report-all keeps CSI u, which is what the program asked for.
    static func kittyKeyProbe() -> Never {
        Persistence.setUp(wanted: true)
        var failures = 0
        func press(_ name: String, enable: String, expect: String, absent: String) {
            do {
                let session = try TerminalSession(size: GridSize(cols: 60, rows: 6, widthPx: 600, heightPx: 120))
                try session.start(command: "printf '\(enable)'; sleep 0.4; cat -v")
                RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                session.send(TerminalSession.Key(
                    action: GHOSTTY_KEY_ACTION_PRESS, key: GHOSTTY_KEY_DIGIT_2,
                    mods: GhosttyMods(GHOSTTY_MODS_SHIFT), consumedMods: 0,
                    text: "@", unshiftedCodepoint: 0x32, composing: false))
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let text = session.scrollbackText()
                if text.contains(expect), !text.contains(absent) {
                    print("ok    kitty-key \(name)")
                } else {
                    print("FAIL  kitty-key \(name): wanted \(expect), screen has \(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(50))")
                    failures += 1
                }
                session.terminate()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            } catch {
                print("FAIL  kitty-key \(name): \(error)")
                failures += 1
            }
        }
        // AZERTY's Ctrl+A: the physical key is US Q, the text the layout's "a"
        // (TerminalView passes it): ^A goes out, not ^Q.
        do {
            let session = try TerminalSession(size: GridSize(cols: 60, rows: 6, widthPx: 600, heightPx: 120))
            try session.start(command: "sleep 0.4; od -An -c")
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            session.send(TerminalSession.Key(
                action: GHOSTTY_KEY_ACTION_PRESS, key: GHOSTTY_KEY_Q, mods: GhosttyMods(GHOSTTY_MODS_CTRL), consumedMods: 0,
                text: "a", unshiftedCodepoint: 0x61, composing: false))
            session.sendText("\n\u{04}")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let text = session.scrollbackText()
            if text.contains("001"), !text.contains("021") { print("ok    kitty-key layout ctrl: ^A") } else {
                print("FAIL  kitty-key layout ctrl: wanted 001 (^A), screen has \(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(50))")
                failures += 1
            }
            session.terminate()
        } catch {
            print("FAIL  kitty-key layout ctrl: \(error)")
            failures += 1
        }
        press("legacy: @", enable: "", expect: "@", absent: "[50")
        press("disambiguate: @", enable: "\\033[>1u", expect: "@", absent: "[50")
        press("report-all: CSI u", enable: "\\033[>8u", expect: "[50;2u", absent: "@")
        print(failures == 0 ? "kitty-key: all passed" : "kitty-key: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
