import SwiftUI

#if DEBUG
/// UI-level player smoke: when `debug.mpvSmokeURL` holds a source URL, the root view presents the
/// real `PlayerScreen` (engine routing included) shortly after launch — with the native engine
/// toggle off this exercises the full libmpv path: event-driven property cache, track-list walks
/// on the event queue, progress saves, and the `[MPVStats]` first-90s diagnostics. With
/// `player.nativeDolbyVision -bool YES` compatible files land on the native AVPlayer screen instead
/// (handy for headed info-panel checks).
///
/// Sim workflow (mirrors `debug.remuxSmokeURL` — see RemuxSmokeTest.swift):
///   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.mpvSmokeURL -string '<url>'
///   xcrun simctl launch --console-pty <dev> com.nuvio.media.NuvioTV     # grep [MPVSmoke]/[MPVStats]
///   xcrun simctl spawn <dev> defaults delete com.nuvio.media.NuvioTV debug.mpvSmokeURL
///
/// `debug.mpvSmokeDelaySec` (default 2) holds presentation until app bootstrap settles.
struct MPVSmokeModifier: ViewModifier {
    @State private var context: PlaybackContext?
    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !armed,
                      let raw = UserDefaults.standard.string(forKey: "debug.mpvSmokeURL"),
                      let url = URL(string: raw) else { return }
                armed = true
                let delay = max(UserDefaults.standard.double(forKey: "debug.mpvSmokeDelaySec"), 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("[MPVSmoke] presenting PlayerScreen for \(url)")
                    let poster = UserDefaults.standard.string(forKey: "debug.mpvSmokePosterURL")
                    context = PlaybackContext(
                        url: url, title: "MPV Smoke", contentType: "movie",
                        parentMetaId: "smoke-mpv", videoId: "smoke-mpv",
                        season: nil, episode: nil, poster: poster, background: nil,
                        providerName: nil, providerAddonId: nil,
                        streamTitle: "Smoke.Release.2160p.WEB-DL", streamSubtitle: nil, externalSubtitles: [],
                        // Info-tab header content for headed sim checks (poster optional).
                        synopsis: "Headless smoke run. This synopsis exists so the native player's Info tab header can be checked in the simulator without a signed-in catalog."
                    )
                }
            }
            .fullScreenCover(item: $context) { ctx in
                PlayerScreen(context: ctx, onPlayNext: { _ in })
                    .ignoresSafeArea()
            }
    }
}
#endif
