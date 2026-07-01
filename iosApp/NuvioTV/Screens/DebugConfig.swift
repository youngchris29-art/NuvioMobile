import Foundation

/// Dev convenience for getting a long addon manifest URL into the app without typing it on the tvOS
/// keyboard (which can't reliably paste). Paste your full Torrentio/TorBox manifest URL into
/// `manifestURL` below **here in Xcode** (paste works fine in the editor), build, then tap
/// "Quick install" on the Add-ons screen.
///
/// Keep your real API key out of version control — don't commit this with the key filled in.
enum DebugConfig {
    /// e.g. "https://torrentio.strem.fun/...|torbox=YOUR_KEY/manifest.json"
    static let manifestURL = "https://torrentio.strem.fun/qualityfilter=unknown,cam,other,scr,480p,720p|debridoptions=nodownloadlinks|torbox=baf5c753-a8ee-4960-9266-e324045e62eb/manifest.json"

    static var hasManifestURL: Bool {
        !manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
