import SharedCore
import SwiftUI
import UIKit

// Home Stage & Strip (P1 §4.3): what the stage draws. Nothing here is focusable or hit-testable.
//
// Who observes what (#5, the `HeroTextLayer` pattern): `StageView` holds the controller as a plain
// `let` and observes nothing; `StageTextBlock` and `StageArtLayer` each observe the swap driver;
// the text block also observes the Continue Watching copy source (W2-A); the background trailer
// (W2-A) is its own leaf observing only the trailer model; the wash (W1-B) observes
// `swap.washFeed`; each DEBUG label observes its own readout. A swap phase, a Continue Watching
// change or a trailer start therefore re-renders these leaves and never the strip.

/// S3: the stage for one page — Home (`StageStripHome`) or the folder Rows page (W2-B). The art is
/// full screen behind everything (alpha-masked into the wash, S5); the text column sits in the stage
/// block at `geometry.stageBlockTop` / `stageBlockLeading`.
struct StageView: View {
    let controller: StageController
    let geometry: StripGeometry
    /// S3: while the stage displays this identity its logo slot draws at opacity 0 (the folder page
    /// docks its own logo there); the meta line and synopsis still draw.
    let hidesLogoWhenDisplaying: String?
    /// S7: the DEBUG readout's identifier. The folder page passes `debug_stage_folder`, so a folder
    /// pushed over Home never yields two `debug_stage` elements.
    let probeID: String

    init(controller: StageController,
         geometry: StripGeometry,
         hidesLogoWhenDisplaying: String? = nil,
         probeID: String = "debug_stage") {
        self.controller = controller
        self.geometry = geometry
        self.hidesLogoWhenDisplaying = hidesLogoWhenDisplaying
        self.probeID = probeID
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The background trailer model is handed down on every host; only Home ever arms it
            // (`StageStripHome`), so on the folder page it stays idle and draws nothing.
            StageArtLayer(swap: controller.swap, geometry: geometry, trailer: controller.bgTrailer)
            StageTextBlock(swap: controller.swap,
                           geometry: geometry,
                           hidesLogoWhenDisplaying: hidesLogoWhenDisplaying,
                           copySource: controller.copySource)
            #if DEBUG
            StageDebugLabel(debug: controller.swap.debug, geometry: geometry, probeID: probeID)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Art

/// The stage art: the shown title's backdrop (`HeroCrossfadeImage`, 0.3 s ease-in-out in place,
/// Reduce Motion honoured), framed full screen at aspect-fill, faded by an ALPHA mask into layer 0
/// (the ambient wash, or the theme background with the wash off) on the left and below the stage.
/// The background trailer (W2-A, §7) mounts here, over the art and under the scrim, the mask and
/// the text.
struct StageArtLayer: View {
    @ObservedObject var swap: StageSwapDriver
    let geometry: StripGeometry
    /// W2-A (§7): the background trailer model (`StageController.bgTrailer`). Observed by its own
    /// leaf (`StageBackgroundTrailer`), never by this view, so a dwell or a play/stop re-renders
    /// that leaf only. nil draws no trailer surface at all.
    var trailer: InlineTrailerCardModel? = nil

    var body: some View {
        let art = swap.output.art
        ZStack {
            HeroCrossfadeImage(image: art?.backdrop, identity: art?.identity ?? "-")
            // §7: over the art, under the scrim (the text stays legible over moving video) and
            // inside the mask (the video fades into the wash exactly as the art does). It can only
            // ever play the shown title: any focus move tears it down before the stage swaps.
            if let trailer {
                StageBackgroundTrailer(model: trailer,
                                       zoomKey: art.map { TrailerResolutionCache.key(type: $0.item.type, id: $0.item.id) })
            }
            // Inside the mask, so it darkens the ART (and the trailer) only, never the wash.
            StageScrim()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .mask {
            StageArtMask(stageHeight: geometry.stageHeight, screenHeight: geometry.screenHeight)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The art's alpha mask (§4.3): leading clear 0 → black 0.35 at 30 % → black at 55 % of the width,
/// times a vertical ramp that is black down to `stage − 40` and clear from `stage + 200`.
struct StageArtMask: View {
    let stageHeight: CGFloat
    let screenHeight: CGFloat

    var body: some View {
        let height = max(screenHeight, 1)
        let solidUntil = min(max((stageHeight - 40) / height, 0), 1)
        let clearFrom = min(max((stageHeight + 200) / height, solidUntil), 1)
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.35), location: 0.30),
            .init(color: .black, location: 0.55),
        ], startPoint: .leading, endPoint: .trailing)
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: solidUntil),
                .init(color: .clear, location: clearFrom),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// W2-A (§7): the stage's background trailer surface — the shown title's trailer, muted through
/// `HeroTrailerAudioState` (Play/Pause on the focused catalog card toggles it, because the model
/// claims the player slot with that card's own key), played once (`loops: false`) and handed back to
/// the still art when it ends. A LEAF observing only the trailer model, so a dwell, a start or a
/// stop re-renders this view and never the art, the text or the strip (#5). Arming and teardown live
/// in `StageController.syncBackgroundTrailer`, driven by `StageStripHome`'s `onReceive`s.
///
/// The image under it is unconditional and never re-identified: the player is the only thing that
/// comes and goes (Classic's `HomeHeroBackdrop.heroSurface` rule), fading in over the still and cut
/// on removal.
struct StageBackgroundTrailer: View {
    @ObservedObject var model: InlineTrailerCardModel
    /// `TrailerResolutionCache.key` of the title on stage: the key the letterbox zoom is remembered
    /// under (BUG-59).
    let zoomKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let url = model.playingURL {
                TrailerHeroPlayer(
                    urlString: url,
                    onFailure: { report in model.playbackFailed(report) },
                    zoomKey: zoomKey,
                    loops: false,
                    onPlaybackEnded: { model.playbackFinished() },
                    surfaceTag: "stage-bg"
                )
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.playingURL)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Legibility for the stage's top band and text column, drawn INSIDE the art's mask: it darkens the
/// art under the tab bar and toward the text, and leaves the wash untouched (S5: nothing opaque over
/// the wash). Tuned on device in W2-A.
struct StageScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.5), location: 0),
                .init(color: .black.opacity(0.15), location: 0.18),
                .init(color: .clear, location: 0.32),
            ], startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.45), location: 0.25),
                .init(color: .black.opacity(0.15), location: 0.45),
                .init(color: .clear, location: 0.62),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Text

