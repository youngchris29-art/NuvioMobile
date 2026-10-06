import Combine
import Foundation
import SharedCore
import SwiftUI
import UIKit

// Home Stage & Strip (H3, W1-B; P2 spec `docs/research/home-stage-strip-spec-P2-ambient-collections-settings.md`
// section 1): the ambient wash's model and view. `AmbientWashRenderer.swift` is the pure half.
//
// Z-order on a Stage page, bottom to top: the page's theme background, THIS layer (full screen, never
// focusable, never hit-tested), the alpha-masked stage art, the stage text and the strip. With the
// wash off, this layer renders nothing and the masked art edge shows the theme background, which
// looks like today's scrim fade.
//
// Mount it once per Stage page, at layer 0, with the stage's wash feed:
// `AmbientWashLayer(feed: stage.swap.washFeed)` (`StageStripHome`, wired by the main session at the
// W1 merge; the folder page passes `probeID: "debug_wash_folder"`).

/// The Ambient Background switch (Settings > Home Screen > Layout), device-local like every Home look
/// key: read with `@AppStorage`, never synced. On by default. `-home_ambient_background NO` works as a
/// launch argument. Both the Settings row and `AmbientWashLayer` read this one key.
nonisolated enum AmbientWashSetting {
    static let defaultsKey: String = "home_ambient_background"
    static let defaultValue: Bool = true
}

/// One title's wash art: the stage's identity plus up to three candidate URLs, tried in order.
/// `identity` is the stage's `"\(type):\(id)"` (`HeroPresentation.identity`), which is also the cache
/// key, so the wash follows exactly the title the stage shows.
nonisolated struct WashArt: Equatable, Sendable {
    /// More candidates than this add nothing: backdrop, poster, then the page's own fallback.
    static let maxURLs = 3

    let identity: String
    /// Deduped, in order, at most `maxURLs`.
    let urls: [URL]

    init(identity: String, urls: [URL?]) {
        var kept: [URL] = []
        for case let url? in urls where !kept.contains(url) {
            kept.append(url)
            if kept.count == Self.maxURLs { break }
        }
        self.identity = identity
        self.urls = kept
    }
}

extension WashArt {
    /// `[heroBackdropURL(for: item), item.poster, fallback]`. `heroBackdropURL(for:)` is the global
    /// chain the stage art itself uses (banner, else the metahub background for an IMDb id, else the
    /// poster), so wash and art share one decode family and the wash usually finds the art's bytes
    /// already in `ArtworkStore`. `fallback` is the folder page's cover.
    @MainActor
    init(item: MetaPreview, fallback: String? = nil) {
        self.init(identity: "\(item.type):\(item.id)", urls: Self.candidateURLs(item: item, fallback: fallback))
    }

    /// The feed's item. The identity is the one the stage published (`StageFeedItem.identity`, the
    /// stage's own `HeroPresentation.identity`), so a probe's `id=` can never disagree with the
    /// stage's `disp=`.
    @MainActor
    init(_ feedItem: StageFeedItem) {
        self.init(identity: feedItem.identity,
                  urls: Self.candidateURLs(item: feedItem.item, fallback: feedItem.washFallback))
    }

    @MainActor
    private static func candidateURLs(item: MetaPreview, fallback: String?) -> [URL?] {
        let strings: [String?] = [heroBackdropURL(for: item), item.poster, fallback]
        return strings.map { (string: String?) -> URL? in
            guard let string, !string.isEmpty else { return nil }
            return URL(string: string)
        }
    }
}

/// How strongly the wash is drawn. OLED True Black dims it to 40 % (the page behind it is pure black,
/// and a bright wash would defeat the setting); Increase Contrast dims it to 60 % so the white stage
/// text keeps its margin; otherwise full strength.
nonisolated enum AmbientWashDimming {
    static func opacity(oled: Bool, increasedContrast: Bool) -> Double {
        if oled { return AmbientWashTuning.oledOpacity }
        return increasedContrast ? AmbientWashTuning.increasedContrastOpacity : 1
    }
}

/// The DEBUG probe's text (spec section 1.6), harness-parsed by key, append-only:
/// `on=<0|1> oled=<0|1> id=<identity|-> gen=<n> shown=<0|1> late=<n> lum=<meanLuma 2dp> ms=<render ms 1dp>`.
/// Pure so the spelling is unit-tested.
nonisolated enum AmbientWashProbeLine {
    static func line(on: Bool, oled: Bool, identity: String?, generation: Int, shown: Bool,
                     late: Int, luma: Float, millis: Double) -> String {
        "on=\(on ? 1 : 0) oled=\(oled ? 1 : 0) id=\(identity ?? "-") gen=\(generation) shown=\(shown ? 1 : 0) "
            + "late=\(late) lum=\(String(format: "%.2f", Double(luma))) ms=\(String(format: "%.1f", millis))"
    }
}

