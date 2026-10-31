import Combine
import SwiftUI
import SharedCore

// MARK: - Perf review 2026-10-17 (#1): Classic Home's hero, observed by leaves
//
// `HomeView` used to observe the hero focus model, the art resolver and the hero trailer model
// directly, so every focus commit (0.2 s after a card takes focus) and every resolver commit re-ran
// its whole body and every visible row. It now owns the three through `HomeHeroModels`, which never
// publishes, and the only views that observe them are the small leaves below. Each one renders
// exactly what `HomeView`'s body rendered at the same spot, from the same inputs; the decisions
// that need the focus model (`HomeHeroTarget`, `HomeHeroTrailerGate`) are shared pure functions,
// so `HomeView`'s own event-time reads and the leaves cannot disagree.

/// Owner of the Classic hero's three models (perf review 2026-10-17, #1). Has no `@Published`
/// property, so the `@StateObject` holding it never invalidates `HomeView`; the lifetime is the one
/// the three `@StateObject`s had.
@MainActor
final class HomeHeroModels: ObservableObject {
    /// UX-7: the row-focused item that takes over the hero (`HomeHeroFocusModel`).
    let focus = HomeHeroFocusModel()
    /// Wave H: the hero actually painted (`HeroArtResolver`).
    let resolver = HeroArtResolver()
    /// FEAT-25: the hero backdrop's dwell → resolve → play state machine.
    let trailer = InlineTrailerCardModel()
}

/// The hero TARGET (`HomeView.displayHero`) as a pure function of its inputs plus the focus model's
/// committed item, so `HomeHeroDriver` resolves exactly what `HomeView` does.
enum HomeHeroTarget {
    /// Everything `displayHero` reads apart from the focus model.
    struct Inputs {
        /// Home Stage & Strip (P1 E3): the stage owns its own focus/art pipeline.
        var isStage: Bool
        /// `HomeView.heroCarouselActive`.
        var carouselActive: Bool
        /// `HomeView.focusHeroActive` (FEAT-15's focus panel).
        var panelActive: Bool
        /// `HomeView.currentHero`: the carousel's current page.
        var currentHero: MetaPreview?
        /// `HomeView.heroRestingItem`: the focus panel's resting title (nil unless the panel is up).
        var restingItem: MetaPreview?
    }

    /// UX-7: a row-focused poster wins over the carousel's page (or, FEAT-15, the panel's resting
    /// title) while one is committed. Both modes off ⇒ nil ⇒ no hero region.
    static func resolve(_ inputs: Inputs, focused: MetaPreview?) -> MetaPreview? {
        if inputs.isStage { return nil }
        if inputs.carouselActive { return focused ?? inputs.currentHero }
        if inputs.panelActive { return focused ?? inputs.restingItem }
        return nil
    }

    /// Wave H: changes to the target's own fields, at the same identity. Cheap to recompute (a
    /// join over eight components) and only ever consumed by an `.onChange`.
    ///
    /// Codex r1 (P2): every field the hero actually RENDERS has to be in here, or a same-id update
    /// leaves stale text on screen forever, because nothing else calls `presentHero()` at a stable
    /// identity. The previous version carried only the description, the genre COUNT and the two
    /// artwork URLs, so a folder renamed on mobile, or genres replaced by a same-length list, was
    /// invisible. What `HomeHeroForeground` draws, and therefore what is listed below:
    /// `name` (`HeroLogo`'s text stand-in and the CTA's accessibility label), `description_`
    /// (the synopsis), `releaseInfo` + `genres` (the meta line), `logo` and `banner` (the resolved
    /// artwork), `poster` (`heroBackdropURL`'s last fallback, so it can BE the backdrop), and
    /// `type` (picks "Go to Movie" vs "Go to Show", and is not covered by the id-only `.onChange`).
    /// `imdbRating` is deliberately absent: `metaLine` does not render it, so including it would
    /// only buy needless `present` calls.
    static func payloadSignature(_ hero: MetaPreview?) -> String {
        guard let hero else { return "-" }
        let description: String? = hero.description_
        let banner: String? = hero.banner
        let logo: String? = hero.logo
        let poster: String? = hero.poster
        let releaseInfo: String? = hero.releaseInfo
        return [
            hero.name,
            description ?? "",
            hero.genres.joined(separator: ","),
            releaseInfo ?? "",
            banner ?? "",
            logo ?? "",
            poster ?? "",
            hero.type,
        ].joined(separator: "|")
    }

