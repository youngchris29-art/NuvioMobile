import SwiftUI
import UIKit

/// rc14 FEAT-46 (Steven rc13 verdict, 2026-09-30: "make the poster border dynamic, so that it
/// adapts to the dominant color of each poster" — his example was an orange ring around a warm
/// poster). Opt-in from Appearance (`focus_ring_poster_color`, default OFF). With it on, the
/// FOCUSED card's accent ring, and No Zoom's neutral still ring, take a colour sampled from that
/// card's own artwork instead of `Theme.Palette.focusRingColor` / `stillHighlight`. Zoom mode's
/// lift draws no ring, so it is untouched.
///
/// Why a process-wide store and not per-card state: the same artwork URL sits in several rows at
/// once (a Home catalog row, a collection folder, More Like This), and a `LazyHStack` throws a
/// card's `@State` away once it scrolls far enough off. The colour has to outlive any one card,
/// or every re-mounted card would sample the same pixels again.
///
/// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): the same sampled mean now also feeds
/// the card-depth rail ("Depth Takes Poster Color", `depth_rail_poster_color`, default OFF). The rail
/// is an UNFOCUSED-card treatment, so its colour has to be known without focus: with that toggle on,
/// a card asks once per URL when its image loads (`CachedAsyncImage.onImageLoaded`). The store keeps
/// the raw mean per URL and derives two lifts from it (`Use.ring`: the unchanged ring floors;
/// `Use.rail`: full brightness, saturation clamped 0.40…0.70, so a rail stays an edge highlight and
/// not a neon frame).
///
/// Cost contract (the BUG-19/BUG-41 lesson: work on the focus path is what the tester feels at 10
/// feet). A colour is computed ONCE per URL, off the main actor, because a card asked for it: on a
/// focus GAIN for the ring, and once on image load for the rail, and only when the depth toggle is
/// on. With both toggles off nothing here runs. Nothing runs per frame or when a row scrolls. The
/// sample itself is one 16×16 draw plus 256 pixel reads, on a `.utility` task.
///
/// Not an `ObservableObject` on purpose: a published dictionary has no per-key granularity (see
/// `TitleLogoStore`'s type note), so one card's colour landing would re-render every card on
/// screen. Each card holds its own `@State` tint instead, written at most once per focus gain from
/// `color(for:completion:)`'s completion, and peeks `cachedColor(for:)` from `body` so a colour
/// sampled earlier (by another row, or before a recycle) is on the ring from the first focused
/// frame rather than one update later.
///
/// Never downloads. The only pixels it reads are decoded images `ArtworkStore` already holds in
/// memory (`ArtworkStore.cachedImage(for:)`). A focused card's art is on screen, so it is almost
/// always there; when it is not (still loading, evicted) the card keeps the accent colour until
/// its next focus gain asks again.
@MainActor
final class ArtworkColorStore {
    static let shared = ArtworkColorStore()

    private init() {}

    /// One sampled verdict per artwork URL string. `color == nil` is a real answer, not a miss: the
    /// art is effectively grey (see `dominantColor(of:)`) and the card keeps its own ring colour.
    /// It is cached like a hit so a black-and-white poster is not re-sampled on every focus.
    private struct Entry {
        /// The raw saturation-weighted mean (nil = grey); both lifts derive from it.
        let mean: Mean?
    }

    /// beta.18 verdict: which lift of the sampled mean a caller wants.
    enum Use {
        /// Focus ring: floors s ≥ 0.55, v ≥ 0.85 (`ringLifted`).
        case ring
        /// Depth rail: v = 1.0, s clamped to 0.40…0.70 (`railLifted`).
        case rail
    }

    /// Sampled mean colour in HSB (each 0…1), before any lift.
    struct Mean: Sendable, Equatable {
        let h: CGFloat
        let s: CGFloat
        let v: CGFloat
    }

    private var entries: [String: Entry] = [:]
    /// Insertion order, oldest first, for FIFO eviction past `maxEntries`.
    private var order: [String] = []
    /// Completions parked behind a sample already running for the same URL, so two cards showing
    /// one poster that gain focus back to back share a single sample.
    private var pending: [String: [@MainActor (Mean?) -> Void]] = [:]

