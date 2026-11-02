import SwiftUI
import Combine
import NuvioAether

#if DEBUG
/// Aether debug harness (Phase 1): when `debug.aetherSmokeURL` holds a source URL, the root view presents
/// a bare `AetherPlaybackSession` surface over the app a few seconds after launch, with a HUD over the
/// façade's published state, and mirrors every engine log line to stdout as `[Aether] …` so the device
/// rig's console capture sees the FFmpeg ownership line and the route. Façade events print as
/// `[AetherSmoke] …` (`state playing`, `firstFrame true`, `route loopback`, …).
///
///   defaults write com.youngchris29.NuvioTV debug.aetherSmokeURL -string '<url>'
///   debug.aetherSmokeObjectAudio  -string render   (TrueHD / DTS:X heights; anything else = off)
///   debug.aetherSmokeLayout       -string 5.1.2|5.1.4|7.1.2|7.1.4|9.1.6   (default 7.1.4)
///   debug.aetherSmokeBridge       -string lossless|surroundCompat   (default lossless)
///   debug.aetherSmokeFEL          -bool YES   (compose DV Profile 7 FEL on the GPU)
///   debug.aetherSmokeSoftware     -bool YES   (force the software decode path)
///   debug.aetherSmokeMatchContent -bool NO    (host owns display criteria; default engine)
///   debug.aetherSmokeBoostDB      -float 6    (Audio Boost, 0...24 dB makeup gain + limiter)
///   debug.aetherSmokeStartSec     -float 120
///   debug.aetherSmokeDelaySec     -float 2
struct AetherSmokeModifier: ViewModifier {
    @State private var url: URL?
    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !armed,
                      let raw = UserDefaults.standard.string(forKey: "debug.aetherSmokeURL"),
                      let u = URL(string: raw) else { return }
                armed = true
                let delay = max(UserDefaults.standard.double(forKey: "debug.aetherSmokeDelaySec"), 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("[AetherSmoke] presenting Aether surface for " + AetherLog.redacted("\(u.host ?? "?")\(u.path)"))
                    url = u
                }
            }
            .fullScreenCover(item: $url) { u in
                AetherSmokeView(url: u)
                    .ignoresSafeArea()
                    .background(Color.black)
            }
    }
}

@MainActor
final class AetherSmokeModel: ObservableObject {
    let session: AetherPlaybackSession?
    let initError: String?
    @Published var hud: [String] = []
    private var bag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?

    init() {
        AetherPlaybackSession.installLog { line in print("[Aether] \(line)") }
        do {
            session = try AetherPlaybackSession()
            initError = nil
        } catch {
            session = nil
            initError = "\(error)"
        }
    }

    static func request(for url: URL, window: UIWindow?) -> AetherLoadRequest {
        let d = UserDefaults.standard
        var r = AetherLoadRequest(url: url)
        if d.string(forKey: "debug.aetherSmokeObjectAudio")?.lowercased() == "render" {
            let layout = AetherSpeakerLayout(rawValue: d.string(forKey: "debug.aetherSmokeLayout") ?? "7.1.4") ?? .l714
            r.objectAudio = .render(layout)
        }
        r.audioBridge = AetherAudioBridge(rawValue: d.string(forKey: "debug.aetherSmokeBridge") ?? "lossless") ?? .lossless
        r.dualLayerDV = d.bool(forKey: "debug.aetherSmokeFEL")
        r.preferSoftwareDecode = d.bool(forKey: "debug.aetherSmokeSoftware")
        let matchContent = d.object(forKey: "debug.aetherSmokeMatchContent") as? Bool ?? true
        r.displayCriteriaOwner = .forMatchContent(matchContent)
        r.systemMatchingEnabled = AetherPlaybackSession.systemMatchingEnabled(in: window)
        r.audioShaping = AetherAudioShaping(boostDB: d.double(forKey: "debug.aetherSmokeBoostDB"))
        let start = d.double(forKey: "debug.aetherSmokeStartSec")
        r.startSec = start > 0 ? start : nil
        r.logTag = "smoke"
        return r
    }

