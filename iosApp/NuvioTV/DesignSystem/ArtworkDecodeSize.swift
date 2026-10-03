import CoreGraphics
import Foundation
import UIKit

/// beta.19-rc1 verdict (I1, tracker BUG-134; Steven's blurry Detail backdrop, posters and logos on a
/// 4K Apple TV): how large an image is decoded.
///
/// `ArtworkStore.downsample` used to cap every decode at a fixed 1920 px. On an Apple TV 4K the UI is
/// 1920×1080 points at scale 2 = 3840×2160 px, so every full-bleed layer was drawn from a 1920 px
/// bitmap stretched 2×. The cap ImageIO gets is now the drawn size in pixels (points × displayScale),
/// aspect-aware, rounded UP to a shared bucket so views of similar size share one bitmap.
nonisolated enum ArtworkDecodeSize: Hashable, Sendable {
    /// The view's drawn size in POINTS (resting size; focus lift is not added). Stored as two
    /// CGFloats, not a CGSize, so the enum is Hashable on every SDK.
    case points(width: CGFloat, height: CGFloat)
    /// A layer that fills the screen: 3840 px on the long side at scale 2 (1920 at scale 1).
    case fullBleed
    /// An explicit long-side cap in pixels, independent of scale. The Stage wash passes 256.
    case pixels(Int)
    /// Today's behaviour (1920 px cap). The default for every call site that has not opted in.
    case legacy
}

nonisolated struct ArtworkDecodeRequest: Hashable, Sendable {
    var size: ArtworkDecodeSize
    /// ContentMode.fill → true, .fit → false.
    var fill: Bool
    /// `displayScale` at the call site.
    var scale: CGFloat

    static let legacy = ArtworkDecodeRequest(size: .legacy, fill: true, scale: 1)

    /// A request in canonical form, so two requests that mean the same decode compare equal:
    /// - a `.points` request with a zero, negative or non-finite side (a GeometryReader's first
    ///   pass) is `.legacy`, so it never decodes a 128 px bucket and then reloads (critique #23a);
    /// - `.fullBleed` and `.pixels` ignore the content mode, `.pixels` also ignores the scale.
    var normalized: ArtworkDecodeRequest {
        switch size {
        case .legacy:
            return .legacy
        case .points(let width, let height):
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .legacy }
            return ArtworkDecodeRequest(size: size, fill: fill, scale: Self.sanitized(scale))
        case .fullBleed:
            return ArtworkDecodeRequest(size: .fullBleed, fill: true, scale: Self.sanitized(scale))
        case .pixels(let px):
            guard px > 0 else { return .legacy }
            return ArtworkDecodeRequest(size: .pixels(min(px, ArtworkDecodeMath.maxPixel)), fill: true, scale: 1)
        }
    }

    private static func sanitized(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }
}

/// Pure math behind the decode request (unit-tested in `ArtworkDecodeMathTests`).
nonisolated enum ArtworkDecodeMath {
    static let buckets: [Int] = [128, 256, 384, 512, 640, 768, 896, 1024, 1280, 1536, 1920, 2560, 3072, 3840]
    static let maxPixel = 3840

    /// Decoded bytes at which a bitmap goes to the large pool (`ArtworkStore`).
    static let largePoolThreshold = 6 * 1024 * 1024

    /// Seeded once on the main thread in `NuvioTVApp.init` (critique #23c), from the first
    /// UIWindowScene's `screen.scale`, else `UIScreen.main.scale`. Used only by non-view code
    /// (hero resolver, prefetch); views read `@Environment(\.displayScale)`. A `static let` would
    /// fall back to 2 forever if first touched off the main thread, which is 2× the memory on a
    /// 1080p TV.
    nonisolated(unsafe) static var screenScale: CGFloat = 2

    @MainActor
    static func seedScreenScale() {
        let sceneScale = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.scale
        let scale = sceneScale ?? UIScreen.main.scale
        screenScale = scale.isFinite && scale > 0 ? scale : 2
    }

    /// The smallest bucket that is at least `ceil(px)`, clamped to [128, 3840].
    static func bucket(for px: CGFloat) -> Int {
        guard px.isFinite, px > 0 else { return buckets[0] }
        if px >= CGFloat(maxPixel) { return maxPixel }
        let needed = Int(px.rounded(.up))
        return buckets.first(where: { $0 >= needed }) ?? maxPixel
    }

    /// Position of `bucket` in `buckets` (the stored-bucket index `ArtworkStore` keeps masks by);
    /// a value that is not a bucket maps to the next bucket up.
    static func index(of bucket: Int) -> Int {
        buckets.firstIndex(where: { $0 >= bucket }) ?? (buckets.count - 1)
    }

    /// The long side, in pixels, the request needs. `source` is the image's own pixel size when it
    /// is known (an earlier decode recorded it).
    /// - `.legacy` → 1920 (today's cap); `.fullBleed` → 1920 × scale; `.pixels(n)` → n.
    /// - `.points(w, h)`: W = w × scale, H = h × scale. With a source size (sw, sh):
    ///   k = fill ? max(W/sw, H/sh) : min(W/sw, H/sh), and the answer is max(sw, sh) × k, which is
    ///   the long side of the source scaled to cover (fill) or fit the view. Without one: max(W, H).
    static func neededLongSide(_ request: ArtworkDecodeRequest, source: CGSize?) -> CGFloat {
        let scale = request.scale.isFinite && request.scale > 0 ? request.scale : 1
        switch request.size {
        case .legacy:
            return 1920
        case .fullBleed:
            return 1920 * scale
        case .pixels(let px):
            return CGFloat(px)
        case .points(let width, let height):
            let w = width * scale
            let h = height * scale
            if let source, source.width > 0, source.height > 0 {
                let kw = w / source.width
                let kh = h / source.height
                let k = request.fill ? max(kw, kh) : min(kw, kh)
                return max(source.width, source.height) * k
            }
            return max(w, h)
        }
    }

    /// The bucket a decode is stored under: the request's bucket, but never above the source (a
    /// 1170 px poster decoded for a 3840 px need is stored as 1280, not 3840).
    static func storeBucket(needed: CGFloat, sourceLongSide: CGFloat?) -> Int {
        if let sourceLongSide, sourceLongSide > 0 {
            return bucket(for: min(needed, sourceLongSide))
        }
        return bucket(for: needed)
    }

    /// `b`, then every larger bucket: a larger decode serves a smaller request.
    static func servingOrder(from b: Int) -> [Int] {
        buckets.filter { $0 >= b }
    }

    /// Strictly smaller buckets, largest first: what to show while the right size loads.
    static func placeholderOrder(below b: Int) -> [Int] {
        buckets.filter { $0 < b }.reversed()
    }
}