    /// An entry is a few bytes. beta.18 verdict: 500 → 1000, because the rail samples every loaded
    /// poster (not only focused ones), so a long browse touches many more distinct URLs.
    static let maxEntries = 1000

    /// Ring floor (see `lifted(h:s:v:)`). A dominant colour pulled from a muted or dark poster is
    /// usually too dull to read as a focus ring on a dark screen at 10 feet; the hue is the part
    /// that carries "this poster's colour", so the hue is kept and saturation/brightness are
    /// floored. 0.55/0.85 keeps a muted brown poster recognisably brown-orange while making it as
    /// visible as the accent ring it replaces.
    nonisolated static let minRingSaturation: CGFloat = 0.55
    nonisolated static let minRingBrightness: CGFloat = 0.85

    /// Rail lift (see `railLifted`): saturation clamp and fixed brightness.
    nonisolated static let railMinSaturation: CGFloat = 0.40
    nonisolated static let railMaxSaturation: CGFloat = 0.70
    nonisolated static let railBrightness: CGFloat = 1.0

    /// Below this MEAN chroma weight per pixel the poster counts as grey and `dominantColor`
    /// returns nil. Not 0: near-black JPEG noise (an RGB of 3/1/1 reads as 67% saturated) gives a
    /// mostly-black poster a mean weight around 0.005, and that noise must not pick the ring's hue.
    /// A poster with as little as 5% genuinely vivid area clears it comfortably (≈0.05).
    nonisolated static let minMeanChromaWeight: CGFloat = 0.01

    /// Side of the sampling bitmap. 16×16 averages the poster's regions instead of point-sampling
    /// them, and keeps the sample in the microsecond range.
    nonisolated static let sampleSide = 16

    // MARK: - Card API

    /// The ring colour for one artwork URL. See `color(for urls:completion:)`.
    func color(for url: String?, use: Use = .ring, completion: @escaping @MainActor (Color?) -> Void) {
        color(for: [url], use: use, completion: completion)
    }

    /// The ring colour for whichever of `urls` the card is actually showing: a card passes its
    /// primary art first and its fallback second (the custom-poster pair `CachedAsyncImage` takes),
    /// and the first candidate that is on screen answers, in `ImageFallbackPlan`'s order.
    ///
    /// - A candidate with a cached verdict answers SYNCHRONOUSLY, inside this call.
    /// - A candidate whose decoded image is in `ArtworkStore`'s memory is sampled off the main
    ///   actor and answered on it; concurrent requests for the same URL share one sample.
    /// - A candidate with neither is skipped (that art is not what the card is showing).
    ///
    /// `completion(nil)` when no candidate is in memory, and for grey art. Never downloads.
    func color(for urls: [String?], use: Use = .ring, completion: @escaping @MainActor (Color?) -> Void) {
        let answer: @MainActor (Mean?) -> Void = { mean in completion(Self.color(from: mean, use: use)) }
        switch lookup(urls) {
        case .notInMemory:
            completion(nil)
        case let .known(mean):
            answer(mean)
        case let .needsSample(key, image):
            if pending[key] != nil {
                pending[key]?.append(answer)
                return
            }
            pending[key] = [answer]
            Task {
                let mean = await Task.detached(priority: .utility) {
                    ArtworkColorStore.meanChroma(of: image)
                }.value
                self.finish(key, mean)
            }
        }
    }

    /// Synchronous read for a card's `body`: the verdict already sampled for the art the card is
    /// showing, or nil when none is (not sampled yet, not in memory, or grey). A dictionary read
    /// and at most one `NSCache` probe per candidate; never samples, never writes.
    func cachedColor(for urls: [String?], use: Use = .ring) -> Color? {
        if case let .known(mean) = lookup(urls) { return Self.color(from: mean, use: use) }
        return nil
    }

