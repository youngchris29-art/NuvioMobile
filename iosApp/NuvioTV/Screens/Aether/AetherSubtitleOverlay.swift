import Combine
import CoreGraphics
import NuvioAether
import SharedCore
import SwiftUI

// Aether (Phase 1), plan section 5: the subtitle overlay the Aether route draws itself, above the video
// surface and below the transport bar. Self-contained: no controller, no engine. W3-A wires it in.
//
// ─── API for W3-A ────────────────────────────────────────────────────────────────────────────────────
//
// Build one model per player screen, next to the `AetherPlaybackSession`:
//
//     let subtitles = AetherSubtitleOverlayModel(
//         clock: session.clock,                                  // time: AetherClock.sourceSec only
//         cues: session.$cues.eraseToAnyPublisher(),             // the engine's cue window
//         activeTrackID: session.$activeSubtitleID.eraseToAnyPublisher(),   // which track a window is for
//         style: AetherSubtitleStyle.input(from: settings.subtitleStyle),
//         aspectMode: .fit)
//
// and place the view in the player's ZStack, above the surface and below the chrome:
//
//     AetherSubtitleOverlay(model: subtitles)                    // full screen; it reads the safe area itself
//
// Then feed it:
//
// - Time: nothing to do. The model subscribes to `clock.$sourceSec` (raw source PTS, never `currentSec`)
//   and re-asks the timeline on each tick, so the overlay updates at most at the clock's tick rate
//   (about 10 Hz), and publishes only when the set of cues on screen changes.
// - Cues: nothing to do with the `cues:` publisher. Without one (tests, previews, a merged source), call
//   `setCues(_:)`. A cue on screen that drops out of a new window is kept until its end.
// - Track: `setTrack(id: session.activeSubtitleID, isForced: track?.isForced ?? false)` whenever the
//   selection changes: call it right before `selectSubtitle(id:)` (and `clearSubtitle()` →
//   `setTrack(id: nil, …)`); calling it right after also works, since the window the engine published
//   for that track is adopted. A new id empties the store at once, and with `activeTrackID:` a cue window
//   is taken only while the engine's active track equals the selected one, so neither a lingering line
//   nor a late window of the old track shows; the new track's next window fills it. Cue ids are NOT
//   session-monotonic across tracks (a sidecar file numbers its cues from 0), so nothing here keys on
//   id order. A nil track takes no cues.
// - Mode (forced rule): `setMode(SubtitleOverlayMode.resolve(primary: settings.preferredSubtitleLanguage,
//   useForcedSubtitles: style.useForcedSubtitles, hasSelectedTrack: id != nil, userSelectedTrack: …,
//   startPlanForcedOnly: plan.mode == .forcedOnly))`. `.off` draws nothing; `.forcedOnly` draws forced
//   cues only (a forced bitmap cue, or every cue of a forced track).
// - Delay: `setDelay(sec)` with the panel's subtitle delay (same key and range as mpv). Positive shows
//   later. Applied host-side: the cue at `sourceSec - delaySec` shows.
// - Style: `setStyle(settings.subtitleStyle)` on every settings change (or `setStyleInput(_:)`).
// - Picture: `setPresentationSize(session.diagnostics.presentationSize)` when diagnostics change, and
//   `setAspect(_:)` with the `PlayerAspectMode` in force (Fit in Phase 1; the Aspect pill is hidden on
//   Aether), or `setAspect(_ aether: AetherAspect)` to mirror `session.aspect`. Only bitmap cues depend on
//   them.
// - New source: `reset()` (a Replay or a DV rebuild of the same source keeps the axis; no reset needed).
//
// Drawing: text cues at the bottom (ASS `\an7…9` at the top), one block per cue, the earliest-starting
// at the bottom, residual `{\…}` tags stripped (`SubtitleCueText`); bitmap cues (`.image`) at their
// normalized rect inside the displayed video frame (`AetherSubtitleLayout`). Text stays inside the safe
// area; bitmaps follow the picture. No animations: a line appears and disappears on the tick that
// changes it, and host animations are disabled inside the overlay. It never takes focus or touches.
//
// Limitations (Phase 1): `AetherCue.anchor` (`\pos`) is ignored, horizontal ASS alignment is centred,
// styled ASS is plain text (styled files are routed to mpv by `AetherSubtitleRouting`).
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

