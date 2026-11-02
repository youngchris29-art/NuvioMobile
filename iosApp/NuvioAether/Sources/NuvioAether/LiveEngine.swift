import AVFoundation
import Combine
import Foundation
import SwiftUI
internal import AetherEngine

/// The only file that names AetherEngine types (`grep -rn "AetherEngine\." Sources` stays here). Owns one
/// engine and its surface, turns every published value into an `EngineEvent` in fork types, and builds
/// `LoadOptions` in one place.
@MainActor
final class LiveEngine: EngineDriving {
    private let engine: AetherEngine
    private let subject = PassthroughSubject<EngineEvent, Never>()
    private let diagnosticsSubject = CurrentValueSubject<AetherDiagnostics, Never>(AetherDiagnostics())
    private var bag = Set<AnyCancellable>()

    // `@Published` sinks run in willSet, so reading the engine property inside a sink returns the OLD
    // value. Every composite event is built from these caches, which each sink updates with the value it
    // was handed.
    private var clock = AetherClockSample()
    private var diag = AetherDiagnostics()
    private var softwareDisplaySize: CGSize?
    private var codedWidth: Int32 = 0
    private var codedHeight: Int32 = 0
    private var audioTracks: [AetherTrack] = []
    private var subtitleTracks: [AetherTrack] = []
    private var activeAudio: Int?
    private var activeSubtitle: Int?
    private var firstFrame = false

    init() throws {
        engine = try AetherEngine()
        // Contract 6: an Aether to mpv fallback leaves the audio session to mpv's own setup.
        engine.deactivatesAudioSessionOnStop = false
        assert(AetherTrack.externalTrackIDBase == AetherEngine.externalSubtitleTrackIDBase,
               "fork external track base drifted from the engine's")
        subscribe()
    }

    // MARK: Statics

    static var version: String { AetherEngine.version }

    static var builtInComponents: [String] {
        AetherEngine.OptionalComponent.allCases.filter(\.isBuiltIn).map(\.rawValue)
    }

    // MARK: EngineDriving

    var events: AnyPublisher<EngineEvent, Never> { subject.eraseToAnyPublisher() }

    var surface: AnyView { AnyView(AetherPlayerSurface(engine: engine)) }

    var aspect: AetherAspect {
        get {
            switch engine.videoGravity {
            case .resizeAspectFill: return .fill
            case .resize: return .stretch
            default: return .fit
            }
        }
        set {
            switch newValue {
            case .fit: engine.videoGravity = .resizeAspect
            case .fill: engine.videoGravity = .resizeAspectFill
            case .stretch: engine.videoGravity = .resize
            }
        }
    }

    var canSeek: Bool { engine.canSeek }
    var maxRate: Float { engine.maxSupportedRate }
    var supportsScrubStills: Bool { engine.supportsCacheBackedStills }
    var scrubStillsSourceGeneration: UUID { engine.scrubPreviewSourceGeneration }
    var audioDelaySec: Double { engine.audioDelaySeconds }
    var audioShaping: AetherAudioShaping { Self.forkShaping(engine.audioShaping) }
    var clockSample: AetherClockSample { clock }

    func load(_ r: AetherLoadRequest) async throws -> AetherProbeSummary? {
        engine.logTag = r.logTag
        do {
            let probe = try await engine.load(url: r.url, startPosition: r.startSec, options: Self.options(for: r),
                                              audioSourceStreamIndex: r.audioStreamIndex.map { Int32($0) })
            return probe.map(Self.summary)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(forThrown: error)
        }
    }

    func stop(resetDisplayCriteria: Bool, finalTeardown: Bool) {
        engine.stop(resetDisplayCriteria: resetDisplayCriteria, finalTeardown: finalTeardown)
    }

