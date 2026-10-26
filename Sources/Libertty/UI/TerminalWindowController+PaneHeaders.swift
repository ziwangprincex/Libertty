import AppKit
import LiberttyCore

/// Pane headers (`pane-headers`): what they show, what their buttons do, dragging a pane by one.
extension TerminalWindowController: PaneHeaderSource {
    func headerInfo(for leaf: NSView) -> PaneHeader.Info {
        let tab = everyTab.first { $0.container?.views.contains { $0 === leaf } == true }
        let focused = tab.map { leaf === $0.focusedLeaf } ?? false
        let split = (tab?.container?.views.count ?? 0) > 1
        if let pane = leaf as? TerminalView {
            let label = label(of: pane)
            let size = "\(pane.session.size.cols)×\(pane.session.size.rows)"
            let directory = Self.shortDirectory(pane.session.workingDirectory)
            // At a prompt the label is the folder: the header names it by its
            // last part, then says where it is (Tern's "cwd  libertty-test/…/cwd").
            var name = label.name, detail = label.detail.isEmpty ? directory : label.detail
            if label.detail.isEmpty, label.name == directory, let path = pane.session.workingDirectory {
                name = path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
            }
            return PaneHeader.Info(name: name, detail: detail, size: size, focused: focused,
                                   marked: split && focused, floats: true, parks: split)
        }
        if let doc = leaf as? DocumentView {
            let folder = doc.url.isFileURL ? Self.shortDirectory(doc.url.deletingLastPathComponent().path) : (doc.url.host ?? "")
            return PaneHeader.Info(name: doc.title, detail: folder, focused: focused, marked: split && focused, floats: false)
        }
        return PaneHeader.Info(name: "", detail: "")
    }

    func header(_ action: PaneHeader.Action, for leaf: NSView) {
        guard let tab = everyTab.first(where: { $0.container?.views.contains { $0 === leaf } == true }) else { return }
        switch action {
        case .focus:
            reveal(leaf, in: tab)
        case .zoom:
            reveal(leaf, in: tab)
            toggleZoom()
        case .pictureInPicture:
            if let pane = leaf as? TerminalView { floatPane(pane) }
        case .park:
            reveal(leaf, in: tab)
            parkFocusedPane()
        case .close:
            if let doc = leaf as? DocumentView { return closeDocumentPane(doc) }
            guard let pane = leaf as? TerminalView else { return }
            closeTerminalPane(pane)
        }
    }

    /// Move `leaf` by dragging it (its grip or header; `event` started it):
    /// onto another pane of its split, it goes beside that one, on the side
    /// the pointer is nearest, or in its middle trades places with it;
    /// dropped outside the window, a terminal gets a window of its own. The
    /// place it would take is lit meanwhile; Esc lets go of it as it was.
    func dragPane(_ leaf: NSView, from event: NSEvent) {
        guard let window, let content = window.contentView,
              let tab = everyTab.first(where: { $0.container?.views.contains { $0 === leaf } == true }),
              let container = tab.container, container.views.count > 1 || leaf is TerminalView else { return }
        reveal(leaf, in: tab)
        let lit = NSView()
        lit.wantsLayer = true
        lit.layer?.cornerRadius = Radius.pane
        lit.layer?.cornerCurve = .continuous
        lit.layer?.backgroundColor = Accent.color.withAlphaComponent(0.18).cgColor
        lit.layer?.borderColor = Accent.color.withAlphaComponent(0.8).cgColor
        lit.layer?.borderWidth = 2
        lit.isHidden = true
        container.addSubview(lit, positioned: .above, relativeTo: nil)
        defer { lit.removeFromSuperview() }
        var drop: SplitContainerView.Drop?
        var outside = false, cancelled = false
        func follow(_ e: NSEvent) {
            outside = !content.bounds.contains(content.convert(e.locationInWindow, from: nil))
            drop = outside ? nil : container.drop(at: container.convert(e.locationInWindow, from: nil), dragging: leaf)
            if let drop {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = lit.isHidden ? 0 : Motion.duration(Motion.hover)
                    lit.animator().frame = container.area(of: drop)
                }
                lit.isHidden = false
            } else {
                lit.isHidden = true
            }
            (outside && leaf is TerminalView ? NSCursor.dragCopy : NSCursor.closedHand).set()
        }
        follow(event)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: .infinity, mode: .eventTracking) { e, stop in
            guard let e else { return }
            switch e.type {
            case .leftMouseUp: stop.pointee = true
            case .keyDown where e.keyCode == 53:  // Esc
                cancelled = true
                stop.pointee = true
            case .leftMouseDragged: follow(e)
            default: break
            }
        }
        NSCursor.arrow.set()
        guard !cancelled else { return }
        switch drop {
        case .swap(let other)?: container.swap(leaf, with: other)
        case .side(let target, let direction)?: container.move(leaf, beside: target, toward: direction)
        case nil:
            if outside, leaf is TerminalView, canMoveFocusedPaneOut { moveFocusedPaneToNewWindow() }
            return
        }
        focusLeaf(leaf)
        updateDimming()
        updateSidebar()
    }

    enum Arrangement { case swap(TerminalView), beside(TerminalView, SplitContainerView.Direction),
                       resize(SplitContainerView.Direction, CGFloat), equalize }

    /// `libertty +swap-pane`, `+resize-pane`, `+move-pane --beside`: `pane`
    /// rearranged in its split. Nil when done, else why not.
    func arrange(_ pane: TerminalView, _ how: Arrangement) -> String? {
        guard let tab = tab(containing: pane), let container = tab.container else { return "it's parked (unpark it first)" }
        switch how {
        case .swap(let other), .beside(let other, _):
            guard other !== pane else { return "that's the same pane" }
            guard container.views.contains(where: { $0 === other }) else { return "the other pane isn't in the same split" }
        case .resize, .equalize:
            guard container.views.count > 1 else { return "it's the only pane of its tab" }
        }
        switch how {
        case .swap(let other): container.swap(pane, with: other)
        case .beside(let other, let side): container.move(pane, beside: other, toward: side)
        case .resize(let side, let points): container.resize(pane, toward: side, by: points)
        case .equalize: container.equalize(animated: true)
        }
        updateDimming()
        updateSidebar()
        return nil
    }

    /// `--ui-probe`: how many terminals glass panes let the desktop through.
    var areaHoleCount: Int { area.holeCount }

    /// `--ui-probe`: the drop of `leaf` on `target` (`side` left, right, up,
    /// down, or swap), as a drag would end.
    func probeDrop(_ leaf: NSView, on target: NSView, _ side: String) -> Bool {
        guard let container = everyTab.first(where: { $0.container?.views.contains { $0 === leaf } == true })?.container,
              container.views.contains(where: { $0 === target }) else { return false }
        if side == "swap" { container.swap(leaf, with: target) }
        else if let d = SplitContainerView.Direction(rawValue: side) { container.move(leaf, beside: target, toward: d) }
        else { return false }
        focusLeaf(leaf)
        updateDimming()
        updateSidebar()
        return true
    }

}
