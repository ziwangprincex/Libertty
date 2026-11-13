import AppKit

/// A session shown in more than one window (`libertty +attach`, two Macs on
/// one host) has one size for its program: the last window to resize set
/// it. A pane of another size says so at its top (Rex's "Sized by another
/// client"), and a click gives the program this pane's size again.
extension TerminalView {
    private static var sizedTagKey: UInt8 = 0
    private static var sizedCheckKey: UInt8 = 0

    /// liberttyd says the program has another size: shown or hidden after a
    /// moment, since a resize of this pane's own crosses one on its way.
    func programSizeChanged() {
        (objc_getAssociatedObject(self, &Self.sizedCheckKey) as? DispatchWorkItem)?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateSizedTag() }
        objc_setAssociatedObject(self, &Self.sizedCheckKey, work, .OBJC_ASSOCIATION_RETAIN)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func updateSizedTag() {
        var tag = objc_getAssociatedObject(self, &Self.sizedTagKey) as? NSButton
        guard session.sizedElsewhere else {
            tag?.removeFromSuperview()
            objc_setAssociatedObject(self, &Self.sizedTagKey, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        if tag == nil {
            let button = NSButton(title: "", target: self, action: #selector(fitProgramHere(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            }
            button.toolTip = L10n.t("Another window set the program's size: this pane shows what was drawn for it. Click to give it this pane's size.")
            addSubview(button)
            button.layer?.zPosition = 2
            objc_setAssociatedObject(self, &Self.sizedTagKey, button, .OBJC_ASSOCIATION_RETAIN)
            tag = button
        }
        guard let tag else { return }
        let text = L10n.t("Sized by another window") + " · " + L10n.t("Fit to This Pane")
        tag.attributedTitle = NSAttributedString(string: "  " + text + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        tag.setAccessibilityLabel(text)
        let size = tag.fittingSize
        let width = min(size.width, max(0, bounds.width - 12))
        tag.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - size.height - 6, width: width, height: size.height)
        tag.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }

    @objc private func fitProgramHere(_ sender: Any?) {
        session.fitProgramToPane()
        programSizeChanged()
    }

    /// What the sized tag says (the UI probe): nil when there's none.
    var sizedTagShown: String? {
        (objc_getAssociatedObject(self, &Self.sizedTagKey) as? NSButton)?.accessibilityLabel()
    }
}
