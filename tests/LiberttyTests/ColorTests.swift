import Testing
@testable import LiberttyApp

/// Contrast, minimum contrast, metric adjustments, generated palettes, CIELAB.
struct ColorTests {
    let black = RGB(0, 0, 0), white = RGB(255, 255, 255)

    @Test func contrastRatio() {
        #expect(abs(black.contrast(with: white) - 21) < 0.01)
        #expect(white.contrast(with: white) == 1)
        #expect(abs(RGB(0x77, 0x77, 0x77).contrast(with: white) - 4.48) < 0.02)
    }

    @Test func readableKeepsWhatReads() {
        let gray = RGB(0x80, 0x80, 0x80)
        #expect(gray.readable(on: black, minimum: 1) == gray)
        #expect(gray.readable(on: black, minimum: 3) == gray)
        #expect(RGB(40, 40, 50).readable(on: RGB(28, 28, 30), minimum: 4.5) == white)
        #expect(RGB(230, 230, 230).readable(on: RGB(250, 250, 250), minimum: 4.5) == black)
    }

    @Test func metricAdjust() {
        #expect(MetricAdjust("2") == .pixels(2))
        #expect(MetricAdjust("-10%") == .percent(-10))
        #expect(MetricAdjust("tall") == nil)
        #expect(MetricAdjust("-100%") == nil)
        #expect(MetricAdjust.pixels(3).applied(to: 30) == 33)
        #expect(MetricAdjust.percent(50).applied(to: 35) == 53)
        #expect(MetricAdjust.none.configString == "")
        #expect(MetricAdjust("20%")!.configString == "20%")
    }

    @Test func labRoundTrips() {
        for c in [black, white, RGB(255, 0, 0), RGB(0x1c, 0x1c, 0x1e), RGB(0x30, 0xd1, 0x58)] {
            let back = Lab(c).rgb
            #expect(abs(Int(back.r) - Int(c.r)) <= 1 && abs(Int(back.g) - Int(c.g)) <= 1 && abs(Int(back.b) - Int(c.b)) <= 1, "\(c)")
        }
    }

    @Test func generatedPaletteCorners() {
        let theme = Theme.named(Theme.defaultName)
        let p = theme.generatedPalette256(harmonious: false)
        #expect(p.count == 256)
        #expect(Array(p[0..<16]) == theme.ansi)
        #expect(p[16] == theme.background)
        #expect(p[231] == theme.foreground)
        #expect(theme.palette256[231] == white)
    }

    @Test func lightThemesRunDarkToLightUnlessHarmonious() {
        var light = Theme.named("Libertty Light")
        light.ansi = Theme.named(Theme.defaultName).ansi
        #expect(light.generatedPalette256(harmonious: false)[16] == light.foreground)
        #expect(light.generatedPalette256(harmonious: true)[16] == light.background)
    }

    @Test func themeAccent() {
        var t = Theme.named(Theme.defaultName)
        t.cursor = RGB(0xf2, 0xb4, 0x5a)
        #expect(Accent.of(t) == t.cursor)
        t.cursor = RGB(0xf2, 0xf2, 0xf2)  // a gray: the theme's blue
        #expect(Accent.of(t) == t.ansi[4])
    }

    @Test @MainActor func themeFileRoundTrip() {
        var t = Theme.named("Nord")
        t.name = "Probe"
        let back = Theme.parse(name: "Probe", text: ThemeEditor.text(of: t))
        #expect(back == t)
    }
}

/// OKLCH, and the interface colors made from a theme with it.
struct SurfaceTests {
    @Test func oklchOfAKnownColor() {
        // As Rex's color picker shows #EFF8FF.
        let c = OKLCH(RGB(0xef, 0xf8, 0xff))
        #expect(abs(c.l - 0.974) < 0.001)
        #expect(abs(c.c - 0.013) < 0.001)
        #expect(abs(c.h - 241) < 1)
    }

    @Test func oklchRoundTrips() {
        for c in [RGB(0, 0, 0), RGB(255, 255, 255), RGB(0x2f, 0x81, 0xf7), RGB(0x0d, 0x11, 0x17), RGB(0xff, 0x7b, 0x72)] {
            #expect(OKLCH(c).rgb == c)
        }
    }

    @Test func outOfGamutKeepsHueAndLightness() {
        let wanted = OKLCH(l: 0.7, c: 0.37, h: 150)
        #expect(!wanted.inGamut)
        let got = OKLCH(wanted.rgb)
        #expect(abs(got.l - 0.7) < 0.01)
        #expect(abs(got.h - 150) < 2)
        #expect(got.c < 0.37 && got.c > 0.1)
    }

    /// Merino Dark's terminal background and text, and the interface colors
    /// Rex gives them.
    @Test func surfacesMatchRexs() {
        var theme = Theme.all[0]
        theme.background = RGB(13, 17, 23)
        theme.foreground = RGB(230, 237, 243)
        let s = theme.surfaces
        func close(_ a: RGB, _ b: RGB) -> Bool { OKLab(a).distance(to: OKLab(b)) < 0.02 }
        #expect(close(s.canvas, RGB(12, 14, 17)))
        #expect(close(s.raised, RGB(30, 32, 35)))
        #expect(close(s.stroke, RGB(46, 49, 53)))
        #expect(close(s.contentSecondary, RGB(130, 135, 140)))
        #expect(close(s.contentTertiary, RGB(102, 106, 111)))
        #expect(theme.chrome == s.canvas)
    }
}
