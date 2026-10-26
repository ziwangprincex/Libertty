import AppKit

/// The app side of updating: Libertty ▸ Check for Updates…, the background
/// check `auto-update` asks for, and the download → verify → install →
/// relaunch flow with a small progress window.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private var timer: Timer?
    private var busy = false
    private var progressWindow: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var task: Task<Void, Never>?
    /// Downloaded and verified in the background (`auto-update = download`):
    /// waiting for the user to restart into it.
    private var ready: (release: Updater.Release, zip: URL)?
    /// The version the background check is downloading (`auto-update = download`).
    private var downloading: String?
    private static let skippedKey = "UpdateSkippedVersion"
    private static let lastCheckKey = "UpdateLastCheck"

    /// Start the background schedule (`auto-update`): a check shortly after
    /// launch if the last one was a day ago, then daily.
    func start() {
        guard Updater.feedURL != nil else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backgroundCheck() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.backgroundCheck() }
    }

    private func backgroundCheck() {
        let mode = ConfigStore.shared.config.autoUpdate
        guard mode != .off, !busy, ready == nil, installed == nil else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 23 * 3600 else { return }
        busy = true
        task = Task { @MainActor in
            do {
                let release = try await Updater.check()
                noteChecked()
                guard let release, release.version != UserDefaults.standard.string(forKey: Self.skippedKey) else {
                    busy = false
                    return
                }
                if mode == .download {
                    downloading = release.version
                    defer { downloading = nil }
                    let zip = try await Updater.download(release) { _ in }
                    ready = (release, zip)
                    busy = false
                    announceReady(release)
                } else {
                    // The check is over before the question: Install starts
                    // what comes next (it would find the check still busy).
                    busy = false
                    offer(release, automatic: true)
                }
            } catch {
                busy = false
                // Quiet in the background: the next check tries again.
                NSLog("Libertty: update check: \(error.localizedDescription)")
            }
        }
    }

    /// When the last check was (a probe's copy of the app shares the app's
    /// preferences: it mustn't put the user's daily check off).
    private func noteChecked() {
        if !Probe.running { UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey) }
    }

    /// Libertty ▸ Check for Updates…: always answers, even "you're up to date".
    @objc func checkForUpdates(_ sender: Any?) {
        // Installed, its restart cancelled: Restart to Update is just that
        // (what relaunches it waits for Libertty to quit).
        if installed != nil { return NSApp.terminate(nil) }
        guard !busy else {
            // Already under way: say so rather than nothing.
            if let downloading {
                return tell("Libertty \(downloading) is downloading.", detail: "Libertty tells you when it's ready to install.")
            }
            if let progressWindow, progressWindow.isVisible {
                Probe.activateApp()
                return progressWindow.makeKeyAndOrderFront(nil)
            }
            return tell("Libertty is checking for updates.", detail: "It tells you if there's a new version.")
        }
        if let ready { return offer(ready.release, automatic: false) }
        guard Updater.feedURL != nil else { return tell("Updates aren't set up for this build.", detail: "It was built without an update feed (see scripts/release.sh).") }
        busy = true
        showProgress("Checking for updates…", indeterminate: true)
        task = Task { @MainActor in
            let release: Updater.Release?
            do {
                release = try await Updater.check()
                noteChecked()
            } catch {
                busy = false
                hideProgress()
                return tell("Couldn't check for updates.", detail: error.localizedDescription)
            }
            // The check is over before the question: Install and Restart
            // starts the download (it would find the check still busy).
            busy = false
            hideProgress()
            if let release { offer(release, automatic: false) } else {
                tell("Libertty \(Updater.currentVersion) is the newest version.", detail: "")
            }
        }
    }

    // MARK: Offering

    private func offer(_ release: Updater.Release, automatic: Bool) {
        let alert = NSAlert()
        alert.messageText = "Libertty \(release.version) is available"
        alert.informativeText = "You have \(Updater.currentVersion). Programs keep running while Libertty restarts, and your windows come back."
        // What's new, in a box of its own size: a release's notes can be long.
        if let notes = Self.notesView(for: release) { alert.accessoryView = notes }
        alert.addButton(withTitle: ready != nil ? "Restart to Update" : "Install and Restart")
        alert.addButton(withTitle: "Later")
        if automatic { alert.addButton(withTitle: "Skip This Version") }
        alert.icon = NSApp.applicationIconImage
        switch answer(alert) {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default: break
        }
    }

    /// `auto-update = download`: the update is here; one notification, and
    /// the menu item turns into "Restart to Update".
    private func announceReady(_ release: Updater.Release) {
        Notifier.shared.post(title: "Libertty \(release.version) is ready",
                             body: "Choose Libertty ▸ Restart to Update when it suits you; nothing you're running stops.",
                             pane: "libertty.update")
        NotificationCenter.default.post(name: Self.readyChanged, object: nil)
    }

    static let readyChanged = Notification.Name("LiberttyUpdateReady")
    var isReady: Bool { ready != nil || installed != nil }
    /// Installed over this copy, the restart into it cancelled.
    private var installed: String?

    // MARK: Installing

    private func install(_ release: Updater.Release) {
        // One at a time (a second would share the first's staging folder).
        guard !busy else { return }
        busy = true
        let app = Bundle.main.bundleURL
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let zip: URL
                if let ready, ready.release == release {
                    zip = ready.zip
                } else {
                    showProgress("Downloading Libertty \(release.version)…", indeterminate: false)
                    zip = try await Updater.download(release) { fraction in
                        Task { @MainActor in UpdateController.shared.progressBar?.doubleValue = fraction }
                    }
                }
                showProgress("Installing…", indeterminate: true)
                try await Task.detached { try Updater.install(zip, release: release, over: app) }.value
                try? FileManager.default.removeItem(at: zip)
                // A probe checks what's on disk; nothing to restart into.
                if Probe.running {
                    probeLog.append("installed \(release.version) over \(app.path)")
                    return hideProgress()
                }
                Updater.relaunch(app.path)
                NSApp.terminate(nil)
                // Still here: the quit was cancelled (unsaved text, running
                // programs). The new version is on disk and opens once Libertty
                // quits; its download is gone, so Restart to Update only quits.
                hideProgress()
                ready = nil
                installed = release.version
                NotificationCenter.default.post(name: Self.readyChanged, object: nil)
                tell("Libertty \(release.version) is installed.", detail: "It opens the next time you quit Libertty.")
            } catch {
                hideProgress()
                ready = nil
                tell("Libertty couldn't update.", detail: error.localizedDescription)
            }
        }
    }

    // MARK: What's new

    /// The release's notes, Markdown shown as text (bullets, code, bold,
    /// links), scrolling past a few dozen lines, with a link to its page.
    static func notesView(for release: Updater.Release) -> NSView? {
        let markdown = [release.releaseNotes, release.notes].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let text = render(notes: markdown)
        if let page = release.releasePage.flatMap(URL.init(string:)) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: "All changes on GitHub", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: page,
            ]))
        }
        guard text.length > 0 else { return nil }
        let width: CGFloat = 440, maxHeight: CGFloat = 300
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(text)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        // The text's height at a width; past the box's, the scroller takes
        // its share of the width (all of it, where scroll bars always show).
        func height(at textWidth: CGFloat) -> CGFloat {
            textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: 10)
            layout.ensureLayout(for: container)
            return ceil(layout.usedRect(for: container).height) + 8
        }
        var full = height(at: width)
        let scrolls = full > maxHeight
        if scrolls {
            let inner = NSScrollView.contentSize(forFrameSize: NSSize(width: width, height: maxHeight),
                                                 horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
                                                 borderType: .noBorder, controlSize: .regular,
                                                 scrollerStyle: NSScroller.preferredScrollerStyle)
            full = height(at: inner.width)
        }
        textView.frame.size.height = full
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(full, maxHeight)))
        scroll.documentView = textView
        scroll.hasVerticalScroller = scrolls
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    /// The changelog's Markdown, line by line: `- `, `* `, `+ ` and `1. `
    /// items with a hanging indent (nested by their own indent; an indented
    /// line under one continues it), `> ` (the summary) and paragraphs as
    /// text, `# ` headings in bold; inline code, bold, italics, struck text
    /// and links within.
    static func render(notes markdown: String) -> NSMutableAttributedString {
        let size = NSFont.smallSystemFontSize
        let font = NSFont.systemFont(ofSize: size)
        let out = NSMutableAttributedString()
        func item(level: Int, continued: Bool) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            let indent = CGFloat(level + 1) * 14
            style.headIndent = indent
            style.firstLineHeadIndent = continued ? indent : indent - 14
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = 5
            return style
        }
        let plain = NSMutableParagraphStyle()
        plain.paragraphSpacing = 7
        var lastItemLevel: Int?
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            var line = raw.trimmingCharacters(in: .whitespaces)
            var style: NSParagraphStyle = plain, prefix = "", bold = false
            let marker = line.firstMatch(of: #/^([-*+]|\d+[.)])\s+/#)
            if let marker {
                let level = min(indent / 2, 3)
                let number = String(marker.output.1)
                prefix = (number.first?.isNumber == true ? number : "•") + "\t"
                line.removeSubrange(marker.range)
                style = item(level: level, continued: false)
                lastItemLevel = level
            } else if indent >= 2, let level = lastItemLevel {
                style = item(level: level, continued: true)  // the item above, on
            } else if line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                lastItemLevel = nil
            } else if let heading = line.firstMatch(of: #/^#{1,6}\s+/#) {
                line.removeSubrange(heading.range)
                bold = true
                lastItemLevel = nil
            } else {
                lastItemLevel = nil
            }
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            let start = out.length
            out.append(NSAttributedString(string: prefix, attributes: [.font: font]))
            out.append(inline(line, size: size, bold: bold))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }
        out.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One line's inline Markdown; as typed if it isn't Markdown.
    private static func inline(_ line: String, size: CGFloat, bold: Bool) -> NSAttributedString {
        let base = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        guard let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return NSAttributedString(string: line, attributes: [.font: base]) }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let strong = bold || intent.contains(.stronglyEmphasized)
            var font = intent.contains(.code) ? .monospacedSystemFont(ofSize: size - 0.5, weight: strong ? .semibold : .regular)
                : strong ? NSFont.boldSystemFont(ofSize: size) : base
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    // MARK: UI

    private func tell(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.icon = NSApp.applicationIconImage
        _ = answer(alert)
    }

    /// `--ui-probe` (no one there to click): how the dialogs are answered,
    /// what they and the install said, and whether anything is under way.
    var probeAnswer = NSApplication.ModalResponse.alertSecondButtonReturn
    private(set) var probeLog: [String] = []
    var isBusy: Bool { busy }

    private func answer(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard Probe.running else { return alert.runModal() }
        probeLog.append(alert.messageText + (alert.informativeText.isEmpty ? "" : ": \(alert.informativeText)"))
        return probeAnswer
    }

    private func showProgress(_ title: String, indeterminate: Bool) {
        // A probe's runs show nothing on the user's screen.
        guard !Probe.running else { return }
        if progressWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Software Update"
            panel.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 20, y: 52, width: 320, height: 20)
            label.tag = 1
            let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 320, height: 16))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            panel.contentView?.addSubview(label)
            panel.contentView?.addSubview(bar)
            panel.center()
            progressWindow = panel
            progressBar = bar
        }
        (progressWindow?.contentView?.viewWithTag(1) as? NSTextField)?.stringValue = title
        progressBar?.isIndeterminate = indeterminate
        if indeterminate { progressBar?.startAnimation(nil) } else { progressBar?.stopAnimation(nil); progressBar?.doubleValue = 0 }
        Probe.activateApp()
        progressWindow?.makeKeyAndOrderFront(nil)
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
    }
}
