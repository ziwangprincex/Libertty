import AppKit
import LiberttyCore
import CGhosttyVt
import Metal
import QuartzCore

/// The terminal surface: owns the Metal layer, paces frames to the display,
/// and turns AppKit input (keys, IME, scroll, paste) into terminal input.
final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    let session: TerminalSession
    /// Names this pane in notifications: its liberttyd session, else per view.
    lazy var paneID: String = session.persistentID ?? UUID().uuidString
    private var renderer: TerminalRenderer!
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?
    private var idleFrames = 0
    private var forceRedraw = true
    /// When the view last changed size; presenting stays synchronous until it settles.
    private var lastResize: CFTimeInterval = 0

    var fontSize: CGFloat = 13 {
        didSet { if fontSize != oldValue { rebuildFonts() } }
    }

    // Settings (see `apply`)
    private var fontFamily = ""
    private var cellHeightAdjust = MetricAdjust.none
    private var configFontSize: CGFloat?
    private(set) var padding = Config().padding
    private var unfocusedOpacity: CGFloat = 0.65
    private var isDimmed = false
    private var copyOnSelect = false
    private var vsync = false
    /// View ▸ Terminal Read-only: nothing typed, pasted or clicked reaches the
    /// program; selecting, copying and scrolling still work.
    var isReadOnly = false {
        didSet { if isReadOnly != oldValue { setNeedsRender(force: true) } }
    }
    private var optionAsAlt = Config.OptionAsAlt.false

    // IME state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastMarkedTextWasEmpty = true

    // Trackpad scrolling keeps the sub-row remainder so motion stays continuous.
    private var scrollRemainder: CGFloat = 0
    /// Smooth scrolling (`scroll-smooth`): how far into the next row the
    /// content is moved up, in points (0 ≤ it < a row).
    private(set) var smoothOffset: CGFloat = 0
    var smoothScrolling = true
    /// When VoiceOver last heard about new output (TerminalAccessibility).
    var lastAccessibilityAnnouncement: CFTimeInterval = 0

    // Scrollbar, cursor blink, pointer hiding (see `apply`).
    private lazy var scroller: OverlayScroller = {
        let s = OverlayScroller()
        s.onScroll = { [weak self] row in
            self?.session.scroll(toRow: row)
            self?.revealScroller = true
            self?.setNeedsRender()
        }
        addSubview(s)
        s.layer?.zPosition = 2
        return s
    }()
    private var showsScrollbar = true
    /// The next frame shows the scrollbar (the user scrolled).
    private var revealScroller = false
    private var blinkTimer: Timer?
    private var hideMouseWhileTyping = false

    /// Other panes that get what's typed here (Broadcast Input), set by the window.
    var broadcastPeers: (() -> [TerminalView])?

    init(session: TerminalSession, config: Config) throws {
        self.session = session
        super.init(frame: .zero)
        // The layer is AppKit's (layer-backed): AppKit sets its gravity from
        // this, at times of its own, over ours below — and its default stretches
        // the contents to the bounds, which squeezed a drawable larger than the
        // view (the sidebar's button, Shift+Tab). Top-left is what AppKit then
        // sets: the bottom-left below, for this flipped view. (The drawable is
        // the view's size too now, see updateGrid; a frame not yet redrawn
        // for a new size is still cropped, not stretched.)
        layerContentsPlacement = .topLeft
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        guard let device = MTLCreateSystemDefaultDevice() else { throw TerminalError.libghostty("no Metal device") }
        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Three drawables: frames are drawn on demand and take about a
        // millisecond, so the queue stays empty and input latency is
        // unaffected, while a resize (which presents inside the window's
        // transaction) never has to wait for the compositor to release one.
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Pin the drawable to the top-left at 1:1 so a frame that hasn't
        // caught up with a resize is cropped or padded, never stretched.
        // (For this flipped, layer-backed view that is CA's bottom-left;
        // checked on screen with an oversized drawable.)
        layer.contentsGravity = .bottomLeft
        clipsToBounds = true
        renderer = try TerminalRenderer(device: device, fonts: FontSet(pointSize: fontSize, scale: 2))
        apply(config)
        registerForDraggedTypes([.fileURL, .string])
    }

    // MARK: Drag and drop: files (sidebar, Finder) type their quoted paths

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isReadOnly ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isReadOnly else { return false }
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            sendInput(urls.map { ShellQuote.quote($0.path) }.joined(separator: " ") + " ")
        } else if let text = pasteboard.string(forType: .string) {
            // As a paste: text that may run commands asks first (it used to go nowhere).
            if session.paste(text, allowUnsafe: false) == .needsConfirmation { confirmUnsafePaste(text) }
        } else {
            return false
        }
        window?.makeFirstResponder(self)
        return true
    }

    /// Take on new settings. The font size follows the config only when the
    /// config's size changed, so ⌘+/⌘- zoom survives unrelated edits —
    /// unless `resetFontSize` (Reload Configuration).
    func apply(_ config: Config, resetFontSize: Bool = false) {
        session.apply(config)
        let theme = config.resolvedTheme
        renderer.selectionColor = theme.selection
        renderer.ligatures = config.ligatures
        renderer.backgroundOpacity = config.backgroundOpacity
        renderer.paddingColor = config.windowPaddingColor
        renderer.minimumContrast = config.minimumContrast
        metalLayer.isOpaque = config.backgroundOpacity >= 1
        padding = config.padding
        unfocusedOpacity = config.unfocusedSplitOpacity
        dimLayer.backgroundColor = theme.background.nsColor.cgColor
        if isDimmed { dimLayer.opacity = Float(1 - unfocusedOpacity) }
        copyOnSelect = config.copyOnSelect
        optionAsAlt = config.optionAsAlt
        vsync = config.windowVsync
        updateDisplaySync()
        showsScrollbar = config.scrollbar != "never"
        scroller.isHidden = !showsScrollbar
        scroller.updateColors(dark: theme.isDark)
        hideMouseWhileTyping = config.mouseHideWhileTyping
        smoothScrolling = config.scrollSmooth
        if !smoothScrolling { setSmoothOffset(0) }

        let size = CGFloat(config.fontSize)
        let familyChanged = config.fontFamily != fontFamily || config.adjustCellHeight != cellHeightAdjust
        fontFamily = config.fontFamily
        cellHeightAdjust = config.adjustCellHeight
        if configFontSize != size || resetFontSize {
            configFontSize = size
            if fontSize != size {
                fontSize = size  // rebuilds fonts
                return setNeedsRender(force: true)
            }
        }
        if familyChanged { rebuildFonts() } else { updateGrid() }
        setNeedsRender(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    var cellSizePoints: CGSize {
        CGSize(width: CGFloat(renderer.fonts.cellWidth) / renderer.fonts.scale,
               height: CGFloat(renderer.fonts.cellHeight) / renderer.fonts.scale)
    }

    /// Content size that fits exactly `cols` × `rows` cells plus padding.
    func contentSize(cols: Int, rows: Int) -> NSSize {
        let p = padding
        return NSSize(width: CGFloat(cols) * cellSizePoints.width + p.left + p.right,
                      height: CGFloat(rows) * cellSizePoints.height + p.top + p.bottom)
    }

    // MARK: Window & display

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else {
            // Out of the window (closed, parked, another tab): it draws no
            // more, so nothing else would stop its cursor's blink — and it
            // has no keyboard, which nothing else would tell its program.
            session.reportFocusLost()
            blinkTimer?.invalidate()
            blinkTimer = nil
            renderer?.blinkOn = true
            return
        }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        // ProMotion: ask for the panel's full rate; the system clamps it.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        rebuildFonts()
    }

    /// `window-vsync`: off in a window (measured: median typing latency 8.5 ms
    /// instead of 30 at 120 Hz, 17 instead of 44 at 60 Hz; WindowServer still
    /// composites the window, so it doesn't tear), always on in full screen,
    /// where a layer can go straight to the display and could tear.
    func updateDisplaySync() {
        let sync = vsync || window?.styleMask.contains(.fullScreen) == true
        if metalLayer.displaySyncEnabled != sync { metalLayer.displaySyncEnabled = sync }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildFonts()
    }

    private func rebuildFonts() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        renderer.setFonts(FontSet(family: fontFamily, pointSize: fontSize, scale: scale, cellHeightAdjust: cellHeightAdjust))
        updateGrid()
    }

    /// The drawable at 1:1 from the top-left, cropped, never scaled to the
    /// bounds — whatever set the layer's gravity since (see init).
    private func pinContents() {
        if metalLayer.contentsGravity != .bottomLeft { metalLayer.contentsGravity = .bottomLeft }
    }

    /// The layer's gravity and how AppKit places it (`--ui-probe`).
    var contentsPlacementSummary: String {
        "placement \(layerContentsPlacement.rawValue) gravity \(metalLayer.contentsGravity.rawValue)"
    }

    /// The drawable is the view, pixel for pixel (`--ui-probe`): mapped onto
    /// the bounds, it shows as it is.
    var drawableFitsView: Bool {
        let scale = metalLayer.contentsScale
        return abs(metalLayer.drawableSize.width - bounds.width * scale) < 1 && abs(metalLayer.drawableSize.height - bounds.height * scale) < 1
    }

    /// Wake the display link; it pauses itself once frames stop changing.
    func setNeedsRender(force: Bool = false) {
        if force { forceRedraw = true }
        idleFrames = 0
        displayLink?.isPaused = false
        // Typing latency: a change that arrives after this display interval's
        // frame was drawn goes out now, not at the next tick, which would be
        // up to a frame later. Continuous output (a frame drawn this
        // interval) stays paced by the display link.
        if !metalLayer.presentsWithTransaction, window != nil,
           CACurrentMediaTime() - lastFrame >= frameInterval * 0.9 {
            immediateFrame = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.immediateFrame else { return }
                self.immediateFrame = false
                self.drawFrame()
            }
        }
    }

    private var immediateFrame = false
    private var lastFrame: CFTimeInterval = 0
    /// Drawn on screen at least once (its scale and grid are real).
    private(set) var renderedOnce = false
    private var frameInterval: CFTimeInterval {
        1 / Double(max(60, window?.screen?.maximumFramesPerSecond ?? 60))
    }

    @objc private func step(_ link: CADisplayLink) {
        if metalLayer.presentsWithTransaction, !inLiveResize, CACurrentMediaTime() - lastResize > 0.1 {
            // The resize settled: go back to presenting from the GPU queue.
            metalLayer.presentsWithTransaction = false
        }
        immediateFrame = false
        if !drawFrame() {
            idleFrames += 1
            // A quarter second without changes: stop ticking until something happens.
            if idleFrames > 30 { link.isPaused = true }
        }
    }

    /// Draw if anything changed; returns whether a frame was presented.
    @discardableResult
    private func drawFrame() -> Bool {
        pinContents()
        // Something else took the viewport to the bottom (typing, new
        // output while following): the rows line up again.
        if smoothOffset != 0, session.scrollbar.atBottom { setSmoothOffset(0) }
        let presented: Bool
        if let observer = onFramePresented {
            // Which output this frame shows, for `--latency-trace`.
            let mark = session.outputMark.count
            presented = renderer.render(session, into: metalLayer, focused: isFocused, force: forceRedraw) { time in
                DispatchQueue.main.async { observer(mark, time) }
            }
        } else {
            presented = renderer.render(session, into: metalLayer, focused: isFocused, force: forceRedraw)
        }
        forceRedraw = false
        if presented {
            idleFrames = 0
            renderedOnce = true
            lastFrame = CACurrentMediaTime()
            if showsScrollbar { scroller.update(session.scrollbar, reveal: revealScroller) }
            revealScroller = false
            updateBlinkTimer()
        }
        return presented
    }

    /// Blink only while the cursor wants to (its modes) and has focus.
    private func updateBlinkTimer() {
        let wanted = renderer.cursorBlinks && isFocused
        if wanted, blinkTimer == nil {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.renderer.blinkOn.toggle()
                self.setNeedsRender(force: true)
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !wanted, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            renderer.blinkOn = true
        }
    }

    /// Typing shows the cursor solid and restarts the blink.
    private func restartBlink() {
        guard blinkTimer != nil else { return }
        renderer.blinkOn = true
        blinkTimer?.fireDate = Date().addingTimeInterval(0.6)
    }

    private var isFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        session.setFocused(true)
        // (In a window in front only: one in the background gets it when it comes forward.)
        session.reportFocus(window?.isKeyWindow == true)
        setNeedsRender(force: true)
        onFocus?(self)
        return true
    }

    /// Called when this pane becomes the focused one in its window.
    var onFocus: ((TerminalView) -> Void)?

    /// Called (on the main thread) when a frame reaches the screen, with the
    /// session's output count it shows and the host time it was presented.
    var onFramePresented: ((UInt64, CFTimeInterval) -> Void)?

    /// The pane's × (shown on hover while its tab is split) asks to close it.
    var onRequestClose: ((TerminalView) -> Void)?
    /// Its program ended and it stayed (a quick failure, wait-after-command):
    /// the next key closes it.
    var closesOnKey = false
    /// Taken out of its split but running on (Park Pane): in no window, and a
    /// Picture in Picture of it stays.
    var isParked = false
    /// The grid got a new size (a pane header says it).
    var onGridResize: ((TerminalView) -> Void)?

    /// What a split pane runs and where ("Vim — …/src/app"), shown on hover
    /// with the ×: an unfocused split is otherwise anonymous (GoRex names
    /// every pane in a header; a tag on hover keeps the card headerless).
    var nameTag: String = "" {
        didSet { if nameTag != oldValue { updateNameTag(show: showsCloseButton && hovering) } }
    }
    private lazy var nameTagLabel: NSTextField = {
        let label = PassThroughLabel(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.wantsLayer = true
        label.drawsBackground = true
        label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        label.layer?.cornerRadius = 5
        label.isHidden = true
        addSubview(label)
        label.layer?.zPosition = 2  // above the dimming overlay, like the ×
        return label
    }()

    private func updateNameTag(show: Bool) {
        guard show, !nameTag.isEmpty else {
            if !nameTagLabel.isHidden { nameTagLabel.isHidden = true }
            return
        }
        nameTagLabel.stringValue = " \(nameTag) "
        let size = nameTagLabel.fittingSize
        nameTagLabel.frame = NSRect(x: 8, y: 9, width: min(size.width, max(0, bounds.width - 70)), height: size.height)
        nameTagLabel.isHidden = false
    }

    /// Whether hovering shows the close button: only when there are other panes.
    var showsCloseButton = false {
        didSet { updateCloseButton() }
    }
    private var hovering = false
    private lazy var closeButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")!,
                         target: self, action: #selector(closeButtonClicked(_:)))
        b.isBordered = false
        b.bezelStyle = .circular
        b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = TerminalWindowController.tip("Close Pane", .closeSurface)
        b.wantsLayer = true
        b.layer?.cornerRadius = 11
        b.isHidden = true
        b.alphaValue = 0
        addSubview(b)
        b.layer?.zPosition = 2  // above the dimming overlay
        return b
    }()

    private func updateCloseButton() {
        let show = showsCloseButton && hovering
        if show {
            updateCloseButtonColor()
            closeButton.isHidden = false
        }
        closeButton.frame = NSRect(x: bounds.width - 30, y: 8, width: 22, height: 22)
        activityDot.frame = NSRect(x: bounds.width - (show ? 52 : 21), y: show ? 13 : 10, width: 11, height: 11)
        updateNameTag(show: show)
        window?.invalidateCursorRects(for: self)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(Motion.hover)
            closeButton.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            if !show, self?.hovering == false || self?.showsCloseButton == false { self?.closeButton.isHidden = true }
        })
    }

    @objc private func closeButtonClicked(_ sender: Any?) { onRequestClose?(self) }

    /// The pane's activity dot: its program printed just now (GoRex's). It
    /// fades in and out once — it never pulses; the frames that would cost
    /// say less than the dot.
    private lazy var activityDot: NSView = {
        let v = NSView()
        v.wantsLayer = true
        let color = NSColor.controlAccentColor
        let halo = CALayer(), core = CALayer()
        halo.backgroundColor = color.withAlphaComponent(0.22).cgColor
        core.backgroundColor = color.cgColor
        halo.cornerRadius = 5.5
        core.cornerRadius = 3
        halo.frame = CGRect(x: 0, y: 0, width: 11, height: 11)
        core.frame = CGRect(x: 2.5, y: 2.5, width: 6, height: 6)
        v.layer?.addSublayer(halo)
        v.layer?.addSublayer(core)
        v.isHidden = true
        addSubview(v)
        v.layer?.zPosition = 2  // above the dimming overlay, like the ×
        return v
    }()
    private var activityFade: DispatchWorkItem?

    /// Output just arrived: show the dot, and let it fade once the program
    /// has been quiet for a moment (GoRex's 1.5 s). Every render calls
    /// this, so it does nothing at all while the dot is already up: one
    /// animation and one timer per burst of output, not per chunk.
    func noteActivity() {
        let dot = activityDot
        if dot.isHidden {
            dot.alphaValue = 0
            dot.isHidden = false
        }
        if dot.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.hover)
                dot.animator().alphaValue = 1
            }
        }
        activityFade?.cancel()
        let fade = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.duration(Motion.hover)
                self.activityDot.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Output during the fade put the dot back up: alpha says so.
                guard let self, self.activityDot.alphaValue == 0 else { return }
                self.activityDot.isHidden = true
            })
        }
        activityFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fade)
    }

    /// Picture in picture: draw the pane's current frame into another
    /// layer too (the same instances; Core Animation scales it down).
    @discardableResult
    func renderMirror(into layer: CAMetalLayer) -> Bool {
        guard renderer != nil else { return false }
        if layer.drawableSize != metalLayer.drawableSize { layer.drawableSize = metalLayer.drawableSize }
        return renderer.render(session, into: layer, focused: isFocused, force: false)
    }

    func forgetMirror(_ layer: CAMetalLayer) { renderer?.forget(layer) }

    /// The pane's drawable, for a mirror's size and look.
    var drawableSize: CGSize { metalLayer.drawableSize }
    var metalDevice: MTLDevice? { renderer?.device }

    /// What the pane shows right now, as an image (tab overview).
    func thumbnail() -> CGImage? {
        let scale = metalLayer.contentsScale
        // The next on-screen frame redraws everything (the snapshot consumed the dirty state).
        defer { setNeedsRender(force: true) }
        return renderer.snapshotImage(session, width: Int(bounds.width * scale), height: Int(bounds.height * scale))
    }

    // MARK: Halo (Tern: a ring closes in on a pane whose agent finished or needs you)

    /// Ring the pane's edge in `color`: it closes in from just outside, glows,
    /// and fades. With reduced motion it only fades.
    func flashHalo(_ color: NSColor) {
        guard let host = layer else { return }
        let ring = CALayer()
        ring.frame = host.bounds
        ring.cornerRadius = host.cornerRadius
        ring.borderWidth = 2
        ring.borderColor = color.cgColor
        ring.shadowColor = color.cgColor
        ring.shadowOpacity = 0.9
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        ring.zPosition = 3
        ring.opacity = 0
        host.addSublayer(ring)
        let duration = Motion.reduced ? 0.8 : 1.4
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.18, 0.55, 1]
        var animations: [CAAnimation] = [fade]
        if !Motion.reduced {
            let close = CABasicAnimation(keyPath: "transform.scale")
            close.fromValue = 1.06
            close.toValue = 1
            close.timingFunction = Motion.out
            close.duration = duration * 0.45
            animations.append(close)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "halo")
        CATransaction.commit()
    }

    /// A three-finger swipe (trackpad set to swipe between pages with three
    /// fingers) moves between tabs.
    override func swipe(with event: NSEvent) {
        guard event.deltaX != 0 else { return super.swipe(with: event) }
        ActionDispatcher.perform(event.deltaX > 0 ? .previousTab : .nextTab, in: self)
    }

    private final class LinkBox: NSObject {
        let link: TerminalLink
        init(_ link: TerminalLink) { self.link = link }
    }

    @objc private func openLinkItem(_ sender: NSMenuItem) {
        if let link = (sender.representedObject as? LinkBox)?.link { open(link) }
    }

    @objc private func copyLinkItem(_ sender: NSMenuItem) {
        guard let link = (sender.representedObject as? LinkBox)?.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateCloseButton()
        focusUnderPointer()
    }

    /// `focus-follows-mouse`: the keyboard comes here from another terminal
    /// pane of the window in front (its tracking area only reports there) —
    /// not from a field (the find bar, a rename), a document or an editor,
    /// not mid-drag, not to a parked pane.
    private func focusUnderPointer() {
        guard ConfigStore.shared.config.focusFollowsMouse, !isParked, let window,
              // Not while dragging. (A probe's pointer is its own, with no
              // buttons; the real mouse is the user's, doing something else.)
              window.attachedSheet == nil, Probe.running || NSEvent.pressedMouseButtons == 0,
              let current = window.firstResponder as? TerminalView, current !== self,
              // Not in the middle of composing (Pinyin…): that would be lost.
              !current.hasMarkedText() else { return }
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateCloseButton()
        if hoveredLink != nil {
            hoveredLink = nil
            renderer.linkSpans = []
            showLinkPreview(nil)
            setNeedsRender(force: true)
        }
    }

    // MARK: Context menu

    /// Right-click (unless the program takes the mouse): the pane's actions,
    /// each with its current shortcut.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !reportsMouse(event) else { return nil }
        window?.makeFirstResponder(self)
        let keybinds = ConfigStore.shared.keybinds
        let menu = NSMenu()
        func add(_ title: String, _ action: Action, symbol: String) {
            let item = menu.addItem(withTitle: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionBox(action)
            if let t = keybinds.trigger(for: action) { (item.keyEquivalent, item.keyEquivalentModifierMask) = t.menuEquivalent }
            if #available(macOS 26, *) { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        }
        if let link = link(at: event) {
            let open = menu.addItem(withTitle: "Open Link", action: #selector(openLinkItem(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = LinkBox(link)
            let copy = menu.addItem(withTitle: "Copy Link", action: #selector(copyLinkItem(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = LinkBox(link)
            if #available(macOS 26, *) {
                open.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
                copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            }
            menu.addItem(.separator())
        }
        add("Copy", .copyToClipboard, symbol: "doc.on.doc")
        add("Copy Output of Last Command", .copyCommandOutput, symbol: "text.append")
        add("Paste", .pasteFromClipboard, symbol: "doc.on.clipboard")
        menu.addItem(.separator())
        add("Split Right", .newSplit(.right), symbol: "rectangle.righthalf.inset.filled")
        add("Split Down", .newSplit(.down), symbol: "rectangle.bottomhalf.inset.filled")
        if showsCloseButton { add("Zoom Split", .toggleSplitZoom, symbol: "arrow.up.left.and.arrow.down.right") }
        add(MainActor.assumeIsolated { PictureInPicture.isShowing(self) } ? "Close Picture in Picture" : "Picture in Picture",
            .togglePictureInPicture, symbol: "pip")
        if showsCloseButton {
            add("Float Pane", .floatSurface, symbol: "pip.enter")
            add("Park Pane", .parkSurface, symbol: "tray.and.arrow.down")
            add("Move to New Tab", .moveSurfaceToNewTab, symbol: "rectangle.portrait.and.arrow.right")
            add("Move to New Window", .moveSurfaceToNewWindow, symbol: "macwindow.badge.plus")
        }
        menu.addItem(.separator())
        add("Clear Screen", .clearScreen, symbol: "eraser")
        add("Find…", .startSearch, symbol: "magnifyingglass")
        menu.addItem(.separator())
        add(showsCloseButton ? "Close Pane" : "Close Tab", .closeSurface, symbol: "xmark")
        return menu
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        ActionDispatcher.perform(action, in: self)
    }


    /// Unfocused splits dim (Otty `unfocusedSplitOpacity`); a lone pane never does.
    /// Dimming fades the contents toward the theme background with an
    /// overlay, rather than lowering the pane's opacity: with a translucent
    /// window, lower opacity would let the desktop through and make the
    /// "dimmed" pane lighter.
    func setDimmed(_ dimmed: Bool) {
        isDimmed = dimmed
        let target: Float = dimmed ? Float(1 - unfocusedOpacity) : 0
        guard dimLayer.opacity != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
        animation.toValue = target
        animation.duration = Motion.duration(Motion.hover)
        animation.timingFunction = Motion.ease
        dimLayer.opacity = target
        dimLayer.add(animation, forKey: "opacity")
    }

    /// The focused pane of a split (Tern's mark): a line in the accent color
    /// along the card's top edge, the one sign of where the keyboard is
    /// besides the others being dimmed.
    var showsFocusLine = false {
        didSet {
            guard showsFocusLine != oldValue else { return }
            focusLine.isHidden = !showsFocusLine
            layoutOverlays()
        }
    }

    // A layer's color is resolved once: follow the accent and appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if showsFocusLine { focusLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor }
        // (Asked only while it shows: asking makes the button.)
        if showsCloseButton && hovering { updateCloseButtonColor() }
    }

    /// The × button's disc, in the appearance the pane has now.
    private func updateCloseButtonColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            closeButton.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        }
    }

    /// A view, placed in the view's own (flipped) coordinates: a sublayer
    /// of the Metal layer would need its flip worked out.
    private lazy var focusLine: NSView = {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        line.layer?.zPosition = 2
        line.isHidden = true
        addSubview(line)
        return line
    }()

    /// Sits over the Metal content, under the close button.
    private lazy var dimLayer: CALayer = {
        let l = CALayer()
        l.opacity = 0
        l.zPosition = 1
        l.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        metalLayer.addSublayer(l)
        return l
    }()

    private func layoutOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = metalLayer.bounds
        CATransaction.commit()
        if showsFocusLine { focusLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1) }
        if showsCloseButton { closeButton.frame = NSRect(x: bounds.width - 30, y: 8, width: 22, height: 22) }
        activityDot.frame = NSRect(x: bounds.width - (showsCloseButton && hovering ? 52 : 21), y: showsCloseButton && hovering ? 13 : 10,
                                   width: 11, height: 11)
        updateNameTag(show: showsCloseButton && hovering)
        // The scrollbar runs along the right edge, below the close button.
        let top: CGFloat = showsCloseButton ? 34 : 0
        scroller.frame = NSRect(x: bounds.width - 16, y: top, width: 16, height: max(0, bounds.height - top))
        if session.host != nil { layoutLinkBanner() }
    }

    override func resignFirstResponder() -> Bool {
        session.reportFocus(false)
        setNeedsRender(force: true)
        return true
    }

    // MARK: Layout

    /// Every size change (window edge, divider drag, split animation) draws
    /// right away and presents inside the Core Animation transaction that
    /// moves the edge, so the grid never stretches or trails behind it.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Frozen: sized for a moment only (see `freeze`).
        guard freezes == 0 else { return }
        layoutOverlays()
        let stale = updateGrid()
        // Same grid and drawable (the same size in pixels): the frame on
        // screen is still right, so skip the draw.
        guard changed, stale, window != nil, renderer != nil else { return }
        metalLayer.presentsWithTransaction = true
        lastResize = CACurrentMediaTime()
        resizeFrames += 1
        pinContents()
        renderer.render(session, into: metalLayer, focused: isFocused, force: true)
        // This was the display link's frame too: drawing it twice would hold
        // every drawable and stall the next step for up to a second.
        forceRedraw = false
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        setNeedsRender(force: true)
    }

    /// A column of the window (the sidebar, the inspector) comes or goes: the
    /// grid stays as it is meanwhile — the edge uncovers background or clips
    /// the last columns — and fits the view again when the last hold lets go.
    /// Reflowing at every frame of a slide redrew everything each frame and
    /// had the shell redraw its prompt mid-way: the content jumped.
    /// How many hold it (slides may overlap: a second toggle mid-way).
    private var gridHolds = 0
    private var holdsGrid: Bool { gridHolds > 0 }

    func holdGrid() { gridHolds += 1 }

    /// The last hold let go: the grid fits the view again.
    func releaseGrid() {
        gridHolds = max(0, gridHolds - 1)
        if gridHolds == 0 { updateGrid() }
    }
    /// How many grid changes the pane has made (`--ui-probe` counts a slide's).
    private(set) var regridCount = 0
    /// How many frames it drew inside a resize's transaction (`--ui-probe`).
    private(set) var resizeFrames = 0

    /// A column of the window comes or goes and the window takes its width
    /// at once (the sidebar's button): the view is laid out at a passing
    /// size and back to its own within one step. Frozen, it neither fits its
    /// grid and drawable nor draws meanwhile, and the frame on screen stays
    /// — its own size's. Drawn there, two frames at two drawable sizes in
    /// one transaction left the last shown scaled down (to about 90%) until
    /// the next frame, up to the cursor's next blink: the text seemed to
    /// shrink and grow back each time the sidebar came or went.
    private var freezes = 0

    func freeze() { freezes += 1 }

    /// The last freeze let go: fit the size it ends at (and draw, only if
    /// that isn't the size it had).
    func thaw() {
        freezes = max(0, freezes - 1)
        guard freezes == 0 else { return }
        layoutOverlays()
        updateGrid()
    }

    /// Fit the grid and drawable to the view. Returns whether either changed,
    /// i.e. whether what is on screen is now out of date.
    @discardableResult
    private func updateGrid() -> Bool {
        // A parked pane shrinking out of its split keeps the grid it had: the
        // program never learns it was put away.
        guard renderer != nil, !isParked else { return false }
        let scale = metalLayer.contentsScale
        let fonts = renderer.fonts
        let p = padding
        let usableW = (bounds.width - p.left - p.right) * scale
        let usableH = (bounds.height - p.top - p.bottom) * scale
        // Before the first layout the view has no size yet; reporting a 1×1
        // grid would reach programs that start immediately (`stty size`).
        guard usableW >= CGFloat(fonts.cellWidth), usableH >= CGFloat(fonts.cellHeight) else { return false }
        // Exactly the view, in pixels (as Ghostty's). A larger drawable (it
        // grew in 256 px steps, to keep one size through a resize) is pinned
        // top-left by the layer's gravity — but not where the window server
        // maps the contents onto the bounds whatever the gravity says: a window
        // brought back (Stage Manager, the Dock) showed its last frame so,
        // squeezed to about 90% × 70%, until the next frame. At the view's
        // own size, mapped onto the bounds is as it is.
        let largest = CGFloat(metalLayer.device?.supportsFamily(.apple3) == true ? 16384 : 8192)
        let drawable = CGSize(width: min(largest, max(1, (bounds.width * scale).rounded())),
                              height: min(largest, max(1, (bounds.height * scale).rounded())))
        var changed = false
        if metalLayer.drawableSize != drawable {
            metalLayer.drawableSize = drawable
            changed = true
        }

        let cols = Int(usableW) / fonts.cellWidth
        let rows = Int(usableH) / fonts.cellHeight
        let origin = SIMD2(Float((p.left * scale).rounded()), Float((p.top * scale).rounded()))
        if renderer.origin != origin {
            renderer.origin = origin
            changed = true
        }

        let grid = holdsGrid ? session.size : GridSize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
                                                       widthPx: UInt16(clamping: cols * fonts.cellWidth),
                                                       heightPx: UInt16(clamping: rows * fonts.cellHeight))
        let regrid = grid != session.size
        if regrid { regridCount += 1 }
        if regrid { changed = true }
        session.resize(to: grid, cellWidthPx: UInt32(fonts.cellWidth), cellHeightPx: UInt32(fonts.cellHeight))
        if regrid { onGridResize?(self) }
        if changed {
            // A new grid (or font) starts at a row edge.
            setSmoothOffset(0)
            setNeedsRender(force: true)
        }
        return changed
    }

    // MARK: Keyboard

    /// Keybinds come first, so a bound key never reaches the program (unless
    /// it is bound to `unbind`, i.e. not bound). Command combinations arrive
    /// here; others are checked at the top of `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, !hasMarkedText(),
              let action = ConfigStore.shared.keybinds.action(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        return ActionDispatcher.perform(action, in: self)
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let action = ConfigStore.shared.keybinds.action(for: event),
           ActionDispatcher.perform(action, in: self) {
            return
        }
        // Its program ended and it stayed: a key (pressed now, not one held
        // from before) closes it, and goes nowhere else.
        if closesOnKey {
            if !event.isARepeat, !event.modifierFlags.contains(.command) { onRequestClose?(self) }
            return
        }
        if hideMouseWhileTyping { NSCursor.setHiddenUntilMouseMoves(true) }
        restartBlink()
        let hadMarkedText = hasMarkedText()
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Let the input method see the key first: it may compose (Pinyin,
        // Kana, dead keys) or commit text. With Option as Alt it sees the key
        // without Option, so ⌥F types "f" and is sent as Alt+F (ESC f).
        let translation = optionIsAlt(event.modifierFlags) ? Self.withoutOption(event) : event
        interpretKeyEvents([translation])

        let committed = keyTextAccumulator ?? []
        if hadMarkedText || hasMarkedText() {
            // The input method had the key. What it committed is the input —
            // also when the same key starts the next composition (Korean
            // commits each syllable so; Japanese, typing on after a conversion).
            // Nothing committed: it only edited or cancelled the composition.
            if !committed.isEmpty, !isReadOnly {
                committed.forEach(session.sendText)
                broadcastPeers?().forEach { peer in committed.forEach(peer.session.sendText) }
            }
            setNeedsRender()
            return
        }
        // Nothing inserted (Ctrl+letter goes to doCommand, not insertText):
        // the key's own character on this layout, so Ctrl+A on AZERTY is ^A,
        // not the US key's ^Q (Ghostty's `ghosttyCharacters`).
        let text = committed.isEmpty ? Self.keyText(translation) : committed.joined()
        send(event, action: event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS, text: text,
             translationFlags: translation.modifierFlags)
    }

    /// What a key types for the encoder: its characters, a control
    /// character's without Control (the encoder makes the control code),
    /// none for a function key (AppKit's private-use range).
    private static func keyText(_ event: NSEvent) -> String? {
        guard event.type == .keyDown || event.type == .keyUp, let characters = event.characters else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    override func keyUp(with event: NSEvent) {
        // Only produces output when the program enabled kitty release events.
        send(event, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        modifiersChangedForLinks(event)
        guard let key = ghosttyKeyForKeyCode[event.keyCode] else { return }
        let flag: NSEvent.ModifierFlags = switch key {
        case GHOSTTY_KEY_SHIFT_LEFT, GHOSTTY_KEY_SHIFT_RIGHT: .shift
        case GHOSTTY_KEY_CONTROL_LEFT, GHOSTTY_KEY_CONTROL_RIGHT: .control
        case GHOSTTY_KEY_ALT_LEFT, GHOSTTY_KEY_ALT_RIGHT: .option
        case GHOSTTY_KEY_META_LEFT, GHOSTTY_KEY_META_RIGHT: .command
        default: []
        }
        guard !flag.isEmpty, !hasMarkedText() else { return }
        let pressed = event.modifierFlags.contains(flag)
        send(event, action: pressed ? GHOSTTY_KEY_ACTION_PRESS : GHOSTTY_KEY_ACTION_RELEASE, text: nil)
    }

    /// `translationFlags`: the modifiers the key's text was made with
    /// (Option left out when it acts as Alt).
    private func send(_ event: NSEvent, action: GhosttyKeyAction, text: String?,
                      translationFlags: NSEvent.ModifierFlags? = nil) {
        guard !isReadOnly else { return }
        let key = ghosttyKeyForKeyCode[event.keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
        // (A modifier's own event has no characters: asking raises an exception.)
        let unshifted = event.type == .keyDown || event.type == .keyUp
            ? event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0 : 0
        // Control characters are the encoder's job (from key + mods); only pass printable text.
        let printable = text.flatMap { t in
            t.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
                ? t : nil
        }
        let input = TerminalSession.Key(
            // Consumed: the modifiers that made the text (Option for German's
            // @, Shift for !). Control and Command never do.
            action: action, key: key, mods: Self.mods(event.modifierFlags),
            consumedMods: Self.mods((translationFlags ?? event.modifierFlags).subtracting([.control, .command])),
            text: printable, unshiftedCodepoint: unshifted, composing: false)
        let sent = session.send(input)
        // Broadcast Input: the same key, encoded for each pane's own modes.
        if let peers = broadcastPeers?() {
            for peer in peers where !peer.isReadOnly && peer.session.send(input) { peer.setNeedsRender() }
        }
        if sent {
            // Typing replaces the selection's relevance (Otty `selection_clear_on_typing`).
            if action != GHOSTTY_KEY_ACTION_RELEASE { session.clearSelection() }
            setNeedsRender(force: action != GHOSTTY_KEY_ACTION_RELEASE)
        }
    }

    /// Whether this press's Option key acts as Alt (`macos-option-as-alt`).
    private func optionIsAlt(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.option) else { return false }
        // Device-dependent bits tell the two Option keys apart.
        let left = flags.rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        let right = flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        switch optionAsAlt {
        case .false: return false
        case .true: return true
        case .left: return left
        case .right: return right
        }
    }

    private static func withoutOption(_ event: NSEvent) -> NSEvent {
        let flags = event.modifierFlags.subtracting(.option)
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var m: GhosttyMods = 0
        if flags.contains(.shift) { m |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { m |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { m |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { m |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { m |= GhosttyMods(GHOSTTY_MODS_CAPS_LOCK) }
        // Which side: the right one (`macos-option-as-alt = right` needs it).
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GhosttyMods(GHOSTTY_MODS_SHIFT_SIDE) }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GhosttyMods(GHOSTTY_MODS_CTRL_SIDE) }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GhosttyMods(GHOSTTY_MODS_ALT_SIDE) }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GhosttyMods(GHOSTTY_MODS_SUPER_SIDE) }
        return m
    }

    /// Keys AppKit maps to commands (arrows, return, ...) are encoded by
    /// `keyDown`; swallow the selector so AppKit doesn't beep.
    override func doCommand(by selector: Selector) {}

    // MARK: Actions

    /// Its text size, cell, layer scale and gravity, drawable and bounds (`--ui-probe`).
    var metricsSummary: String {
        let f = renderer.fonts
        let regrids = Probe.running ? " regrids \(regridCount)" : ""
        return "font \(fontSize)pt \(f.familyName) cell \(f.cellWidth)x\(f.cellHeight)px scale \(f.scale) "
            + "layer \(metalLayer.contentsScale) gravity \(metalLayer.contentsGravity.rawValue) "
            + "drawable \(Int(metalLayer.drawableSize.width))x\(Int(metalLayer.drawableSize.height)) "
            + "bounds \(Int(bounds.width))x\(Int(bounds.height)) grid \(session.size.cols)x\(session.size.rows)" + regrids
    }

    /// The background its theme gives it, "#rrggbb" (`--ui-probe`).
    var backgroundHex: String {
        guard let color = dimLayer.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    func adjustFontSize(by delta: Double) {
        fontSize = min(72, max(6, fontSize + CGFloat(delta)))
    }

    func resetFontSize() {
        fontSize = configFontSize ?? 13
    }

    func clearScreen() {
        session.clearScreen()
        setNeedsRender(force: true)
    }

    func scroll(_ body: (TerminalSession) -> Void) {
        body(session)
        revealScroller = true
        setNeedsRender()
    }

    /// Bytes from a `text:`/`csi:`/`esc:` keybind, straight to the program.
    func sendInput(_ text: String) {
        guard !isReadOnly else { return }
        session.sendText(text)
        setNeedsRender()
    }

    // MARK: Edit menu

    /// Plain text, plus HTML with the colors for apps that paste rich text
    /// (Ghostty's copy_to_clipboard:mixed).
    @objc func copy(_ sender: Any?) {
        guard let text = session.selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let html = session.selectedHTML() { NSPasteboard.general.setString(html, forType: .html) }
    }

    override func selectAll(_ sender: Any?) {
        session.selectAll()
        setNeedsRender(force: true)
    }

    // MARK: Mouse: reporting to programs, or selection

    private var pressedButtons = Set<Int>()

    /// Programs that track the mouse get the events; Shift bypasses them so
    /// text can still be selected (Otty's default bypass modifier).
    private func reportsMouse(_ event: NSEvent) -> Bool {
        !isReadOnly && !event.modifierFlags.contains(.shift) && session.isMouseTracking
    }

    private func report(_ event: NSEvent, _ action: GhosttyMouseAction, button: GhosttyMouseButton?) {
        let p = convert(event.locationInWindow, from: nil)
        let scale = metalLayer.contentsScale
        let pad = padding
        let fonts = renderer.fonts
        var surface = GhosttyMouseEncoderSize()
        surface.screen_width = UInt32(bounds.width * scale)
        surface.screen_height = UInt32(bounds.height * scale)
        surface.cell_width = UInt32(fonts.cellWidth)
        surface.cell_height = UInt32(fonts.cellHeight)
        surface.padding_left = UInt32(pad.left * scale)
        surface.padding_top = UInt32(pad.top * scale)
        surface.padding_right = UInt32(pad.right * scale)
        surface.padding_bottom = UInt32(pad.bottom * scale)
        session.sendMouse(.init(action: action, button: button, mods: Self.mods(event.modifierFlags),
                                positionPx: CGPoint(x: p.x * scale, y: p.y * scale),
                                anyButtonPressed: !pressedButtons.isEmpty, surface: surface))
    }

    private static func button(_ event: NSEvent) -> GhosttyMouseButton {
        switch event.buttonNumber {
        case 0: GHOSTTY_MOUSE_BUTTON_LEFT
        case 1: GHOSTTY_MOUSE_BUTTON_RIGHT
        case 2: GHOSTTY_MOUSE_BUTTON_MIDDLE
        default: GHOSTTY_MOUSE_BUTTON_UNKNOWN
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⌘-click opens a link, even in programs that track the mouse.
        if event.modifierFlags.contains(.command), let link = link(at: event) {
            open(link)
            return
        }
        if reportsMouse(event) {
            pressedButtons.insert(event.buttonNumber)
            report(event, GHOSTTY_MOUSE_ACTION_PRESS, button: Self.button(event))
            return
        }
        // Shift-click grows the selection to here (Shift also bypasses mouse reporting).
        if event.modifierFlags.contains(.shift), event.clickCount == 1, session.extendSelection(to: pointer(for: event)) {
            extendingSelection = true
            setNeedsRender(force: true)
            return
        }
        session.selectionGesture(.press, pointer(for: event))
        setNeedsRender(force: true)
    }

    override func mouseDragged(with event: NSEvent) {
        // What the press was decides the whole drag: Shift let go before the
        // button doesn't hand the rest of a selection to the program.
        if pressedButtons.contains(event.buttonNumber) {
            report(event, GHOSTTY_MOUSE_ACTION_MOTION, button: Self.button(event))
            return
        }
        if extendingSelection {
            _ = session.extendSelection(to: pointer(for: event))
            return setNeedsRender(force: true)
        }
        // ⌥-drag selects a rectangle (columns), as in Ghostty and Terminal.
        let direction = session.selectionGesture(.drag, pointer(for: event), rectangle: event.modifierFlags.contains(.option))
        autoscroll(direction, event)
        setNeedsRender(force: true)
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        if pressedButtons.remove(event.buttonNumber) != nil {
            report(event, GHOSTTY_MOUSE_ACTION_RELEASE, button: Self.button(event))
            return
        }
        if extendingSelection {
            extendingSelection = false
            if copyOnSelect { copy(nil) }
            return
        }
        session.selectionGesture(.release, pointer(for: event))
        setNeedsRender(force: true)
        if copyOnSelect { copy(nil) }
    }

    // MARK: Selection autoscroll (dragging past the top or bottom)

    private var extendingSelection = false
    private var autoscrollTimer: Timer?
    private var autoscrollDirection = TerminalSession.Autoscroll.none
    private var lastDrag: NSEvent?

    private func autoscroll(_ direction: TerminalSession.Autoscroll, _ event: NSEvent) {
        lastDrag = event
        autoscrollDirection = direction
        guard direction != .none else { return stopAutoscroll() }
        guard autoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.autoscrollTick() }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func autoscrollTick() {
        guard let event = lastDrag, autoscrollDirection != .none else { return stopAutoscroll() }
        // Faster the further past the edge the pointer is.
        let p = convert(event.locationInWindow, from: nil)
        let past = autoscrollDirection == .up ? -p.y : p.y - bounds.height
        let rows = max(1, min(8, Int(past / max(1, cellSizePoints.height)) + 1))
        session.selectionAutoscroll(autoscrollDirection, rows: rows, pointer(for: event),
                                    rectangle: event.modifierFlags.contains(.option))
        setNeedsRender(force: true)
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        autoscrollDirection = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        // Not reported to the program: AppKit shows `menu(for:)`.
        guard reportsMouse(event) else { return super.rightMouseDown(with: event) }
        pressedButtons.insert(event.buttonNumber)
        report(event, GHOSTTY_MOUSE_ACTION_PRESS, button: Self.button(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard pressedButtons.remove(event.buttonNumber) != nil else { return super.rightMouseUp(with: event) }
        report(event, GHOSTTY_MOUSE_ACTION_RELEASE, button: Self.button(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard reportsMouse(event) else { return }
        pressedButtons.insert(event.buttonNumber)
        report(event, GHOSTTY_MOUSE_ACTION_PRESS, button: Self.button(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard pressedButtons.remove(event.buttonNumber) != nil else { return }
        report(event, GHOSTTY_MOUSE_ACTION_RELEASE, button: Self.button(event))
    }

    override func rightMouseDragged(with event: NSEvent) { mouseMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMotion(event) }
    override func mouseMoved(with event: NSEvent) {
        mouseMotion(event)
        focusUnderPointer()  // back from a dialog or another app, the pointer already over it
    }

    /// Hover and non-left drags matter only to programs tracking the mouse;
    /// the encoder drops motion the program's mode didn't ask for.
    private func mouseMotion(_ event: NSEvent) {
        updateHoveredLink(event)
        guard reportsMouse(event) else { return }
        report(event, GHOSTTY_MOUSE_ACTION_MOTION, button: pressedButtons.isEmpty ? nil : Self.button(event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self, userInfo: nil))
    }

    // MARK: Links (⌘-hover underlines, ⌘-click opens)

    private var hoveredLink: TerminalLink?

    private func cell(at event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let cell = cellSizePoints, pad = padding
        return (Int(floor((p.x - pad.left) / cell.width)), Int(floor((p.y - pad.top + smoothOffset) / cell.height)))
    }

    private func link(at event: NSEvent) -> TerminalLink? {
        let (col, row) = cell(at: event)
        return session.link(atCol: col, row: row)
    }

    /// Pressing or releasing ⌘ over a link shows or hides it without a move.
    private func modifiersChangedForLinks(_ event: NSEvent) {
        guard let window, window.isKeyWindow else { return }
        let location = window.mouseLocationOutsideOfEventStream
        guard bounds.contains(convert(location, from: nil)),
              let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: event.modifierFlags,
                                             timestamp: event.timestamp, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        updateHoveredLink(moved)
    }

    private func updateHoveredLink(_ event: NSEvent) {
        let link = event.modifierFlags.contains(.command) ? link(at: event) : nil
        guard link != hoveredLink else { return }
        hoveredLink = link
        renderer.linkSpans = link?.spans ?? []
        if link != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
        showLinkPreview(link)
        setNeedsRender(force: true)
    }

    // MARK: Link to a host

    /// "Reconnecting to host…" over a pane whose host is out of reach (shown
    /// after a moment, so a quick connect doesn't flash it).
    private lazy var linkBanner: NSView = {
        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.tag = 1
        // Why it can't connect, from ssh, and a way to try again.
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 360
        detail.tag = 2
        detail.isHidden = true
        let retry = NSButton(title: "Try Again", target: self, action: #selector(retryLink(_:)))
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.tag = 3
        retry.isHidden = true
        let texts = NSStackView(views: [label, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let stack = NSStackView(views: [spinner, texts, retry])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor), stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor), stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        pill.isHidden = true
        pill.alphaValue = 0
        addSubview(pill)
        pill.layer?.zPosition = 3
        return pill
    }()
    private var linkBannerWork: DispatchWorkItem?

    func updateLinkBanner() {
        linkBannerWork?.cancel()
        guard !session.linkUp else {
            guard !linkBanner.isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.duration(Motion.hover)
                linkBanner.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.session.linkUp != false { self?.linkBanner.isHidden = true }
            })
            return
        }
        // Shown only if the link stays down a moment: a newer liberttyd
        // taking over is over before anyone would read it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.session.linkUp else { return }
            if let host = self.session.host { self.fillLinkBanner(host) } else { self.fillLocalBanner() }
            self.layoutLinkBanner()
            self.linkBanner.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.hover)
                self.linkBanner.animator().alphaValue = 1
            }
        }
        linkBannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// This Mac's liberttyd went away (it crashed, or was killed): the
    /// program may still be running in a new one or may be gone; the window
    /// keeps trying for a while (GoRex's "Lost the connection").
    private func fillLocalBanner() {
        (linkBanner.viewWithTag(1) as? NSTextField)?.stringValue = "Lost the connection to the session server — reconnecting…"
        if let detail = linkBanner.viewWithTag(2) as? NSTextField {
            detail.stringValue = "What you type isn't sent until it's back."
            detail.isHidden = false
        }
        linkBanner.viewWithTag(3)?.isHidden = true
    }

    private var linkBannerTimer: Timer?

    /// What the banner says (refreshed while it shows: ssh's answer comes later).
    private func fillLinkBanner(_ host: RemoteHost) {
        let stuck = host.needsUser
        (linkBanner.viewWithTag(1) as? NSTextField)?.stringValue = stuck ? "Can't connect to \(host.destination)"
            : session.hasConnectedOnce ? "Reconnecting to \(host.destination)…" : "Connecting to \(host.destination)…"
        let why = (host.lastError as? LocalizedError)?.errorDescription ?? host.lastError.map { "\($0)" }
        if let detail = linkBanner.viewWithTag(2) as? NSTextField {
            detail.stringValue = why ?? ""
            detail.isHidden = why == nil
        }
        linkBanner.viewWithTag(3)?.isHidden = !stuck
        if linkBannerTimer == nil {
            linkBannerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, let host = self.session.host, !self.session.linkUp else {
                    timer.invalidate()
                    self?.linkBannerTimer = nil
                    return
                }
                self.fillLinkBanner(host)
                self.layoutLinkBanner()
            }
        }
    }

    @objc private func retryLink(_ sender: Any?) {
        guard let host = session.host else { return }
        host.retry()
        fillLinkBanner(host)
        layoutLinkBanner()
    }

    private func layoutLinkBanner() {
        guard !linkBanner.isHidden || linkBannerWork != nil else { return }
        let size = linkBanner.fittingSize
        linkBanner.frame = NSRect(x: (bounds.width - size.width) / 2, y: 12, width: size.width, height: size.height)
    }

    /// Where a link goes, at the pane's bottom left (as a browser shows it):
    /// a program's OSC 8 link may say one thing and point elsewhere.
    private lazy var linkPreview: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.wantsLayer = true
        label.drawsBackground = true
        label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        label.layer?.cornerRadius = 5
        label.isHidden = true
        addSubview(label)
        label.layer?.zPosition = 2
        return label
    }()

    private func showLinkPreview(_ link: TerminalLink?) {
        guard let link else { linkPreview.isHidden = true; return }
        linkPreview.stringValue = " " + link.url + " "
        let size = linkPreview.fittingSize
        linkPreview.frame = NSRect(x: 6, y: bounds.height - size.height - 6,
                                   width: min(size.width, bounds.width - 12), height: size.height)
        linkPreview.isHidden = false
    }

    /// Web and mail links go to their apps; text files open in Libertty; a
    /// program's link with any other scheme asks first.
    private func open(_ link: TerminalLink) {
        hoveredLink = nil
        renderer.linkSpans = []
        showLinkPreview(nil)
        setNeedsRender(force: true)
        guard let url = URL(string: link.url) ?? URL(string: link.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased() else { return NSSound.beep() }
        if scheme == "file" {
            // OSC 8 file links carry a hostname: only this machine's open.
            if let host = url.host, !host.isEmpty, host != "localhost",
               TerminalSession.path(fromPwd: "file://\(host)/") == nil { return NSSound.beep() }
            // ⌥⌘-click: beside the terminal instead of in a tab.
            if DocumentView.canShow(url), let onOpenDocument {
                return onOpenDocument(url, link.line, NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            }
            NSWorkspace.shared.open(url)
            return
        }
        if ["http", "https"].contains(scheme), NSApp.currentEvent?.modifierFlags.contains(.option) == true, let onOpenDocument {
            // ⌥⌘-click: the page beside the terminal (a dev server next to its log).
            return onOpenDocument(url, nil, true)
        }
        if ["http", "https", "mailto", "ftp"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = link.url
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// Opens a text file from a link in a tab (or beside the pane), at a line if given (set by the window).
    var onOpenDocument: ((URL, Int?, Bool) -> Void)?

    private func pointer(for event: NSEvent) -> TerminalSession.Pointer {
        let p = convert(event.locationInWindow, from: nil)
        let cell = cellSizePoints
        let pad = padding
        let scale = metalLayer.contentsScale
        return .init(col: Int(floor((p.x - pad.left) / cell.width)),
                     row: Int(floor((p.y - pad.top + smoothOffset) / cell.height)),
                     positionPx: CGPoint(x: p.x * scale, y: (p.y + smoothOffset) * scale),
                     cellWidthPx: renderer.fonts.cellWidth,
                     paddingLeftPx: Int(pad.left * scale),
                     surfaceHeightPx: Int(bounds.height * scale))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
        // The close button is a control, not text: the normal arrow there.
        if showsCloseButton, !closeButton.isHidden { addCursorRect(closeButton.frame, cursor: .arrow) }
    }

    @objc func paste(_ sender: Any?) {
        guard !isReadOnly, let text = NSPasteboard.general.string(forType: .string) else { return }
        switch session.paste(text, allowUnsafe: false) {
        case .needsConfirmation:
            confirmUnsafePaste(text)
        case .pasted:
            setNeedsRender()
        case .nothing:
            break
        }
    }

    private func confirmUnsafePaste(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Paste text that may run commands?"
        let lines = text.split(whereSeparator: \.isNewline).count
        alert.informativeText = "The clipboard has \(lines) line\(lines == 1 ? "" : "s"). "
            + "Pasting it may run each line as a command."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            _ = self.session.paste(text, allowUnsafe: true)
            self.setNeedsRender()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(contextAction(_:)), let action = (item.representedObject as? ActionBox)?.action {
            switch action {
            case .copyToClipboard: return session.selectedText()?.isEmpty == false
            case .pasteFromClipboard: return !isReadOnly && NSPasteboard.general.string(forType: .string) != nil
            default: return true
            }
        }
        if item.action == #selector(paste(_:)) {
            return NSPasteboard.general.string(forType: .string) != nil
        }
        if item.action == #selector(copy(_:)) {
            return session.selectedText() != nil
        }
        return true
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let rowHeight = cellSizePoints.height
        if smoothScrolling, event.hasPreciseScrollingDeltas, !reportsMouse(event), !session.isAlternateScreen {
            return smoothScroll(by: event.scrollingDeltaY, rowHeight: rowHeight)
        }
        let rows: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad: follow the fingers directly, no added easing.
            scrollRemainder += event.scrollingDeltaY
            rows = Int((scrollRemainder / rowHeight).rounded(.towardZero))
            scrollRemainder -= CGFloat(rows) * rowHeight
        } else {
            rows = Int(event.scrollingDeltaY.rounded()) * 3
        }
        guard rows != 0 else { return }

        if reportsMouse(event) {
            // Wheel up/down are buttons 4/5, one press per row.
            let button = rows > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
            for _ in 0..<abs(rows) { report(event, GHOSTTY_MOUSE_ACTION_PRESS, button: button) }
            return
        }
        if session.isAlternateScreen, !isReadOnly {
            // Full-screen programs without mouse tracking (less, man): the
            // wheel scrolls their content via arrow keys, as alternate scroll mode does.
            let key = rows > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN
            for _ in 0..<abs(rows) {
                session.send(.init(action: GHOSTTY_KEY_ACTION_PRESS, key: key, mods: 0, consumedMods: 0,
                                   text: nil, unshiftedCodepoint: 0, composing: false))
            }
            return
        }
        session.scroll(rows: -rows)
        revealScroller = true
        setNeedsRender()
    }

    /// A trackpad moves the content by points: whole rows scroll the
    /// viewport, the rest moves the picture (the renderer shows the row
    /// below peeking in). The ends of the history stop it at a row edge.
    private func smoothScroll(by delta: CGFloat, rowHeight: CGFloat) {
        guard rowHeight > 0 else { return }
        var position = smoothOffset - delta
        let rows = Int(floor(position / rowHeight))
        position -= CGFloat(rows) * rowHeight
        if rows != 0 {
            let before = session.scrollbar.offset
            session.scroll(rows: rows)
            if Int64(session.scrollbar.offset) - Int64(before) != Int64(rows) { position = 0 }
            revealScroller = true
        }
        if session.scrollbar.atBottom { position = 0 }
        setSmoothOffset(position)
        setNeedsRender()
    }

    private func setSmoothOffset(_ points: CGFloat) {
        smoothOffset = points
        renderer?.pixelOffset = Float(points * metalLayer.contentsScale)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            // Text not tied to a key event (e.g. emoji picker, dictation).
            if !isReadOnly {
                session.sendText(text)
                broadcastPeers?().forEach { $0.session.sendText(text) }
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: s)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        renderer.preedit = markedText.string
        setNeedsRender(force: true)
    }

    func unmarkText() {
        markedText.mutableString.setString("")
        if !renderer.preedit.isEmpty {
            renderer.preedit = ""
            setNeedsRender(force: true)
        }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the IME candidate window goes: at the terminal cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let cell = cellSizePoints
        let p = padding
        let pos = session.cursorPosition
        let local = NSRect(x: p.left + CGFloat(pos.x) * cell.width, y: p.top + CGFloat(pos.y) * cell.height - smoothOffset,
                           width: cell.width, height: cell.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

/// A label over the terminal that clicks go through: the pane under it
/// takes them (focus, selection, a program's mouse), as if it weren't there.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
