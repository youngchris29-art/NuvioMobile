import SwiftUI

#if DEBUG
/// UI-level player smoke: when `debug.mpvSmokeURL` holds a source URL, the root view presents the
/// real `PlayerScreen` (engine routing included) shortly after launch — with the native-DV toggle
/// off this exercises the full libmpv path: event-driven property cache, track-list walks on the
/// event queue, progress saves, and the `[MPVStats]` first-90s diagnostics.
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
                    context = PlaybackContext(
                        url: url, title: "MPV Smoke", contentType: "movie",
                        parentMetaId: "smoke-mpv", videoId: "smoke-mpv",
                        season: nil, episode: nil, poster: nil, background: nil,
                        providerName: nil, providerAddonId: nil,
                        streamTitle: nil, streamSubtitle: nil, externalSubtitles: []
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
