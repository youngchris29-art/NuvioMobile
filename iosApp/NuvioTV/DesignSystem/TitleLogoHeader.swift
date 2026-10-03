import SwiftUI
import UIKit

/// A title header that shows a configured logo image once it loads, falling back to plain text
/// while it loads or when the title has none.
///
/// BUG-38 (folder page hero): originated as `CollectionsUI.swift`'s private `FolderHeroTitle` — the
/// folder page's title, showing `titleLogoUrl` through the same `ArtworkStore` path `HeroLogo`
/// (`HomeView.swift`) uses for the Home hero's logo, capped to the pinned Home hero's logo slot so a
/// 1:1 genre badge and a wide wordmark both sit on one baseline.
///
/// rc13: promoted to `DesignSystem` and generalized with three extra parameters (`alignment`,
/// `textFont`, `slotHeight`) so more than one screen can share the exact same load/cache/fallback
/// behavior instead of a per-screen copy — `StreamPickerView`/the episode picker (FEAT-42) want the
/// original leading/`screenTitle`/pinned-height layout (the defaults below reproduce it byte-
/// identically), while `FolderDetailView`'s header (FEAT-40) wants centred + `Theme.Font.hero` + the
/// taller `Theme.Size.heroLogoSlotHeight`. The body below is otherwise unchanged from
/// `FolderHeroTitle`, including its Codex round-1 fixes.
struct TitleLogoHeader: View {
    let title: String
    let alignment: Alignment
    let textFont: Font
    let slotHeight: CGFloat
    private let logoUrl: String?
    private let url: URL?
    /// beta.19-rc1 verdict (I1, BUG-134): how large the logo is decoded, and which larger rendition of
    /// the same file to try first (TMDB `original`, see `ArtworkURLUpgrade`). Both default to the
    /// old behaviour (`.legacy`, no upgrade), so a caller that has not opted in loads exactly as it
    /// did.
    private let decodeSize: ArtworkDecodeSize
    private let upgrade: ArtworkURLUpgrade.Role?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    init(
        title: String,
        logoUrl: String?,
        alignment: Alignment = .leading,
        textFont: Font = Theme.Font.screenTitle,
        slotHeight: CGFloat = Theme.Size.heroLogoSlotHeightPinned,
        decodeSize: ArtworkDecodeSize = .legacy,
        upgrade: ArtworkURLUpgrade.Role? = nil
    ) {
        self.title = title
        self.alignment = alignment
        self.textFont = textFont
        self.slotHeight = slotHeight
        self.logoUrl = logoUrl
        self.url = logoUrl.flatMap(URL.init(string:))
        self.decodeSize = decodeSize
        self.upgrade = upgrade
        // Codex round 1: seed synchronously from the cache, exactly as `HeroLogo` does — a
        // reopened screen whose logo is already in ArtworkStore must not flash its text title for
        // one frame before the `.task` consults the same cache. (I1: `cached(_:)` is the largest
        // decode of any rendition of this logo, so it also finds one drawn from the upgraded URL.)
        _image = State(initialValue: ArtworkStore.cached(url))
    }

    /// beta.19-rc1 verdict (I1): `[upgraded(url), url]` plus the decode request; nil without a URL.
    /// It is the `.task` id, so a new URL, size or scale reloads the logo.
    private var chain: ImageURLChain? {
        guard let url else { return nil }
        var upgraded: URL?
        if let upgrade { upgraded = ArtworkURLUpgrade.upgraded(url, role: upgrade) }
        return ImageURLChain(
            urls: ImageFallbackPlan.candidates(upgraded: upgraded, primary: url, fallback: nil),
            request: ArtworkDecodeRequest(size: decodeSize, fill: false, scale: displayScale).normalized
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: Theme.Size.heroLogoMaxWidth, maxHeight: slotHeight, alignment: alignment)
                    .accessibilityLabel(title)
            } else {
                Text(title)
                    .font(textFont)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        // Codex round 1: when a logo is configured, text-while-loading and the loaded logo share
        // ONE fixed-height slot, so the swap cannot resize the header and shove whatever sits below
        // it (tabs/grid, stream list, …) while focus is live. No logo configured → no slot: the
        // header keeps the caller's plain text metrics.
        //
        // rc13: this reserved-height decision is the same pure check `slotHeight(logoUrl:slotHeight:)`
        // exposes for unit testing (`TitleLogoHeaderTests`) — call through it instead of
        // re-deriving `url == nil` inline, so the tested helper is the one actually driving layout.
        .frame(height: Self.slotHeight(logoUrl: logoUrl, slotHeight: slotHeight), alignment: alignment)
        .task(id: chain) {
            guard let chain else {
                image = nil
                return
            }
            // beta.19-rc1 verdict (I1): the head (the upgraded file when there is one) at the
            // requested size is final. Otherwise show whatever smaller or sibling decode is in
            // memory right now and swap to the right one when it lands, so a logo never flashes the
            // text title just because its bucket changed.
            if let hit = ArtworkStore.cached(chain.urls[0], decode: chain.request) {
                image = hit
                return
            }
            image = ArtworkStore.cachedPlaceholder(for: chain.urls, decode: chain.request)
            let fetched = await ImageFallbackPlan.load(candidates: chain.urls, request: chain.request)
            // Codex round 1: `.task(id:)` cancels this task when the URL changes, but
            // `ArtworkStore.fetch` lets shared work run to completion — so a superseded fetch can
            // land after its replacement. Never install a result for a URL that is no longer ours.
            guard !Task.isCancelled, let fetched else { return }
            withAnimation(.easeIn(duration: 0.25)) { image = fetched }
        }
    }
}

extension TitleLogoHeader {
    /// Pure decision behind `body`'s fixed-height slot: a logo URL gets one pinned height slot
    /// (so the swap from placeholder text to the loaded image can never resize the header and
    /// shove whatever sits below it while focus is live); no logo configured means no slot at
    /// all, and the caller's plain text keeps its own natural metrics. Exposed as a static, view-
    /// free function (mirrors `TitleLogoStore.shouldCommit`'s pattern) so this can be pinned in a
    /// unit test with no view host.
    static func slotHeight(logoUrl: String?, slotHeight: CGFloat) -> CGFloat? {
        guard let logoUrl, URL(string: logoUrl) != nil else { return nil }
        return slotHeight
    }
}