    func start(url: URL) {
        guard let session else {
            hud = ["AetherPlaybackSession() threw: \(initError ?? "?")"]
            print("[AetherSmoke] \(hud[0])")
            return
        }
        print("[AetherSmoke] version \(AetherPlaybackSession.engineVersion)")
        print("[AetherSmoke] components \(AetherPlaybackSession.builtInComponents.joined(separator: ","))")
        observe(session)
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let request = Self.request(for: url, window: window)
        print("[AetherSmoke] request bridge=\(request.audioBridge.rawValue) objectAudio=\(request.objectAudio) "
              + "fel=\(request.dualLayerDV) software=\(request.preferSoftwareDecode) "
              + "owner=\(request.displayCriteriaOwner) systemMatching=\(request.systemMatchingEnabled) "
              + "boost=\(request.audioShaping.boostDB)")
        loadTask = Task {
            do {
                let probe = try await session.load(request)
                if let p = probe {
                    print("[AetherSmoke] load returned \(p.width)x\(p.height) \(p.videoCodec ?? "-") "
                          + "\(p.sourceFormat.rawValue) dv=\(p.dvProfile.map(String.init) ?? "-") "
                          + "duration=\(Int(p.durationSec))s audio=\(p.audioTracks.count) subs=\(p.subtitleTracks.count)")
                } else {
                    print("[AetherSmoke] load returned no probe")
                }
            } catch is CancellationError {
                print("[AetherSmoke] load cancelled")
            } catch let f as AetherFailure {
                print("[AetherSmoke] load threw \(f.kind.token) http=\(f.httpStatus.map(String.init) ?? "-") \(f.message)")
                hud = ["load threw \(f.kind.token)"]
            } catch {
                print("[AetherSmoke] load threw \(error)")
                hud = ["load threw \(error)"]
            }
        }
    }

    private func observe(_ s: AetherPlaybackSession) {
        s.onFailure = { f in print("[AetherSmoke] failure \(f.kind.token) beforeFirstFrame=\(f.beforeFirstFrame) at=\(f.atSec)") }
        s.onEnded = { print("[AetherSmoke] ended") }
        s.onEscalatedToSoftware = { e in
            print("[AetherSmoke] softwareEscalation at=\(e.atSec) startup=\(e.duringStartup) absorbed=\(e.absorbed.token)")
        }
        s.onAuthorizationRefused = { print("[AetherSmoke] authorizationRefused \($0)") }
        s.onAudioDropped = { print("[AetherSmoke] audioDropped") }
        s.$phase.removeDuplicates().sink { print("[AetherSmoke] state \($0.label)") }.store(in: &bag)
        s.$firstFrameShown.removeDuplicates().sink { print("[AetherSmoke] firstFrame \($0)") }.store(in: &bag)
        s.$diagnostics.map(\.route).removeDuplicates().sink { print("[AetherSmoke] route \($0.rawValue)") }.store(in: &bag)
        s.$diagnostics.map(\.audioDelivery).removeDuplicates()
            .sink { print("[AetherSmoke] audioDelivery \($0.rawValue)") }.store(in: &bag)
        s.$audioTracks.sink { tracks in
            for t in tracks {
                print("[AetherSmoke] audioTrack \(t.id) \(t.codec) ch=\(t.channels) lang=\(t.language ?? "-") "
                      + "atmos=\(t.isAtmos) dtsx=\(t.isDTSX) default=\(t.isDefault)")
            }
        }.store(in: &bag)

        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self, weak s] _ in
            guard let self, let s else { return }
            let d = s.diagnostics
            let c = s.clock
            self.hud = [
                "phase \(s.phase.label)  paused \(s.isPaused)  firstFrame \(s.firstFrameShown)",
                "route \(d.route.rawValue)  audio \(d.audioDelivery.rawValue)  shaping \(d.audioShaping.rawValue)",
                "video \(d.sourceFormat.rawValue) -> \(d.outputFormat.rawValue)  dv \(d.sourceDVProfile.map(String.init) ?? "-") p7to81 \(d.dvConvertedP7ToP81)",
                "decoders \(d.videoDecoder ?? "-") / \(d.audioDecoder ?? "-")  escalations \(d.softwareEscalations)",
                "t \(Int(c.currentSec))s / \(Int(c.durationSec))s  buffered \(Int(c.bufferedSec))s  cues \(s.cues.count)",
            ]
            print("[AetherSmoke] tick " + self.hud.joined(separator: " | "))
        }.store(in: &bag)
    }

    func stop() {
        loadTask?.cancel()
        bag.removeAll()
        session?.stop()
    }
}

struct AetherSmokeView: View {
    let url: URL
    @StateObject private var model = AetherSmokeModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let session = model.session { session.surface }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.hud, id: \.self) { Text($0) }
            }
            .font(.system(size: 22, design: .monospaced))
            .padding(16)
            .background(Color.black.opacity(0.55))
            .padding(40)
        }
        .onAppear { model.start(url: url) }
        .onDisappear { model.stop() }
    }
}
#endif
