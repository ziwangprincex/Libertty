#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --web-serve-probe`: serve one pane (a colored line, then `cat`)
    /// for a minute, for a browser to load the page (LIBERTTY_WEB_PORT, LIBERTTY_WEB_TOKEN).
    @MainActor
    static func webServeProbe() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let session = try? TerminalSession(size: GridSize(cols: 60, rows: 10, widthPx: 0, heightPx: 0)),
              (try? session.start(command: "printf '\\033[1;32mgreen\\033[0m on the \\033[44mweb\\033[0m <b>&\\n'; exec cat")) != nil
        else { exit(1) }
        let web = WebAccess.shared
        web.panes = { [WebPane(id: "p1", title: "probe", place: "probe window", host: nil, session: session)] }
        var config = Config()
        config.webAccess = "local"
        config.webAccessPort = Int(ProcessInfo.processInfo.environment["LIBERTTY_WEB_PORT"] ?? "") ?? 17682
        web.apply(config)
        print("serving on \(config.webAccessPort)")
        RunLoop.main.run(until: Date().addingTimeInterval(60))
        print("screen at the end:\n" + session.scrollbackText())
        exit(0)
    }
}
#endif
