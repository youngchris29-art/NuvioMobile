import CoreGraphics
import XCTest
@testable import NuvioTV

/// Home Stage & Strip (H3, W1-B; P2 spec sections 1 and 4.2): the ambient wash's pure pipeline
/// (`DesignSystem/AmbientWashRenderer.swift`): the downsample, the saturation boost, the tint, the
/// box blur, the exposure window and the half-float output, plus the rendered-wash cache. Every
/// source image is synthesized in an explicit sRGB bitmap context, so no colour conversion can move a
/// byte, and nothing here touches the network, `ArtworkStore` or the main actor.
final class AmbientWashRendererTests: XCTestCase {

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat,
                       width: Int = 256, height: Int = 144) throws -> CGImage {
        try makeImage(width: width, height: height) { context in
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func grey(_ value: CGFloat, width: Int = 256, height: Int = 144) throws -> CGImage {
        try solid(red: value, green: value, blue: value, width: width, height: height)
    }

    /// The output's pixels as floats, four per pixel (r, g, b, alpha lane), rows top first.
    private func halfFloats(of image: CGImage) throws -> [Float] {
        let cfData = try XCTUnwrap(image.dataProvider?.data)
        let data = cfData as Data
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Float16.self)) }
        }
    }

    private func pixel(_ floats: [Float], x: Int, y: Int, width: Int = AmbientWashTuning.width) -> (r: Float, g: Float, b: Float) {
        let index = (y * width + x) * 4
        return (floats[index], floats[index + 1], floats[index + 2])
    }

    private func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - The shipped numbers

    func testTuningIsTheSpecNumbers() {
        XCTAssertEqual(AmbientWashTuning.width, 160)
        XCTAssertEqual(AmbientWashTuning.height, 90)
        XCTAssertEqual(AmbientWashTuning.blurSigmaPoints, 80)
        XCTAssertEqual(AmbientWashTuning.screenWidthPoints, 1920)
        XCTAssertEqual(AmbientWashTuning.saturationBoost, 1.25)
        XCTAssertEqual(AmbientWashTuning.tintAmount, 0.25)
        XCTAssertEqual(AmbientWashTuning.maxMeanLuma, 0.26)
        XCTAssertEqual(AmbientWashTuning.minMeanLuma, 0.10)
        XCTAssertEqual(AmbientWashTuning.maxGain, 1.8)
        XCTAssertEqual(AmbientWashTuning.crossFade, 0.4)
        XCTAssertEqual(AmbientWashTuning.crossFadeReducedMotion, 0.2)
        XCTAssertEqual(AmbientWashTuning.prepareDebounce, 0.15)
        XCTAssertEqual(AmbientWashTuning.oledOpacity, 0.4)
        XCTAssertEqual(AmbientWashTuning.increasedContrastOpacity, 0.6)
        XCTAssertEqual(AmbientWashTuning.cacheCount, 40)
        // The decode request is I1's per-view size API at 256 px (a fill request at scale 1).
        XCTAssertEqual(AmbientWashTuning.decode, ArtworkDecodeRequest(size: .pixels(256), fill: true, scale: 1))
    }

    // MARK: - boxRadius

    func testBoxRadiusForTheShippedNumbers() {
        XCTAssertEqual(AmbientWashRenderer.boxRadius(sigmaPoints: 80, workingWidth: 160, screenWidth: 1920, passes: 3), 6)
        // The tuning constants feed the same call.
        XCTAssertEqual(AmbientWashRenderer.boxRadius(
            sigmaPoints: AmbientWashTuning.blurSigmaPoints, workingWidth: AmbientWashTuning.width,
            screenWidth: AmbientWashTuning.screenWidthPoints, passes: AmbientWashTuning.blurPasses), 6)
    }

    func testBoxRadiusGrowsWithSigmaAndIsZeroForDegenerateInput() {
        XCTAssertGreaterThan(
            AmbientWashRenderer.boxRadius(sigmaPoints: 160, workingWidth: 160, screenWidth: 1920, passes: 3), 6)
        XCTAssertEqual(AmbientWashRenderer.boxRadius(sigmaPoints: 0, workingWidth: 160, screenWidth: 1920, passes: 3), 0)
        XCTAssertEqual(AmbientWashRenderer.boxRadius(sigmaPoints: 80, workingWidth: 0, screenWidth: 1920, passes: 3), 0)
        XCTAssertEqual(AmbientWashRenderer.boxRadius(sigmaPoints: 80, workingWidth: 160, screenWidth: 0, passes: 3), 0)
        XCTAssertEqual(AmbientWashRenderer.boxRadius(sigmaPoints: 80, workingWidth: 160, screenWidth: 1920, passes: 0), 0)
    }

    // MARK: - exposureGain

    func testExposureGainWindow() {
        // Brighter than the cap: scaled down to it.
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.6), 0.26 / 0.6, accuracy: 1e-6)
        // Darker than the floor: lifted by at most 1.8.
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.04), 1.8, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.05), 1.8, accuracy: 1e-6)
        // Darker than the floor, but within reach: lifted exactly to it.
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.08), 0.10 / 0.08, accuracy: 1e-5)
        // Inside the window: untouched.
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.18), 1, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.26), 1, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0.10), 1, accuracy: 1e-6)
        // Nothing to scale.
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.exposureGain(meanLuma: -0.5), 1, accuracy: 1e-6)
    }

    // MARK: - rgbFloats / meanLuma

    func testRgbFloatsDropsTheAlphaByteAndScalesToUnit() {
        let floats = AmbientWashRenderer.rgbFloats([255, 0, 0, 255, 0, 128, 255, 255])
        XCTAssertEqual(floats.count, 6)
        XCTAssertEqual(floats[0], 1, accuracy: 1e-6)
        XCTAssertEqual(floats[1], 0, accuracy: 1e-6)
        XCTAssertEqual(floats[2], 0, accuracy: 1e-6)
        XCTAssertEqual(floats[3], 0, accuracy: 1e-6)
        XCTAssertEqual(floats[4], 128.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(floats[5], 1, accuracy: 1e-6)
    }

    func testMeanLumaIsRec709OverThePixels() {
        XCTAssertEqual(AmbientWashRenderer.meanLuma([1, 0, 0]), 0.2126, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.meanLuma([0, 1, 0]), 0.7152, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.meanLuma([0, 0, 1]), 0.0722, accuracy: 1e-6)
        // Mean over two pixels (white and black).
        XCTAssertEqual(AmbientWashRenderer.meanLuma([1, 1, 1, 0, 0, 0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AmbientWashRenderer.meanLuma([]), 0)
    }

    // MARK: - boostSaturation

    func testSaturationBoostKeepsLuma() {
        var px: [Float] = [0.5, 0.4, 0.3, 0.3, 0.45, 0.4]
        let before = [luma(px[0], px[1], px[2]), luma(px[3], px[4], px[5])]
        AmbientWashRenderer.boostSaturation(&px, by: 1.25)
        XCTAssertEqual(luma(px[0], px[1], px[2]), before[0], accuracy: 1e-5)
        XCTAssertEqual(luma(px[3], px[4], px[5]), before[1], accuracy: 1e-5)
        // The chroma really grew: red now sits 25 % further above blue than it did.
        XCTAssertEqual(px[0] - px[2], (0.5 - 0.3) * 1.25, accuracy: 1e-5)
    }

    func testSaturationBoostLeavesGreyAloneAndClampsToUnit() {
        var px: [Float] = [0.4, 0.4, 0.4, 1, 0, 0, 0, 0, 1]
        AmbientWashRenderer.boostSaturation(&px, by: 1.25)
        XCTAssertEqual(px[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(px[1], 0.4, accuracy: 1e-6)
        XCTAssertEqual(px[2], 0.4, accuracy: 1e-6)
        XCTAssertTrue(px.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(px)")
        // Pure red stays pure red: the over-range red clamps to 1, the negative green and blue to 0.
        XCTAssertEqual(px[3], 1, accuracy: 1e-6)
        XCTAssertEqual(px[4], 0, accuracy: 1e-6)
        XCTAssertEqual(px[5], 0, accuracy: 1e-6)
    }

    // MARK: - tint

    func testTintMovesTwentyFivePercentTowardTheColour() {
        var px: [Float] = [0, 0, 0, 0.4, 0.4, 0.4, 1, 1, 1]
        AmbientWashRenderer.tint(&px, toward: (r: 1, g: 0, b: 0.2), amount: 0.25)
        let expected: [Float] = [
            0.25, 0, 0.05,
            0.4 * 0.75 + 0.25, 0.4 * 0.75, 0.4 * 0.75 + 0.05,
            1, 0.75, 0.75 + 0.05,
        ]
        for (got, want) in zip(px, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-6)
        }
    }

    func testTintDoesNothingWithoutAColour() {
        var px: [Float] = [0.1, 0.5, 0.9, 0.3, 0.3, 0.3]
        AmbientWashRenderer.tint(&px, toward: nil, amount: 0.25)
        XCTAssertEqual(px, [0.1, 0.5, 0.9, 0.3, 0.3, 0.3])
        var untouched = px
        AmbientWashRenderer.tint(&untouched, toward: (r: 1, g: 1, b: 1), amount: 0)
        XCTAssertEqual(untouched, px)
    }

    // MARK: - boxBlur

    func testBoxBlurStepStaysMonotoneAndKeepsTheMean() {
        let width = 160, height = 90
        var px = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 80..<width {
                for channel in 0..<3 { px[(y * width + x) * 3 + channel] = 1 }
            }
        }
        let meanBefore = px.reduce(0, +) / Float(px.count)
        AmbientWashRenderer.boxBlur(&px, width: width, height: height, radius: 6, passes: 3)
        let meanAfter = px.reduce(0, +) / Float(px.count)
        XCTAssertEqual(meanAfter, meanBefore, accuracy: 1e-3)
        // Monotone across the step, on a middle row.
        let row = 45
        var previous: Float = -1
        for x in 0..<width {
            let value = px[(row * width + x) * 3]
            XCTAssertGreaterThanOrEqual(value, previous - 1e-6, "x=\(x)")
            previous = value
        }
        // Far from the step nothing moved, and the step's own centre is half way.
        XCTAssertEqual(px[(row * width + 10) * 3], 0, accuracy: 1e-5)
        XCTAssertEqual(px[(row * width + 150) * 3], 1, accuracy: 1e-5)
        XCTAssertEqual(px[(row * width + 80) * 3], 0.5, accuracy: 0.06)
        // The blur really spread it: the pixel just left of the step is no longer 0.
        XCTAssertGreaterThan(px[(row * width + 76) * 3], 0.01)
    }

    func testBoxBlurLeavesAUniformImageUnchangedEdgesIncluded() {
        let width = 160, height = 90
        let value: Float = 0.37
        var px = [Float](repeating: value, count: width * height * 3)
        AmbientWashRenderer.boxBlur(&px, width: width, height: height, radius: 6, passes: 3)
        // Edge replication keeps the corner pixel exactly where it was.
        XCTAssertEqual(px[0], value, accuracy: 1e-6)
        XCTAssertEqual(px[px.count - 1], value, accuracy: 1e-6)
        XCTAssertTrue(px.allSatisfy { abs($0 - value) < 1e-6 })
    }

    func testBoxBlurMatchesABruteForceBoxAverageOnOneLine() {
        // A single row (height 1) with radius 2 and one pass: compare to the textbook clamped average.
        let width = 12
        let row: [Float] = [0, 1, 0, 0.5, 0.25, 1, 0, 0, 0.75, 0.1, 1, 0.2]
        var px = [Float]()
        for value in row { px.append(contentsOf: [value, value, value]) }
        AmbientWashRenderer.boxBlur(&px, width: width, height: 1, radius: 2, passes: 1)
        for x in 0..<width {
            var sum: Float = 0
            for offset in -2...2 { sum += row[min(max(x + offset, 0), width - 1)] }
            XCTAssertEqual(px[x * 3], sum / 5, accuracy: 1e-6, "x=\(x)")
        }
    }

    func testBoxBlurIgnoresABadBuffer() {
        var px: [Float] = [0.1, 0.2, 0.3]
        AmbientWashRenderer.boxBlur(&px, width: 10, height: 10, radius: 6, passes: 3)
        XCTAssertEqual(px, [0.1, 0.2, 0.3])
        AmbientWashRenderer.boxBlur(&px, width: 1, height: 1, radius: 0, passes: 3)
        XCTAssertEqual(px, [0.1, 0.2, 0.3])
    }

    // MARK: - downsample

    func testDownsampleIsTopFirstAndOpaque() throws {
        // Top half red, bottom half blue. A bitmap context's origin is bottom-left, so y >= 90 is the top.
        let image = try makeImage(width: 320, height: 180) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 90))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 90, width: 320, height: 90))
        }
        let rgba = try XCTUnwrap(AmbientWashRenderer.downsample(image, width: 160, height: 90))
        XCTAssertEqual(rgba.count, 160 * 90 * 4)
        func bytes(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[((y * 160 + x) * 4)..<((y * 160 + x) * 4 + 4)]) }
        let top = bytes(80, 2)
        let bottom = bytes(80, 87)
        XCTAssertGreaterThan(top[0], 240, "top row is red \(top)")
        XCTAssertLessThan(top[2], 15, "\(top)")
        XCTAssertGreaterThan(bottom[2], 240, "bottom row is blue \(bottom)")
        XCTAssertLessThan(bottom[0], 15, "\(bottom)")
        XCTAssertTrue(stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 }, "every pixel is opaque")
    }

    func testDownsampleFillsTheFrameFromAPortraitSource() throws {
        // Aspect-FILL: a 171x256 portrait image is cropped to the 16:9 frame, so no black bleeds in.
        let image = try grey(1, width: 171, height: 256)
        let rgba = try XCTUnwrap(AmbientWashRenderer.downsample(image, width: 160, height: 90))
        XCTAssertEqual(rgba.count, 160 * 90 * 4)
        let minimum = rgba.min() ?? 0
        XCTAssertGreaterThanOrEqual(minimum, 250, "white source, no black borders")
    }

    func testDownsampleRejectsDegenerateSizes() throws {
        let image = try grey(0.5)
        XCTAssertNil(AmbientWashRenderer.downsample(image, width: 0, height: 90))
        XCTAssertNil(AmbientWashRenderer.downsample(image, width: 160, height: -1))
    }

    // MARK: - render

    func testRenderOfLargeAndPortraitSourcesIsA160By90HalfFloatBitmap() throws {
        let large = try makeImage(width: 3840, height: 2160) { context in
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
            context.setFillColor(red: 0.8, green: 0.5, blue: 0.1, alpha: 1)
            context.fill(CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        }
        let portrait = try makeImage(width: 171, height: 256) { context in
            context.setFillColor(red: 0.6, green: 0.2, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 171, height: 256))
        }
        for source in [large, portrait] {
            let output = try XCTUnwrap(AmbientWashRenderer.render(source))
            let image = output.image
            XCTAssertEqual(image.width, 160)
            XCTAssertEqual(image.height, 90)
            XCTAssertEqual(image.bitsPerComponent, 16)
            XCTAssertEqual(image.bitsPerPixel, 64)
            XCTAssertTrue(image.bitmapInfo.contains(.floatComponents), "half floats")
            XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.extendedSRGB as String?)
            XCTAssertGreaterThanOrEqual(output.millis, 0)
            XCTAssertGreaterThan(output.meanLuma, 0)
            XCTAssertLessThanOrEqual(output.meanLuma, AmbientWashTuning.maxMeanLuma + 0.002)
            XCTAssertEqual(try halfFloats(of: image).count, 160 * 90 * 4)
        }
    }

    func testWhiteArtIsCappedAtTheMaxMeanLuma() throws {
        let output = try XCTUnwrap(AmbientWashRenderer.render(try grey(1)))
        XCTAssertLessThanOrEqual(output.meanLuma, AmbientWashTuning.maxMeanLuma + 0.001)
        XCTAssertEqual(output.meanLuma, 0.26, accuracy: 0.002)
        // The pixels agree with the reported mean: white scaled to 0.26 on every channel.
        let floats = try halfFloats(of: output.image)
        let centre = pixel(floats, x: 80, y: 45)
        XCTAssertEqual(centre.r, 0.26, accuracy: 0.002)
        XCTAssertEqual(centre.g, 0.26, accuracy: 0.002)
        XCTAssertEqual(centre.b, 0.26, accuracy: 0.002)
    }

    func testNearBlackArtIsLiftedByTheMaxGain() throws {
        let source = try grey(0.02)
        // What the 8-bit bitmap actually holds for 0.02 (5/255), whatever rounding Core Graphics used.
        let input = Float(try XCTUnwrap(AmbientWashRenderer.downsample(source, width: 160, height: 90))[0]) / 255
        let output = try XCTUnwrap(AmbientWashRenderer.render(source))
        XCTAssertEqual(output.meanLuma, input * 1.8, accuracy: 0.002)
        XCTAssertLessThan(output.meanLuma, AmbientWashTuning.minMeanLuma, "near-black stays dark, it is not lifted to grey")
    }

    func testGreyArtGetsNoTint() throws {
        let output = try XCTUnwrap(AmbientWashRenderer.render(try grey(0.5)))
        let floats = try halfFloats(of: output.image)
        for (x, y) in [(0, 0), (80, 45), (159, 89)] {
            let p = pixel(floats, x: x, y: y)
            XCTAssertEqual(p.r, p.g, accuracy: 0.002, "x=\(x) y=\(y)")
            XCTAssertEqual(p.g, p.b, accuracy: 0.002, "x=\(x) y=\(y)")
        }
        XCTAssertEqual(output.meanLuma, 0.26, accuracy: 0.002, "0.5 grey is scaled down to the cap")
    }

    func testVividArtKeepsItsHueAndAnEvenWashOfIt() throws {
        // A warm red: the wash must stay red-dominant (boost and tint both push the same way), and the
        // exposure step caps its luma.
        let output = try XCTUnwrap(AmbientWashRenderer.render(try solid(red: 0.8, green: 0.2, blue: 0.1)))
        let floats = try halfFloats(of: output.image)
        let centre = pixel(floats, x: 80, y: 45)
        XCTAssertGreaterThan(centre.r, 0.6)
        XCTAssertLessThan(centre.g, 0.25)
        XCTAssertLessThan(centre.b, 0.1)
        XCTAssertEqual(luma(centre.r, centre.g, centre.b), output.meanLuma, accuracy: 0.003)
        XCTAssertLessThanOrEqual(output.meanLuma, AmbientWashTuning.maxMeanLuma + 0.002)
    }

    func testRenderIsDeterministic() throws {
        let source = try makeImage(width: 640, height: 360) { context in
            context.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 100, y: 40, width: 300, height: 200))
        }
        let first = try XCTUnwrap(AmbientWashRenderer.render(source))
        let second = try XCTUnwrap(AmbientWashRenderer.render(source))
        XCTAssertEqual(first.meanLuma, second.meanLuma)
        let a = try XCTUnwrap(first.image.dataProvider?.data) as Data
        let b = try XCTUnwrap(second.image.dataProvider?.data) as Data
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    // MARK: - makeCGImage

    func testMakeCGImageRoundTripsHalfFloatValues() throws {
        let image = try XCTUnwrap(AmbientWashRenderer.makeCGImage([0.5, 0.25, 1.0], width: 1, height: 1))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        let floats = try halfFloats(of: image)
        XCTAssertEqual(floats.count, 4)
        XCTAssertEqual(floats[0], 0.5, accuracy: 1e-3)
        XCTAssertEqual(floats[1], 0.25, accuracy: 1e-3)
        XCTAssertEqual(floats[2], 1.0, accuracy: 1e-3)
        XCTAssertEqual(floats[3], 1.0, accuracy: 1e-3, "the alpha lane stays opaque")
    }

    func testMakeCGImageRejectsAMismatchedBuffer() {
        XCTAssertNil(AmbientWashRenderer.makeCGImage([0.1, 0.2], width: 1, height: 1))
        XCTAssertNil(AmbientWashRenderer.makeCGImage([], width: 0, height: 0))
    }

    // MARK: - AmbientWashCache

    func testCacheStoresAndReturnsByIdentity() throws {
        let cache = AmbientWashCache(countLimit: 4)
        let pixels = [Float](repeating: 0.2, count: AmbientWashTuning.width * AmbientWashTuning.height * 3)
        let image = try XCTUnwrap(AmbientWashRenderer.makeCGImage(
            pixels, width: AmbientWashTuning.width, height: AmbientWashTuning.height))
        let output = AmbientWashRenderer.Output(image: image, meanLuma: 0.2, millis: 1)
        XCTAssertNil(cache.output(for: "movie:tt1"))
        cache.store(output, for: "movie:tt1")
        let hit = try XCTUnwrap(cache.output(for: "movie:tt1"))
        XCTAssertTrue(hit.image === image)
        XCTAssertEqual(hit.meanLuma, 0.2)
        XCTAssertNil(cache.output(for: "movie:tt2"))
        cache.removeAll()
        XCTAssertNil(cache.output(for: "movie:tt1"))
    }
}
