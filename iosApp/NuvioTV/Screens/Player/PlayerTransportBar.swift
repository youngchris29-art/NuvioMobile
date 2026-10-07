import SwiftUI
import UIKit

// The mpv player's transport bar (P1, Infuse geometry, D4/D8). Pure geometry, formats and the hide
// rule live up here and are unit-tested; the view below draws them. The bar is always in the tree
// (`state.controlsVisible` only fades and slides it), and it never owns focus: libmpv owns the
// remote, so the pill row is drawn from `TransportBarModel.focusedPill` (see `PlayerPills.swift`).

// MARK: - Geometry

/// Pure layout of the bar on a canvas (1920 × 1080 on every Apple TV, but everything derives from
/// `canvas`). All frames are in the full-screen coordinate space (the bar ignores safe areas).
struct TransportBarLayout: Equatable {
    static let sideInset: CGFloat = 86
    static let trackCentreFromBottom: CGFloat = 95
    static let trackRestHeight: CGFloat = 10
    static let trackActiveHeight: CGFloat = 14
    static let timesGap: CGFloat = 13
    static let timesHeight: CGFloat = 34
    static let titleHeight: CGFloat = 53
    static let metaHeight: CGFloat = 34
    static let titleAboveTrack: CGFloat = 60
    static let lockupSpacing: CGFloat = 2
    static let pillSize: CGFloat = 62
    static let pillSpacing: CGFloat = 25
    static let lockupPillGap: CGFloat = 40
    static let scrimHeight: CGFloat = 300
    static let labelGap: CGFloat = 16
    // Swipe scrub preview card (P2).
    static let cardSize = CGSize(width: 400, height: 225)
    static let cardGapAboveTrack: CGFloat = 30          // above the 14 pt active track's top
    static let cardCornerRadius: CGFloat = 12
    static let chapterGap: CGFloat = 8
    static let chapterHeight: CGFloat = 34

    let canvas: CGSize
    let pillCount: Int

    var trackMinX: CGFloat { Self.sideInset }
    var trackMaxX: CGFloat { canvas.width - Self.sideInset }
    var trackWidth: CGFloat { trackMaxX - trackMinX }
    /// Global y of the track's centre line.
    var trackCentreY: CGFloat { canvas.height - Self.trackCentreFromBottom }
    var trackRestFrame: CGRect {
        CGRect(x: trackMinX, y: trackCentreY - Self.trackRestHeight / 2, width: trackWidth, height: Self.trackRestHeight)
    }
    static func trackHeight(active: Bool) -> CGFloat { active ? trackActiveHeight : trackRestHeight }

    /// Maps a time to a global x on the track (clamped to the track; unknown duration → left end).
    func x(forSec sec: Double, durationSec: Double) -> CGFloat {
        guard durationSec > 0, sec.isFinite else { return trackMinX }
        let f = min(max(sec / durationSec, 0), 1)
        return trackMinX + trackWidth * CGFloat(f)
    }

    /// Top of the times row: track rest bottom + 13.
    var timesTop: CGFloat { trackRestFrame.maxY + Self.timesGap }
    var timesRowFrame: CGRect { CGRect(x: trackMinX, y: timesTop, width: trackWidth, height: Self.timesHeight) }

    var titleFrameBottom: CGFloat { trackCentreY - Self.titleAboveTrack }
    var pillRowWidth: CGFloat {
        guard pillCount > 0 else { return 0 }
        return CGFloat(pillCount) * Self.pillSize + CGFloat(pillCount - 1) * Self.pillSpacing
    }
    var lockupWidth: CGFloat {
        var w = trackWidth
        if pillCount > 0 { w -= pillRowWidth + Self.lockupPillGap }
        return max(w, 0)
    }
    var lockupFrame: CGRect {
        let height = Self.titleHeight + Self.lockupSpacing + Self.metaHeight
        return CGRect(x: trackMinX, y: titleFrameBottom - Self.titleHeight, width: lockupWidth, height: height)
    }
    /// Pill row: trailing edge on the track end, vertically centred on the title.
    var pillRowFrame: CGRect {
        let centreY = titleFrameBottom - Self.titleHeight / 2
        return CGRect(x: trackMaxX - pillRowWidth, y: centreY - Self.pillSize / 2, width: pillRowWidth, height: Self.pillSize)
    }
    var scrimFrame: CGRect {
        CGRect(x: 0, y: canvas.height - Self.scrimHeight, width: canvas.width, height: Self.scrimHeight)
    }

