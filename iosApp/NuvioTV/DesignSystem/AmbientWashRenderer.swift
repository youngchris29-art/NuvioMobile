import CoreGraphics
import Foundation

// Home Stage & Strip (H3, W1-B; P2 spec `docs/research/home-stage-strip-spec-P2-ambient-collections-settings.md`
// section 1): the ambient wash's PURE half. The wash is the soft, blurred colour of the focused
// title's own artwork that fills the Stage page's background behind the (alpha-masked) stage art.
//
// Why a CPU bitmap and not a live `.blur`: a full-screen `.blur(radius: 80)` renders offscreen at
// 3840x2160 every frame anything under it changes (the BUG-19/BUG-41 class: work on the focus path
// is what the tester feels at 10 feet). So the blur happens ONCE per title, here, on a 160x90 bitmap
// off the main actor, and the view just draws that bitmap magnified (12x) as a full-screen quad.
// Nothing in this file touches the main actor, UIKit or SwiftUI; `AmbientWashLayer.swift` owns the
// model and the view.
//
// A note on the loops below. They are plain `while` loops with wrapping arithmetic and no generic
// `min`/`max`/`Range` iteration, which is not how this codebase usually writes Swift. The reason is
// the DEBUG probe: it prints how long `render` took, the device pass reads that number from a Debug
// build (`-Onone`), and there a `for`/`min`/`Double(...)` loop costs ten times what it does in
// Release. Measured on an M-series Mac in an unoptimized build, the straightforward version of the
// blur alone took 46 ms (the whole render 59 ms); this form takes the blur to about 2 ms and the whole
// render to about 5 ms, and in Release the same code is a fraction of a millisecond.

/// Every number the wash uses, in one place. All of them are first guesses the device pass tunes
/// (spec risks 3 and 4): the luma caps between "cold, dull, too dark" and legible white text, and
/// the working size if the 12x magnification bands on hardware.
nonisolated enum AmbientWashTuning {
    /// What the wash asks `ArtworkStore` for (I1's per-view decode size, `ArtworkDecodeSize.swift`:
    /// "The Stage wash passes 256"). It shares the stage art's bytes (`ArtworkStore.fetch` joins a
    /// download already in flight), and a larger decode already in memory serves it.
    static let decode = ArtworkDecodeRequest(size: .pixels(256), fill: true, scale: 1)
    /// The working bitmap. 12 points per pixel at the 1920 pt Apple TV screen.
    static let width = 160
    static let height = 90
    /// The blur's sigma in screen points, and the screen width those points are measured on. The box
    /// radius is derived from both (`AmbientWashRenderer.boxRadius`).
    static let blurSigmaPoints: CGFloat = 80
    static let screenWidthPoints: CGFloat = 1920
    /// Three box passes approximate a gaussian; one pass would leave visible box edges.
    static let blurPasses = 3
    /// Chroma stretch away from each pixel's own luma before the tint.
    static let saturationBoost: Float = 1.25
    /// How far each pixel moves toward the art's wash colour (`ArtworkColorStore.washRGB`). Zero for
    /// grey art.
    static let tintAmount: Float = 0.25
    /// Exposure window on the encoded mean luma: a brighter wash is scaled down to `maxMeanLuma`, a
    /// darker one is lifted toward `minMeanLuma` by at most `maxGain`.
    static let maxMeanLuma: Float = 0.26
    static let minMeanLuma: Float = 0.10
    static let maxGain: Float = 1.8
    /// The cross-fade between two washes, and its Reduce Motion variant (still a fade, just shorter).
    static let crossFade: TimeInterval = 0.4
    static let crossFadeReducedMotion: TimeInterval = 0.2
    /// How long a PENDING title must hold still before its wash is rendered into the cache.
    static let prepareDebounce: TimeInterval = 0.15
    /// Whole-layer opacity under OLED True Black and under Increase Contrast.
    static let oledOpacity: Double = 0.4
    static let increasedContrastOpacity: Double = 0.6
    /// Rendered washes kept (about 115 KB each, so about 4.6 MB).
    static let cacheCount = 40
    /// A wash that lands this long after the stage showed its title counts as late (probe `late=`).
    static let lateAfter: TimeInterval = 0.1
}

