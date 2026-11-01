import SwiftUI
import Combine
import NuvioAether

#if DEBUG
/// Aether feasibility spike (2026-11-01): when `debug.aetherSmokeURL` holds a source URL, the root
/// view presents a bare Aether surface over the app a few seconds after launch, with a HUD that
/// reads the engine's published facts and mirrors every engine log line to stdout as `[Aether] …`,
/// so the device rig's console capture sees the FFmpeg ownership line and the route.
///
///   defaults write com.youngchris29.NuvioTV debug.aetherSmokeURL -string '<url>'
///   debug.aetherSmokeObjectAudio  -string render|lpcm|apac   (TrueHD / DTS:X heights)
///   debug.aetherSmokeLayout       -string 5.1.2|5.1.4|7.1.2|7.1.4|9.1.6   (default 7.1.4)
///   debug.aetherSmokeLossless     -bool YES   (FLAC bridge instead of E-AC-3 5.1)
///   debug.aetherSmokeFEL          -bool YES   (compose DV Profile 7 FEL on the GPU)
///   debug.aetherSmokeSoftware     -bool YES   (force the software decode path)
///   debug.aetherSmokeConfirmAtmos -bool YES   (background JOC confirmation of the audio tracks)
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
                    print("[AetherSmoke] presenting Aether surface for \(u.host ?? "?")\(u.path)")
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
    let session: AetherSmokeSession?
    let initError: String?
    @Published var hud: [String] = []

    init() {
        AetherSmokeSession.installLog { line in print("[Aether] \(line)") }
        do {
            session = try AetherSmokeSession()
            initError = nil
        } catch {
            session = nil
            initError = "\(error)"
        }
    }

    func start(url: URL) {
        guard let session else {
            hud = ["AetherEngine() threw: \(initError ?? "?")"]
            print("[AetherSmoke] \(hud[0])")
            return
        }
        let d = UserDefaults.standard
        var o = AetherSmokeSession.Options()
        o.objectAudio = d.string(forKey: "debug.aetherSmokeObjectAudio")
        o.layout = d.string(forKey: "debug.aetherSmokeLayout") ?? "7.1.4"
        o.losslessBridge = d.bool(forKey: "debug.aetherSmokeLossless")
        o.dualLayerDolbyVision = d.bool(forKey: "debug.aetherSmokeFEL")
        o.forceSoftware = d.bool(forKey: "debug.aetherSmokeSoftware")
        o.confirmAtmos = d.bool(forKey: "debug.aetherSmokeConfirmAtmos")
        print("[AetherSmoke] version \(AetherSmokeSession.version) display=\(AetherSmokeSession.displayCapabilities)")
        for c in AetherSmokeSession.optionalComponents { print("[AetherSmoke] component \(c.name) builtIn=\(c.builtIn)") }
        session.onEvent = { print("[AetherSmoke] \($0)") }
        session.$facts.receive(on: DispatchQueue.main).assign(to: &$hud)
        Task {
            do {
                let probe = try await session.load(url: url, options: o)
                print("[AetherSmoke] load returned probe=\(probe)")
            } catch {
                print("[AetherSmoke] load threw \(error)")
                hud = ["load threw \(error)"]
            }
        }
    }

    func stop() { session?.stop() }
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