    /// The preview target label, centred under `centreX` and clamped inside the track span.
    func targetLabelFrame(centreX: CGFloat, width: CGFloat) -> CGRect {
        let x = min(max(centreX - width / 2, trackMinX), max(trackMaxX - width, trackMinX))
        return CGRect(x: x, y: timesTop, width: width, height: Self.timesHeight)
    }

    /// The scrub preview card, centred on `centreX` and clamped inside the track span. On a 1080
    /// canvas it spans y 723 … 948 (30 pt above the active track).
    func previewCardFrame(centreX: CGFloat) -> CGRect {
        let w = Self.cardSize.width
        let x = min(max(centreX - w / 2, trackMinX), max(trackMaxX - w, trackMinX))
        let y = trackCentreY - Self.trackActiveHeight / 2 - Self.cardGapAboveTrack - Self.cardSize.height
        return CGRect(x: x, y: y, width: w, height: Self.cardSize.height)
    }

    /// The chapter title above the card, same clamp, `width` wide. One position whether or not a
    /// card frame is shown (`cardShown`), so nothing jumps when a frame arrives.
    func chapterLabelFrame(centreX: CGFloat, width: CGFloat, cardShown: Bool) -> CGRect {
        let x = min(max(centreX - width / 2, trackMinX), max(trackMaxX - width, trackMinX))
        let y = previewCardFrame(centreX: centreX).minY - Self.chapterGap - Self.chapterHeight
        return CGRect(x: x, y: y, width: width, height: Self.chapterHeight)
    }

    /// While a preview shows, the end labels give way to the target label when they would touch it.
    static func labelVisibility(target: CGRect, elapsed: CGRect, remaining: CGRect,
                                gap: CGFloat = labelGap) -> (elapsed: Bool, remaining: Bool) {
        (elapsed: !(target.minX < elapsed.maxX + gap), remaining: !(target.maxX > remaining.minX - gap))
    }
}

// MARK: - Formats

enum TransportTimeFormat {
    /// `m:ss` or `h:mm:ss`; non-finite or negative → `0:00`.
    static func elapsed(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `-` + the remaining time; `--:--` while the duration is unknown.
    static func remaining(position: Double, duration: Double) -> String {
        guard duration > 0 else { return "--:--" }
        return "-" + elapsed(max(duration - position, 0))
    }

    /// The wall-clock time the file would end at: now + remaining / speed. nil while the duration is unknown.
    static func endClock(now: Date, position: Double, duration: Double, speed: Double,
                         locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard duration > 0 else { return nil }
        let end = now.addingTimeInterval(max(duration - position, 0) / max(speed, 0.1))
        return endClockFormatter(locale: locale, timeZone: timeZone).string(from: end)
    }

    /// One formatter per locale + time zone (main thread: SwiftUI renders and the tests).
    nonisolated(unsafe) private static var cachedEndClockFormatter: DateFormatter?
    private static func endClockFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        if let f = cachedEndClockFormatter, f.locale == locale, f.timeZone == timeZone { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        cachedEndClockFormatter = f
        return f
    }
}

// MARK: - Skip spans, hide rule

enum TransportSpanMath {
    /// Fractions (0…1) of a span on the track; nil when the duration is unknown or the span is empty.
    static func fractions(_ span: TransportSpan, durationSec: Double) -> (start: Double, end: Double)? {
        guard durationSec > 0 else { return nil }
        let s = min(max(span.start / durationSec, 0), 1)
        let e = min(max(span.end / durationSec, 0), 1)
        return e > s ? (s, e) : nil
    }
}

enum TransportHideRule {
    /// Seconds after the last input until the bar hides; nil = never (paused with the pause card off).
    static func delay(isPaused: Bool, pauseCardEnabled: Bool) -> TimeInterval? {
        if !isPaused { return 4 }
        return pauseCardEnabled ? 5 : nil
    }

