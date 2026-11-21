import Foundation
import NuvioAether

// Aether disk cache (GitHub #29), Settings › Player › Buffering › Disk Cache. One pure decision,
// `AetherDiskCachePlan.resolve`, turns the stored choice, the Aether toggle and the free space on the
// tmp volume into the request's cache fields, the whole GB the row shows and the row's label, all from
// the same G: G = ⌊min(choice × 10⁹, ⌊free / 4⌋) / 10⁹⌋, hard limit N = G × 10⁹, budget = N − headroom(N).
// The label never shows more than the hard limit the load sends. Off, Aether off, unknown free space
// and G < 1 send nil: the engine's defaults for every cache field. The app writes and deletes no cache
// file; the engine owns its directory and its cleanup.

/// The stored choice (`player.diskCacheGB`): 0 Off, 5 / 10 / 20 GB, -1 Maximum.
nonisolated enum AetherDiskCacheChoice: Hashable, Sendable {
    case off
    /// 5, 10 or 20 (`fixedSizes`).
    case gigabytes(Int)
    /// A quarter of the free space, rounded down to a whole GB.
    case maximum

    static let fixedSizes = [5, 10, 20]
    static let maximumRawValue = -1
    /// Off, 5, 10, 20, Maximum: the menu order.
    static let all: [AetherDiskCacheChoice] = [.off] + fixedSizes.map { .gigabytes($0) } + [.maximum]

    /// 0 → Off; 5 / 10 / 20 → that size; -1 → Maximum; anything else → Off.
    init(rawValue: Int) {
        if rawValue == Self.maximumRawValue {
            self = .maximum
        } else if Self.fixedSizes.contains(rawValue) {
            self = .gigabytes(rawValue)
        } else {
            self = .off
        }
    }

    var rawValue: Int {
        switch self {
        case .off: return 0
        case .gigabytes(let g): return g
        case .maximum: return Self.maximumRawValue
        }
    }
}

/// The row's value (and a menu item's text).
nonisolated enum AetherDiskCacheLabel: Equatable, Sendable {
    case off
    /// A fixed size that fits: "5 GB".
    case gigabytes(Int)
    /// Maximum, or a fixed size above the quarter of the free space: "Up to 24 GB".
    case upTo(Int)
    /// Only under `.budgetOnly` enforcement (not shipped while the hard limit stays): "About 24 GB".
    case about(Int)
    /// Before the first free-space reading: the choice's own name, no size claimed.
    case unmeasured(AetherDiskCacheChoice)
    /// A non-Off choice that rounds down to under 1 GB.
    case notEnoughSpace

    var text: String {
        switch self {
        case .off: return String(localized: "Off")
        case .gigabytes(let g): return String(localized: "\(g) GB")
        case .upTo(let g): return String(localized: "Up to \(g) GB")
        case .about(let g): return String(localized: "About \(g) GB")
        case .unmeasured(let choice): return AetherDiskCachePlan.itemName(choice)
        case .notEnoughSpace: return String(localized: "Not enough free space")
        }
    }
}

/// What `resolve` decides, all from one G.
nonisolated struct AetherDiskCacheResolution: Equatable, Sendable {
    /// The whole GB shown and enforced; nil when nothing is enforced (Off, Aether off, unknown free, G < 1).
    let shownGB: Int?
    /// What the load sends; nil = Off. Under `.hardLimit`, `hardLimitBytes == shownGB × 10⁹`.
    let cache: AetherDiskCache?
    /// The row's value. Under `.hardLimit`, `.gigabytes(g)` / `.upTo(g)` only with g == the enforced G.
    let label: AetherDiskCacheLabel
}

/// Decision R: the hard limit stays unless the spike drops it (then every on value reads "About G GB").
nonisolated enum AetherDiskCacheEnforcement: Equatable, Sendable { case hardLimit, budgetOnly }

/// The inputs a fresh load reads, once. Injected so tests supply them.
nonisolated struct AetherDiskCacheInputs: Equatable, Sendable {
    let choice: AetherDiskCacheChoice
    let aetherOn: Bool
    let freeBytes: Int64?
    #if DEBUG
    /// Harness only (code review r4, finding 3): `debug.diskCacheHardLimitBytes` <bytes> lowers the hard
    /// limit of a load that is already On, so the integration leg can fill the cache with a small fixture.
    /// DEBUG only: a Release build has no such field, key or code path.
    var debugHardLimitBytes: Int? = nil
    #endif

    /// The stored choice, the Aether toggle and the tmp volume's free space, read now. The one place a
    /// fresh load's cache inputs are read.
    static func live() -> AetherDiskCacheInputs {
        #if DEBUG
        return AetherDiskCacheInputs(choice: AetherTuning.diskCacheChoice(),
                                     aetherOn: AetherTuning.isEngineEnabled(),
                                     freeBytes: TemporaryVolumeSpace.availableBytes(),
                                     debugHardLimitBytes: AetherDiskCachePlan.debugHardLimit(defaults: .standard))
        #else
        return AetherDiskCacheInputs(choice: AetherTuning.diskCacheChoice(),
                                     aetherOn: AetherTuning.isEngineEnabled(),
                                     freeBytes: TemporaryVolumeSpace.availableBytes())
        #endif
    }
}