    /// `HomeView.heroArtVisible`: `hero_poster_focus_only` fades the artwork while the carousel
    /// idles unengaged; every other configuration shows it always (UX-7/FEAT-15 precedence).
    static func artVisible(posterFocusOnly: Bool, carouselActive: Bool,
                           heroFocused: Bool, rowFocused: Bool) -> Bool {
        guard posterFocusOnly && carouselActive else { return true }
        return heroFocused || rowFocused
    }
}

/// The two hero-trailer claims (`HomeView.heroTrailerAutoplayActive` / `heroFocusTrailerActive`,
/// folded by `heroTrailerActive`) as pure functions of their non-focus inputs plus "a row poster
/// holds committed focus". See those properties in `HomeView` for the precedence contract.
struct HomeHeroTrailerGate: Equatable {
    /// `hero_trailer_autoplay`.
    var autoplayEnabled: Bool
    /// `HomeView.heroTrailerSharedGatesOpen` (system autoplay, nothing pushed, no stream picker).
    var sharedGatesOpen: Bool
    var heroFocused: Bool
    /// `hero_poster_focus_only`.
    var posterFocusOnly: Bool
    var carouselActive: Bool
    /// `inline_trailers_enabled`.
    var inlineTrailersEnabled: Bool
    /// `HomeView.heroFocusTrailerMode` (Trailer Location: Hero).
    var focusTrailerMode: Bool

    /// FEAT-25's carousel claim.
    func autoplayActive(rowFocused: Bool) -> Bool {
        guard autoplayEnabled, sharedGatesOpen else { return false }
        let heroEngaged = heroFocused || rowFocused
        if posterFocusOnly && carouselActive && !heroEngaged { return false }
        if inlineTrailersEnabled && rowFocused { return false }
        return true
    }

    /// Trailer Location: Hero — the focused title's trailer on the backdrop.
    func focusActive(rowFocused: Bool) -> Bool {
        guard focusTrailerMode, sharedGatesOpen else { return false }
        return rowFocused
    }

    /// The single Bool `HomeHeroBackdrop` gets as `autoplaysTrailer`. A collection folder on the
    /// backdrop (BUG-38 round three, keyed on the PRESENTED item per Wave H) has no trailer.
    func active(rowFocused: Bool, presented: MetaPreview?) -> Bool {
        if let presented, isCollectionHero(presented) { return false }
        return focusActive(rowFocused: rowFocused) || autoplayActive(rowFocused: rowFocused)
    }
}

/// Invisible: the `.onChange` triggers `HomeView` used to carry for values that depend on the focus
/// model — the hero target's identity and payload (Wave H, `presentHero`) and the artwork layer's
/// visibility (`heroArtOpacity`). Mounted as `HomeView`'s background, so it lives as long as Home.
struct HomeHeroDriver: View {
    @ObservedObject var focusModel: HomeHeroFocusModel
    let inputs: HomeHeroTarget.Inputs
    let posterFocusOnly: Bool
    let heroFocused: Bool
    /// The target's identity or payload changed: `HomeView.presentHero()`.
    let onTargetChange: () -> Void
    /// `HomeView.heroArtVisible` changed: the artwork layer's opacity fade.
    let onArtVisibleChange: (Bool) -> Void
    /// The carousel pages' ids (`heroItems.map(\.id)`) and FEAT-15's resting item: a change warms
    /// their artwork (`HomeView.prefetchHeroArt`).
    let heroItemIds: [String]
    let restingItemId: String?
    let onPrefetch: () -> Void

