// The release's look on the real screen (tests/screen-check.sh builds and
// runs this): a built Libertty.app, started with a private liberttyd, data
// folder and config, brought to the front (Stage Manager or not) and driven
// from outside — its config file and its menus, as a person would — through
// Rex's layouts: sidebar and split, compact, glass, light, tabs above,
// translucent, the Settings window and the Theme Customizer. Each is shot
// as the window server shows it, into one contact sheet a person looks at
// before publishing, and checked where a check can be made:
//   - the window is on the stage at its size (not a Stage Manager thumbnail)
//     and every window it opens fits the screen's visible part (not under
//     the Dock);
//   - between the sidebar and the panes there's the window's own surface,
//     not the desktop (0.3.x's gap with background-opacity below 1);
//   - every pane wears its header (its Split Right button).
// Needs Screen Recording and Accessibility for whatever runs it; without,
// it says which and exits 3. It takes the screen for about half a minute.
//   screen-check APP OUTDIR [--only translucent,classic-dark,...] [--keep]
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: screen-check APP OUTDIR [--only NAME,NAME]")
    exit(2)
}
let appURL = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
let outDir = URL(fileURLWithPath: args[2])
let only: Set<String>? = args.firstIndex(of: "--only").flatMap { i in
    i + 1 < args.count ? Set(args[i + 1].split(separator: ",").map(String.init)) : nil
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard CGPreflightScreenCaptureAccess() else {
    print("screen-check: no Screen Recording permission for this terminal (System Settings ▸ Privacy & Security)")
    exit(3)
}
guard AXIsProcessTrusted() else {
    print("screen-check: no Accessibility permission for this terminal (System Settings ▸ Privacy & Security)")
    exit(3)
}

var failures: [String] = []
var shots: [(name: String, file: URL, notes: [String])] = []

// MARK: The app, private

let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("libertty-screen-check-\(getpid())")
try? FileManager.default.removeItem(at: home)
let configDir = home.appendingPathComponent("config/libertty")
try! FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
let configFile = configDir.appendingPathComponent("config")

/// Every scenario's config: the defaults but for what makes shots comparable,
/// and English: the check finds menu items, windows and buttons by their
/// English names, whatever language this Mac uses (`language = auto` would
/// follow it).
func writeConfig(_ lines: [String]) {
    let base = ["theme = light:Libertty Light,dark:Libertty Dark", "confirm-close = false", "window-columns = 110", "window-rows = 30",
                "language = en"]
    try! (base + lines).joined(separator: "\n").appending("\n").write(to: configFile, atomically: true, encoding: .utf8)
}
writeConfig(["window-theme = dark"])

let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = ["-n", appURL.path,
                  "--env", "LIBERTTY_DAEMON_SOCKET=\(home.path)/d.sock", "--env", "LIBERTTY_DAEMON_LOG=\(home.path)/d.log",
                  "--env", "LIBERTTY_DATA_DIR=\(home.path)", "--env", "LIBERTTY_STATE_FILE=\(home.path)/windows.json",
                  "--env", "XDG_CONFIG_HOME=\(home.path)/config"]
try! open.run()
open.waitUntilExit()

func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

var app: NSRunningApplication?
for _ in 0..<100 where app == nil {
    wait(0.1)
    app = NSWorkspace.shared.runningApplications.first {
        $0.bundleURL?.resolvingSymlinksInPath() == appURL && $0.processIdentifier != getpid()
            && ($0.launchDate ?? .distantPast) > Date().addingTimeInterval(-30)
    }
}
guard let app else { print("screen-check: \(appURL.path) didn't start"); exit(1) }
let pid = app.processIdentifier
let ax = AXUIElementCreateApplication(pid)

func quit() -> Never {
    // --keep: left running to look at (its private folder stays too).
    if args.contains("--keep") {
        print("screen-check: left running, pid \(pid), in \(home.path)")
        exit(failures.isEmpty ? 0 : 1)
    }
    app.forceTerminate()
    // Its liberttyd too: it's ours, in the private folder.
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    kill.arguments = ["-f", "liberttyd.*\(home.lastPathComponent)|\(home.path)"]
    try? kill.run()
    kill.waitUntilExit()
    try? FileManager.default.removeItem(at: home)
    exit(failures.isEmpty ? 0 : 1)
}

// MARK: Accessibility

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return v
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func all(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
    guard depth < 40 else { return [] }
    return (match(e) ? [e] : []) + children(e).flatMap { all($0, depth: depth + 1, match) }
}
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
func label(_ e: AXUIElement) -> String { (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "" }

/// Press the menu item titled `title`, wherever it is in the menu bar.
@discardableResult
func pressMenu(_ title: String) -> Bool {
    guard let bar = attr(ax, kAXMenuBarAttribute) else { return false }
    let found = all(bar as! AXUIElement) { role($0) == "AXMenuItem" && (attr($0, kAXTitleAttribute) as? String) == title }
    guard let item = found.first else { return false }
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
}

/// In front, its windows on the stage: with Stage Manager a window of an
/// app that isn't is a thumbnail at the screen's side until it comes back,
/// and asking once isn't always enough.
func front(until ready: () -> Bool = { true }) {
    for _ in 0..<8 {
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        wait(0.9)
        if app.isActive, ready() { return }
    }
}

// MARK: Windows, shots

struct Shown { let id: CGWindowID; let frame: CGRect; let title: String }

func windows() -> [Shown] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat], let id = w[kCGWindowNumber as String] as? CGWindowID
        else { return nil }
        return Shown(id: id, frame: CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!),
                     title: w[kCGWindowName as String] as? String ?? "")
    }
}