/// A main-actor time source for the overlay: the raw source PTS axis and its publisher. `AetherClock`
/// conforms; tests and previews use `SubtitleOverlayManualClock`. The publisher must emit on the main
/// thread (an off-main value is hopped to main, one run-loop turn late).
@MainActor
protocol SubtitleOverlayTimeSource: AnyObject {
    var overlaySourceSec: Double { get }
    var overlaySourceSecPublisher: AnyPublisher<Double, Never> { get }
}

extension AetherClock: SubtitleOverlayTimeSource {
    var overlaySourceSec: Double { sourceSec }
    var overlaySourceSecPublisher: AnyPublisher<Double, Never> { $sourceSec.eraseToAnyPublisher() }
}

/// A clock the host sets by hand, for previews and tests.
@MainActor
final class SubtitleOverlayManualClock: SubtitleOverlayTimeSource {
    @Published var sourceSec: Double

    init(sourceSec: Double = 0) { self.sourceSec = sourceSec }

    var overlaySourceSec: Double { sourceSec }
    var overlaySourceSecPublisher: AnyPublisher<Double, Never> { $sourceSec.eraseToAnyPublisher() }
}

/// The overlay's state: the timeline, the inputs W3-A feeds, and the cues on screen. The view observes
/// this object only, and it publishes only when what is drawn changes (the cue set, the style, the
/// picture geometry), never on a tick that changes nothing.
@MainActor
final class AetherSubtitleOverlayModel: ObservableObject {
    /// The cues on screen now, in `(startSec, id)` order.
    @Published private(set) var activeCues: [AetherCue] = []
    @Published private(set) var styleInput: AetherSubtitleStyle.Input
    @Published private(set) var aspectMode: PlayerAspectMode
    @Published private(set) var presentationSize: CGSize?

    private(set) var timeline = SubtitleCueTimeline()
    private(set) var sourceSec: Double
    private(set) var delaySec: Double = 0
    private(set) var trackID: Int?
    /// Set once `setTrack` has been called: from then on a nil track takes no cues at all.
    private var trackWasSet = false
    /// Whether an engine active-track publisher gates the cue windows, and its last value.
    private let gatesOnEngineTrack: Bool
    private(set) var engineTrackID: Int?
    /// The latest window and the engine track it arrived under, kept even when the gate dropped it, so a
    /// `setTrack` that follows the engine's synchronous switch (track id and whole-file sidecar window in
    /// one block) can still adopt it.
    private var lastWindow: [AetherCue] = []
    private var lastWindowEngineTrackID: Int?
    private var cancellables: Set<AnyCancellable> = []

    /// `activeTrackID`: the session's `$activeSubtitleID`. With it, a cue window is adopted only while the
    /// engine's active track is the selected one (`setTrack`). The engine assigns the track before or after
    /// the matching window depending on the path, but always clears or replaces the window on a switch,
    /// so dropping windows while the ids differ (and never re-adopting a dropped one) loses nothing.
    init(timeSource: any SubtitleOverlayTimeSource,
         cues: AnyPublisher<[AetherCue], Never>? = nil,
         activeTrackID: AnyPublisher<Int?, Never>? = nil,
         style: AetherSubtitleStyle.Input = .default,
         aspectMode: PlayerAspectMode = .fit) {
        self.styleInput = style
        self.aspectMode = aspectMode
        self.sourceSec = timeSource.overlaySourceSec
        self.gatesOnEngineTrack = activeTrackID != nil
        activeTrackID?
            .sink { [weak self] id in Self.onMain { self?.engineTrackID = id } }
            .store(in: &cancellables)
        timeSource.overlaySourceSecPublisher
            .removeDuplicates()
            .sink { [weak self] t in Self.onMain { self?.tick(sourceSec: t) } }
            .store(in: &cancellables)
        cues?
            .sink { [weak self] list in Self.onMain { self?.setCues(list) } }
            .store(in: &cancellables)
    }

    convenience init(clock: AetherClock, cues: AnyPublisher<[AetherCue], Never>? = nil,
                     activeTrackID: AnyPublisher<Int?, Never>? = nil,
                     style: AetherSubtitleStyle.Input = .default, aspectMode: PlayerAspectMode = .fit) {
        self.init(timeSource: clock, cues: cues, activeTrackID: activeTrackID, style: style, aspectMode: aspectMode)
    }

    // MARK: Inputs

    /// A clock tick (also driven by the time source subscription).
    func tick(sourceSec t: Double) {
        guard t != sourceSec else { return }
        sourceSec = t
        refresh()
    }