    /// The SwiftUI colour for one lift of a sampled mean; nil for grey.
    nonisolated static func color(from mean: Mean?, use: Use) -> Color? {
        guard let mean else { return nil }
        let lifted: (h: CGFloat, s: CGFloat, v: CGFloat)
        switch use {
        case .ring: lifted = ringLifted(h: mean.h, s: mean.s, v: mean.v)
        case .rail: lifted = railLifted(h: mean.h, s: mean.s, v: mean.v)
        }
        let out = rgb(h: lifted.h, s: lifted.s, v: lifted.v)
        return Color(.sRGB, red: Double(out.r), green: Double(out.g), blue: Double(out.b), opacity: 1)
    }

    // MARK: - Lookup

    private enum Lookup {
        case notInMemory
        case known(Mean?)
        case needsSample(key: String, image: UIImage)
    }

    /// The candidate walk shared by `color(for:completion:)` and `cachedColor(for:)`, so the
    /// synchronous peek and the asynchronous answer can never disagree about which art counts.
    private func lookup(_ urls: [String?]) -> Lookup {
        for case let raw? in urls where !raw.isEmpty {
            if let entry = entries[raw] { return .known(entry.mean) }
            // Same `URL(string:)` the card's `CachedAsyncImage(string:)` built, so the NSURL key
            // matches the one `ArtworkStore` cached the decoded image under.
            if let url = URL(string: raw), let image = ArtworkStore.cachedImage(for: url) {
                return .needsSample(key: raw, image: image)
            }
        }
        return .notInMemory
    }