/// The wash pipeline: a source image in, one 160x90 half-float bitmap out. Pure, deterministic and
/// `nonisolated`, so it runs on a detached `.utility` task and the unit tests drive it directly.
///
/// Steps (spec section 1.2): downsample to 160x90 (aspect-fill) -> wash colour from the downsampled
/// bytes -> saturation boost -> tint -> three-pass box blur -> exposure -> RGBA16F `CGImage`.
/// Everything between the downsample and the output works on encoded sRGB values, not linear light:
/// the luma caps below are numbers on that scale.
nonisolated enum AmbientWashRenderer {
    /// One finished wash. `meanLuma` is the Rec. 709 luma of the OUTPUT (after the exposure step), the
    /// number the probe prints as `lum=` and the cap in `AmbientWashTuning` bounds. `millis` is the
    /// time `render` took (downsample to output).
    nonisolated struct Output: @unchecked Sendable {
        let image: CGImage
        let meanLuma: Float
        let millis: Double
    }

    // MARK: - Pipeline

    /// Steps 2 to 8 of the spec's pipeline for one decoded source image. nil when the source has no
    /// size or a bitmap cannot be made.
    static func render(_ source: CGImage) -> Output? {
        let started = ProcessInfo.processInfo.systemUptime
        let width = AmbientWashTuning.width
        let height = AmbientWashTuning.height
        guard let rgba = downsample(source, width: width, height: height) else { return nil }

        // The wash colour comes from the SAME 160x90 bytes the wash is made of, so nothing hops to
        // the main actor and `ArtworkColorStore`'s per-URL ring/rail cache stays untouched. Grey art
        // has no hue to give: nil here means no tint at all.
        let tintColor: (r: Float, g: Float, b: Float)? = ArtworkColorStore
            .washRGB(from: ArtworkColorStore.meanChroma(rgba: rgba))
            .map { (r: Float($0.r), g: Float($0.g), b: Float($0.b)) }

        var px = rgbFloats(rgba)
        boostSaturation(&px, by: AmbientWashTuning.saturationBoost)
        tint(&px, toward: tintColor, amount: AmbientWashTuning.tintAmount)
        boxBlur(&px, width: width, height: height,
                radius: boxRadius(sigmaPoints: AmbientWashTuning.blurSigmaPoints,
                                  workingWidth: width,
                                  screenWidth: AmbientWashTuning.screenWidthPoints,
                                  passes: AmbientWashTuning.blurPasses),
                passes: AmbientWashTuning.blurPasses)

        // Exposure: scale the whole wash so its mean luma sits inside the window.
        applyGain(&px, gain: exposureGain(meanLuma: meanLuma(px)))

        guard let image = makeCGImage(px, width: width, height: height) else { return nil }
        let millis = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return Output(image: image, meanLuma: meanLuma(px), millis: millis)
    }

    /// Step 2: `source` drawn aspect-FILL (centre crop) into a `width` x `height` RGBA8 sRGB bitmap
    /// over an opaque black fill, so the result is always opaque and a transparent PNG composites over
    /// black. Premultiplied RGBA byte order, rows top first (what `ArtworkColorStore.meanChroma(rgba:)`
    /// reads). `.medium` interpolation: a filtered downscale, and the blur that follows hides the rest.
    static func downsample(_ source: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, source.width > 0, source.height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Aspect-fill: the larger of the two scales, centred, so the draw rect always covers the
            // whole bitmap and the overflow is cropped.
            let scale = max(CGFloat(width) / CGFloat(source.width), CGFloat(height) / CGFloat(source.height))
            let drawWidth = CGFloat(source.width) * scale
            let drawHeight = CGFloat(source.height) * scale
            context.draw(source, in: CGRect(x: (CGFloat(width) - drawWidth) / 2,
                                            y: (CGFloat(height) - drawHeight) / 2,
                                            width: drawWidth,
                                            height: drawHeight))
            return true
        }
        return drawn ? pixels : nil
    }

    /// RGBA8 bytes to 3 floats per pixel (r, g, b in 0...1). The alpha byte is dropped: `downsample`
    /// output is opaque, so premultiplied and straight colour are the same thing.
    static func rgbFloats(_ rgba: [UInt8]) -> [Float] {
        let pixelCount = rgba.count / 4
        var out = [Float](repeating: 0, count: pixelCount * 3)
        let unit: Float = 1 / 255
        rgba.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                var s = 0
                var d = 0
                var index = 0
                while index < pixelCount {
                    destination[d] = Float(source[s]) * unit
                    destination[d &+ 1] = Float(source[s &+ 1]) * unit
                    destination[d &+ 2] = Float(source[s &+ 2]) * unit
                    s &+= 4
                    d &+= 3
                    index &+= 1
                }
            }
        }
        return out
    }

    /// Step 4: each channel moves away from the pixel's own luma by `factor` (`c' = L + (c - L) * f`),
    /// then clamps to 0...1. The luma is unchanged until a channel clamps; grey stays grey.
    static func boostSaturation(_ px: inout [Float], by factor: Float) {
        let pixelCount = px.count / 3
        px.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            var index = 0
            while index < pixelCount {
                let r = buffer[offset]
                let g = buffer[offset &+ 1]
                let b = buffer[offset &+ 2]
                let luma = lumaR * r + lumaG * g + lumaB * b
                buffer[offset] = unitClamped(luma + (r - luma) * factor)
                buffer[offset &+ 1] = unitClamped(luma + (g - luma) * factor)
                buffer[offset &+ 2] = unitClamped(luma + (b - luma) * factor)
                offset &+= 3
                index &+= 1
            }
        }
    }

    /// Step 5: each channel moves `amount` of the way toward `color` (`c' = c * (1 - t) + w * t`).
    /// nil colour (grey art) or a non-positive amount leaves the pixels alone.
    static func tint(_ px: inout [Float], toward color: (r: Float, g: Float, b: Float)?, amount: Float) {
        guard let color, amount > 0 else { return }
        let t = amount > 1 ? 1 : amount
        let keep = 1 - t
        let targetR = color.r * t
        let targetG = color.g * t
        let targetB = color.b * t
        let pixelCount = px.count / 3
        px.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            var index = 0
            while index < pixelCount {
                buffer[offset] = buffer[offset] * keep + targetR
                buffer[offset &+ 1] = buffer[offset &+ 1] * keep + targetG
                buffer[offset &+ 2] = buffer[offset &+ 2] * keep + targetB
                offset &+= 3
                index &+= 1
            }
        }
    }

    /// Step 6: a separable box blur, `passes` times (horizontal then vertical each pass), with
    /// edge-replicated borders and running sums. Replication keeps a uniform image unchanged and a
    /// step's mean unchanged, and the box kernels are non-negative, so a monotone step stays
    /// monotone. `px` is 3 interleaved floats per pixel, rows top first.
    static func boxBlur(_ px: inout [Float], width: Int, height: Int, radius: Int, passes: Int) {
        guard width > 0, height > 0, radius > 0, passes > 0, px.count == width * height * 3 else { return }
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: max(width, height) + 2 * radius + 1)
        defer { padded.deallocate() }
        px.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for _ in 0..<passes {
                for y in 0..<height {
                    for channel in 0..<3 {
                        blurLine(base + (y * width * 3 + channel), stride: 3, count: width,
                                 radius: radius, padded: padded)
                    }
                }
                for x in 0..<width {
                    for channel in 0..<3 {
                        blurLine(base + (x * 3 + channel), stride: width * 3, count: height,
                                 radius: radius, padded: padded)
                    }
                }
            }
        }
    }

    /// One line of the box blur, in place: `count` samples `stride` floats apart, window
    /// `2 * radius + 1`. The line is first copied into `padded` with its first and last samples
    /// replicated `radius` times at each end (so the window never needs a clamp), then a running sum
    /// slides along it: add the sample entering on the right, drop the one leaving on the left.
    /// `padded` holds at least `count + 2 * radius + 1` floats.
    private static func blurLine(_ line: UnsafeMutablePointer<Float>, stride: Int, count n: Int, radius r: Int,
                                 padded: UnsafeMutablePointer<Float>) {
        let first = line[0]
        let last = line[(n &- 1) &* stride]
        var k = 0
        while k < r {
            padded[k] = first
            k &+= 1
        }
        var source = line
        k = 0
        while k < n {
            padded[r &+ k] = source.pointee
            source += stride
            k &+= 1
        }
        let tail = r &+ n
        k = 0
        while k <= r {   // r + 1 copies: the last one is the sample the final slide reads
            padded[tail &+ k] = last
            k &+= 1
        }
        let span = 2 &* r &+ 1
        var sum: Float = 0
        k = 0
        while k < span {
            sum += padded[k]
            k &+= 1
        }
        let scale = 1 / Float(span)
        var out = line
        var index = 0
        while index < n {
            out.pointee = sum * scale
            out += stride
            sum += padded[index &+ span] - padded[index]
            index &+= 1
        }
    }

    /// Mean Rec. 709 luma over the encoded values (3 floats per pixel). 0 for an empty buffer.
    static func meanLuma(_ px: [Float]) -> Float {
        let pixelCount = px.count / 3
        guard pixelCount > 0 else { return 0 }
        var sum = 0.0
        px.withUnsafeBufferPointer { buffer in
            var offset = 0
            var index = 0
            while index < pixelCount {
                sum += Double(lumaR * buffer[offset] + lumaG * buffer[offset &+ 1] + lumaB * buffer[offset &+ 2])
                offset &+= 3
                index &+= 1
            }
        }
        return Float(sum / Double(pixelCount))
    }

    /// Step 7: the multiplier that brings a wash of mean luma `m` inside the window. A wash brighter
    /// than `maxMeanLuma` is scaled down to it; one darker than `minMeanLuma` is lifted toward it, by
    /// at most `maxGain` (so near-black art stays dark rather than turning grey); in between, 1.
    /// `m <= 0` (a black image, or an empty buffer) is 1: there is nothing to scale.
    static func exposureGain(meanLuma m: Float) -> Float {
        if m <= 0 { return 1 }
        if m > AmbientWashTuning.maxMeanLuma { return AmbientWashTuning.maxMeanLuma / m }
        if m < AmbientWashTuning.minMeanLuma {
            let lift = AmbientWashTuning.minMeanLuma / m
            return lift > AmbientWashTuning.maxGain ? AmbientWashTuning.maxGain : lift
        }
        return 1
    }

    /// Multiplies every channel by `gain`, clamped at 1: the output is a plain 0...1 image (no EDR).
    /// A gain of exactly 1 is skipped.
    static func applyGain(_ px: inout [Float], gain: Float) {
        guard gain != 1 else { return }
        let count = px.count
        px.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index < count {
                buffer[index] = unitClamped(buffer[index] * gain)
                index &+= 1
            }
        }
    }

    /// The box radius (in working pixels) whose `passes`-fold repetition approximates a gaussian of
    /// `sigmaPoints` screen points. sigma in pixels is `sigmaPoints * workingWidth / screenWidth`
    /// (80 pt -> 6.67 px); the ideal box width for n passes is `sqrt(12 sigma^2 / n + 1)` (13.4 -> 13);
    /// the radius is `(width - 1) / 2` (6). 0 for any non-positive input.
    static func boxRadius(sigmaPoints: CGFloat, workingWidth: Int, screenWidth: CGFloat, passes: Int) -> Int {
        guard sigmaPoints > 0, workingWidth > 0, screenWidth > 0, passes > 0 else { return 0 }
        let sigma = Double(sigmaPoints) * Double(workingWidth) / Double(screenWidth)
        let ideal = (12 * sigma * sigma / Double(passes) + 1).squareRoot()
        return max(0, (Int(ideal.rounded()) - 1) / 2)
    }

    /// Step 8: the finished floats as a `width` x `height` RGBA16F `CGImage` in extended sRGB.
    /// Half-float output keeps the dark gradients, magnified 12x on screen, from banding. nil for a
    /// buffer that is not `width * height * 3` floats, or if Core Graphics refuses the format.
    ///
    /// The skip-alpha layout is the one the spec names; premultiplied alpha (every alpha lane is 1, so
    /// the pixels are identical) is the fallback if a platform's Core Graphics does not accept it.
    static func makeCGImage(_ px: [Float], width: Int, height: Int) -> CGImage? {
        let pixelCount = width * height
        guard width > 0, height > 0, px.count == pixelCount * 3 else { return nil }
        var halves = [Float16](repeating: 1, count: pixelCount * 4)   // the alpha lanes stay 1
        px.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBufferPointer { destination in
                var s = 0
                var d = 0
                var index = 0
                while index < pixelCount {
                    destination[d] = Float16(source[s])
                    destination[d &+ 1] = Float16(source[s &+ 1])
                    destination[d &+ 2] = Float16(source[s &+ 2])
                    s &+= 3
                    d &+= 4
                    index &+= 1
                }
            }
        }
        let data = halves.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return nil }
        let halfFloatLittle = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let alphaLayouts: [CGImageAlphaInfo] = [.noneSkipLast, .premultipliedLast]
        for alpha in alphaLayouts {
            if let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 64,
                bytesPerRow: width * 8,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | halfFloatLittle),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) {
                return image
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// `x` limited to 0...1, without the generic `min`/`max` (see the note at the top of the file).
    private static func unitClamped(_ x: Float) -> Float {
        x < 0 ? 0 : (x > 1 ? 1 : x)
    }

    // Rec. 709 luma weights, applied to encoded values.
    private static let lumaR: Float = 0.2126
    private static let lumaG: Float = 0.7152
    private static let lumaB: Float = 0.0722
}

/// A rendered wash, boxed for `NSCache` (a cache holds classes, and `Output` is a struct).
nonisolated final class AmbientWashCacheEntry {
    let output: AmbientWashRenderer.Output

    init(_ output: AmbientWashRenderer.Output) {
        self.output = output
    }
}

/// Rendered washes by stage identity (`"\(type):\(id)"`), process-wide. `prepare` fills it ahead of the
/// swap (the wash for a title the stage is about to show), `show` reads it, so a wash that was
/// prepared appears the instant the stage swaps. An `NSCache` with a count limit: thread-safe,
/// evicts entry by entry under memory pressure, and about 115 KB per entry.
nonisolated final class AmbientWashCache: @unchecked Sendable {
    static let shared = AmbientWashCache()

    private let cache = NSCache<NSString, AmbientWashCacheEntry>()

    init(countLimit: Int = AmbientWashTuning.cacheCount) {
        cache.countLimit = countLimit
    }

    func output(for identity: String) -> AmbientWashRenderer.Output? {
        cache.object(forKey: identity as NSString)?.output
    }

    func store(_ output: AmbientWashRenderer.Output, for identity: String) {
        cache.setObject(AmbientWashCacheEntry(output), forKey: identity as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
