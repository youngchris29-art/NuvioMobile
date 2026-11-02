import Foundation
import SharedCore

// Insights wave 1c: the pure rules behind the native route's Rivulet / AVKit tvOS 26 chrome, kept
// free of UIKit so NuvioTVTests can pin them. The UIKit side is `NativeInfoPills.swift` (the text
// pills under the seek bar) and `NativePlayerScreen.installTransportMenu` (the round tool buttons).

/// Which text pills the native player hosts as `customInfoViewControllers`.
enum NativePillPlan {
    /// tvOS draws its own Chapters pill from the `navigationMarkerGroups` the remux sets
    /// (`NativeChapterMarkers.groups`), so the native route does not add a second one. Flip to
    /// false if the device pass shows no system pill; `PlayerChaptersTab` is then hosted instead.
    static let systemDrawsChapterPill = true

    /// `PlayerInfoPill.visible(for:)` as the native screen applies it: the shared order, minus
    /// Chapters while the system draws that pill itself.
    static func pills(visible: [PlayerInfoPill], systemChapterPill: Bool = systemDrawsChapterPill) -> [PlayerInfoPill] {
        systemChapterPill ? visible.filter { $0 != .chapters } : visible
    }
}

/// The subtitle Timing tool button: −0.5 s / +0.5 s / Reset, clamped to the shared delay range.
enum NativeSubtitleTiming {
    static let stepMs = 500

    static var minMs: Int { Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MIN_MS) }
    static var maxMs: Int { Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MAX_MS) }

    /// `current + deltaMs`, clamped to `[minMs, maxMs]`.
    static func adjusted(_ current: Int, by deltaMs: Int, minMs: Int = minMs, maxMs: Int = maxMs) -> Int {
        min(maxMs, max(minMs, current + deltaMs))
    }

    /// "+0.5 s", "−1.5 s", "0 s": the delay as the menu shows it (positive = subtitles later).
    static func label(_ ms: Int) -> String {
        guard ms != 0 else { return "0 s" }
        let seconds = String(format: "%g", Double(abs(ms)) / 1000)
        return "\(ms > 0 ? "+" : "\u{2212}")\(seconds) s"
    }
}

/// Menu inside the Cast pill. With the actor view open the press goes back to the card row and
/// both halves of it are swallowed; otherwise it passes on to AVKit, which closes the pill.
struct NativePillMenuRouter {
    private var swallowRelease = false

    /// Menu went down. `menuBack` is `PlayerTopPanelModel.menuBack`. True = consumed.
    mutating func menuBegan(menuBack: () -> Bool) -> Bool {
        let consumed = menuBack()
        swallowRelease = consumed
        return consumed
    }

    /// Menu came up. True = consumed (its press was consumed on the way down).
    mutating func menuEnded() -> Bool {
        defer { swallowRelease = false }
        return swallowRelease
    }

    /// The press was cancelled (focus moved mid-press): forget a pending swallow.
    mutating func menuCancelled() { swallowRelease = false }
}