#if DEBUG
/// The wash's console lines (DEBUG builds only), in the `[Tag] key=value` shape the other probes use,
/// so the device pass can read them from the streamed console (spec section 4.5, step 6: "console
/// `ms=` < 20"):
///
///     [AmbientWash] render id=<identity> src=<w>x<h> ms=<render ms 1dp> lum=<2dp>
///     [AmbientWash] show id=<identity> gen=<n> late=<count> ms=<render ms 1dp> lum=<2dp>
///
/// `render` is printed once per rendered wash (a cache hit prints none), `show` once per committed
/// layer. `late=` is the running count of washes that landed more than 100 ms after the stage showed
/// their title.
nonisolated enum AmbientWashConsole {
    static func log(_ line: String) {
        NSLog("%@", "[AmbientWash] " + line)
    }
}
#endif

/// The wash's state: the layer on screen (`base`) and the one fading in over it (`incoming`).
///
/// The stage feeds it two events (`AmbientWashLayer` forwards them from `StageWashFeed`):
/// - `prepare(_:)`, for the title the stage has just taken as PENDING (its pause started). After a
///   0.15 s debounce the wash is rendered into `AmbientWashCache`, never shown. Held-Down hops come
///   about 0.5 s apart, longer than the debounce, so every passed row warms one wash (a millisecond or
///   two off the main thread): cheap, and the wash keeps up with the stage.
/// - `show(_:)`, for the title the stage DISPLAYS (the swap point, or the seed). The wash is loaded
///   (a cache hit when `prepare` ran) and cross-fades in over the current one.
///
/// Rules (unit-tested, `AmbientWashModelTests`):
/// - `show(nil)` keeps the current wash (the genre chips row, the See All tile). The same identity as
///   the layer on screen, or as the one already being loaded, is a no-op.
/// - Late image: an uncached `show` records `wanted` and commits on arrival only if `wanted` is
///   unchanged. A stale result is dropped (it still sits in the cache). A commit more than 100 ms after
///   its `show` counts in `lateCount`.
/// - A `show` while a fade is running (unreachable at the stage's 600 ms swap cadence, since the fade
///   is 400 ms) promotes `incoming` at once, then fades the new one.
/// - Nothing is committed until the first `show`: a cold launch has no layers until the stage's first
///   displayed title. The first layer fades in over the page background like any other.
@MainActor
final class AmbientWashModel: ObservableObject {
    struct Layer: Identifiable {
        let id: Int
        let identity: String
        let image: CGImage
    }

    /// cache, then fetch, then render off the main actor, then cache. Injected so the unit tests drive
    /// resolution order by hand.
    typealias Loader = @MainActor (WashArt) async -> AmbientWashRenderer.Output?

    /// The layer drawn at full opacity underneath.
    @Published private(set) var base: Layer?
    /// The layer fading in over `base`; `AmbientWashLayer` animates `incomingOpacity` to 1 and calls
    /// `promote(_:)` when the fade completes.
    @Published private(set) var incoming: Layer?
    @Published var incomingOpacity: Double = 0

    /// Layers committed so far; a layer's `id` is the value after its commit. Probe `gen=`.
    private(set) var generation = 0
    // Probe only.
    private(set) var lateCount = 0
    private(set) var lastMeanLuma: Float = 0
    private(set) var lastMillis: Double = 0

    private let loader: Loader
    private let debounce: TimeInterval
    private let lateAfter: TimeInterval
    /// The identity the last `show` asked for and has not committed yet. nil when nothing is in flight.
    private var wanted: String?
    private var prepareTask: Task<Void, Never>?
    /// The identity a still-sleeping `prepare` will warm (cleared once its load starts).
    private var prepareIdentity: String?

    /// `debounce` and `lateAfter` default to the shipped numbers; they are parameters so the unit tests
    /// can drive both with wide timing margins.
    init(loader: @escaping Loader = AmbientWashModel.liveLoader,
         debounce: TimeInterval = AmbientWashTuning.prepareDebounce,
         lateAfter: TimeInterval = AmbientWashTuning.lateAfter) {
        self.loader = loader
        self.debounce = debounce
        self.lateAfter = lateAfter
    }

    deinit {
        prepareTask?.cancel()
    }

    /// The identity of the newest layer on screen or fading in.
    var shownIdentity: String? { incoming?.identity ?? base?.identity }

    /// True once any layer exists. Probe `shown=`.
    var isShown: Bool { base != nil || incoming != nil }

    // MARK: - Events

