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
        guard mode != .off, !busy, ready == nil else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 23 * 3600 else { return }
        busy = true
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let release = try await Updater.check()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let release, release.version != UserDefaults.standard.string(forKey: Self.skippedKey) else { return }
                if mode == .download {
                    let zip = try await Updater.download(release) { _ in }
                    ready = (release, zip)
                    announceReady(release)
                } else {
                    offer(release, automatic: true)
                }
            } catch {
                // Quiet in the background: the next check tries again.
                NSLog("Libertty: update check: \(error.localizedDescription)")
            }
        }
    }

    /// Libertty ▸ Check for Updates…: always answers, even "you're up to date".
    @objc func checkForUpdates(_ sender: Any?) {
        if let ready { return offer(ready.release, automatic: false) }
        guard !busy else { return }
        guard Updater.feedURL != nil else { return tell("Updates aren't set up for this build.", detail: "It was built without an update feed (see scripts/release.sh).") }
        busy = true
        showProgress("Checking for updates…", indeterminate: true)
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let release = try await Updater.check()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                hideProgress()
                if let release { offer(release, automatic: false) } else {
                    tell("Libertty \(Updater.currentVersion) is the newest version.", detail: "")
                }
            } catch {
                hideProgress()
                tell("Couldn't check for updates.", detail: error.localizedDescription)
            }
        }
    }

    // MARK: Offering

    private func offer(_ release: Updater.Release, automatic: Bool) {
        let alert = NSAlert()
        alert.messageText = "Libertty \(release.version) is available"
        var detail = "You have \(Updater.currentVersion). Programs keep running while Libertty restarts, and your windows come back."
        if let notes = release.notes, !notes.isEmpty { detail += "\n\n" + notes }
        alert.informativeText = detail
        alert.addButton(withTitle: ready != nil ? "Restart to Update" : "Install and Restart")
        alert.addButton(withTitle: "Later")
        if automatic { alert.addButton(withTitle: "Skip This Version") }
        alert.icon = NSApp.applicationIconImage
        switch alert.runModal() {
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
    var isReady: Bool { ready != nil }

    // MARK: Installing

    private func install(_ release: Updater.Release) {
        guard !busy || ready != nil else { return }
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
                Updater.relaunch(app.path)
                NSApp.terminate(nil)
            } catch {
                hideProgress()
                ready = nil
                tell("Libertty couldn't update.", detail: error.localizedDescription)
            }
        }
    }

    // MARK: UI

    private func tell(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }

    private func showProgress(_ title: String, indeterminate: Bool) {
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
