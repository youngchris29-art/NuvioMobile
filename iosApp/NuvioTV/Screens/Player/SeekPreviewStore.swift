import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes and decodes one preview frame for `SeekPreviewStore` (tests use a fake).
nonisolated protocol PreviewFrameCodec: Sendable {
    func encode(_ image: CGImage) -> Data?
    func decode(_ data: Data) -> CGImage?
}

/// JPEG through ImageIO, quality 0.6 (about 12–25 KB for a 320 × 180 frame).
nonisolated struct JPEGPreviewCodec: PreviewFrameCodec {
    static let quality = 0.6

    func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let props = [kCGImageDestinationLossyCompressionQuality: Self.quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// The seek-preview thumbnail store (P2): small frames harvested from the mpv decode, one per
/// ~10 s of playback, kept in memory for the life of the player controller. No disk, no sync.
/// Eviction is by insertion order (lookups do not refresh), so at 200 entries × 10 s the store
/// covers roughly the last 33 minutes harvested.
actor SeekPreviewStore {
    static let defaultMaxEntries = 200
    static let defaultMaxBytes = 6 * 1024 * 1024
    static let targetWidth = 320

    private struct Entry {
        let sec: Double
        let jpeg: Data
        let seq: UInt64
    }

    let streamKey: String
    private let codec: PreviewFrameCodec
    private let maxEntries: Int
    private let maxBytes: Int
    private var entries: [Entry] = []          // sorted by `sec`
    private var nextSeq: UInt64 = 0
    private var bytes = 0
    private var lastDecoded: (seq: UInt64, image: CGImage)?

    init(streamKey: String, codec: PreviewFrameCodec = JPEGPreviewCodec(),
         maxEntries: Int = defaultMaxEntries, maxBytes: Int = defaultMaxBytes) {
        self.streamKey = streamKey
        self.codec = codec
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
    }

    var count: Int { entries.count }
    var byteCount: Int { bytes }

    func insert(_ image: CGImage, at sec: Double) {
        guard sec.isFinite, sec >= 0, image.width <= Self.targetWidth else { return }
        guard let jpeg = codec.encode(image) else { return }
        nextSeq &+= 1
        let entry = Entry(sec: sec, jpeg: jpeg, seq: nextSeq)
        // Replace the nearest existing entry within 1 s.
        if let i = nearestIndex(to: sec), abs(entries[i].sec - sec) <= 1.0 {
            invalidateDecode(entries[i].seq)
            bytes -= entries[i].jpeg.count
            entries.remove(at: i)
        }
        entries.insert(entry, at: insertionIndex(for: sec))
        bytes += jpeg.count
        while entries.count > maxEntries || bytes > maxBytes {
            guard let oldest = entries.indices.min(by: { entries[$0].seq < entries[$1].seq }) else { break }
            invalidateDecode(entries[oldest].seq)
            bytes -= entries[oldest].jpeg.count
            entries.remove(at: oldest)
        }
    }

    /// `SeekPreviewSource`: the default tolerance.
    func thumbnail(near sec: Double) -> CGImage? { thumbnail(near: sec, tolerance: nil) }

    /// The entry nearest `sec` (ties go to the earlier one), or nil when it is further than
    /// `tolerance` (default: the sample spacing clamped to 5…30 s).
    func thumbnail(near sec: Double, tolerance: Double?) -> CGImage? {
        guard sec.isFinite, let i = nearestIndex(to: sec) else { return nil }
        let tol = tolerance ?? min(max(sampleSpacing(), 5), 30)
        let e = entries[i]
        guard abs(e.sec - sec) <= tol else { return nil }
        if let cached = lastDecoded, cached.seq == e.seq { return cached.image }
        guard let image = codec.decode(e.jpeg) else { return nil }
        lastDecoded = (e.seq, image)
        return image
    }

    /// Median of the gaps between consecutive stamps, counting only gaps ≤ 60 s (a seek leaves a
    /// hole that is not spacing); 10 when fewer than two such gaps exist.
    func sampleSpacing() -> Double {
        guard entries.count >= 3 else { return 10 }
        var gaps: [Double] = []
        for i in 1..<entries.count {
            let g = entries[i].sec - entries[i - 1].sec
            if g <= 60 { gaps.append(g) }
        }
        guard gaps.count >= 2 else { return 10 }
        gaps.sort()
        let mid = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[mid] : (gaps[mid - 1] + gaps[mid]) / 2
    }

    /// Runs of stamps whose gaps are ≤ 2 × the sample spacing; a lone stamp is `s...s`.
    func coverage() -> [ClosedRange<Double>] {
        guard let first = entries.first else { return [] }
        let join = 2 * sampleSpacing()
        var out: [ClosedRange<Double>] = []
        var lo = first.sec, hi = first.sec
        for e in entries.dropFirst() {
            if e.sec - hi <= join { hi = e.sec } else { out.append(lo...hi); lo = e.sec; hi = e.sec }
        }
        out.append(lo...hi)
        return out
    }

    func removeAll() {
        entries.removeAll()
        bytes = 0
        lastDecoded = nil
    }

    // MARK: - Private

    private func invalidateDecode(_ seq: UInt64) {
        if lastDecoded?.seq == seq { lastDecoded = nil }
    }

    /// First index whose `sec` is ≥ `sec`.
    private func insertionIndex(for sec: Double) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].sec < sec { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func nearestIndex(to sec: Double) -> Int? {
        guard !entries.isEmpty else { return nil }
        let i = insertionIndex(for: sec)
        if i == 0 { return 0 }
        if i == entries.count { return entries.count - 1 }
        // Tie goes to the earlier entry.
        return (sec - entries[i - 1].sec) <= (entries[i].sec - sec) ? i - 1 : i
    }
}

extension SeekPreviewStore: SeekPreviewSource {}

/// One decoded frame copied out of `screenshot-raw` (no subtitles, no OSD).
nonisolated struct MPVRawFrame: Sendable {
    let width: Int
    let height: Int
    let stride: Int
    let format: String
    let bytes: Data
}

/// Turns a raw mpv frame into a store-sized thumbnail. Pure; runs off the main thread.
nonisolated enum PreviewFrameScaler {
    static func bitmapInfo(for format: String) -> CGBitmapInfo? {
        switch format {
        case "bgr0":
            return CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case "bgra":
            return CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case "rgba":
            return CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        default:
            return nil
        }
    }

    static func targetHeight(width: Int, sourceWidth: Int, sourceHeight: Int) -> Int {
        guard sourceWidth > 0 else { return 2 }
        return max(2, Int((Double(width) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
    }

    static func makeThumbnail(_ f: MPVRawFrame, width: Int = SeekPreviewStore.targetWidth) -> CGImage? {
        guard f.width > 0, f.height > 0, let info = bitmapInfo(for: f.format),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: f.bytes as CFData),
              let source = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: f.stride, space: space, bitmapInfo: info, provider: provider,
                                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let w = min(width, f.width)
        let h = targetHeight(width: w, sourceWidth: f.width, sourceHeight: f.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// The process's physical footprint (what jetsam counts), for the Info tab's Seek Previews row.
nonisolated enum ProcessMemory {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }
}
