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
    @State private var image: UIImage?

    init(
        title: String,
        logoUrl: String?,
        alignment: Alignment = .leading,
        textFont: Font = Theme.Font.screenTitle,
        slotHeight: CGFloat = Theme.Size.heroLogoSlotHeightPinned
    ) {
        self.title = title
        self.alignment = alignment
        self.textFont = textFont
        self.slotHeight = slotHeight
        self.logoUrl = logoUrl
        self.url = logoUrl.flatMap(URL.init(string:))
        // Codex round 1: seed synchronously from the cache, exactly as `HeroLogo` does — a
        // reopened screen whose logo is already in ArtworkStore must not flash its text title for
        // one frame before the `.task` consults the same cache.
        _image = State(initialValue: ArtworkStore.cached(url))
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
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ArtworkStore.cached(url) {
                image = hit
                return
            }
            image = nil
            let fetched = try? await ArtworkStore.fetch(url)
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