/// The terminal window: the widest that isn't Settings or the customizer.
func mainWindow() -> Shown? {
    windows().filter { $0.title != "Settings" && $0.title != "Theme Customizer" && $0.frame.width > 100 }
        .max { $0.frame.width < $1.frame.width }
}

/// The screen's visible part, in window-list coordinates (top-left origin).
let visible: CGRect = {
    let screen = NSScreen.screens.first!
    let v = screen.visibleFrame, full = screen.frame
    return CGRect(x: v.minX, y: full.height - v.maxY, width: v.width, height: v.height)
}()

func check(_ ok: Bool, _ what: String, into notes: inout [String]) {
    print(ok ? "ok    screen-check \(what)" : "FAIL  screen-check \(what)")
    notes.append((ok ? "✓ " : "✗ ") + what)
    if !ok { failures.append(what) }
}

/// The window alone (no tooltip or other window over it), else the
/// screen where it is.
func capture(_ window: Shown, as name: String) -> URL? {
    let file = outDir.appendingPathComponent("\(name).png")
    let r = window.frame
    func shoot(_ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x"] + arguments + [file.path]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
    }
    if shoot(["-o", "-l", String(window.id)]) { return file }
    return shoot(["-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]) ? file : nil
}

/// sRGB and alpha, 0–255: a window shot alone is transparent where the
/// window draws nothing (where the desktop would show).
func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Double]? {
    guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh,
          let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
    return [c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255, c.alphaComponent * 255]
}

/// The column between the sidebar and the panes is the sidebar's own
/// surface (the backdrop), not something else showing through.
func seamCheck(_ file: URL, window: Shown, notes: inout [String]) {
    guard let axWindow = all(ax, { role($0) == "AXWindow" }).first(where: { frame($0).width >= window.frame.width - 2 }),
          let splitter = all(axWindow, { role($0) == "AXSplitter" }).min(by: { frame($0).minX < frame($1).minX }),
          let image = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data()) else {
        return check(false, "seam: no sidebar splitter to look at", into: &notes)
    }
    let scale = Double(image.pixelsWide) / window.frame.width
    let divider = frame(splitter)
    // The divider's first pixel: a thin one is a single pixel wide.
    let x = Int(((divider.minX - window.frame.minX) * scale).rounded(.down))
    let inside = Int(((divider.minX - 24 - window.frame.minX) * scale).rounded())
    var worst = 0.0
    for fraction in [0.35, 0.5, 0.65, 0.8] {
        let y = Int(Double(image.pixelsHigh) * fraction)
        guard let a = pixel(image, x, y), let b = pixel(image, inside, y) else { continue }
        worst = max(worst, zip(a, b).map { abs($0 - $1) }.max() ?? 0)
    }
    check(worst <= 12, "seam: between the sidebar and the panes is the sidebar's surface (off by \(Int(worst)))", into: &notes)
}

func headersCheck(panes: Int, notes: inout [String]) {
    let headers = all(ax) { role($0) == "AXButton" && label($0) == "Split Right" }.count
    check(headers >= panes, "pane headers: \(headers) for \(panes) panes", into: &notes)
}

func onStage(_ w: Shown?, _ what: String, notes: inout [String]) {
    guard let w else { return check(false, "\(what): not on screen", into: &notes) }
    check(w.frame.width >= 400, "\(what): on the stage at its size (\(Int(w.frame.width))×\(Int(w.frame.height)))", into: &notes)
    // (A few points of slack: the Dock's edge as this process sees it.)
    check(w.frame.minY >= visible.minY - 4 && w.frame.maxY <= visible.maxY + 4,
          "\(what): within the screen's visible part (\(Int(w.frame.minY))–\(Int(w.frame.maxY)) of \(Int(visible.minY))–\(Int(visible.maxY)))",
          into: &notes)
}

// MARK: Scenarios