    private func finish(_ key: String, _ mean: Mean?) {
        remember(Entry(mean: mean), for: key)
        let waiters = pending.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter(mean) }
    }

    private func remember(_ entry: Entry, for key: String) {
        if entries[key] == nil {
            if order.count >= Self.maxEntries {
                let oldest = order.removeFirst()
                entries[oldest] = nil
            }
            order.append(key)
        }
        entries[key] = entry
    }

    // MARK: - Sampling (pure)

    /// `dominantColor(of: CGImage)` as a SwiftUI colour, nil for grey art or an image with no
    /// bitmap behind it. Blocking for well under a millisecond; the store calls it off-main.
    nonisolated static func dominantColor(of image: UIImage) -> Color? {
        color(from: meanChroma(of: image), use: .ring)
    }

    /// beta.18 verdict: the raw (unlifted) mean for `image`, nil for grey or no bitmap. What the
    /// store caches; `dominantColor(of:)` and the rail both derive from it.
    nonisolated static func meanChroma(of image: UIImage) -> Mean? {
        guard let cgImage = image.cgImage else { return nil }
        return meanChroma(of: cgImage)
    }

    /// The ring colour for `cgImage`, already lifted for ring use (`lifted(h:s:v:)`), or nil when
    /// the image is effectively grey. Draws the image into a 16×16 RGBA8 bitmap, then takes a
    /// saturation-weighted mean (`dominantColor(rgba:)`).
    nonisolated static func dominantColor(of cgImage: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let mean = meanChroma(of: cgImage) else { return nil }
        let ring = ringLifted(h: mean.h, s: mean.s, v: mean.v)
        return rgb(h: ring.h, s: ring.s, v: ring.v)
    }

    /// The raw 16×16 saturation-weighted mean for `cgImage` (see `meanChroma(rgba:)`), unlifted.
    nonisolated static func meanChroma(of cgImage: CGImage) -> Mean? {
        let side = sampleSide
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // `.medium`, not `ArtworkLetterbox`'s `.low`: this draw IS the averaging step, so a
            // filtered downscale (each cell a blend of its region) beats a point sample of it.
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard drawn else { return nil }
        return meanChroma(rgba: pixels)
    }

    /// The weighting itself, on premultiplied RGBA8 bytes, split from the draw so it reads (and
    /// could be tested) on its own.
    ///
    /// Each pixel weighs `s² · v · alpha` (HSB saturation `(max − min) / max`, brightness `max`).
    /// Squaring the saturation is what makes this "dominant colour" and not "average colour": a
    /// plain mean of an orange title block on a dark grey poster is a muddy brown, while this mean
    /// is the orange, because grey pixels weigh nothing and dim ones weigh little. A small epsilon
    /// on every weight (so grey art would still average to SOME colour) was considered and left
    /// out: a solid grey poster must keep the accent ring, so grey has to come back nil, and
    /// `minMeanChromaWeight` makes that call explicitly instead.
    nonisolated static func dominantColor(rgba pixels: [UInt8]) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let mean = meanChroma(rgba: pixels) else { return nil }
        let ring = ringLifted(h: mean.h, s: mean.s, v: mean.v)
        return rgb(h: ring.h, s: ring.s, v: ring.v)
    }

    /// beta.18 verdict: the weighting below, returning the raw mean as HSB (nil = grey) so the ring
    /// and rail lifts derive from one number.
    nonisolated static func meanChroma(rgba pixels: [UInt8]) -> Mean? {
        var sumR: CGFloat = 0, sumG: CGFloat = 0, sumB: CGFloat = 0, sumW: CGFloat = 0
        var counted = 0
        var index = 0
        while index + 3 < pixels.count {
            let alpha = CGFloat(pixels[index + 3]) / 255
            if alpha > 0 {
                // Premultiplied: divide alpha back out so a soft edge keeps its hue.
                let r = min(1, CGFloat(pixels[index]) / 255 / alpha)
                let g = min(1, CGFloat(pixels[index + 1]) / 255 / alpha)
                let b = min(1, CGFloat(pixels[index + 2]) / 255 / alpha)
                let hi = max(r, g, b)
                let lo = min(r, g, b)
                counted += 1
                if hi > 0 {
                    let s = (hi - lo) / hi
                    let weight = s * s * hi * alpha
                    sumR += r * weight
                    sumG += g * weight
                    sumB += b * weight
                    sumW += weight
                }
            }
            index += 4
        }
        guard counted > 0, sumW > 0, sumW / CGFloat(counted) >= minMeanChromaWeight else { return nil }
        let mean = hsb(r: sumR / sumW, g: sumG / sumW, b: sumB / sumW)
        return Mean(h: mean.h, s: mean.s, v: mean.v)
    }

    /// Lifts a sampled colour into one that reads as a focus ring: the hue is kept, saturation and
    /// brightness are floored at `minRingSaturation` / `minRingBrightness` (see those). A colour
    /// already past both floors is returned unchanged.
    nonisolated static func lifted(h: CGFloat, s: CGFloat, v: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        ringLifted(h: h, s: s, v: v)
    }

    /// The ring lift (unchanged numbers; `lifted` is its pre-beta.18 name).
    nonisolated static func ringLifted(h: CGFloat, s: CGFloat, v: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        (h, min(1, max(s, minRingSaturation)), min(1, max(v, minRingBrightness)))
    }

    /// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): the depth-rail lift. Hue kept, full
    /// brightness, saturation clamped to 0.40…0.70: a rail is a 1-3 pt hairline, so it needs to be
    /// bright to read, but a fully saturated poster colour would turn the edge into a neon frame.
    nonisolated static func railLifted(h: CGFloat, s: CGFloat, v: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        (h, min(railMaxSaturation, max(railMinSaturation, s)), railBrightness)
    }

    /// RGB (0…1) → HSB (each 0…1, hue 0 = red, wrapping). Hue is 0 for a grey.
    nonisolated static func hsb(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let hi = max(r, g, b)
        let lo = min(r, g, b)
        let delta = hi - lo
        let s = hi > 0 ? delta / hi : 0
        var h: CGFloat = 0
        if delta > 0 {
            if hi == r {
                h = (g - b) / delta
            } else if hi == g {
                h = 2 + (b - r) / delta
            } else {
                h = 4 + (r - g) / delta
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, hi)
    }

    /// HSB (each 0…1) → RGB (0…1). The inverse of `hsb(r:g:b:)`.
    nonisolated static func rgb(h: CGFloat, s: CGFloat, v: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let wrapped = h - floor(h)
        let scaled = wrapped * 6
        let sector = Int(scaled) % 6
        let f = scaled - floor(scaled)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
