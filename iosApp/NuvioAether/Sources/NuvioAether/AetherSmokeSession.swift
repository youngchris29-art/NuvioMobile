import SwiftUI
import Combine
internal import AetherEngine

/// Spike façade: one engine, one surface, the published facts as strings, every engine log line
/// mirrored to a host callback. Nothing from AetherEngine leaks through this interface.
@MainActor
public final class AetherSmokeSession: ObservableObject {
    public struct Options: Sendable {
        /// nil | "render" | "lpcm" | "apac"
        public var objectAudio: String?
        /// "5.1.2" | "5.1.4" | "7.1.2" | "7.1.4" | "9.1.6"
        public var layout: String = "7.1.4"
        public var losslessBridge = false
        public var dualLayerDolbyVision = false
        public var forceSoftware = false
        public var confirmAtmos = false
        public init() {}
    }

    @Published public private(set) var facts: [String] = []
    public var onEvent: ((String) -> Void)?

    private let engine: AetherEngine
    private var bag = Set<AnyCancellable>()
    private var ticker: AnyCancellable?

    public init() throws {
        engine = try AetherEngine()
    }

    public static var version: String { AetherEngine.version }
    public static var displayCapabilities: String { "\(AetherEngine.displayCapabilities)" }
    public static var optionalComponents: [(name: String, builtIn: Bool)] {
        AetherEngine.OptionalComponent.allCases.map { ($0.rawValue, $0.isBuiltIn) }
    }
    public static func installLog(_ handler: @escaping @Sendable (String) -> Void) {
        EngineLog.handler = handler
    }

    public var surface: AnyView { AnyView(AetherPlayerSurface(engine: engine)) }

    public func load(url: URL, options o: Options) async throws -> String {
        var options = LoadOptions()
        let layout = SpatialSpeakerLayout(rawValue: o.layout) ?? .l714
        switch o.objectAudio?.lowercased() {
        case "render": options.objectAudioRendering = .render(layout)
        case "lpcm": options.objectAudioRendering = .lpcm(layout)
        case "apac": options.objectAudioRendering = .apac(layout)
        default: break
        }
        if o.losslessBridge { options.audioBridgeMode = .lossless }
        if o.dualLayerDolbyVision { options.preferDualLayerDolbyVision = true }
        if o.forceSoftware { options.preferredDecodePath = .software }
        if o.confirmAtmos { options.confirmAtmos = true }
        emit("options objectAudio=\(options.objectAudioRendering) bridge=\(options.audioBridgeMode) fel=\(options.preferDualLayerDolbyVision) software=\(o.forceSoftware)")

        observe()
        let probe = try await engine.load(url: url, options: options)
        return String(describing: probe)
    }

    public func stop() {
        ticker?.cancel()
        bag.removeAll()
        engine.stop()
    }

    private func emit(_ s: String) { onEvent?(s) }

    private func observe() {
        bag.removeAll()
        engine.$state.removeDuplicates().sink { [weak self] in self?.emit("state \($0)") }.store(in: &bag)
        engine.$playbackPhase.removeDuplicates().sink { [weak self] in self?.emit("phase \($0)") }.store(in: &bag)
        engine.$videoRoute.removeDuplicates().sink { [weak self] in self?.emit("route \($0)") }.store(in: &bag)
        engine.$audioDelivery.removeDuplicates().sink { [weak self] in self?.emit("audioDelivery \($0)") }.store(in: &bag)
        engine.$videoFormat.removeDuplicates().sink { [weak self] in self?.emit("videoFormat \($0)") }.store(in: &bag)
        engine.$errorInfo.compactMap { $0 }.sink { [weak self] in self?.emit("errorInfo \($0)") }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().sink { [weak self] in self?.emit("firstFrame \($0)") }.store(in: &bag)
        engine.$audioTracks.sink { [weak self] tracks in
            for t in tracks { self?.emit("audioTrack \(t)") }
        }.store(in: &bag)
        engine.softwarePathEscalations.sink { [weak self] in self?.emit("softwareEscalation \($0)") }.store(in: &bag)

        ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            let e = self.engine
            self.facts = [
                "state \(e.state)  phase \(e.playbackPhase)",
                "route \(e.videoRoute)  audio \(e.audioDelivery)",
                "video \(e.sourceVideoFormat) -> \(e.videoFormat)  dv \(String(describing: e.sourceDVProfile)) \(String(describing: e.dolbyVisionConversion))",
                "decoders \(e.activeVideoDecoder ?? "-") / \(e.activeAudioDecoder ?? "-")",
                "t \(Int(e.currentTime))s / \(Int(e.duration))s  buffered \(Int(e.bufferedPosition))s",
            ]
            self.emit("tick " + self.facts.joined(separator: " | "))
        }
    }
}