    /// The engine's cue window (or any full cue list). A cue on screen that the new list lacks stays
    /// until its end.
    func setCues(_ cues: [AetherCue]) {
        lastWindow = cues
        lastWindowEngineTrackID = engineTrackID
        if trackWasSet && trackID == nil { return }
        if gatesOnEngineTrack && trackWasSet && engineTrackID != trackID { return }
        if timeline.replace(cues: cues, keepingActiveAtSourceSec: sourceSec, delaySec: delaySec) { refresh() }
    }

    /// The host subtitle delay in seconds; positive shows later. Non-finite values count as 0.
    func setDelay(_ sec: Double) {
        let d = sec.isFinite ? sec : 0
        guard d != delaySec else { return }
        delaySec = d
        refresh()
    }

    func setMode(_ mode: SubtitleOverlayMode) {
        guard mode != timeline.mode else { return }
        timeline.mode = mode
        refresh()
    }

    /// The selected subtitle track; `isForced` is the track's `AetherTrack.isForced`. A different id
    /// empties the store at once; with the engine track gate, windows for any other track are dropped,
    /// so no line of the old track lingers or comes back from a late window. A nil track takes no cues
    /// until the next `setTrack`. Call it when you call `selectSubtitle(id:)` / `clearSubtitle()`, before the
    /// engine answers with the new track's cues.
    func setTrack(id: Int?, isForced: Bool) {
        var changed = false
        if id != trackID || !trackWasSet {
            // A later switch empties the store. The first call keeps what already arrived (the start
            // track's cues can land before the host learns the id), unless the gate shows the engine is
            // on another track (its own default), whose cues must not stay.
            if trackWasSet || (gatesOnEngineTrack && engineTrackID != id) { timeline.removeAll() }
            trackWasSet = true
            trackID = id
            // The engine already switched (selectSubtitle ran first): adopt the window it published for
            // this track, without carry-over. Never re-adopted on a later engine id change.
            if gatesOnEngineTrack, id != nil, engineTrackID == id, lastWindowEngineTrackID == id,
               timeline.cues.isEmpty {
                timeline.replace(cues: lastWindow)
            }
            changed = true
        }
        if isForced != timeline.trackIsForced {
            timeline.trackIsForced = isForced
            changed = true
        }
        if changed { refresh() }
    }

    func setStyle(_ state: SubtitleStyleState) { setStyleInput(AetherSubtitleStyle.input(from: state)) }

    func setStyleInput(_ input: AetherSubtitleStyle.Input) {
        if input != styleInput { styleInput = input }
    }

    func setAspect(_ mode: PlayerAspectMode) {
        if mode != aspectMode { aspectMode = mode }
    }

    /// Mirrors the session's `aspect` (`AetherAspect` has no zoom).
    func setAspect(_ aether: AetherAspect) {
        switch aether {
        case .fit: setAspect(PlayerAspectMode.fit)
        case .fill: setAspect(PlayerAspectMode.fill)
        case .stretch: setAspect(PlayerAspectMode.stretch)
        @unknown default: setAspect(PlayerAspectMode.fit)
        }
    }

    func setPresentationSize(_ size: CGSize?) {
        if size != presentationSize { presentationSize = size }
    }

    /// A new source: no cues, no track, nothing on screen. The time axis follows the clock.
    func reset() {
        trackID = nil
        trackWasSet = false
        lastWindow = []
        lastWindowEngineTrackID = nil
        timeline.removeAll()
        timeline.trackIsForced = false
        refresh()
    }

    // MARK: Private

    /// Re-asks the timeline. Eviction runs on each new window (`setCues`), not per tick, so a tick costs
    /// one binary search and a short scan.
    private func refresh() {
        let next = timeline.active(atSourceSec: sourceSec, delaySec: delaySec)
        if next != activeCues { activeCues = next }
    }

    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }
}