    /// A hide timer that fires while a pill is focused or a seek mode is active does nothing; the
    /// next input re-arms it.
    static func mayHide(pillFocused: Bool, modeActive: Bool) -> Bool { !pillFocused && !modeActive }
}

// MARK: - Fonts

/// The bar's literal sizes, in one place (the HIG contract bans fixed sizes at call sites, and no
/// `Theme.Font` token is 44 or 28). They follow the font family and Larger Text.
enum PlayerTransportMetrics {
    private static func font(size: CGFloat, weight: Font.Weight, style: Font.TextStyle, ui: UIFont.TextStyle) -> Font {
        switch Theme.Font.family {
        case .system:
            return .system(size: UIFontMetrics(forTextStyle: ui).scaledValue(for: size), weight: weight)
        case .openSans:
            return .custom("Open Sans", size: size * Theme.Font.openSansScale, relativeTo: style).weight(weight)
        }
    }
    static var title: Font { font(size: 44, weight: .semibold, style: .title3, ui: .title3) }
    static var meta: Font { font(size: 28, weight: .regular, style: .body, ui: .body) }
    static var time: Font { meta.monospacedDigit() }
}

// MARK: - View

struct PlayerTransportBar: View {
    @ObservedObject var model: TransportBarModel
    @ObservedObject var state: MPVPlaybackState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trackGlobal: CGRect = .zero
    @State private var elapsedWidth: CGFloat = 80
    @State private var remainingWidth: CGFloat = 100
    @State private var targetWidth: CGFloat = 80
    @State private var chapterWidth: CGFloat = 0

    private var visible: Bool { state.controlsVisible }

    var body: some View {
        GeometryReader { geo in
            let layout = TransportBarLayout(canvas: geo.size, pillCount: model.pills.count)
            ZStack(alignment: .topLeading) {
                chrome(layout)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible || reduceMotion ? 0 : 24)
                    .animation(.easeInOut(duration: 0.25), value: visible)
                    .allowsHitTesting(visible)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("player.bar")
                #if DEBUG
                probe(layout, canvasHeight: geo.size.height)
                #endif
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Chrome

    private func chrome(_ layout: TransportBarLayout) -> some View {
        let active = model.mode.isActive
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(width: layout.scrimFrame.width, height: layout.scrimFrame.height)
                .position(x: layout.scrimFrame.midX, y: layout.scrimFrame.midY)

            lockup(layout)
                .opacity(active ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: active)
            PlayerPillRow(model: model)
                .frame(width: layout.pillRowFrame.width, height: layout.pillRowFrame.height)
                .position(x: layout.pillRowFrame.midX, y: layout.pillRowFrame.midY)
                .opacity(active ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: active)

            track(layout, active: active)
            timesRow(layout)
            scrubCard(layout)
        }
        .foregroundStyle(.white)
    }

    private func lockup(_ layout: TransportBarLayout) -> some View {
        VStack(alignment: .leading, spacing: TransportBarLayout.lockupSpacing) {
            Text(verbatim: model.title)
                .font(PlayerTransportMetrics.title)
                .lineLimit(1).truncationMode(.tail)
                .frame(height: TransportBarLayout.titleHeight, alignment: .bottomLeading)
            Text(verbatim: model.metaLine)
                .font(PlayerTransportMetrics.meta)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).truncationMode(.tail)
                .frame(height: TransportBarLayout.metaHeight, alignment: .topLeading)
        }
        .frame(width: layout.lockupFrame.width, height: layout.lockupFrame.height, alignment: .topLeading)
        .position(x: layout.lockupFrame.midX, y: layout.lockupFrame.midY)
    }

