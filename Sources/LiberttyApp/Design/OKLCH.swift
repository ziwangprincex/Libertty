import Foundation

/// OKLab in polar form (Björn Ottosson's): lightness 0–1, chroma 0 to about
/// 0.37 for sRGB, hue in degrees. Equal steps look equal, so the interface's
/// surfaces are a theme's colors moved by fixed amounts of lightness, and the
/// Theme Customizer's picker turns hue and chroma on a wheel (Rex's).
struct OKLCH: Equatable {
    var l: Double, c: Double, h: Double

    init(l: Double, c: Double, h: Double) { (self.l, self.c, self.h) = (l, c, h) }

    init(_ rgb: RGB) {
        let lab = OKLab(rgb)
        let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        self.init(l: lab.l, c: c, h: c < 1e-7 ? 0 : h)
    }

    var lab: OKLab {
        let r = h * .pi / 180
        return OKLab(l: l, a: c * cos(r), b: c * sin(r))
    }

    /// The nearest sRGB color: the same lightness and hue, with as much of
    /// the chroma as fits (a bisection; out-of-gamut colors keep their hue).
    var rgb: RGB {
        let l = min(max(self.l, 0), 1)
        if OKLCH(l: l, c: c, h: h).lab.inGamut { return OKLCH(l: l, c: c, h: h).lab.rgb }
        var lo = 0.0, hi = c
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if OKLCH(l: l, c: mid, h: h).lab.inGamut { lo = mid } else { hi = mid }
        }
        return OKLCH(l: l, c: lo, h: h).lab.rgb
    }

    /// Whether this color is in sRGB as it is.
    var inGamut: Bool { lab.inGamut }

    /// Lighter (positive) or darker by `amount` of lightness.
    func lightened(_ amount: Double) -> OKLCH { OKLCH(l: min(max(l + amount, 0), 1), c: c, h: h) }
}

/// OKLab: lightness and two opponent axes.
struct OKLab: Equatable {
    var l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) { (self.l, self.a, self.b) = (l, a, b) }

    init(_ c: RGB) {
        func linear(_ v: UInt8) -> Double {
            let x = Double(v) / 255
            return x > 0.04045 ? pow((x + 0.055) / 1.055, 2.4) : x / 12.92
        }
        self.init(linear: (linear(c.r), linear(c.g), linear(c.b)))
    }

    init(linear rgb: (r: Double, g: Double, b: Double)) {
        let l = cbrt(0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b)
        let m = cbrt(0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b)
        let s = cbrt(0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b)
        self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear sRGB, unclamped (outside 0–1 when out of gamut).
    var linear: (r: Double, g: Double, b: Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    var inGamut: Bool {
        let (r, g, b) = linear
        let e = 1e-4
        return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && b >= -e && b <= 1 + e
    }

    /// sRGB, each channel clamped.
    var rgb: RGB {
        let (r, g, b) = linear
        func gamma(_ v: Double) -> UInt8 {
            let v = min(max(v, 0), 1)
            let c = v > 0.0031308 ? 1.055 * pow(v, 1 / 2.4) - 0.055 : 12.92 * v
            return UInt8((c * 255).rounded())
        }
        return RGB(gamma(r), gamma(g), gamma(b))
    }

    /// Euclidean distance: about 0.02 is where two colors start to look different.
    func distance(to other: OKLab) -> Double {
        let (dl, da, db) = (l - other.l, a - other.a, b - other.b)
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