/// One state: its config, then what's done to the window; then a shot and its checks.
func scenario(_ name: String, config: [String], seam: Bool = false, panes: Int = 2, then act: () -> Void = {}) {
    guard only?.contains(name) ?? true else { return }
    writeConfig(config)
    wait(1.5)
    act()
    front { (mainWindow()?.frame.width ?? 0) >= 400 }
    var notes: [String] = []
    let w = mainWindow()
    onStage(w, "window", notes: &notes)
    guard let w, let file = capture(w, as: name) else { return }
    if seam { seamCheck(file, window: w, notes: &notes) }
    headersCheck(panes: panes, notes: &notes)
    shots.append((name, file, notes))
}

front()
for _ in 0..<50 where mainWindow() == nil { wait(0.1) }
guard mainWindow() != nil else { print("screen-check: no window"); quit() }
// Two panes for every layout.
pressMenu("Split Right")
wait(1.0)

scenario("classic-dark", config: ["window-theme = dark"], seam: true)
// As the config that showed 0.3.x's gap: the window clear, blurred.
scenario("translucent", config: ["window-theme = dark", "background-opacity = 0", "background-blur = true"], seam: true)
scenario("compact-dark", config: ["window-theme = dark", "pane-style = compact"])
scenario("glass-dark", config: ["window-theme = dark", "interface-style = glass"])
scenario("classic-light", config: ["window-theme = light"], seam: true)
scenario("tabs-above", config: ["window-theme = dark", "tab-bar = top"])
scenario("active-border", config: ["window-theme = dark", "active-border = true"])

/// A window the app opens from its menu: on screen and within its visible part.
func panel(_ name: String, menu: String, title: String, close: String?) {
    guard only?.contains(name) ?? true else { return }
    writeConfig(["window-theme = dark"])
    wait(1.0)
    front()
    var notes: [String] = []
    check(pressMenu(menu), "\(menu) in the menus", into: &notes)
    wait(2.0)
    front { (windows().first { $0.title == title }?.frame.width ?? 0) >= 400 }
    let w = windows().first { $0.title == title }
    onStage(w, title, notes: &notes)
    if let w, let file = capture(w, as: name) { shots.append((name, file, notes)) }
    // Closed again: by its own button, else its window's.
    if let close, let button = all(ax, { role($0) == "AXButton" && label($0) == close }).first {
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    } else if let window = all(ax, { role($0) == "AXWindow" && (attr($0, kAXTitleAttribute) as? String) == title }).first,
              let closeButton = attr(window, kAXCloseButtonAttribute) {
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }
    wait(0.8)
}

panel("settings", menu: "Settings…", title: "Settings", close: nil)
panel("theme-customizer", menu: "Theme Editor…", title: "Theme Customizer", close: "Cancel")

// MARK: The contact sheet

func contactSheet() {
    let width: CGFloat = 900, gap: CGFloat = 24, caption: CGFloat = 20
    let images = shots.compactMap { shot -> (NSImage, String, [String])? in
        guard let image = NSImage(contentsOf: shot.file) else { return nil }
        return (image, shot.name, shot.notes)
    }
    guard !images.isEmpty else { return }
    let heights = images.map { min(640, width * $0.0.size.height / max(1, $0.0.size.width)) + caption * CGFloat(1 + $0.2.count) }
    let rows = stride(from: 0, to: images.count, by: 2).map { max(heights[$0], $0 + 1 < heights.count ? heights[$0 + 1] : 0) }
    let size = NSSize(width: width * 2 + gap * 3, height: rows.reduce(0, +) + gap * CGFloat(rows.count + 1))
    let sheet = NSImage(size: size)
    sheet.lockFocus()
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    var top = size.height - gap
    for (r, rowHeight) in rows.enumerated() {
        for c in 0..<2 {
            let i = r * 2 + c
            guard i < images.count else { continue }
            let (image, name, notes) = images[i]
            let x = gap + CGFloat(c) * (width + gap)
            var y = top
            let title = NSAttributedString(string: name, attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white])
            title.draw(at: NSPoint(x: x, y: y - caption))
            y -= caption
            for note in notes {
                let failed = note.hasPrefix("✗")
                NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                              .foregroundColor: failed ? NSColor.systemRed : NSColor(white: 0.95, alpha: 1)])
                    .draw(at: NSPoint(x: x, y: y - caption))
                y -= caption
            }
            let h = min(640, width * image.size.height / max(1, image.size.width))
            let w = h * image.size.width / max(1, image.size.height)
            image.draw(in: NSRect(x: x, y: y - h, width: w, height: h))
        }
        top -= rowHeight + gap
    }
    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: outDir.appendingPathComponent("contact.png"))
    }
}

contactSheet()
let summary = failures.isEmpty ? "screen-check: all passed" : "screen-check: \(failures.count) failed"
try? ([summary] + shots.flatMap { s in ["\(s.name):"] + s.notes.map { "  " + $0 } }).joined(separator: "\n")
    .appending("\n").write(to: outDir.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
print(summary)
print("contact sheet: \(outDir.appendingPathComponent("contact.png").path)")
quit()