    var body: some View {
        let focused = focusModel.focusedItem
        let target = HomeHeroTarget.resolve(inputs, focused: focused)
        let artVisible = HomeHeroTarget.artVisible(posterFocusOnly: posterFocusOnly,
                                                   carouselActive: inputs.carouselActive,
                                                   heroFocused: heroFocused, rowFocused: focused != nil)
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // Wave H: the hero TARGET changed identity — hand it to the resolver, which decides
            // when (and as one transaction, with what artwork) it may actually be painted. Keyed on
            // the id alone: a payload change at the same identity is the next trigger.
            .onChange(of: target?.id) { _, _ in onTargetChange() }
            // Wave H: the target's own fields changed without its identity changing — a TMDB
            // gap-fill landing on a focused row poster (`HomeHeroFocusModel.enrichIfNeeded`), or a
            // shared-publish payload edit. The resolver adopts the text and keeps the committed
            // artwork; without this trigger a late synopsis would never reach the panel at all.
            .onChange(of: HomeHeroTarget.payloadSignature(target)) { _, _ in onTargetChange() }
            // Wave H: the artwork layer's fade (see `HomeView.heroArtOpacity`).
            .onChange(of: artVisible) { _, visible in onArtVisibleChange(visible) }
            // Warm every hero page's artwork when the pages change.
            .onChange(of: heroItemIds) { _, _ in onPrefetch() }
            // FEAT-15: the focus panel has no hero pages to warm, but it DOES paint the resting
            // item the moment rows land — warm that one title's backdrop/logo so Home doesn't
            // open on a placeholder. Inert in carousel mode: the resting item is nil there, so
            // this fires once (nil → nil) and never again.
            .onChange(of: restingItemId) { _, _ in onPrefetch() }
    }
}

/// BUG-190 (Steven rc9: the Classic rows page inside a collection showed no title poster and no
/// synopsis, only the collection art): the Classic folder rows page's `HomeHeroDriver`. Hands the
/// focus model's committed card to the resolver, keyed on its identity and its payload as Home is
/// (`HomeHeroTarget.payloadSignature`). A nil commit (focus up on the Edit band) is not handed on,
/// so the panel keeps the last title instead of emptying. Invisible; a leaf, so a commit never
/// re-renders the page or its rows.
struct FolderHeroDriver: View {
    @ObservedObject var focusModel: HomeHeroFocusModel
    let resolver: HeroArtResolver

    var body: some View {
        let focused = focusModel.focusedItem
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: focused.map { "\($0.type):\($0.id)" }) { _, _ in present() }
            .onChange(of: HomeHeroTarget.payloadSignature(focused)) { _, _ in present() }
    }

    private func present() {
        guard let item = focusModel.focusedItem else { return }
        // The panel's backdrop is the Nuvio form (`HomeView.heroSharpenForm`'s panel case).
        resolver.setSharpenForm(.nuvio)
        resolver.present(item, isFolder: false)
    }
}

/// The full-bleed hero backdrop + scrim (Classic only), formerly inline in `HomeView.body`.
/// Observes the resolver (what is painted) and the focus model (whether a row poster's committed
/// focus claims the trailer).
struct HomeHeroBackdropLayer: View {
    @ObservedObject var resolver: HeroArtResolver
    @ObservedObject var focusModel: HomeHeroFocusModel
    let trailerModel: InlineTrailerCardModel
    let isStage: Bool
    /// Nuvio-style artwork treatment (`heroNuvioStyle || focusHeroActive`).
    let nuvioStyle: Bool
    let gate: HomeHeroTrailerGate
    /// `HomeView.heroArtOpacity`.
    let opacity: Double

    var body: some View {
        if !isStage, let presentation = resolver.presented {
            Group {
                // Nuvio-style: right-anchored artwork whose left edge fades to the
                // flat background — the info panel never sits over the art.
                // FEAT-15: the focus panel always uses that treatment (see heroNuvioStyle).
                HomeHeroBackdrop(
                    presentation: presentation,
                    nuvioStyle: nuvioStyle,
                    autoplaysTrailer: gate.active(rowFocused: focusModel.focusedItem != nil,
                                                  presented: presentation.item),
                    trailerModel: trailerModel
                )
                HomeHeroScrim()
            }
            // UX-7: a row-focused poster (focusModel.focusedItem != nil) always shows
            // its artwork — heroPosterFocusOnly only gates the carousel's own idle fade.
            // FEAT-15: and only the CAROUSEL's. In focus-panel mode the toggle is inert —
            // hiding the artwork "while browsing" there would hide it always, since
            // browsing is the only thing that mode ever shows (see heroPosterFocusOnly).
            // Wave H: the value is `heroArtOpacity`, animated from `.onChange` in `HomeView` —
            // see that state's doc for why an `.animation(_:value:)` modifier here was the
            // resizing-mosaic bug.
            .opacity(opacity)
            // Purely decorative background art — the same title/synopsis is exposed by
            // the focusable HomeHeroForeground button in front of it, so VoiceOver
            // shouldn't stop on this layer too.
            .accessibilityHidden(true)
        }
    }
}

