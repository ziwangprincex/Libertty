import AppKit
import QuartzCore

/// Cubic Bézier timing curve evaluated on the CPU (same math as WebKit's
/// UnitBezier), for animations we drive per frame ourselves — e.g. split
/// ratios, where the grid must reflow on every step rather than be scaled.
struct CubicBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x; bx = 3 * (p2x - p1x) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }

    private func x(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func y(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    /// Progress (0...1) at normalized time `x`.
    func callAsFunction(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Newton's method, falling back to bisection where the slope is flat.
        var t = x
        for _ in 0..<8 {
            let err = self.x(t) - x
            if abs(err) < 1e-6 { return y(t) }
            let d = dx(t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        while hi - lo > 1e-6 {
            if self.x(t) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return y(t)
    }
}

extension Motion {
    static let easeCurve = CubicBezier(0.2, 0.7, 0.2, 1)
    static let outCurve = CubicBezier(0.16, 1, 0.3, 1)
}

/// Drives a 0→1 progress value once per display frame of `view`'s screen.
/// With Reduce Motion (or zero duration) it jumps straight to the end.
final class FrameAnimator {
    private let duration: CFTimeInterval
    private let curve: CubicBezier
    /// Let go of once it ends: whoever keeps the animator (a container,
    /// till its next change) mustn't keep what they captured — a closed pane.
    private var update: ((Double) -> Void)?
    private var completion: (() -> Void)?
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var retainSelf: FrameAnimator?

    @discardableResult
    static func run(on view: NSView, duration: CFTimeInterval, curve: CubicBezier = Motion.outCurve,
                    update: @escaping (Double) -> Void, completion: @escaping () -> Void = {}) -> FrameAnimator {
        let animator = FrameAnimator(duration: Motion.duration(duration), curve: curve,
                                     update: update, completion: completion)
        animator.begin(on: view)
        return animator
    }

    private init(duration: CFTimeInterval, curve: CubicBezier,
                 update: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        self.duration = duration
        self.curve = curve
        self.update = update
        self.completion = completion
    }

    private func begin(on view: NSView) {
        guard duration > 0, view.window != nil else {
            end()
            return
        }
        retainSelf = self  // keep alive until the animation finishes
        start = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        update?(0)
        // A window that isn't on screen gets no display frames: end on time anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in self?.finish() }
    }

    /// Stop where it is (the caller takes over).
    func cancel() {
        link?.invalidate()
        link = nil
        retainSelf = nil
        update = nil
        completion = nil
    }

    /// Jump to the end and run the completion now, if it hasn't run yet
    /// (a new change interrupts this one: its end state must still happen).
    func finish() {
        guard link != nil else { return }
        end()
    }

    private func end() {
        let (update, completion) = (self.update, self.completion)
        cancel()
        update?(1)
        completion?()
    }

    @objc private func step(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        guard t < 1 else { return end() }
        update?(curve(t))
    }
}