nonisolated enum AetherDiskCachePlan {
    static let bytesPerGB: Int64 = 1_000_000_000
    static let headroomCapBytes: Int64 = 2_000_000_000
    /// The forward window every On load sends, whatever route the engine then picks (code review r1,
    /// finding 2). The engine has one window field for both routes and decides the route itself after
    /// `load` (codec, the hardware decode probe, Dolby Vision dual layer and what the box can afford,
    /// escalations mid-play), so the app does not predict it. On the loopback route the window lets the
    /// producer fill the disk budget. On the software route the same field sets the in-memory packet
    /// store's forward-seconds limit (window × 4 s, `SoftwarePlaybackHost.swift:1759-1765`), while the
    /// store stays bounded by its fixed tvOS memory caps (96 MiB forward, 128 MiB history,
    /// `SoftwarePlaybackHost.swift:77, 113-125`): a low-bitrate software title reads further ahead in
    /// memory, up to that cap, than with Off (~40 s). The explainer says software-decoded videos buffer
    /// in memory up to a small fixed limit, which holds in both cases.
    static let forwardSegments = 2700
    /// Decision R, pending the device spike. `.budgetOnly` drops the hard limit and relabels.
    static let enforcement: AetherDiskCacheEnforcement = .hardLimit

    /// The row shows only while Experimental engine: Aether is On; the stored choice is kept while hidden.
    static func rowVisible(aetherOn: Bool) -> Bool { aetherOn }

    /// ⌊free / 4⌋, the engine's integer division; nil when free is unknown or negative.
    static func quarterOfFree(_ freeBytes: Int64?) -> Int64? {
        guard let freeBytes, freeBytes >= 0 else { return nil }
        return freeBytes / 4
    }

    /// Room kept for the 20 segments behind the playhead: min(2 GB, N / 4).
    static func headroom(for n: Int64) -> Int64 { min(headroomCapBytes, n / 4) }

    /// THE decision, used by the load and by the row. Total over every input.
    static func resolve(_ choice: AetherDiskCacheChoice, aetherOn: Bool, freeBytes: Int64?,
                        enforcement: AetherDiskCacheEnforcement = enforcement) -> AetherDiskCacheResolution {
        let requested: Int64?   // the choice in bytes; nil = Maximum
        switch choice {
        case .off:
            return AetherDiskCacheResolution(shownGB: nil, cache: nil, label: .off)
        case .gigabytes(let g):
            guard g > 0 else { return AetherDiskCacheResolution(shownGB: nil, cache: nil, label: .off) }
            let (bytes, overflow) = Int64(g).multipliedReportingOverflow(by: bytesPerGB)
            requested = overflow ? Int64.max : bytes
        case .maximum:
            requested = nil
        }
        guard let quarter = quarterOfFree(freeBytes) else {
            return AetherDiskCacheResolution(shownGB: nil, cache: nil, label: .unmeasured(choice))
        }
        let allowed = requested.map { min($0, quarter) } ?? quarter
        let shown = allowed / bytesPerGB
        guard shown >= 1 else {
            return AetherDiskCacheResolution(shownGB: nil, cache: nil, label: .notEnoughSpace)
        }
        let g = Int(shown)
        let n = shown * bytesPerGB
        let label: AetherDiskCacheLabel
        switch enforcement {
        case .budgetOnly:
            label = .about(g)
        case .hardLimit:
            if case .gigabytes(let fixed) = choice, fixed == g { label = .gigabytes(g) } else { label = .upTo(g) }
        }
        // Aether off: nothing is sent or enforced; the label reads as if on (the row is hidden then).
        guard aetherOn else { return AetherDiskCacheResolution(shownGB: nil, cache: nil, label: label) }
        let cache = AetherDiskCache(budgetBytes: Int(n - headroom(for: n)),
                                    hardLimitBytes: enforcement == .hardLimit ? Int(n) : nil,
                                    forwardSegments: forwardSegments)
        return AetherDiskCacheResolution(shownGB: g, cache: cache, label: label)
    }

    #if DEBUG
    /// Harness only (code review r4, finding 3), read by `AetherDiskCacheInputs.live()`.
    static let debugHardLimitKey = "debug.diskCacheHardLimitBytes"

    /// The key as a positive byte count; nil when absent or not positive. `integer(forKey:)` coerces a
    /// launch argument's string.
    static func debugHardLimit(defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: debugHardLimitKey) != nil else { return nil }
        let bytes = defaults.integer(forKey: debugHardLimitKey)
        return bytes > 0 ? bytes : nil
    }

    /// The override applied to a resolved cache: only ever lowers an On load's hard limit (never turns a
    /// load On, never raises it), with the budget and window derived as `resolve` derives them.
    static func applyingDebugHardLimit(_ cache: AetherDiskCache?, _ override: Int?) -> AetherDiskCache? {
        guard let cache, let override, override > 0 else { return cache }
        let hard = min(override, cache.hardLimitBytes ?? override)
        let n = Int64(hard)
        return AetherDiskCache(budgetBytes: Int(n - headroom(for: n)), hardLimitBytes: hard,
                               forwardSegments: cache.forwardSegments)
    }
    #endif

    /// Menu items: Off, each fixed size whose bytes fit in ⌊¼ free⌋ (all of them while free is
    /// unknown), Maximum. The stored choice always stays, so the picker's selection is valid.
    static func options(stored: AetherDiskCacheChoice, freeBytes: Int64?) -> [AetherDiskCacheChoice] {
        let quarter = quarterOfFree(freeBytes)
        var sizes = AetherDiskCacheChoice.fixedSizes.filter { g in
            guard let quarter else { return true }
            return Int64(g) * bytesPerGB <= quarter
        }
        if case .gigabytes(let g) = stored, !sizes.contains(g) {
            sizes.append(g)
            sizes.sort()
        }
        return [.off] + sizes.map { .gigabytes($0) } + [.maximum]
    }

    /// The closed row's value for the stored choice (code review r1, finding 3): the size the next load
    /// would enforce at this free-space reading, so "Up to G GB" shows G == the hard limit in GB. The
    /// menu items do not use it: two choices can resolve to the same size ("20 GB" clamped and Maximum
    /// both "Up to 10 GB" at 40 GB free), so each item shows `itemName` instead.
    static func rowLabel(stored: AetherDiskCacheChoice, freeBytes: Int64?) -> AetherDiskCacheLabel {
        resolve(stored, aetherOn: true, freeBytes: freeBytes).label
    }

    /// A menu item's own name ("Off", "5 GB", "10 GB", "20 GB", "Maximum"), independent of free space,
    /// so distinct choices always read differently in the menu.
    static func itemName(_ choice: AetherDiskCacheChoice) -> String {
        switch choice {
        case .off: return String(localized: "Off")
        case .gigabytes(let g): return String(localized: "\(g) GB")
        case .maximum: return String(localized: "Maximum")
        }
    }
}