    private func track(_ layout: TransportBarLayout, active: Bool) -> some View {
        let h = TransportBarLayout.trackHeight(active: active)
        let duration = model.durationSec
        let playedSec = model.previewSec ?? model.positionSec
        let playedX = layout.x(forSec: playedSec, durationSec: duration) - layout.trackMinX
        let container = CGRect(x: layout.trackMinX, y: layout.trackCentreY - TransportBarLayout.trackActiveHeight / 2,
                               width: layout.trackWidth, height: TransportBarLayout.trackActiveHeight)
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.20)).frame(height: h)
            ForEach(Array(model.bufferedRanges.enumerated()), id: \.offset) { _, r in
                let x0 = layout.x(forSec: r.start, durationSec: duration) - layout.trackMinX
                let x1 = layout.x(forSec: r.end, durationSec: duration) - layout.trackMinX
                Capsule().fill(.white.opacity(0.35)).frame(width: max(x1 - x0, 0), height: h).offset(x: x0)
            }
            Capsule().fill(.white).frame(width: max(playedX, 0), height: h)
            ForEach(Array(model.skipSpans.enumerated()), id: \.offset) { _, span in
                if let f = TransportSpanMath.fractions(span, durationSec: duration) {
                    Rectangle().fill(.white.opacity(0.6))
                        .frame(width: layout.trackWidth * CGFloat(f.end - f.start), height: 4)
                        .offset(x: layout.trackWidth * CGFloat(f.start))
                }
            }
            ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, chapter in
                Rectangle().fill(.white.opacity(0.6)).frame(width: 2, height: h * 2)
                    .offset(x: layout.x(forSec: chapter.sec, durationSec: duration) - layout.trackMinX - 1)
            }
            if model.previewSec != nil {
                let dotX = layout.x(forSec: model.positionSec, durationSec: duration) - layout.trackMinX
                Circle().fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .offset(x: dotX - 8)
            }
        }
        .frame(width: container.width, height: container.height, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: active)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { trackGlobal = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("player.bar.track")
        .position(x: container.midX, y: container.midY)
    }

    // MARK: Scrub card (P2)

    private var scrubTarget: Double? {
        if case .scrubbing(let t) = model.mode { return t }
        return nil
    }

    /// The frame you will land on (letterboxed on a black body, never cropped), with the chapter
    /// title above it. No frame: no card body, the title keeps its position.
    @ViewBuilder
    private func scrubCard(_ layout: TransportBarLayout) -> some View {
        let fade: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.15)
        ZStack(alignment: .topLeading) {
            if let target = scrubTarget {
                let cx = layout.x(forSec: target, durationSec: model.durationSec)
                if let frame = model.previewFrame {
                    let f = layout.previewCardFrame(centreX: cx)
                    let shape = RoundedRectangle(cornerRadius: TransportBarLayout.cardCornerRadius, style: .continuous)
                    ZStack {
                        Color.black
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: f.width, height: f.height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.4), lineWidth: 2))
                    .position(x: f.midX, y: f.midY)
                    .transition(.opacity)
                    .accessibilityIdentifier("player.bar.previewCard")
                    .accessibilityHidden(true)
                }
                if let title = model.chapterTitle(at: target) {
                    let w = min(chapterWidth, TransportBarLayout.cardSize.width)
                    let f = layout.chapterLabelFrame(centreX: cx, width: w, cardShown: model.previewFrame != nil)
                    Text(verbatim: title)
                        .font(PlayerTransportMetrics.meta)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: w, height: f.height)
                        .background(
                            // The natural width, measured off-screen (the visible text is clamped).
                            Text(verbatim: title).font(PlayerTransportMetrics.meta).lineLimit(1)
                                .fixedSize().hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chapterWidth = $0 }
                        )
                        .position(x: f.midX, y: f.midY)
                        .transition(.opacity)
                        .accessibilityIdentifier("player.bar.previewChapter")
                }
            }
        }
        .animation(fade, value: model.previewFrame != nil)
        .animation(fade, value: scrubTarget != nil)
    }

    private func rightLabel() -> String {
        if model.showsEndTime,
           let clock = TransportTimeFormat.endClock(now: Date(), position: model.positionSec,
                                                    duration: model.durationSec, speed: model.playbackSpeed) {
            return String(localized: "ends \(clock)")
        }
        return TransportTimeFormat.remaining(position: model.positionSec, duration: model.durationSec)
    }

    private func timesRow(_ layout: TransportBarLayout) -> some View {
        let row = layout.timesRowFrame
        let preview = model.previewSec
        var showElapsed = true, showRemaining = true
        var targetFrame: CGRect = .zero
        if let p = preview {
            targetFrame = layout.targetLabelFrame(centreX: layout.x(forSec: p, durationSec: model.durationSec), width: targetWidth)
            let vis = TransportBarLayout.labelVisibility(
                target: targetFrame,
                elapsed: CGRect(x: row.minX, y: row.minY, width: elapsedWidth, height: row.height),
                remaining: CGRect(x: row.maxX - remainingWidth, y: row.minY, width: remainingWidth, height: row.height))
            showElapsed = vis.elapsed; showRemaining = vis.remaining
        }
        // While scrubbing, the target label is the only time on the row.
        let scrubbing = scrubTarget != nil
        if scrubbing { showElapsed = false; showRemaining = false }
        let labelFade: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.15)
        let elapsedText = TransportTimeFormat.elapsed(model.positionSec)
        let rightText = rightLabel()
        return ZStack(alignment: .topLeading) {
            ZStack {
                HStack {
                    Text(verbatim: elapsedText)
                        .font(PlayerTransportMetrics.time)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { elapsedWidth = $0 }
                        .opacity(showElapsed ? 1 : 0)
                        .animation(labelFade, value: scrubbing)
                        .accessibilityIdentifier("player.bar.time.elapsed")
                        .accessibilityValue(elapsedText)
                    Spacer(minLength: 0)
                    Text(verbatim: rightText)
                        .font(PlayerTransportMetrics.time)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { remainingWidth = $0 }
                        .opacity(showRemaining ? 1 : 0)
                        .animation(labelFade, value: scrubbing)
                        .accessibilityIdentifier("player.bar.time.remaining")
                        .accessibilityValue(rightText)
                }
                if preview == nil {
                    Label("Swipe down for info", systemImage: "chevron.down")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: row.width, height: row.height)
            .position(x: row.midX, y: row.midY)

            if let p = preview {
                let text = TransportTimeFormat.elapsed(p)
                Text(verbatim: text)
                    .font(PlayerTransportMetrics.time)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { targetWidth = $0 }
                    .accessibilityIdentifier("player.bar.time.target")
                    .accessibilityValue(text)
                    .position(x: targetFrame.midX, y: targetFrame.midY)
            }
        }
    }

    // MARK: Probe (DEBUG)

    #if DEBUG
    private func probe(_ layout: TransportBarLayout, canvasHeight: CGFloat) -> some View {
        let focus: String
        if !visible { focus = "none" }
        else if let p = model.focusedPill { focus = "pill:\(p.rawValue)" }
        else { focus = "track" }
        let prev = model.previewSec.map { String(format: "%.1f", $0) } ?? "nil"
        let scrub: String
        if case .scrubbing(let t) = model.mode { scrub = String(format: "%.1f", t) } else { scrub = "nil" }
        let text = "mode=\(model.mode.probeName) pos=\(String(format: "%.1f", model.positionSec)) prev=\(prev) "
            + "buf=\(model.bufferedRanges.count) focus=\(focus) y=\(String(format: "%.0f", canvasHeight - trackGlobal.midY)) "
            + "x0=\(String(format: "%.0f", trackGlobal.minX)) x1=\(String(format: "%.0f", trackGlobal.maxX)) "
            + "vis=\(visible ? 1 : 0) ends=\(model.showsEndTime ? 1 : 0) pills=\(model.pills.count)"
            + " scrub=\(scrub) curve=\(model.scrubCurveCode) frame=\(model.previewFrame != nil ? 1 : 0) arb=\(model.debugArbiter)"
            + " chapters=\(model.chapters.count) aspect=\(model.aspectMode.rawValue)"
            + " thumbs=\(model.previewFrames)"
        return Text(verbatim: text)
            .font(.system(size: 8))
            .opacity(0.011)
            .allowsHitTesting(false)
            .accessibilityIdentifier("debug_transportProbe")
    }
    #endif
}

