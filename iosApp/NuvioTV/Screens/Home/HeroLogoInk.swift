import UIKit

/// beta.19-rc1 verdict (M5, BUG-138): the hero with no visible title. Steven's video showed a hero
/// with nothing where the title belongs (Comme des frères): `HeroLogo` falls back to the text
/// wordmark only when the logo bitmap is nil, so a bitmap that draws nothing readable on the dark
/// hero left the slot empty. Two shapes, told apart by sampling the bitmap once per URL:
///
/// - **blank**: transparent or a placeholder, or an opaque dark box. The resolver commits no logo,
///   so `HeroLogo` draws the title text instead.
/// - **dark**: near-black, low-chroma ink on transparency (a black wordmark). `HeroLogo` draws it
///   as a template in the primary text colour, i.e. a white silhouette.
/// - **legible**: everything else, drawn as it always was. Red, blue, Netflix red and every other
///   brand colour stay as drawn (critique #10: only near-black, low-chroma ink is whitened).
///
/// Thresholds do not depend on the source resolution (TMDB logos move to `original` in this batch,
/// spec B); the per-URL memo simply refills for the new URLs.
nonisolated enum HeroLogoInk: String, Equatable, Sendable {
    case legible, dark, blank

    /// Side of the sampling bitmap.
    static let side = 32
    /// A pixel counts as ink above this alpha.
    static let alphaFloor: Double = 0.1
    /// Less ink than this fraction of the frame is nothing to read: blank.
    static let blankCoverage: Double = 0.005
    /// More ink than this fraction, dark and grey, is an opaque box rather than a wordmark: blank.
    static let boxCoverage: Double = 0.9
    static let boxLuma: Double = 0.15
    /// Near-black ink: mean Rec. 709 luma below this and mean chroma below `lowChroma`.
    static let darkLuma: Double = 0.08
    static let lowChroma: Double = 0.12

    /// Draws `image` into a 32×32 RGBA8 bitmap with `.medium` interpolation (area averaging, so a
    /// thin wordmark is not missed the way a point sample would miss it), then `verdict(rgba:)`.
    /// A bitmap with no `CGImage` backing reads `.legible` (drawn exactly as before). Blocking for
    /// well under a millisecond; the resolver runs it off the main actor for fetched logos.
    static func verdict(of image: UIImage) -> HeroLogoInk {
        guard let cgImage = image.cgImage else { return .legible }
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
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard drawn else { return .legible }
        return verdict(rgba: pixels)
    }

    /// The decision on premultiplied RGBA8 bytes. Over pixels with alpha > 0.1, un-premultiplied:
    /// coverage = their fraction of all pixels; luma = mean Rec. 709 luminance; chroma = mean
    /// (max − min).
    ///
    ///     coverage < 0.005                               → blank  (transparent / placeholder)
    ///     coverage > 0.9 && luma < 0.15 && chroma < 0.12 → blank  (opaque dark box)
    ///     luma < 0.08 && chroma < 0.12                   → dark   (near-black, low-chroma ink)
    ///     else                                           → legible
    static func verdict(rgba pixels: [UInt8]) -> HeroLogoInk {
        let total = pixels.count / 4
        guard total > 0 else { return .legible }
        var inked = 0
        var sumLuma = 0.0
        var sumChroma = 0.0
        var index = 0
        while index + 3 < pixels.count {
            let alpha = Double(pixels[index + 3]) / 255
            if alpha > alphaFloor {
                let r = min(1, Double(pixels[index]) / 255 / alpha)
                let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
                let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
                inked += 1
                sumLuma += 0.2126 * r + 0.7152 * g + 0.0722 * b
                sumChroma += max(r, g, b) - min(r, g, b)
            }
            index += 4
        }
        let coverage = Double(inked) / Double(total)
        if coverage < blankCoverage { return .blank }
        let luma = sumLuma / Double(inked)
        let chroma = sumChroma / Double(inked)
        if coverage > boxCoverage && luma < boxLuma && chroma < lowChroma { return .blank }
        if luma < darkLuma && chroma < lowChroma { return .dark }
        return .legible
    }

    // MARK: - Per-URL memo

    /// One verdict per logo URL, process-lifetime. NSCache locks internally, so the detached
    /// sampler and the main actor can both use it.
    nonisolated(unsafe) private static let memo: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    static func cachedVerdict(for url: String) -> HeroLogoInk? {
        memo.object(forKey: url as NSString).flatMap { HeroLogoInk(rawValue: $0 as String) }
    }

    static func remember(_ verdict: HeroLogoInk, for url: String) {
        memo.setObject(verdict.rawValue as NSString, forKey: url as NSString)
    }

    /// The memo for `url`, or a sample taken OFF the main actor and memoized. The resolver awaits
    /// this in its logo fetch tasks before handing the bitmap to the commit wait, so the commit
    /// itself finds the memo and never samples on main for a fetched logo.
    static func prepare(_ image: UIImage, url: String) async -> HeroLogoInk {
        if let hit = cachedVerdict(for: url) { return hit }
        let verdict = await Task.detached(priority: .userInitiated) {
            HeroLogoInk.verdict(of: image)
        }.value
        remember(verdict, for: url)
        return verdict
    }

    #if DEBUG
    static func removeAllForTesting() {
        memo.removeAllObjects()
    }
    #endif
}