    /// The stage's PENDING title: warms `AmbientWashCache` for it after the debounce. Newest wins (each
    /// call replaces the previous one's pending work), and nil cancels. Never changes what is shown.
    func prepare(_ art: WashArt?) {
        cancelPrepare()
        guard let art, art.identity != shownIdentity, art.identity != wanted else { return }
        prepareIdentity = art.identity
        let load = loader
        let delay = debounce
        prepareTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.prepareIdentity == art.identity else { return }
            // From here a `show` of the same identity no longer cancels this load: it runs to
            // completion and the loader fills the cache.
            self.prepareIdentity = nil
            _ = await load(art)
        }
    }

    /// The stage's DISPLAYED title: loads its wash and fades it in. nil keeps the current wash; the
    /// identity already shown, or already being loaded, is a no-op.
    func show(_ art: WashArt?) {
        guard let art else { return }
        if art.identity == shownIdentity {
            // The stage is back on the wash that is already up: forget any other title still loading.
            wanted = nil
            return
        }
        if art.identity == wanted { return }
        if incoming != nil { promoteIncoming() }
        if prepareIdentity == art.identity { cancelPrepare() }   // this show loads it anyway
        wanted = art.identity
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let load = loader
        Task { [weak self] in
            let output = await load(art)
            self?.commit(output, for: art, requestedAt: requestedAt)
        }
    }

    /// Called by the view when the fade of layer `id` completes: it becomes `base`. A call for a layer
    /// that is no longer `incoming` (it was promoted early, or replaced) is ignored.
    func promote(_ id: Int) {
        guard incoming?.id == id else { return }
        promoteIncoming()
    }

    // MARK: - Internals

    private func cancelPrepare() {
        prepareTask?.cancel()
        prepareTask = nil
        prepareIdentity = nil
    }

    private func promoteIncoming() {
        guard let layer = incoming else { return }
        base = layer
        incoming = nil
        incomingOpacity = 0
    }

    private func commit(_ output: AmbientWashRenderer.Output?, for art: WashArt, requestedAt: TimeInterval) {
        guard wanted == art.identity else { return }   // superseded, or the stage came back to what is up
        wanted = nil
        guard let output else { return }               // nothing loaded: the current wash stays
        if incoming != nil { promoteIncoming() }
        if ProcessInfo.processInfo.systemUptime - requestedAt > lateAfter { lateCount += 1 }
        generation += 1
        lastMeanLuma = output.meanLuma
        lastMillis = output.millis
        incomingOpacity = 0
        incoming = Layer(id: generation, identity: art.identity, image: output.image)
        #if DEBUG
        AmbientWashConsole.log("show id=\(art.identity) gen=\(generation) late=\(lateCount) "
            + "ms=\(String(format: "%.1f", output.millis)) lum=\(String(format: "%.2f", Double(output.meanLuma)))")
        #endif
    }

    // MARK: - Production loader

    /// cache, then fetch, then render, then cache. The fetch is `ArtworkStore`'s (the stage art's
    /// bytes are joined, a larger decode in memory serves the 256 px request); the decode-sized work
    /// (downsample, blur, half-float output) runs on a detached `.utility` task, never on the main
    /// actor. nil when no candidate URL loads, or the image has no bitmap.
    static func liveLoader(_ art: WashArt) async -> AmbientWashRenderer.Output? {
        if let cached = AmbientWashCache.shared.output(for: art.identity) { return cached }
        guard !art.urls.isEmpty,
              let image = await ImageFallbackPlan.load(candidates: art.urls, request: AmbientWashTuning.decode),
              let cgImage = image.cgImage else { return nil }
        let rendered = await Task.detached(priority: .utility) {
            AmbientWashRenderer.render(cgImage)
        }.value
        guard let output = rendered else { return nil }
        AmbientWashCache.shared.store(output, for: art.identity)
        #if DEBUG
        AmbientWashConsole.log("render id=\(art.identity) src=\(cgImage.width)x\(cgImage.height) "
            + "ms=\(String(format: "%.1f", output.millis)) lum=\(String(format: "%.2f", Double(output.meanLuma)))")
        #endif
        return output
    }
}

/// The ambient wash. Mount once per Stage page, at layer 0 (see the file header). Renders nothing
/// while Settings > Home Screen > Ambient Background is off (in DEBUG builds the probe stays, reading
/// `on=0`).
struct AmbientWashLayer: View {
    let feed: StageWashFeed
    let probeID: String

    @AppStorage(AmbientWashSetting.defaultsKey) private var enabled: Bool = AmbientWashSetting.defaultValue

    init(feed: StageWashFeed, probeID: String = "debug_wash") {
        self.feed = feed
        self.probeID = probeID
    }

    var body: some View {
        if enabled {
            AmbientWashContent(feed: feed, probeID: probeID)
        } else {
            AmbientWashOffProbe(probeID: probeID)
        }
    }
}