/// The optional wall clock (Settings → player.showClock), top-trailing; the screen stacks it above
/// the stream-info card and fades it with the bar.
struct PlayerTransportClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(Theme.Font.sectionTitle.monospacedDigit())
                .foregroundStyle(.white)
                .accessibilityIdentifier("player.bar.clock")
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// Reposted from the Darwin notification `com.nuvio.debug.transport.lightTap` (UI legs).
    static let nuvioDebugTransportLightTap = Notification.Name("nuvio.debug.transport.lightTap")
    /// Reposted from `com.nuvio.debug.transport.scrubInject` (UI legs): run `-debug.scrubInject`.
    static let nuvioDebugTransportScrubInject = Notification.Name("nuvio.debug.transport.scrubInject")
}
#endif

#if DEBUG
/// DEBUG: reposts the Darwin notifications `com.nuvio.debug.transport.lightTap` and
/// `com.nuvio.debug.transport.scrubInject` (posted by the UI test runner, which has no touch
/// surface) as `NotificationCenter` notifications. Process-wide and installed once; the
/// controller's block observers are the part that is torn down.
enum TransportDebugDarwinBridge {
    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .nuvioDebugTransportLightTap, object: nil)
                }
            },
            "com.nuvio.debug.transport.lightTap" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .nuvioDebugTransportScrubInject, object: nil)
                }
            },
            "com.nuvio.debug.transport.scrubInject" as CFString, nil, .deliverImmediately)
    }
}
#endif