/// The stage's text column, under the M5 render contract (`TextSwapModel`'s type doc): the block is
/// keyed on the shown identity with `.transition(.identity)` (the swap is a hard cut while the text
/// is invisible) and only its opacity animates, outside the `.id`, with the driver's curve. The
/// outer frame is fixed (`stage_text_slot`): it changes with a settings change, never with a swap.
///
/// W2-A (§5): the copy is Continue-Watching-aware through `copySource` (`StageController.copySource`),
/// which this leaf observes, so a Continue Watching change (a resume position moving on, the next
/// episode taking over) rewrites the shown title's meta line and synopsis in place, with no fade and
/// no re-render of anything else.
struct StageTextBlock: View {
    @ObservedObject var swap: StageSwapDriver
    let geometry: StripGeometry
    let hidesLogoWhenDisplaying: String?
    /// W2-A's Continue Watching copy input (`StageController.copySource`); a nil lookup = Classic copy.
    @ObservedObject var copySource: StageCopySource

    init(swap: StageSwapDriver,
         geometry: StripGeometry,
         hidesLogoWhenDisplaying: String?,
         copySource: StageCopySource) {
        _swap = ObservedObject(wrappedValue: swap)
        self.geometry = geometry
        self.hidesLogoWhenDisplaying = hidesLogoWhenDisplaying
        _copySource = ObservedObject(wrappedValue: copySource)
    }