    func reloadAtCurrentPosition() async throws {
        do {
            try await engine.reloadAtCurrentPosition()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(forThrown: error)
        }
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func togglePause() { engine.togglePlayPause() }
    func setRate(_ rate: Float) { engine.setRate(rate) }
    func seek(toSec: Double, exact: Bool) async { await engine.seek(to: toSec, exact: exact) }

    func selectAudio(id: Int) { engine.selectAudioTrack(index: id) }
    func selectSubtitle(id: Int) { engine.selectSubtitleTrack(index: id) }
    func clearSubtitle() { engine.clearSubtitle() }

    func addExternalSubtitle(_ s: AetherExternalSubtitle) -> AetherTrack {
        Self.track(engine.addExternalSubtitleTrack(Self.external(s)))
    }

    func setAudioDelay(_ sec: Double) { engine.setAudioDelay(sec) }
    func setAudioShaping(_ s: AetherAudioShaping) { engine.setAudioShaping(Self.engineShaping(s)) }

    func updateRequestHeaders(_ headers: [String: String]) -> Bool {
        engine.updateRequestHeaders(headers) == .appliedToLiveRequests
    }

    func scrubFrame(atSec: Double, refined: Bool, maxWidth: Int,
                    isCancelled: @escaping @Sendable () -> Bool) async -> AetherScrubFrame? {
        guard let f = await engine.scrubPreviewFrame(atSeconds: atSec, refined: refined, maxWidth: maxWidth,
                                                     isCancelled: isCancelled) else { return nil }
        return AetherScrubFrame(image: f.image, actualSec: f.actualSeconds, refined: f.refined, validRange: f.validRange)
    }

    // MARK: Failures

    private func failure(forThrown error: Error) -> AetherFailure {
        // `errorInfo` is assigned before `state` turns `.error` and is cleared by any other state, so a
        // non-nil value under `.error` belongs to this throw.
        if case .error = engine.state, let info = engine.errorInfo {
            return failure(from: info)
        }
        return AetherFailure.thrown(error, atSec: clock.currentSec, beforeFirstFrame: !firstFrame)
    }

    private func failure(from info: PlaybackErrorInfo) -> AetherFailure {
        AetherFailure.fromEngine(token: info.kind.rawValue, domain: info.underlyingDomain, code: info.underlyingCode,
                                 ffmpegCode: info.ffmpegErrorCode, message: info.message,
                                 atSec: clock.currentSec, beforeFirstFrame: !firstFrame)
    }

    // MARK: Subscriptions

    private func send(_ e: EngineEvent) { subject.send(e) }

    /// Engine publishers fire on the main actor (the engine and its clock are `@MainActor`); a subject the
    /// engine feeds from another thread is hopped, never run off-main.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    private func sink<P: Publisher>(_ p: P, _ body: @escaping @MainActor (LiveEngine, P.Output) -> Void)
    where P.Failure == Never, P.Output: Sendable {
        p.sink { [weak self] value in
            Self.onMain { [weak self] in
                guard let self else { return }
                body(self, value)
            }
        }
        .store(in: &bag)
    }

    private func subscribe() {
        // Transport and phase.
        sink(engine.$state.removeDuplicates()) { me, s in
            me.send(.state(isPaused: s == .paused))
        }
        sink(engine.$playbackPhase.removeDuplicates()) { me, p in
            me.send(.phase(Self.phase(p)))
        }
        sink(engine.$errorInfo.compactMap { $0 }) { me, info in
            me.send(.failure(me.failure(from: info)))
        }
        sink(engine.$hasFirstFrameReadyForDisplay.removeDuplicates()) { me, v in
            me.firstFrame = v
            me.send(.firstFrame(v))
        }

        // Clock.
        sink(engine.clock.$currentTime.removeDuplicates()) { me, v in me.clock.currentSec = v; me.send(.clock(me.clock)) }
        sink(engine.clock.$sourceTime.removeDuplicates()) { me, v in me.clock.sourceSec = v; me.send(.clock(me.clock)) }
        sink(engine.clock.$sourceTimeFollowsPicture.removeDuplicates()) { me, v in
            me.clock.sourceFollowsPicture = v; me.send(.clock(me.clock))
        }
        sink(engine.clock.$bufferedPosition.removeDuplicates()) { me, v in me.clock.bufferedSec = v; me.send(.clock(me.clock)) }
        sink(engine.$duration.removeDuplicates()) { me, v in me.clock.durationSec = v; me.send(.clock(me.clock)) }
        sink(engine.$residentRanges.removeDuplicates()) { me, v in me.clock.residentRanges = v; me.send(.clock(me.clock)) }
        sink(engine.$isClockHeld.removeDuplicates()) { me, v in me.clock.isClockHeld = v; me.send(.clock(me.clock)) }

        // Tracks, cues, chapters.
        sink(engine.$audioTracks.removeDuplicates()) { me, v in me.audioTracks = v.map(Self.track); me.sendTracks() }
        sink(engine.$subtitleTracks.removeDuplicates()) { me, v in me.subtitleTracks = v.map(Self.track); me.sendTracks() }
        sink(engine.$activeAudioTrackIndex.removeDuplicates()) { me, v in me.activeAudio = v; me.sendTracks() }
        sink(engine.$activeSubtitleTrackIndex.removeDuplicates()) { me, v in me.activeSubtitle = v; me.sendTracks() }
        sink(engine.$subtitleCues.removeDuplicates()) { me, v in me.send(.cues(v.map(Self.cue))) }
        sink(engine.$mediaChapters.removeDuplicates()) { me, v in
            me.send(.chapters(v.map { AetherChapter(id: $0.id, title: $0.name, startSec: $0.startSeconds,
                                                     durationSec: $0.durationSeconds) }))
        }

        // Diagnostics: cached field by field, published coalesced at 2 Hz.
        sink(engine.$videoRoute.removeDuplicates()) { me, v in me.updateDiag { $0.route = Self.route(v) } }
        sink(engine.$sourceVideoFormat.removeDuplicates()) { me, v in me.updateDiag { $0.sourceFormat = Self.format(v) } }
        sink(engine.$videoFormat.removeDuplicates()) { me, v in me.updateDiag { $0.outputFormat = Self.format(v) } }
        sink(engine.$sourceDVProfile.removeDuplicates()) { me, v in me.updateDiag { $0.sourceDVProfile = v } }
        sink(engine.$dolbyVisionConversion.removeDuplicates()) { me, v in
            me.updateDiag { $0.dvConvertedP7ToP81 = (v == .profile7ToProfile81) }
        }
        sink(engine.$sourceVideoCodecName.removeDuplicates()) { me, v in me.updateDiag { $0.videoCodec = v } }
        sink(engine.$sourceContainerFormat.removeDuplicates()) { me, v in me.updateDiag { $0.container = v } }
        sink(engine.$sourceVideoFrameRate.removeDuplicates()) { me, v in me.updateDiag { $0.frameRate = v } }
        sink(engine.$sourceVideoBitrate.removeDuplicates()) { me, v in me.updateDiag { $0.videoBitrate = v } }
        sink(engine.$activeVideoDecoder.removeDuplicates()) { me, v in me.updateDiag { $0.videoDecoder = v } }
        sink(engine.$activeAudioDecoder.removeDuplicates()) { me, v in me.updateDiag { $0.audioDecoder = v } }
        sink(engine.$audioShapingState.removeDuplicates()) { me, v in me.updateDiag { $0.audioShaping = Self.shapingState(v) } }
        sink(engine.$audioDelivery.removeDuplicates()) { me, v in
            let d = Self.delivery(v)
            me.updateDiag { $0.audioDelivery = d }
            me.send(.audioDelivery(d))
        }
        sink(engine.$softwareDisplaySize.removeDuplicates()) { me, v in me.softwareDisplaySize = v; me.updatePresentationSize() }
        // The pixel aspect ratio is not published and is assigned after the coded size: recompute one turn
        // later, when it is in place.
        sink(engine.$sourceVideoWidth.removeDuplicates()) { me, v in
            me.codedWidth = v
            DispatchQueue.main.async { [weak me] in me?.updatePresentationSize() }
        }
        sink(engine.$sourceVideoHeight.removeDuplicates()) { me, v in
            me.codedHeight = v
            DispatchQueue.main.async { [weak me] in me?.updatePresentationSize() }
        }
        diagnosticsSubject
            .removeDuplicates()
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] d in Self.onMain { [weak self] in self?.send(.diagnostics(d)) } }
            .store(in: &bag)

