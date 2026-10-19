import AppKit

/// A borderless panel that can still take the keyboard.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Ghostty's quick terminal: a terminal that slides in from a screen edge
/// (`quick-terminal-position`) over everything, on whichever Space and
/// screen you're on, and slides away again. Its panes are ordinary ones:
/// splits, tabs, find and liberttyd persistence all work; the session comes back
/// at the next launch.
final class QuickTerminal {
    static let shared = QuickTerminal()

    private var controller: TerminalWindowController?
    /// The app that was in front before it came down; focus goes back there.
    private var previousApp: NSRunningApplication?
    private var animating = false
    private static let sessionKey = "QuickTerminalSession"

    var isVisible: Bool { controller?.window?.isVisible == true }
    /// Its window, once it has come down (Go to Pane lists its panes).
    var windowController: TerminalWindowController? { controller }

    func toggle() {
        if isVisible, controller?.window?.isKeyWindow == true { hide(restoreFocus: true) } else { show() }
    }

    func show() {
        guard !animating else { return }
        let config = ConfigStore.shared.config
        if controller == nil { controller = make(config: config) }
        guard let controller, let window = controller.window else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let target = Self.frame(in: area, config: config)
        let hidden = Self.offscreen(target, in: area, config.quickTerminalPosition)

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let wasVisible = window.isVisible
        if !wasVisible {
            window.setFrame(hidden, display: false)
            window.alphaValue = config.quickTerminalPosition == .center ? 0 : 1
        }
        Probe.activateApp()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.focusedTerminal)
        if wasVisible { return }
        if !controller.hasStarted { try? controller.start(); controller.hasStarted = true }
        animate(window, to: target, alpha: 1)
        remember()
    }

    /// Slide it away. `restoreFocus`: give the keyboard back to the app that
    /// had it (toggling off); not when you clicked elsewhere (autohide).
    func hide(restoreFocus: Bool) {
        guard let window = controller?.window, window.isVisible, !animating else { return }
        let config = ConfigStore.shared.config
        let area = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let hidden = Self.offscreen(window.frame, in: area, config.quickTerminalPosition)
        animate(window, to: hidden, alpha: config.quickTerminalPosition == .center ? 0 : 1) {
            window.orderOut(nil)
            window.alphaValue = 1
        }
        if restoreFocus, let app = previousApp, !app.isTerminated {
            app.activate()
        }
        previousApp = nil
        remember()
    }

    private func animate(_ window: NSWindow, to frame: NSRect, alpha: CGFloat, completion: (() -> Void)? = nil) {
        guard !Motion.reduced else {
            window.setFrame(frame, display: true)
            window.alphaValue = alpha
            completion?()
            return
        }
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            self?.animating = false
            completion?()
        })
    }

    private func make(config: Config) -> TerminalWindowController? {
        // Its liberttyd session, if it's still running from last time.
        var pane: TerminalView?
        if let id = UserDefaults.standard.string(forKey: Self.sessionKey),
           let session = try? TerminalSession.attach(id, config: config) {
            pane = try? TerminalView(session: session, config: config)
        }
        let restored = pane != nil
        guard let pane = pane ?? (try? TerminalWindowController.makePane(config: config, cols: config.windowColumns,
                                                                         rows: config.windowRows)) else { return nil }
        let controller = TerminalWindowController.makeQuick(config: config, pane: pane)
        controller.hasStarted = restored
        if restored { controller.markRestored(unstarted: []) }
        controller.onClose = { [weak self] _ in
            // Its last pane closed: the next toggle starts a fresh one.
            self?.controller = nil
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        }
        if let window = controller.window {
            window.isMovable = false
            window.hasShadow = true
            window.backgroundColor = config.resolvedTheme.background.nsColor
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 12
            window.contentView?.layer?.masksToBounds = true
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return controller
    }

    /// Keep its session for the next launch.
    private func remember() {
        if let id = controller?.persistentSessionIDs.first {
            UserDefaults.standard.set(id, forKey: Self.sessionKey)
        }
    }

    /// Where it sits on screen: against its edge, inset a little so its
    /// rounded corners and shadow show.
    private static func frame(in area: NSRect, config: Config) -> NSRect {
        let size = CGFloat(config.quickTerminalSize)
        let inset: CGFloat = 8
        switch config.quickTerminalPosition {
        case .top:
            return NSRect(x: area.minX + inset, y: area.maxY - area.height * size, width: area.width - inset * 2,
                          height: area.height * size - inset)
        case .bottom:
            return NSRect(x: area.minX + inset, y: area.minY + inset, width: area.width - inset * 2,
                          height: area.height * size - inset)
        case .left:
            return NSRect(x: area.minX + inset, y: area.minY + inset, width: area.width * size - inset,
                          height: area.height - inset * 2)
        case .right:
            return NSRect(x: area.maxX - area.width * size, y: area.minY + inset, width: area.width * size - inset,
                          height: area.height - inset * 2)
        case .center:
            let w = area.width * max(size, 0.5), h = area.height * size
            return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        }
    }

    /// The same frame just past its edge (where it slides from).
    private static func offscreen(_ frame: NSRect, in area: NSRect, _ position: Config.QuickPosition) -> NSRect {
        var f = frame
        switch position {
        case .top: f.origin.y = area.maxY + 2
        case .bottom: f.origin.y = area.minY - f.height - 2
        case .left: f.origin.x = area.minX - f.width - 2
        case .right: f.origin.x = area.maxX + 2
        case .center: f = frame.insetBy(dx: frame.width * 0.03, dy: frame.height * 0.03)
        }
        return f
    }
}