    var body: some View {
        let output = swap.output
        let progressLookup = copySource.progressLookup
        ZStack(alignment: .topLeading) {
            if let shown = output.shown {
                let copy = StageCopy.make(item: shown.item, progress: progressLookup?(shown.item))
                VStack(alignment: .leading, spacing: StripGeometry.slotGap) {
                    HeroLogo(item: shown.item, image: shown.logo, maxHeight: geometry.logoSlot, ink: shown.logoInk)
                        .frame(height: geometry.logoSlot, alignment: .bottomLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(shown.identity == hidesLogoWhenDisplaying ? 0 : 1)   // S3

                    Text(copy.meta)
                        .font(Theme.Font.metaStrong)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .frame(height: StripGeometry.metaSlot, alignment: .leading)

                    Text(copy.synopsis)
                        .font(Theme.Font.synopsis)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                        .lineLimit(geometry.synopsisLines)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: geometry.synopsisSlot, alignment: .topLeading)
                        // A late synopsis (the one gap-fill allowed after a commit) lands with no
                        // motion: the slot is fixed, so there is nothing to animate but the text.
                        .animation(nil, value: copy.synopsis)
                }
                .frame(width: Theme.Size.heroInfoPanelWidth, alignment: .leading)
                #if DEBUG
                // The "never two titles at once" oracle (`debug_stage … maxLive=`), counted from
                // INSIDE the `.id` like Classic's `hero_info`.
                .onAppear { HeroInfoLiveCounter.appear() }
                .onDisappear { HeroInfoLiveCounter.disappear() }
                #endif
                .id(shown.identity)
                .transition(.identity)
                .animation(output.animation) { $0.opacity(output.textOpacity) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stage_info")
            }
        }
        .frame(width: Theme.Size.heroInfoPanelWidth,
               height: max(0, geometry.stageHeight - geometry.stageBlockTop - StripGeometry.stageBottomGap),
               alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stage_text_slot")
        .padding(.top, geometry.stageBlockTop)
        .padding(.leading, geometry.stageBlockLeading)
    }
}

// MARK: - Strip edge

/// The strip's top edge (§3.4, D4 / #3): a full-width mask from `gutter` above the strip's top to
/// its bottom, whose top `gutter` ramps clear → opaque. Those points are the stage block's bottom
/// gutter, so a row leaving upward softens there and never draws over the synopsis. The negative
/// padding lets the mask reach above the masked view's own frame.
struct StripEdgeMask: View {
    let gutter: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: gutter)
            Color.black
        }
        .padding(.top, -gutter)
    }
}

// MARK: - DEBUG readouts

#if DEBUG
/// S7: `<probeID> phase= shown= pending= swaps= maxLive= stageH= stripH= P= fits= rest= row= fitem=
/// disp=` (append-only). `row` is the strip's row index, `fitem` the last reported item id
/// (`nuvio-folder://…` for a folder tile), `disp` the shown identity. A LEAF observing only its own
/// readout state.
struct StageDebugLabel: View {
    @ObservedObject var debug: StageDebugState
    let geometry: StripGeometry
    let probeID: String

    var body: some View {
        Text("\(probeID) \(debug.swapLine) maxLive=\(HeroInfoLiveCounter.max) stageH=\(Self.number(geometry.stageHeight)) stripH=\(Self.number(geometry.stripHeight)) P=\(Self.number(geometry.pageHeight)) fits=\(geometry.fits ? 1 : 0) rest=\(debug.rest) row=\(debug.row) fitem=\(debug.fitem) disp=\(debug.disp)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier(probeID)
            .allowsHitTesting(false)
    }

    /// Whole numbers print bare ("447"), half points with one decimal ("520.5").
    static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", Double(value))
    }
}

/// W2-A (§7): `debug_stageTrailer armed=<type:id|-> arms=<n> resets=<n> last=<arm|reset>/<via>`, the
/// background trailer's arming record (Home only: `StageStripHome` mounts it). `via` is the gate
/// that moved it (`rest`, `activity`, `focus`, `cover`, `scene`, `mode`, `autoplay`, `chrome`,
/// `focusLost`, `disappear`). Separate from `debug_stage`, whose S7 tokens stay as they are. A LEAF.
struct StageTrailerDebugLabel: View {
    @ObservedObject var debug: StageDebugState

    var body: some View {
        Text(verbatim: "debug_stageTrailer armed=\(debug.trailerArmed) arms=\(debug.trailerArms) resets=\(debug.trailerResets) last=\(debug.trailerLast)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_stageTrailer")
            .allowsHitTesting(false)
    }
}

/// `debug_strip <last PRESS summary> row= key= foc=<rowKey>/<itemId> atTop= segs=<n> seg=<travel>/<dur ms>`
/// (#18). `segs` and `seg` move at each motion segment's END, never per frame. A LEAF.
struct StripDebugLabel: View {
    @ObservedObject var debug: StageDebugState
    @ObservedObject private var probe = StageStripProbe.shared

    var body: some View {
        Text("debug_strip \(probe.lastSummary.isEmpty ? "-" : probe.lastSummary) row=\(debug.row) key=\(debug.rowKey) foc=\(debug.foc) atTop=\(debug.atTop ? 1 : 0) segs=\(probe.segmentCount) seg=\(probe.lastSegment)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_strip")
            .allowsHitTesting(false)
    }
}
#endif
