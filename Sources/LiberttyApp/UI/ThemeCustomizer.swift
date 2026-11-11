import AppKit
import SwiftUI

/// The Theme Customizer's window (Rex's): the theme's name and whether it's
/// light or dark; its colors as swatches; the extended palette; Revert,
/// Cancel and Save & Apply.
struct ThemeCustomizerView: View {
    @ObservedObject var model: ThemeCustomizerModel
    let editor: ThemeEditor

    /// Eight swatches to a row, as wide as the box they're in allows.
    static let swatchWidth: CGFloat = 72
    static let swatchSpacing: CGFloat = 8

    /// How tall the colors may be before they scroll: the screen's room
    /// less the bottom bar, so Save & Apply is never under the Dock.
    private var maxContentHeight: CGFloat {
        max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 130)
    }

    var body: some View {
        let look = CustomizerLook(theme: model.theme, themed: model.preview)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    header(look)
                    colors(look)
                    extendedPalette(look)
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 24)
                .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
            }
            .scrollIndicators(.automatic)
            .frame(height: min(model.contentHeight, maxContentHeight))
            .onPreferenceChange(ContentHeight.self) { height in
                if abs(height - model.contentHeight) > 0.5 { model.contentHeight = height }
            }
            bottomBar(look)
        }
        .frame(width: 8 * Self.swatchWidth + 7 * Self.swatchSpacing + 2 * 16 + 2 * 28)
        .foregroundStyle(look.text)
        .background(look.canvas)
        .tint(look.accent)
    }

    // MARK: Header

    private func header(_ look: CustomizerLook) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(look.secondary)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(look.canvas, look.text)
                    .background(Circle().fill(look.canvas).padding(-1.5))
                    .offset(x: 4, y: 3)
            }
            .frame(width: 34, height: 34)
            TextField("Theme Name", text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .onSubmit { model.status = "" }
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Image(systemName: model.theme.isDark ? "moon.fill" : "sun.max.fill")
                Text(model.theme.isDark ? "Dark Theme" : "Light Theme")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(look.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(look.control))
            .overlay(Capsule().strokeBorder(look.stroke))
            .help("Determined by the theme's background color.")
            MoreMenu(isOwn: model.isOwnTheme, editor: editor).equatable()
        }
    }

    // MARK: Colors

    private func colors(_ look: CustomizerLook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Colors").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Preview").font(.system(size: 12)).foregroundStyle(look.secondary)
                Toggle("Preview", isOn: $model.preview)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("Show these colors in every window, and here, as you edit. Turn off to see your windows as they are.")
            }
            Box(look) {
                VStack(alignment: .leading, spacing: 16) {
                    swatches("Terminal", ThemeCustomizerModel.Slot.terminal, look)
                    swatches("ANSI Standard", (0..<8).map { .ansi($0) }, look)
                    swatches("ANSI Bright", (8..<16).map { .ansi($0) }, look)
                }
            }
        }
    }

    private func swatches(_ title: String, _ slots: [ThemeCustomizerModel.Slot], _ look: CustomizerLook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(look.secondary)
            HStack(alignment: .top, spacing: Self.swatchSpacing) {
                ForEach(slots, id: \.self) { slot in
                    SwatchTile(slot: slot, color: model.color(slot), picking: model.picking == slot, look: look,
                               help: help(for: slot), editor: editor)
                }
            }
        }
    }

    private func help(for slot: ThemeCustomizerModel.Slot) -> String {
        switch slot {
        case .ansi(let i):
            // Black on a dark background is meant to be dim.
            let ratio = model.theme.ansi[i].contrast(with: model.theme.background)
            return String(format: "%@: contrast %.1f against the background%@", slot.longTitle, ratio,
                          ratio < 3 && i != 0 && i != 8 ? " (hard to read)" : "")
        case .cursorText where model.theme.cursorText == nil:
            return "Cursor Text: the background's color until you choose one"
        case .selectionForeground where model.theme.selectionForeground == nil:
            return "Selected Text: each character's own color until you choose one"
        default:
            return "\(slot.longTitle): click to choose a color"
        }
    }

    // MARK: Extended palette

    private func extendedPalette(_ look: CustomizerLook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Extended Palette").font(.system(size: 15, weight: .semibold))
                    Text("Generate colors 16 through 255 from this theme. Turn off to use the default xterm palette.")
                        .font(.system(size: 12))
                        .foregroundStyle(look.secondary)
                }
                Spacer()
                Toggle("Extended Palette", isOn: $model.generate)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            Box(look) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.generate {
                        OptionRow(title: "Automatically regenerate palette",
                                  detail: model.autoRegenerate
                                      ? "Changes to the base theme colors and the ANSI Standard palette update the extended palette."
                                      : "The extended palette keeps its colors when the base theme colors change.",
                                  isOn: Binding(get: { model.autoRegenerate }, set: { model.setAutoRegenerate($0) }),
                                  look: look) {
                            if !model.autoRegenerate {
                                Button("Regenerate Palette") { model.regenerate() }
                                    .buttonStyle(CustomizerButtonStyle(look: look, small: true))
                                    .help("Regenerates the extended color palette from the base theme.")
                            }
                        }
                        Divider().overlay(look.stroke)
                        OptionRow(title: "Harmonious order",
                                  detail: "Orders generated colors from the background to the text, rather than dark to light.",
                                  isOn: $model.harmonious, look: look) { EmptyView() }
                    } else {
                        Text("Colors 16 through 255 use the default xterm palette, which many terminal programs expect.")
                            .font(.system(size: 12))
                            .foregroundStyle(look.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(look.stroke)
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { model.showExtended.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(model.showExtended ? 90 : 0))
                                Text(model.showExtended ? "Hide extended palette" : "Show extended palette")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(look.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if model.overrides > 0 {
                            Button("Reset Overrides (\(model.overrides))") { model.resetOverrides() }
                                .buttonStyle(CustomizerButtonStyle(look: look, small: true))
                                .help("Back to the generated colors for the ones you chose yourself.")
                        }
                    }
                    if model.showExtended {
                        ExtendedPaletteGrid(palette: model.palette,
                                            overridden: model.overrides > 0 ? Set(model.theme.extendedPalette.keys) : [],
                                            picking: model.picking, look: look, editor: editor)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    // MARK: Buttons

    private func bottomBar(_ look: CustomizerLook) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(look.stroke).frame(height: 1)
            HStack(spacing: 10) {
                Button("Revert…") { editor.revert() }
                    .buttonStyle(CustomizerButtonStyle(look: look))
                    .disabled(model.theme == model.original && model.name == model.originalName)
                    .help("Restore the palette and name from the start of this editing session or your last save.")
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { editor.cancel() }
                    .buttonStyle(CustomizerButtonStyle(look: look))
                    .keyboardShortcut(.cancelAction)
                Button("Save & Apply") { editor.save() }
                    .buttonStyle(CustomizerButtonStyle(look: look, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .help("Save this theme and use it as your \(SystemAppearance.isDark ? "dark" : "light") theme")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}

/// The customizer's colors: the theme's own interface colors (Rex's
/// surfaces) while it previews, else the system's.
struct CustomizerLook {
    var canvas: Color
    var group: Color
    var band: Color
    var control: Color
    /// The picker's popover: the theme's raised surface, or the system's material.
    var popover: Color
    var stroke: Color
    var text: Color
    var secondary: Color
    var accent: Color

    init(theme: Theme, themed: Bool) {
        let accent = ConfigStore.shared.savedConfig.accent(with: theme)
        self.accent = accent.map(\.color) ?? Color(nsColor: .controlAccentColor)
        if themed {
            let s = theme.surfaces
            canvas = s.canvas.color
            group = s.content.color.opacity(s.isDark ? 0.035 : 0.03)
            band = (s.isDark ? Color.black : s.content.color).opacity(s.isDark ? 0.28 : 0.05)
            control = s.content.color.opacity(s.isDark ? 0.07 : 0.06)
            popover = s.raised.color
            stroke = s.stroke.color
            text = s.content.color
            secondary = s.contentSecondary.color
        } else {
            canvas = Color(nsColor: .windowBackgroundColor)
            group = Color.primary.opacity(0.035)
            band = Color.primary.opacity(0.07)
            control = Color.primary.opacity(0.06)
            popover = .clear
            stroke = Color(nsColor: .separatorColor)
            text = Color(nsColor: .labelColor)
            secondary = Color(nsColor: .secondaryLabelColor)
        }
    }
}

extension RGB {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

/// A rounded box with a hairline around it.
private struct Box<Content: View>: View {
    let look: CustomizerLook
    let content: Content

    init(_ look: CustomizerLook, @ViewBuilder content: () -> Content) {
        self.look = look
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(look.group))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(look.stroke))
    }
}

/// A switch with its title and what it does, and anything else beside it.
private struct OptionRow<Accessory: View>: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>
    let look: CustomizerLook
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(look.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory()
            Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// A color as a tile: the color, its hex under it in a darker band, its
/// name above. Opens the picker.
private struct SwatchTile: View {
    let slot: ThemeCustomizerModel.Slot
    let color: RGB
    let picking: Bool
    let look: CustomizerLook
    let help: String
    let editor: ThemeEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(slot.title)
                .font(.system(size: 11))
                .foregroundStyle(look.secondary)
                .lineLimit(1)
            Button { editor.pick(slot) } label: {
                VStack(spacing: 0) {
                    Rectangle().fill(color.color).frame(height: 34)
                    Text(color.hexString.uppercased())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(look.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background(look.band)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(look.stroke))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(look.accent, lineWidth: 2).padding(-3).opacity(picking ? 1 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PopoverAnchor { editor.anchors[slot] = $0 })
            .help(help)
            .accessibilityLabel(slot.longTitle)
            .accessibilityValue(color.hexString)
        }
        .frame(width: ThemeCustomizerView.swatchWidth)
    }
}

/// Colors 16–255: the cube as six 6×6 squares (red across them, blue along,
/// green down), then the gray ramp. A click opens the picker on one.
struct ExtendedPaletteGrid: View {
    let palette: [RGB]
    let overridden: Set<Int>
    let picking: ThemeCustomizerModel.Slot?
    let look: CustomizerLook
    let editor: ThemeEditor

    /// Six blocks across the box: 6 × (6 cells and 5 gaps) and 5 gaps between.
    static let cell: CGFloat = 14.5, gap: CGFloat = 2, blockGap: CGFloat = 10

    static func frame(of index: Int) -> CGRect {
        let step = cell + gap
        if index >= 232 {
            let i = index - 232
            return CGRect(x: CGFloat(i) * step, y: 6 * step + blockGap, width: cell, height: cell)
        }
        let n = index - 16, r = n / 36, g = n / 6 % 6, b = n % 6
        let blockWidth = 6 * step - gap + blockGap
        return CGRect(x: CGFloat(r) * blockWidth + CGFloat(b) * step, y: CGFloat(g) * step, width: cell, height: cell)
    }

    static var size: CGSize {
        let last = frame(of: 231), gray = frame(of: 255)
        return CGSize(width: max(last.maxX, gray.maxX), height: gray.maxY)
    }

    var body: some View {
        Canvas { context, _ in
            for i in 16..<256 {
                let rect = Self.frame(of: i)
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(palette[i].color))
                if overridden.contains(i) {
                    let dot = CGRect(x: rect.midX - 1.5, y: rect.midY - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(OKLCH(palette[i]).l > 0.6 ? .black : .white))
                }
                if picking == .indexed(i) {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3.5),
                                   with: .color(look.accent), lineWidth: 2)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(PopoverAnchor { editor.anchors[.indexed(0)] = $0 })
        .onTapGesture(coordinateSpace: .local) { point in
            guard let i = (16..<256).first(where: { Self.frame(of: $0).insetBy(dx: -1, dy: -1).contains(point) }) else { return }
            editor.pick(.indexed(i), at: Self.frame(of: i))
        }
        .help("Click a color to choose it yourself")
    }
}

/// Start from another theme, import one, delete one of your own.
private struct MoreMenu: View, Equatable {
    let isOwn: Bool
    let editor: ThemeEditor

    static func == (a: MoreMenu, b: MoreMenu) -> Bool { a.isOwn == b.isOwn }

    var body: some View {
        Menu {
            Menu("Start From") {
                Section("Libertty") {
                    ForEach(Theme.all, id: \.name) { theme in
                        Button(theme.name) { editor.startFrom(theme.name) }
                    }
                }
                let builtIn = Set(Theme.all.map { $0.name.lowercased() })
                let entries = ThemeLibrary.shared.entries.filter { !builtIn.contains($0.name.lowercased()) }
                ForEach(["user", "Rex", "Ghostty"], id: \.self) { source in
                    let names = entries.filter { $0.source == source }.map(\.name)
                    if !names.isEmpty {
                        Menu(source == "user" ? "Yours" : source) {
                            ForEach(names, id: \.self) { name in
                                Button(name) { editor.startFrom(name) }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Import…") { editor.importTheme() }
            Button("Delete Theme…") { editor.deleteTheme() }.disabled(!isOwn)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.secondary)
        .fixedSize()
        .help("Start from another theme, import one, or delete one of your own")
    }
}

/// Rex's buttons: a quiet rounded one, or the prominent one in the accent.
struct CustomizerButtonStyle: ButtonStyle {
    let look: CustomizerLook
    var prominent = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, style: self)
    }

    private struct Styled: View {
        let configuration: Configuration
        let style: CustomizerButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.small ? 6 : 7, style: .continuous)
            configuration.label
                .font(.system(size: style.small ? 12 : 13, weight: style.prominent ? .semibold : .regular))
                .foregroundStyle(style.prominent ? Color.white : style.look.text)
                .padding(.horizontal, style.small ? 10 : 14)
                .frame(height: style.small ? 24 : 28)
                .background(shape.fill(style.prominent ? style.look.accent : style.look.control))
                .overlay(shape.strokeBorder(style.prominent ? Color.white.opacity(0.12) : style.look.stroke))
                .brightness(configuration.isPressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
        }
    }
}

/// The AppKit view under a SwiftUI one, for a popover to point at
/// (flipped: SwiftUI's coordinates are its own).
struct PopoverAnchor: NSViewRepresentable {
    let register: (NSView) -> Void

    final class View: NSView {
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        register(view)
        return view
    }

    func updateNSView(_ view: View, context: Context) { register(view) }
}

/// The customizer's colors' own height, to size their scroll view by.
private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
