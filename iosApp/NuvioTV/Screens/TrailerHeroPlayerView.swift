import SwiftUI
import UIKit
import Libmpv

/// A minimal, muted, looping libmpv surface for playing a resolved trailer video behind the hero.
///
/// Deliberately stripped down versus `MPVTVPlayerViewController`: no controls, no focus, no remote
/// handling, no audio, no watch-progress. It is purely decorative — a moving backdrop that the
/// Detail screen crossfades in once a trailer URL resolves, and tears down when the screen goes away.
/// Reuses the proven GPU option set (and the shared `TVMetalLayer`) from the main player.
final class TrailerHeroPlayerController: UIViewController {

    private var metalLayer = TVMetalLayer()
    private var mpv: OpaquePointer?
    private var lastDrawableSize: CGSize = .zero
    private let eventQueue = DispatchQueue(label: "mpv-trailer-events", qos: .userInitiated)
    private let videoURL: String
    private var didLoad = false

    // Watchdog: a trailer that never starts (undecodable codec like AV1 on the simulator, a stalled
    // or dead CDN URL, etc.) must never wedge the app — if no frames arrive in time, we give up and
    // let the Detail screen fall back to the static backdrop.
    private var watchdog: Timer?
    private var started = false
    private var loadStartUptime: TimeInterval = 0
    /// Called (once, on the main thread) if the trailer fails or times out.
    var onFailure: (() -> Void)?

    init(videoURL: String) {
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resizeAspectFill
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

        setupMpv()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didLoad else { return }
        didLoad = true
        command("loadfile", args: [videoURL, "replace"])
        loadStartUptime = ProcessInfo.processInfo.systemUptime
        startWatchdog()
    }

    // A decorative surface never takes focus — the Detail screen's buttons own it.
    override var canBecomeFirstResponder: Bool { false }

    private func layoutMetalLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = UIScreen.main.nativeScale
        let drawable = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.contentsScale = scale
        if drawable != lastDrawableSize {
            metalLayer.drawableSize = drawable
            lastDrawableSize = drawable
        }
        CATransaction.commit()
    }

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else { print("[Trailer] Failed to create mpv"); return }

        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))

        let options: [(String, String)] = [
            // Use the classic `gpu` output (not `gpu-next`/libplacebo) for this decorative surface —
            // libplacebo's vo path asserts on the tvOS simulator when running alongside SwiftUI's
            // own Metal compositor. If this still crashes, the surface moves to AVPlayer.
            ("vo", "gpu"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("vulkan-swap-mode", "fifo"),
            ("vulkan-queue-count", "1"),
            ("vulkan-async-compute", "no"),
            ("vulkan-async-transfer", "no"),
            ("vulkan-disable-interop", "yes"),
            ("video-rotate", "no"),
            // Give up on a stalled CDN instead of blocking forever.
            ("network-timeout", "8"),
            // Decorative hero: silent + endless loop.
            ("ao", "null"),
            ("mute", "yes"),
            ("loop-file", "inf"),
            ("keep-open", "yes"),
        ]
        for (key, value) in options {
            checkError(mpv_set_option_string(mpv, key, value))
        }

        checkError(mpv_initialize(mpv))

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: TrailerHeroPlayerController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                guard let ev = mpv_wait_event(mpv, 0) else { break }
                let id = ev.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                if id == MPV_EVENT_SHUTDOWN { return }
                if id == MPV_EVENT_END_FILE, let data = ev.pointee.data {
                    let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                    if endFile.reason == MPV_END_FILE_REASON_ERROR {
                        DispatchQueue.main.async { [weak self] in self?.fail() }
                    }
                }
            }
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkProgress() {
        guard mpv != nil, !started else { watchdog?.invalidate(); watchdog = nil; return }
        // Playback actually started — we're good, stop watching.
        if getDouble("time-pos") > 0.05 {
            started = true
            watchdog?.invalidate(); watchdog = nil
            return
        }
        // No frames within the grace window → treat as failed and let Detail fall back.
        if ProcessInfo.processInfo.systemUptime - loadStartUptime > 8 {
            watchdog?.invalidate(); watchdog = nil
            fail()
        }
    }

    private func fail() {
        guard let callback = onFailure else { return }
        onFailure = nil
        callback()
    }

    deinit {
        watchdog?.invalidate()
        destroyPlayer()
    }

    private func destroyPlayer() {
        guard let ctx = mpv else { return }
        mpv = nil
        mpv_terminate_destroy(ctx)
    }

    // MARK: - libmpv C-interop helpers (minimal subset)

    private func command(_ command: String, args: [String?] = []) {
        guard mpv != nil else { return }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        checkError(mpv_command(mpv, &cargs))
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            print("[Trailer] mpv error: \(String(cString: mpv_error_string(status)))")
        }
    }
}

/// SwiftUI wrapper for the decorative trailer surface. `onFailure` fires if the trailer never starts
/// (undecodable/stalled), so the host can remove it and keep the static backdrop.
struct TrailerHeroPlayer: UIViewControllerRepresentable {
    let videoURL: String
    var onFailure: () -> Void = {}

    func makeUIViewController(context: Context) -> TrailerHeroPlayerController {
        let controller = TrailerHeroPlayerController(videoURL: videoURL)
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: TrailerHeroPlayerController, context: Context) {}
}