/// The hero info panel's text slot (`HeroTextLayer`), formerly the `if let` inside
/// `HomeView.heroCarousel`. Observes only the resolver: the text on screen and the artwork behind it
/// are two halves of one committed value (Wave H).
struct HomeHeroTextSlot: View {
    @ObservedObject var resolver: HeroArtResolver
    var heroFocused: FocusState<Bool>.Binding
    let compact: Bool
    let showsCTA: Bool
    let forceNuvioLayout: Bool
    let compression: CGFloat
    let folderRoutes: [String: FolderRoute]

    var body: some View {
        if let presentation = resolver.presented {
            HeroTextLayer(presentation: presentation, heroFocused: heroFocused, compact: compact,
                          showsCTA: showsCTA,
                          forceNuvioLayout: forceNuvioLayout,
                          compression: compression,
                          folderRoutes: folderRoutes)
        }
    }
}

/// The carousel's page dots, formerly inline in `HomeView.heroCarousel`. Observes the focus model
/// only: the dots fade out while a row poster owns the hero (UX-7).
struct HomeHeroDotsSlot: View {
    @ObservedObject var focusModel: HomeHeroFocusModel
    /// `heroItems.count`.
    let count: Int
    /// `heroIndex`.
    let index: Int

    var body: some View {
        let dotsVisible = count > 1 && focusModel.focusedItem == nil
        HeroPageDots(count: max(count, 1),
                     index: min(index, max(count - 1, 0)))
            .padding(.leading, Theme.Spacing.lg)
            .opacity(dotsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: dotsVisible)
    }
}

#if DEBUG
/// BUG-23 diagnostic (invisible, harness-readable): the hero carousel's live selection + focus
/// state, formerly inline in `HomeView.body`. Same text, token for token (see the field history at
/// its call site in `HomeView`); a leaf so a focus commit re-renders this label, not Home.
struct HomeHeroDebugLabel: View {
    @ObservedObject var focusModel: HomeHeroFocusModel
    @ObservedObject var resolver: HeroArtResolver
    @ObservedObject var trailerModel: InlineTrailerCardModel
    let heroIndex: Int
    let heroFocused: Bool
    let count: Int
    let nuvioStyle: Bool
    /// "carousel" / "focus" / "none".
    let mode: String
    let heroFocusTrailerMode: Bool
    /// A Binding, read here and not in `HomeView.body`: Home's `isScrolledDown` flips at Stage's row 0/1
    /// crossing, and a plain `Bool` argument made Home's body (and the whole strip under it) re-run in
    /// DEBUG only, which skewed the body counts. The label observes the state itself.
    @Binding var scrolledDown: Bool

    /// Short code for the hero trailer model's live phase, for the `hph=` field — the harness reads
    /// fixed-width-ish tokens, not Swift's synthesized descriptions (`playing(_:)` would otherwise
    /// splat a resolved URL key into the string).
    private var phase: String {
        switch trailerModel.phase {
        case .idle: return "idle"
        case .dwelling: return "dwell"
        case .expandedStatic: return "exp"
        case .playing: return "play"
        }
    }

    var body: some View {
        Text("debug_hero idx=\(heroIndex) foc=\(heroFocused ? 1 : 0) n=\(count) src=\(focusModel.focusedItem == nil ? "c" : "f") fitem=\(focusModel.focusedItem?.id ?? "-") pin=\(nuvioStyle ? 1 : 0) mode=\(mode) tloc=\(heroFocusTrailerMode ? "h" : "p") hph=\(phase) pitem=\(resolver.presented?.identity ?? "-") pbd=\(resolver.presented?.backdrop != nil ? 1 : 0) plg=\(resolver.presented?.logo != nil ? 1 : 0) plgs=\(resolver.presentedLogoSource.rawValue) sd=\(scrolledDown ? 1 : 0)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_hero")
    }
}
#endif
