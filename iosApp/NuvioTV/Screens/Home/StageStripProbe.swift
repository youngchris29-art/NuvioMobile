import Combine
import QuartzCore
import SwiftUI
import UIKit

// Home Stage & Strip (P1 §8): the strip's frame-accurate motion probe, ported from the Wave 0.5
// spike (`StageSpikeProbe` + `StageSpikeMarker`, commit 035095a4) with the `[StageStrip]` prefix.
//
// Armed by `-debug.homeScrollProbe YES` (`HomeGeometryProbe.enabled`, read once at launch; not
// `#if DEBUG`, the house rule for device passes on release sideloads). One `CADisplayLink` samples
// a 1×1 marker's RENDERED (presentation-layer) y in window space every frame; a SEGMENT is
// consecutive frames moving ≥ 0.25 pt, ended by 6 still frames. Segment lines are the ground truth
// (`seg p= k= start= dur= from= to= travel=`): the press summaries can assign a segment to the
// wrong press when a row's focus report lags the scroll.
//
// Added for the Stage (beyond the spike's lines):
//   geometry rowH= P= H= stage= logo= synL= fits= posterH= font=      (on change)
//   swap phase=out|in|cancel|idle id= sinceAct=<ms> pageEnd=<ms|timeout>  (from the driver)
//   restore row= item= rung= landed=                                  (from the pager)
//   trailer arm|reset|start key= via=                                 (W2-A)

/// See the file header.
@MainActor
final class StageStripProbe: NSObject, ObservableObject {
    static let shared = StageStripProbe()

    /// `-debug.homeScrollProbe YES`.
    nonisolated static var enabled: Bool { HomeGeometryProbe.enabled }

    /// Compact form of the latest PRESS summary. Published ONLY on summaries, never per frame.
    @Published private(set) var lastSummary: String = ""
    /// Motion segments ended so far, and the last one as `<travel>/<dur ms>` (the `debug_strip`
    /// readout, #18). Published at each segment END, never per frame.
    @Published private(set) var segmentCount = 0
    @Published private(set) var lastSegment = "-"

    // Tunables (the spike's).
    private static let stillThreshold: CGFloat = 0.25
    private static let restFrames = 6
    private static let idleClose: CFTimeInterval = 1.5
    private static let afterRestGap: CFTimeInterval = 0.15
    /// A segment that started this recently before a press/row-change window opened belongs to
    /// that window (the engine's scroll starts in the same turn as the focus update, before the
    /// ownership report reaches the view).
    private static let carryWindow: CFTimeInterval = 0.15
    /// A row change this soon after a `notePress` is that press's row change, not a new press.
    private static let mergeWindow: CFTimeInterval = 2.0

    private weak var marker: StageStripMarkerView?
    private var displayLink: CADisplayLink?
    private var observersStarted = false
    private var observerTokens: [NSObjectProtocol] = []

    // Config.
    private var pageHeight: CGFloat = 0
    private var stripHeight: CGFloat = 0
    private var rowCount = 0
    private var currentRow = 0
    private var lastGeometryLine = ""

    // Frame sampling.
    private var lastY: CGFloat?
    private var lastTime: CFTimeInterval = 0
    private var stillFrames = 0
    private var restY: CGFloat?
    private var baselineY: CGFloat?
    private var loggedReadFailure = false
    private var lastCardMidY: CGFloat?

    private struct Segment {
        /// Press window number; 0 = no window was open; -1 = being carried to a new window.
        var owner: Int
        var k: Int
        var pressT0: CFTimeInterval?
        var start: CFTimeInterval
        var y0: CGFloat
        var lastMove: CFTimeInterval
        var afterRest: Bool
    }

    private struct DoneSegment {
        var start: CFTimeInterval
        var end: CFTimeInterval
        var y0: CGFloat
        var y1: CGFloat
        var afterRest: Bool
    }

    private struct PressWindow {
        var n: Int
        var label: String
        var from: Int
        var to: Int
        var key: String
        var t0: CFTimeInterval
        var byPress: Bool
        var rowMerged: Bool
        var segCount: Int = 0
        var done: [DoneSegment] = []
        var lastActivity: CFTimeInterval
    }

    private var pressCounter = 0
    private var window: PressWindow?
    private var activeSegment: Segment?

