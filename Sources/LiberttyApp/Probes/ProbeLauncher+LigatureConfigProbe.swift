#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --ligature-config-probe`: font-feature lines → whether ligatures stay on.
    static func ligatureConfigProbe() -> Never {
        let cases: [(String, Bool)] = [
            ("", true), ("font-feature = -calt", false), ("font-feature = -calt, -liga, -dlig", false),
            ("font-feature = calt off", false), ("font-feature = liga=0", false), ("font-feature = +calt", true),
            ("font-feature = -calt\nfont-feature = +calt", true), ("font-feature = ss01", true),
        ]
        let wrong = cases.filter { Config.parse($0.0).0.ligatures != $0.1 }
        print(wrong.isEmpty ? "ligature config: all \(cases.count) right" : "ligature config wrong: \(wrong.map(\.0))")
        exit(0)
    }
}
#endif
