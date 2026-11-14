import SwiftUI

/// The alpha mask on the left edge of Classic Home's Nuvio-style hero artwork. The artwork sits in
/// a trailing frame and dissolves into the screen background over its leading `endLocation`
/// fraction. A smootherstep curve (zero slope at both ends) replaces a linear ramp, so the start
/// and the end of the fade have no visible kink on bright art. The stops are sampled from the
/// formula, not typed in, so the curve and its tests share one definition.
nonisolated enum HomeHeroLeadingFade {
    /// Where the artwork becomes fully opaque, as a fraction of the artwork frame's width.
    static let endLocation: CGFloat = 0.45
    /// Number of equal segments the curve is sampled into (`segments + 1` stops).
    static let segments = 10

    /// 6t^5 - 15t^4 + 10t^3, with `t` clamped to 0...1.
    static func smootherstep(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * c * (c * (c * 6 - 15) + 10)
    }

    /// (location, alpha) pairs, `segments + 1` of them, `location = endLocation * i / segments`,
    /// `alpha = smootherstep(location / endLocation)`.
    static let samples: [(location: CGFloat, alpha: CGFloat)] = (0...segments).map { i in
        let location = endLocation * CGFloat(i) / CGFloat(segments)
        return (location, smootherstep(location / endLocation))
    }

    /// `samples` as mask stops: black at `alpha` opacity, so alpha 0 is clear.
    static var stops: [Gradient.Stop] {
        samples.map { Gradient.Stop(color: .black.opacity(Double($0.alpha)), location: $0.location) }
    }
}