    private override init() {
        super.init()
    }

    // MARK: Logging

    func log(_ line: String) {
        guard Self.enabled else { return }
        NSLog("[StageStrip] %@", line)
    }

    private static func f1(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func ms(_ seconds: CFTimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func signedMs(_ seconds: CFTimeInterval) -> String {
        let value = ms(seconds)
        return value >= 0 ? "+\(value)" : "\(value)"
    }

    // MARK: Config

    func configure(pageHeight: CGFloat, stripHeight: CGFloat, rowCount: Int) {
        guard Self.enabled else { return }
        let geometryChanged = abs(pageHeight - self.pageHeight) > 0.5 || abs(stripHeight - self.stripHeight) > 0.5
        let rowsChanged = rowCount != self.rowCount
        self.rowCount = rowCount
        if geometryChanged {
            self.pageHeight = pageHeight
            self.stripHeight = stripHeight
            if baselineY != nil { log("geometry changed - baseline reset") }
            baselineY = nil
        }
        if geometryChanged || rowsChanged {
            log("config P=\(Self.f1(pageHeight)) H=\(Self.f1(stripHeight)) rows=\(rowCount) pageSeconds=\(StageStripTuning.pageSeconds)")
        }
    }

    /// `geometry rowH= P= H= stage= logo= synL= fits= posterH= font=`, logged when it changes.
    func logGeometry(_ geometry: StripGeometry) {
        guard Self.enabled else { return }
        let line = "geometry rowH=\(Self.f1(geometry.rowHeight)) P=\(Self.f1(geometry.pageHeight))"
            + " H=\(Self.f1(geometry.stripHeight)) stage=\(Self.f1(geometry.stageHeight))"
            + " logo=\(Int(geometry.logoSlot)) synL=\(geometry.synopsisLines) fits=\(geometry.fits ? 1 : 0)"
            + " posterH=\(Self.f1(geometry.layoutPosterHeight)) font=\(Theme.Font.family.rawValue)"
        guard line != lastGeometryLine else { return }
        lastGeometryLine = line
        log(line)
    }

    // MARK: Marker + display link

    func attach(_ view: StageStripMarkerView) {
        guard Self.enabled else { return }
        marker = view
        startObservers()
        lastY = nil
        stillFrames = 0
        activeSegment = nil
        restY = nil
        loggedReadFailure = false
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        log("marker attached")
    }

    func detach(_ view: StageStripMarkerView) {
        guard marker === view || marker == nil else { return }
        marker = nil
        displayLink?.invalidate()
        displayLink = nil
        closeWindow(reason: "detach")
        activeSegment = nil
        lastY = nil
        log("marker detached")
    }

    /// The marker's RENDERED y in window space: presentation layers' superlayer chain is the
    /// presentation tree, so this includes in-flight ancestor scroll/offset animations.
    private func markerY() -> CGFloat? {
        guard let marker, let markerWindow = marker.window,
              let presented = marker.layer.presentation() else {
            if !loggedReadFailure, marker != nil {
                loggedReadFailure = true
                log("marker read failed (no window or no presentation layer yet)")
            }
            return nil
        }
        let target: CALayer = markerWindow.layer.presentation() ?? markerWindow.layer
        return presented.convert(CGPoint.zero, to: target).y
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard let y = markerY() else { return }
        let prevY = lastY
        let prevTime = lastTime
        lastY = y
        lastTime = now
        guard let prevY else { return }

        if abs(y - prevY) >= Self.stillThreshold {
            stillFrames = 0
            if activeSegment == nil {
                beginSegment(start: prevTime, y0: prevY)
            }
            activeSegment?.lastMove = now
        } else {
            stillFrames += 1
            if stillFrames >= Self.restFrames {
                if activeSegment != nil { finishSegment(y1: y) }
                restY = y
                captureBaselineIfNeeded(y)
            }
        }

        if let win = window, activeSegment == nil, now - win.lastActivity > Self.idleClose {
            closeWindow(reason: "idle")
        }
    }

    private func beginSegment(start: CFTimeInterval, y0: CGFloat) {
        var owner = 0
        var k = 1
        var pressT0: CFTimeInterval?
        var afterRest = false
        if var win = window {
            owner = win.n
            win.segCount += 1
            k = win.segCount
            pressT0 = win.t0
            if let lastEnd = win.done.map(\.end).max(), start - lastEnd > Self.afterRestGap {
                afterRest = true
            }
            win.lastActivity = max(win.lastActivity, start)
            window = win
        }
        activeSegment = Segment(owner: owner, k: k, pressT0: pressT0, start: start, y0: y0,
                                lastMove: start, afterRest: afterRest)
    }

    private func finishSegment(y1: CGFloat) {
        guard let segment = activeSegment else { return }
        activeSegment = nil
        let startOffset = segment.pressT0.map { Self.signedMs(segment.start - $0) } ?? "n/a"
        let durationMs = Self.ms(segment.lastMove - segment.start)
        let travel = y1 - segment.y0
        log("seg p=\(segment.owner) k=\(segment.k) start=\(startOffset) dur=\(durationMs) from=\(Self.f1(segment.y0)) to=\(Self.f1(y1)) travel=\(Self.f1(travel))")
        segmentCount += 1
        lastSegment = "\(Self.f1(travel))/\(durationMs)"
        if var win = window, win.n == segment.owner {
            win.done.append(DoneSegment(start: segment.start, end: segment.lastMove,
                                        y0: segment.y0, y1: y1, afterRest: segment.afterRest))
            win.lastActivity = max(win.lastActivity, segment.lastMove)
            window = win
        }
    }

    private func captureBaselineIfNeeded(_ y: CGFloat) {
        guard baselineY == nil, currentRow == 0, rowCount > 0, activeSegment == nil else { return }
        baselineY = y
        log("baseline y=\(Self.f1(y)) P=\(Self.f1(pageHeight)) H=\(Self.f1(stripHeight)) rows=\(rowCount)")
    }

    // MARK: Press windows

    /// Menu (and any other app-handled press).
    func notePress(_ label: String) {
        guard Self.enabled else { return }
        openWindow(label: label, from: currentRow, to: currentRow, key: "-", byPress: true)
    }

    /// Every strip row-index change. Merged into the press window a `notePress` opened just before,
    /// otherwise opens its own window.
    func noteRowChange(from: Int, to: Int, key: String) {
        guard Self.enabled else { return }
        currentRow = to
        let now = CACurrentMediaTime()
        if var win = window, win.byPress, !win.rowMerged, now - win.t0 < Self.mergeWindow {
            win.from = from
            win.to = to
            win.key = key
            win.rowMerged = true
            window = win
            return
        }
        openWindow(label: "row", from: from, to: to, key: key, byPress: false)
    }

    private func openWindow(label: String, from: Int, to: Int, key: String, byPress: Bool) {
        let now = CACurrentMediaTime()
        var carry = false
        if let segment = activeSegment, now - segment.start < Self.carryWindow {
            carry = true
            activeSegment?.owner = -1   // excluded from the closing window's summary
        }
        closeWindow(reason: byPress ? "press" : "row")
        pressCounter += 1
        var win = PressWindow(n: pressCounter, label: label, from: from, to: to, key: key, t0: now,
                              byPress: byPress, rowMerged: !byPress, lastActivity: now)
        if carry {
            win.segCount = 1
            activeSegment?.owner = win.n
            activeSegment?.k = 1
            activeSegment?.pressT0 = now
            activeSegment?.afterRest = false
        }
        window = win
    }

    private func closeWindow(reason: String) {
        guard let win = window else { return }
        window = nil
        let inFlight: Segment? = (activeSegment?.owner == win.n) ? activeSegment : nil
        let moves = win.done.count + (inFlight == nil ? 0 : 1)
        let settle: String
        if inFlight != nil {
            settle = "moving"
        } else if let end = win.done.map(\.end).max() {
            settle = "\(Self.ms(end - win.t0))"
        } else {
            settle = "0"
        }
        var travel = win.done.reduce(CGFloat(0)) { $0 + ($1.y1 - $1.y0) }
        if let segment = inFlight, let y = lastY { travel += y - segment.y0 }
        let afterRest = win.done.filter(\.afterRest).count + ((inFlight?.afterRest ?? false) ? 1 : 0)
        let residual: String
        if let baseline = baselineY {
            if activeSegment != nil || restY == nil {
                residual = "moving"
            } else if let rest = restY {
                residual = Self.f1(rest - (baseline - CGFloat(win.to) * pageHeight))
            } else {
                residual = "moving"
            }
        } else {
            residual = "n/a"
        }
        let fromTo = "\(win.from)\u{2192}\(win.to)"
        log("PRESS #\(win.n) \(fromTo) moves=\(moves) settle=\(settle) travel=\(Self.f1(travel)) afterRest=\(afterRest) residual=\(residual) src=\(win.label) key=\(win.key) close=\(reason)")
        lastSummary = "#\(win.n) \(fromTo) \(win.label) moves=\(moves) settle=\(settle) trav=\(Self.f1(travel)) aftRest=\(afterRest) res=\(residual)"
    }

    // MARK: Focus + movement-failure logging

    /// Idempotent; called on marker attach.
    func startObservers() {
        guard !observersStarted else { return }
        observersStarted = true
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: UIFocusSystem.didUpdateNotification,
                                                 object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                StageStripProbe.shared.logFocus(note)
            }
        })
        observerTokens.append(center.addObserver(forName: UIFocusSystem.movementDidFailNotification,
                                                 object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                StageStripProbe.shared.log("moveFail heading=\(StageStripProbe.headingName(StageStripProbe.focusHeading(of: note)))")
            }
        })
        log("observers started")
    }

    private func logFocus(_ note: Notification) {
        let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
        guard let item = context?.nextFocusedItem else {
            log("focus \u{2192} nil")
            return
        }
        let typeName = String(describing: type(of: item))
        let frame = Self.screenFrame(of: item).map {
            "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())),\(Int($0.width.rounded())),\(Int($0.height.rounded()))"
        } ?? "?"
        let label = Self.clean((item as? NSObject)?.accessibilityLabel)
        let ident = Self.clean((item as? UIAccessibilityIdentification)?.accessibilityIdentifier)
        log("focus \u{2192} \(typeName) frame=\(frame) label=\(label) id=\(ident)")
        // Device-grade press marker: a vertical focus move between card-sized items opens the press
        // window at the moment the engine moves focus (the row's ownership report can lag the
        // scroll). Section filler items (very wide) are ignored; a fresh press window wins.
        if let rect = Self.screenFrame(of: item), rect.width < 600 {
            let mid = rect.midY
            if let prev = lastCardMidY, abs(mid - prev) > 150 {
                let now = CACurrentMediaTime()
                if let win = window, win.byPress, now - win.t0 < 0.3 {
                    // A press window opened this press already.
                } else {
                    notePress(mid > prev ? "vfocus-down" : "vfocus-up")
                }
            }
            lastCardMidY = mid
        }
    }

    private static func clean(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "-" }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "\u{2026}" : flat
    }

    /// `UIFocusItem.frame` is in the coordinate space of the container the item sits in, i.e. the
    /// PARENT environment's `focusItemContainer` (an item's own `focusItemContainer` holds its
    /// children). UIView items convert directly.
    static func screenFrame(of item: UIFocusItem) -> CGRect? {
        if let view = item as? UIView {
            guard view.window != nil else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        guard let target = keyWindow(),
              let space = item.parentFocusEnvironment?.focusItemContainer?.coordinateSpace else { return nil }
        return space.convert(item.frame, to: target)
    }

    static func focusHeading(of note: Notification) -> UIFocusHeading? {
        (note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext)?.focusHeading
    }

    static func headingName(_ heading: UIFocusHeading?) -> String {
        guard let heading else { return "other" }
        if heading.contains(.left) { return "left" }
        if heading.contains(.right) { return "right" }
        if heading.contains(.up) { return "up" }
        if heading.contains(.down) { return "down" }
        return "other"
    }

    static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }
}

// MARK: - Marker

/// A 1×1 clear UIView in a background that MOVES with the strip's content (its page stack's). Its
/// rendered y is what the probe samples every frame. Mounted only while the probe is armed.
struct StageStripMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> StageStripMarkerView {
        let view = StageStripMarkerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: StageStripMarkerView, context: Context) {}
}

final class StageStripMarkerView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            StageStripProbe.shared.attach(self)
        } else {
            StageStripProbe.shared.detach(self)
        }
    }
}