        // Events.
        sink(engine.seekEvents) { me, e in me.send(.seek(Self.seekSample(e))) }
        sink(engine.softwarePathEscalations) { me, e in
            me.send(.escalation(AetherEscalation(atSec: e.positionSeconds, duringStartup: e.duringStartup,
                                                 absorbed: AetherFailureKind(token: e.absorbedFailure.kind.rawValue))))
        }
        sink(engine.sourceAuthorizationRefused) { me, status in me.send(.authorizationRefused(status)) }
    }

    private func sendTracks() {
        send(.tracks(audio: audioTracks, subtitle: subtitleTracks, activeAudio: activeAudio, activeSubtitle: activeSubtitle))
    }

    private func updateDiag(_ change: (inout AetherDiagnostics) -> Void) {
        change(&diag)
        diagnosticsSubject.send(diag)
    }

    private func updatePresentationSize() {
        let size: CGSize?
        if let s = softwareDisplaySize {
            size = s
        } else if codedWidth > 0, codedHeight > 0 {
            size = CGSize(width: Double(codedWidth) * engine.sourceVideoPixelAspectRatio, height: Double(codedHeight))
        } else {
            size = nil
        }
        updateDiag { $0.presentationSize = size }
    }

    // MARK: Conversions (engine -> fork)

    private static func phase(_ p: PlaybackPhase) -> AetherEnginePhase {
        switch p {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .seeking
        case .rebuffering: return .rebuffering
        case .stalled(let reconnecting): return .stalled(reconnecting: reconnecting)
        case .ended: return .ended
        case .error(let message): return .error(message)
        }
    }

    private static func track(_ t: TrackInfo) -> AetherTrack {
        AetherTrack(id: t.id, name: t.name, codec: t.codec, language: t.language, channels: t.channels,
                    profile: t.profile, isDefault: t.isDefault, isForced: t.isForced,
                    isHearingImpaired: t.isHearingImpaired, isCommentary: t.isCommentary, isAtmos: t.isAtmos,
                    isDTSX: t.isDTSX, isExternal: t.isExternal, isNativelyRendered: t.isNativelyRenderedSubtitle)
    }

    private static func cue(_ c: SubtitleCue) -> AetherCue {
        let source: AetherCueSource
        switch c.body {
        case .text(let s): source = .text(s)
        case .richText(let runs): source = .runs(runs.map(\.text))
        case .image(let img):
            source = .image(img.cgImage, position: img.position, canvasSize: img.canvasSize, isForced: img.isForced)
        }
        return AetherCueFlattener.flatten(id: c.id, startSec: c.startTime, endSec: c.endTime, source: source,
                                          alignment: c.placement?.alignment, anchor: c.placement?.position)
    }

    private static func format(_ f: VideoFormat) -> AetherVideoFormat {
        switch f {
        case .sdr: return .sdr
        case .hdr10: return .hdr10
        case .hdr10Plus: return .hdr10Plus
        case .dolbyVision: return .dolbyVision
        case .hlg: return .hlg
        }
    }

    private static func route(_ r: VideoRoute) -> AetherVideoRoute {
        AetherVideoRoute(rawValue: r.rawValue) ?? .none
    }

    private static func delivery(_ d: AudioDelivery) -> AetherAudioDelivery {
        AetherAudioDelivery(rawValue: d.rawValue) ?? .none
    }

    private static func shapingState(_ s: AudioShapingState) -> AetherAudioShapingState {
        AetherAudioShapingState(rawValue: s.rawValue) ?? .off
    }

    private static func summary(_ p: SourceProbe) -> AetherProbeSummary {
        AetherProbeSummary(durationSec: p.durationSeconds, videoCodec: p.videoCodecName, width: Int(p.videoWidth),
                           height: Int(p.videoHeight), frameRate: p.videoFrameRate, isDolbyVision: p.isDolbyVision,
                           dvProfile: p.dvProfile, sourceFormat: format(p.videoFormat),
                           audioTracks: p.audioTracks.map(track), subtitleTracks: p.subtitleTracks.map(track))
    }

    private static func seekSample(_ e: SeekEvent) -> AetherSeekEventSample {
        let origin: AetherSeekEventSample.Origin
        switch e.origin {
        case .programmatic: origin = .programmatic
        case .nativeScrub: origin = .nativeScrub
        case .deferred: origin = .deferred
        }
        let outcome: AetherSeekEventSample.Outcome
        switch e.outcome {
        case .began: outcome = .began
        case .landed(let rendered): outcome = .landed(renderedSec: rendered)
        case .stalled: outcome = .stalled
        case .superseded: outcome = .superseded
        case .rejected(let r):
            switch r {
            case .noActiveSession: outcome = .rejected(.noActiveSession)
            case .liveWithoutDVR: outcome = .rejected(.liveWithoutDVR)
            case .sourceNotSeekable: outcome = .rejected(.sourceNotSeekable)
            }
        }
        return AetherSeekEventSample(id: e.id, origin: origin, target: e.target, outcome: outcome)
    }

    private static func forkShaping(_ s: AudioShaping) -> AetherAudioShaping {
        AetherAudioShaping(dialogueLiftDB: s.dialogueGainDB, boostDB: s.compressor?.makeupGainDB ?? 0)
    }

    // MARK: Conversions (fork -> engine)

    /// Boost is a pure makeup gain (threshold 0 dBFS, ratio 1:1), so nothing is compressed and the
    /// engine's -1 dBFS limiter catches the overs. 0 dB Boost means no compressor at all.
    private static func engineShaping(_ s: AetherAudioShaping) -> AudioShaping {
        let c = s.clamped
        let compressor = c.boostDB > 0
            ? AudioShaping.Compressor(thresholdDB: 0, ratio: 1, makeupGainDB: c.boostDB)
            : nil
        return AudioShaping(dialogueGainDB: c.dialogueLiftDB, compressor: compressor)
    }

    private static func external(_ s: AetherExternalSubtitle) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: s.url, name: s.name, language: s.language, isForced: s.isForced,
                              isHearingImpaired: s.isHearingImpaired, isDefault: s.isDefault,
                              httpHeaders: s.httpHeaders, formatHint: s.formatHint)
    }

    private static func layout(_ l: AetherSpeakerLayout) -> SpatialSpeakerLayout {
        SpatialSpeakerLayout(rawValue: l.rawValue) ?? .l714
    }

    /// Every option the engine reads before `load()`, set in one place.
    static func options(for r: AetherLoadRequest) -> LoadOptions {
        var o = LoadOptions()
        o.httpHeaders = r.headers
        o.preferredAudioLanguages = r.preferredAudioLanguages
        switch r.initialSubtitle {
        case .off: break
        case .track(let id): o.initialSubtitleTrackID = id
        case .preferLanguages(let langs): o.preferredSubtitleLanguages = langs
        }
        o.externalSubtitles = r.externalSubtitles.map(external)
        switch r.objectAudio {
        case .off: o.objectAudioRendering = .off
        case .render(let l): o.objectAudioRendering = .render(layout(l))
        }
        o.audioBridgeMode = r.audioBridge == .lossless ? .lossless : .surroundCompat
        o.preferDualLayerDolbyVision = r.dualLayerDV
        o.displayCriteriaOwner = r.displayCriteriaOwner == .engine ? .engine : .host
        o.matchContentEnabled = r.systemMatchingEnabled
        o.audioDelaySeconds = r.audioDelaySec
        o.audioShaping = engineShaping(r.audioShaping)
        if r.preferSoftwareDecode { o.preferredDecodePath = .software }
        // Contract 3: the engine's own software rung stays on; the session only reports it.
        o.escalatesToSoftwarePath = true
        return o
    }
}
