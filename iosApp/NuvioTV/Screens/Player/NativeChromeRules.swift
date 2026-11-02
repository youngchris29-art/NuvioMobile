import Foundation
import SharedCore

// Insights wave 1c: the pure rules behind the native route's Rivulet / AVKit tvOS 26 chrome, kept
// free of UIKit so NuvioTVTests can pin them. The UIKit side is `NativeInfoPills.swift` (the text
// pills under the seek bar) and `NativeTransportMenus.swift` (the round tool buttons).

/// Which text pills the native player hosts as `customInfoViewControllers`.
enum NativePillPlan {
    /// tvOS draws its own Chapters pill from the `navigationMarkerGroups` the remux sets
    /// (`NativeChapterMarkers.groups`), so the native route does not add a second one. Flip to
    /// false if the device pass shows no system pill; `PlayerChaptersTab` is then hosted instead.
    static let systemDrawsChapterPill = true

    /// tvOS draws its own "Info" pill whenever the item carries `externalMetadata` (title, episode
    /// line, synopsis, artwork: `NativeNowPlayingMetadata`), which the native route always sets
    /// (it also feeds the title view and Now Playing). The app's Info content therefore goes in
    /// under another name and without the what's-playing header the system pill already shows:
    /// "Stream Info" (badges, metadata chips, the live stream rows the system cannot show).
    static let systemDrawsInfoPill = true

    /// One fixed content height for every custom pill. AVKit sizes all the info tabs to the
    /// tallest `preferredContentSize`, so differing heights only make the band jump between tabs;
    /// 420 pt fits the Cast card row (and its focus lift) under the pill row on tvOS 26.
    static let contentHeight: CGFloat = 420
    /// The content width offered to AVKit (it clamps to the panel's own width).
    static let contentWidth: CGFloat = 1760

    /// `PlayerInfoPill.visible(for:)` as the native screen applies it: the shared order, minus
    /// Chapters while the system draws that pill itself.
    static func pills(visible: [PlayerInfoPill], systemChapterPill: Bool = systemDrawsChapterPill) -> [PlayerInfoPill] {
        systemChapterPill ? visible.filter { $0 != .chapters } : visible
    }

    /// The pill's title on the native route: the shared one, except Info, which is "Stream Info"
    /// while the system draws its own "Info" pill (no "Info · Info" row).
    static func title(for pill: PlayerInfoPill, systemInfoPill: Bool = systemDrawsInfoPill) -> String {
        pill == .info && systemInfoPill ? String(localized: "Stream Info") : pill.title
    }

    /// The pill row as tvOS draws it: the system's own Info pill (when it draws one) followed by
    /// the custom pills' titles. Used by the tests to pin "no duplicate title".
    static func rowTitles(custom: [PlayerInfoPill], systemInfoPill: Bool = systemDrawsInfoPill) -> [String] {
        (systemInfoPill ? [PlayerInfoPill.info.title] : []) + custom.map { title(for: $0, systemInfoPill: systemInfoPill) }
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

/// Menu inside the Cast pill. With the actor view open the press goes back to the card row: both
/// halves are consumed, and the view tree changes only on the release (the app's rule: never
/// mutate the focused view tree mid-press, or the release lands on AVKit, which closes the whole
/// pill). Otherwise the press passes on to AVKit, which closes the pill.
struct NativePillMenuRouter {
    /// What the controller does with a Menu release.
    enum Release: Equatable {
        /// Not ours: hand it to `super` (AVKit).
        case passOn
        /// Consume it and back out of the actor view (`PlayerTopPanelModel.menuBack`) now.
        case consumeAndBack
    }

    private var pending = false

    /// Whether the pill takes Menu at all: the Cast pill with its actor view open.
    static func intercepts(pill: PlayerInfoPill, actorViewOpen: Bool) -> Bool {
        pill == .cast && actorViewOpen
    }

    /// Menu went down. True = consumed (nothing changes yet; the release does the work).
    mutating func menuBegan(pill: PlayerInfoPill, actorViewOpen: Bool) -> Bool {
        pending = Self.intercepts(pill: pill, actorViewOpen: actorViewOpen)
        return pending
    }

    /// Menu came up. A press consumed on the way down is consumed here too and backs out.
    mutating func menuEnded() -> Release {
        defer { pending = false }
        return pending ? .consumeAndBack : .passOn
    }

    /// The press was cancelled (focus moved mid-press): forget it, change nothing.
    mutating func menuCancelled() { pending = false }
}