/// OLED True Black, read once with the idiom `AppThemeModel.init` uses (`amoledEnabled` is a bare
/// `StateFlow<Boolean>`). An OLED change re-identifies the whole tree (`ContentView` pins `.id` on
/// the palette key), which recreates the layer, so one read at creation is always current and
/// `Theme.swift` needs no edit.
private func ambientWashOledEnabled() -> Bool {
    (ThemeSettingsRepository.shared.amoledEnabled.value_ as? KotlinBoolean)?.boolValue ?? false
}

/// The off state: nothing to draw. DEBUG builds keep the harness label so a UI test can assert `on=0`.
private struct AmbientWashOffProbe: View {
    let probeID: String

    var body: some View {
        #if DEBUG
        Text(AmbientWashProbeLine.line(on: false, oled: ambientWashOledEnabled(), identity: nil, generation: 0,
                                       shown: false, late: 0, luma: 0, millis: 0))
            .font(.system(size: 8))
            .opacity(0.011)
            .allowsHitTesting(false)
            .accessibilityIdentifier(probeID)
        #else
        EmptyView()
        #endif
    }
}

/// The wash while it is on. Owns the model, so switching the setting off drops the layers and
/// switching it on starts over: the on-appear below re-reads the feed, and a cache hit is back within
/// the 0.4 s fade.
///
/// It observes the feed itself (`onReceive` on the feed's two publishers) and nothing else does, so a
/// pending change re-renders no strip row. Note the closures read the EMITTED value: a `@Published`
/// publisher fires before its property changes.
private struct AmbientWashContent: View {
    let feed: StageWashFeed
    let probeID: String
    private let oled: Bool

    @StateObject private var model = AmbientWashModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(feed: StageWashFeed, probeID: String) {
        self.feed = feed
        self.probeID = probeID
        self.oled = ambientWashOledEnabled()
    }

    var body: some View {
        ZStack {
            layers
            #if DEBUG
            Text(AmbientWashProbeLine.line(on: true, oled: oled, identity: model.shownIdentity,
                                           generation: model.generation, shown: model.isShown,
                                           late: model.lateCount, luma: model.lastMeanLuma,
                                           millis: model.lastMillis))
                .font(.system(size: 8))
                .opacity(0.011)
                .allowsHitTesting(false)
                .accessibilityIdentifier(probeID)
            #endif
        }
        .onAppear {
            model.prepare(feed.pending.map { WashArt($0) })
            model.show(feed.displayed.map { WashArt($0) })
        }
        .onReceive(feed.$pending) { item in
            model.prepare(item.map { WashArt($0) })
        }
        .onReceive(feed.$displayed) { item in
            model.show(item.map { WashArt($0) })
        }
        .onChange(of: model.incoming?.id) { _, id in
            guard let id else { return }
            // The new layer is drawn at opacity 0 (the model reset it), so animating to 1 fades it in
            // over `base`, which stays at 1 underneath: the midpoint never dips toward black.
            let seconds = reduceMotion ? AmbientWashTuning.crossFadeReducedMotion : AmbientWashTuning.crossFade
            withAnimation(.easeInOut(duration: seconds)) {
                model.incomingOpacity = 1
            } completion: {
                model.promote(id)
            }
        }
    }

    /// Both washes, drawn as full-screen quads of a 160x90 bitmap: no `.blur`, no `.drawingGroup()`, no
    /// `.compositingGroup()` (the whole point of the CPU render). The dimming is one opacity on the
    /// group, so a cross-fade under OLED or Increase Contrast composites as a whole instead of
    /// letting the old wash show through the new one.
    private var layers: some View {
        ZStack {
            if let base = model.base {
                washImage(base)
            }
            if let incoming = model.incoming {
                washImage(incoming)
                    .opacity(model.incomingOpacity)
            }
        }
        .opacity(AmbientWashDimming.opacity(oled: oled, increasedContrast: contrast == .increased))
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One wash, aspect-filled and centre-cropped to exactly the space it is given. The fill is an
    /// overlay on `Color.clear`, so it can never report a size larger than its proposal (the
    /// `HeroCrossfadeImage` rule, BUG-95). As a plain `.aspectRatio(contentMode: .fill)` inside a
    /// flexible frame it did: Home's tab region under the tab bar's top inset is not 16:9 (1920x1128.5
    /// on FA87), the 16:9 fill came back 2006 wide, and that width spread up through Stage to
    /// HomeView's root ZStack, which then centred its page background 80 pt to the right. The
    /// background stopped 160 pt short of the left bezel, and under OLED True Black's 40 % wash that
    /// strip showed as a light grey bar (device pass 2026-10-05).
    private func washImage(_ layer: AmbientWashModel.Layer) -> some View {
        Color.clear
            .overlay {
                Image(decorative: layer.image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
            .id(layer.id)
            .transition(.identity)
    }
}