/// The overlay view. Full screen (it ignores the safe area for the picture and keeps text inside it),
/// never hit-testable, hidden from accessibility.
struct AetherSubtitleOverlay: View {
    @ObservedObject var model: AetherSubtitleOverlayModel

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let container = CGRect(origin: .zero, size: proxy.size)
            let style = AetherSubtitleStyle.resolve(model.styleInput, height: proxy.size.height,
                                                    safeAreaBottom: insets.bottom)
            let video = AetherSubtitleLayout.videoRect(container: container,
                                                       presentationSize: model.presentationSize,
                                                       mode: model.aspectMode)
            let items = AetherSubtitleOverlayItems(cues: model.activeCues)
            ZStack(alignment: .topLeading) {
                ForEach(items.bitmaps) { bitmap in
                    let rect = AetherSubtitleLayout.bitmapRect(normalizedRect: bitmap.normalizedRect,
                                                               canvasSize: bitmap.canvasSize,
                                                               videoRect: video, container: container)
                    Image(decorative: bitmap.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                textStack(items.top, style: style)
                    .frame(width: container.width - insets.leading - insets.trailing)
                    .padding(.top, max(insets.top, style.bottomPadding))
                    .padding(.leading, insets.leading)
                    .frame(width: container.width, height: container.height, alignment: .top)
                textStack(Array(items.bottom.reversed()), style: style)
                    .frame(width: container.width - insets.leading - insets.trailing)
                    .padding(.bottom, style.bottomPadding)
                    .padding(.leading, insets.leading)
                    .frame(width: container.width, height: container.height, alignment: .bottom)
            }
            .frame(width: container.width, height: container.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { t in
            t.animation = nil
            t.disablesAnimations = true
        }
    }

    @ViewBuilder
    private func textStack(_ lines: [AetherSubtitleOverlayItems.Line], style: AetherSubtitleStyle) -> some View {
        if !lines.isEmpty {
            VStack(spacing: style.fontPoints * 0.12) {
                ForEach(lines) { line in
                    AetherSubtitleLine(text: line.text, style: style)
                }
            }
        }
    }
}

/// One text cue: an outline ring of copies under the fill, then the optional background box.
struct AetherSubtitleLine: View {
    let text: String
    let style: AetherSubtitleStyle

    var body: some View {
        let offsets = AetherSubtitleStyle.outlineOffsets(width: style.outlinePoints)
        ZStack {
            if !offsets.isEmpty {
                ZStack {
                    ForEach(offsets.indices, id: \.self) { k in
                        glyphs.foregroundStyle(style.opaqueOutlineColor).offset(offsets[k])
                    }
                }
                .compositingGroup()
                .opacity(style.outlineOpacity)
            }
            glyphs.foregroundStyle(style.textColor)
        }
        .compositingGroup()
        .padding(.horizontal, style.showsBackground ? style.fontPoints * 0.25 : 0)
        .padding(.vertical, style.showsBackground ? style.fontPoints * 0.06 : 0)
        .background {
            if style.showsBackground {
                RoundedRectangle(cornerRadius: style.fontPoints * 0.1, style: .continuous)
                    .fill(style.backgroundColor)
            }
        }
    }

    private var glyphs: some View {
        Text(verbatim: text)
            .font(.system(size: style.fontPoints, weight: style.bold ? .bold : .regular))
            .multilineTextAlignment(.center)
    }
}

/// The active cues split into what the view draws, with the text already cleaned.
struct AetherSubtitleOverlayItems {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    struct Bitmap: Identifiable {
        let id: Int
        let image: CGImage
        let normalizedRect: CGRect
        let canvasSize: CGSize
    }

    /// Bottom cues in `(startSec, id)` order (the view stacks the earliest at the bottom).
    private(set) var bottom: [Line] = []
    /// Top-aligned cues (`\an7…9`), in `(startSec, id)` order, drawn top-down.
    private(set) var top: [Line] = []
    private(set) var bitmaps: [Bitmap] = []

    init(cues: [AetherCue]) {
        for cue in cues {
            switch cue.body {
            case .text(let raw):
                let text = SubtitleCueText.display(raw)
                guard !text.isEmpty else { continue }
                let line = Line(id: cue.id, text: text)
                if SubtitleCueText.isTopAligned(cue.alignment) { top.append(line) } else { bottom.append(line) }
            case .image(let image, let rect, let canvas):
                bitmaps.append(Bitmap(id: cue.id, image: image, normalizedRect: rect, canvasSize: canvas))
            @unknown default:
                continue
            }
        }
    }
}

#if DEBUG
#Preview("Aether subtitles") {
    let clock = SubtitleOverlayManualClock(sourceSec: 2)
    let model = AetherSubtitleOverlayModel(timeSource: clock)
    model.setCues([
        AetherCue(id: 1, startSec: 0, endSec: 5, body: .text("{\\i1}The overlay draws this line\\Nin two rows")),
        AetherCue(id: 2, startSec: 1, endSec: 4, body: .text("An overlapping cue"), alignment: 8),
    ])
    return ZStack {
        Color.gray
        AetherSubtitleOverlay(model: model)
    }
}
#endif
