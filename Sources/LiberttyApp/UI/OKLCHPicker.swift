import AppKit
import SwiftUI

/// The Theme Customizer's color picker (Rex's): the color's hex at the top;
/// a disc of the colors at its lightness, hue around and chroma outward,
/// with a needle to the color; sliders for hue, chroma and lightness, each
/// track showing what moving it would give.
struct OKLCHPickerView: View {
    @ObservedObject var model: ThemeCustomizerModel
    @FocusState private var hexFocused: Bool

    static let maxChroma = 0.37

    var body: some View {
        let lch = model.picked
        let rgb = lch.rgb
        let look = CustomizerLook(theme: model.theme, themed: model.preview)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(model.picking?.longTitle ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                TextField("#RRGGBB", text: $model.pickedHex)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 76, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(look.accent, lineWidth: 2))
                    .overlay(RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .strokeBorder(look.accent.opacity(0.3), lineWidth: 3).padding(-3.5))
                    .focused($hexFocused)
                    .onSubmit(commitHex)
                    .help("Six-digit sRGB hex color, for example #AABBCC")
            }
            ChromaDisc(lch: lch, rgb: rgb, ink: look.text) { model.setPicked($0) }
                .frame(width: 264, height: 264)
                .frame(maxWidth: .infinity)
            PickerSlider(title: "Hue", value: lch.h, range: 0...360, text: String(format: "%.0f°", lch.h),
                         stops: (0...24).map { OKLCH(l: lch.l, c: lch.c, h: Double($0) * 15).rgb.color }, thumb: rgb.color) {
                let p = model.picked
                model.setPicked(OKLCH(l: p.l, c: p.c, h: $0))
            }
            PickerSlider(title: "Chroma", value: lch.c, range: 0...Self.maxChroma, text: String(format: "%.3f", lch.c),
                         stops: (0...12).map { OKLCH(l: lch.l, c: Double($0) / 12 * Self.maxChroma, h: lch.h).rgb.color },
                         thumb: rgb.color) {
                let p = model.picked
                model.setPicked(OKLCH(l: p.l, c: $0, h: p.h))
            }
            PickerSlider(title: "Lightness", value: lch.l, range: 0...1, text: String(format: "%.3f", lch.l),
                         stops: (0...12).map { OKLCH(l: Double($0) / 12, c: lch.c, h: lch.h).rgb.color }, thumb: rgb.color) {
                let p = model.picked
                model.setPicked(OKLCH(l: $0, c: p.c, h: p.h))
            }
        }
        .padding(16)
        .frame(width: 300)
        .foregroundStyle(look.text)
        .background(look.popover)
        .tint(look.accent)
        .onAppear { model.pickedHex = rgb.hexString.uppercased() }
        .onChange(of: rgb) { _, new in
            if !hexFocused { model.pickedHex = new.hexString.uppercased() }
        }
        .onChange(of: hexFocused) { _, focused in
            if !focused { model.pickedHex = model.picked.rgb.hexString.uppercased() }
        }
    }

    private func commitHex() {
        guard let rgb = RGB(string: model.pickedHex) else {
            model.pickedHex = model.picked.rgb.hexString.uppercased()
            return
        }
        model.setPicked(OKLCH(rgb))
        model.pickedHex = rgb.hexString.uppercased()
    }
}