/// Free space on the volume the engine caches to, read the way the engine reads it on tvOS.
nonisolated enum TemporaryVolumeSpace {
    /// `.volumeAvailableCapacityKey` on `NSTemporaryDirectory()`, through a fresh URL each call
    /// (resource values are cached per URL instance). nil when unreadable.
    static func availableBytes(at path: String = NSTemporaryDirectory()) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }
}

#if DEBUG
/// The cache fields of `debug_seekProbe` on Aether (code review r4, finding 3): the engine's own ledger
/// as `LiveEngine` last received it, and the resident span the transport shows. Harness only.
///   `creq=<bytes|-> croute=<route> cdisk=<bytes> cpeak=<bytes> chard=<bytes|-> cevict=<n> crej=<n> cwait=<0|1> bfrom=<s> bto=<s> branges=<n>`
/// `creq` is the hard limit the load requested and `croute` the engine's route; the ledger fields read
/// `cdisk=-` while the loopback route owns no cache.
nonisolated enum AetherCacheProbe {
    static func text(_ s: AetherSessionCacheSnapshot?, resident: [ClosedRange<Double>],
                     requestedHard: Int?, route: String) -> String {
        let head = "creq=\(requestedHard.map(String.init) ?? "-") croute=\(route) "
        guard let s else { return head + "cdisk=-" }
        let from = resident.map(\.lowerBound).min()
        let to = resident.map(\.upperBound).max()
        func sec(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        return head + "cdisk=\(s.diskBytes) cpeak=\(s.peakDiskBytes) chard=\(s.hardLimitBytes.map(String.init) ?? "-") "
            + "cevict=\(s.evictions) crej=\(s.rejectedWrites) cwait=\(s.admissionWaiting ? 1 : 0) "
            + "bfrom=\(sec(from)) bto=\(sec(to)) branges=\(resident.count)"
    }
}
#endif
