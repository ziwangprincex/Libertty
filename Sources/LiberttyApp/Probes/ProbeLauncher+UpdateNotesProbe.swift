#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --update-notes-probe FEED.json OUT.png`: what Check for
    /// Updates would show of FEED's notes (the box under the dialog's text),
    /// as a PNG in light and dark, and the box's size.
    @MainActor
    static func updateNotesProbe(feed: String, to output: String) -> Never {
        guard let data = FileManager.default.contents(atPath: feed),
              let release = try? JSONDecoder().decode(Updater.Release.self, from: data) else {
            print("update-notes-probe: \(feed) isn't an update feed")
            exit(1)
        }
        guard let view = UpdateController.notesView(for: release) else {
            print("update-notes-probe: no notes")
            exit(0)
        }
        print("notes box: \(Int(view.frame.width))x\(Int(view.frame.height))")
        // On a dialog's background, as it shows.
        let backdrop = Backdrop(frame: view.frame.insetBy(dx: -12, dy: -12))
        view.setFrameOrigin(NSPoint(x: 12, y: 12))
        backdrop.addSubview(view)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let path = (output as NSString).deletingPathExtension + "-\(name).png"
            backdrop.appearance = NSAppearance(named: appearance)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
                backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
                guard (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
                else { return print("update-notes-probe: couldn't write \(path)") }
                print(path)
            }
        }
        exit(0)
    }
}
#endif