/// Hue around, chroma outward (0 at the centre, 0.37 at the rim), the
/// colors at the picked lightness as a grid of dots: those sRGB can't show
/// are small and faded, nearer the middle lightness (at the ends, near white
/// or black, they'd all be one gray). A needle and a ring for the color.
private struct ChromaDisc: View {
    let lch: OKLCH
    let rgb: RGB
    /// The needle's: the popover's text color, to show on what's around the dots.
    let ink: Color
    let onChange: (OKLCH) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - 9
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let angle = lch.h * .pi / 180
            let distance = min(lch.c / OKLCHPickerView.maxChroma, 1) * radius
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y - sin(angle) * distance)
            ZStack {
                Image(decorative: DiscDots.image(lightness: lch.l, radius: radius), scale: DiscDots.scale)
                    .position(center)
                Circle()
                    .strokeBorder(Color.primary.opacity(0.12))
                    .frame(width: radius * 2 + 6, height: radius * 2 + 6)
                    .position(center)
                Path { p in
                    p.move(to: center)
                    p.addLine(to: point)
                }
                .stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                Circle().fill(ink).frame(width: 5, height: 5).position(center)
                Circle()
                    .fill(rgb.color)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .position(point)
            }
            .contentShape(Circle().inset(by: -10))
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let dx = drag.location.x - center.x, dy = center.y - drag.location.y
                let c = min((dx * dx + dy * dy).squareRoot() / radius, 1) * OKLCHPickerView.maxChroma
                var h = atan2(dy, dx) * 180 / .pi
                if h < 0 { h += 360 }
                // At the centre the hue is anything: keep it.
                onChange(OKLCH(l: lch.l, c: c, h: c < 0.002 ? lch.h : h))
            })
            .accessibilityElement()
            .accessibilityLabel("Hue and chroma")
            .accessibilityValue(String(format: "%.0f degrees, chroma %.3f", lch.h, lch.c))
            .help("Drag around the center to change hue and outward to increase chroma.")
        }
    }
}

/// The disc's dots at one lightness, drawn once for it (dragging hue or
/// chroma only moves the needle).
@MainActor
private enum DiscDots {
    static let scale: CGFloat = 2
    private static var last: (key: Int, radius: CGFloat, image: CGImage)?

    static func image(lightness: Double, radius: CGFloat) -> CGImage {
        let key = Int((lightness * 1000).rounded())
        if let last, last.key == key, last.radius == radius { return last.image }
        let image = draw(lightness: Double(key) / 1000, radius: radius)
        last = (key, radius, image)
        return image
    }

    private static func draw(lightness l: Double, radius: CGFloat) -> CGImage {
        let side = Int((radius * 2 * scale).rounded(.up))
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        let step: CGFloat = 4.4, dot: CGFloat = 3, faded: CGFloat = 2
        let count = Int(radius / step)
        // (CoreGraphics' y runs up: hue turns counterclockwise, as on the needle.)
        for j in -count...count {
            for i in -count...count {
                let x = CGFloat(i) * step, y = CGFloat(j) * step
                let r = (x * x + y * y).squareRoot()
                guard r <= radius - dot / 2 else { continue }
                var h = atan2(Double(y), Double(x)) * 180 / .pi
                if h < 0 { h += 360 }
                var lch = OKLCH(l: l, c: Double(r / radius) * OKLCHPickerView.maxChroma, h: h)
                let inGamut = lch.inGamut
                if !inGamut { lch.l = min(max(l, 0.4), 0.8) }
                let c = lch.rgb
                context.setFillColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255,
                                     alpha: inGamut ? 1 : 0.3)
                let d = inGamut ? dot : faded
                context.fillEllipse(in: CGRect(x: radius + x - d / 2, y: radius + y - d / 2, width: d, height: d))
            }
        }
        return context.makeImage()!
    }
}

/// A labelled slider with its value on the right, its track the colors
/// along it.
private struct PickerSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let text: String
    let stops: [Color]
    let thumb: Color
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(text).font(.system(size: 11.5, design: .monospaced)).opacity(0.65)
            }
            GeometryReader { geo in
                let inset: CGFloat = 9
                let span = max(geo.size.width - 2 * inset, 1)
                let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                    / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                        .frame(height: 10)
                    Circle()
                        .fill(thumb)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .position(x: inset + span * fraction, y: geo.size.height / 2)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let t = min(max((drag.location.x - inset) / span, 0), 1)
                    onChange(range.lowerBound + t * (range.upperBound - range.lowerBound))
                })
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(text)
            .accessibilityAdjustableAction { direction in
                let step = (range.upperBound - range.lowerBound) / 100
                onChange(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
            }
        }
    }
}
