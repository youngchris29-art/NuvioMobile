import AVFoundation
import CoreMedia

/// P4 (A8): `AVPlayerItem.externalMetadata` for the native engine — the title and subtitle the
/// system transport bar shows above the scrubber, the synopsis in its Info area, and the Now
/// Playing artwork. Pure apart from the artwork item wrapping already-encoded JPEG bytes.
enum NativeNowPlayingMetadata {
    /// Title, subtitle ("S1 · E4 · Episode name", or the stream label for a movie), description and
    /// genres, all but the title omitted when empty.
    static func textItems(context: PlaybackContext) -> [AVMetadataItem] {
        let header = NativeInfoHeader(context: context)
        var items = [item(.commonIdentifierTitle, context.title)]
        if let subtitle = header.subtitle, !subtitle.isEmpty {
            items.append(item(.iTunesMetadataTrackSubTitle, subtitle))
        }
        if let synopsis = context.synopsis, !synopsis.isEmpty {
            items.append(item(.commonIdentifierDescription, synopsis))
        }
        // Insights device fix: the system Info pill is the native route's what's-playing panel
        // (the app's own pill is "Stream Info"), so it gets the genres too. No content rating: on
        // tvOS that item drives the parental-restriction gate, which must not start blocking here.
        if let genres = context.meta?.genres, !genres.isEmpty {
            items.append(item(.quickTimeMetadataGenre, genres.prefix(3).joined(separator: ", ")))
        }
        return items
    }

    static func artworkItem(jpeg: Data) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = jpeg as NSData
        m.dataType = kCMMetadataBaseDataType_JPEG as String
        m.extendedLanguageTag = "und"
        return m
    }

    /// Now Playing wants the 2:3 poster first (the Info tab header prefers the episode still).
    static func artworkURL(context: PlaybackContext) -> URL? {
        for candidate in [context.poster, context.episodeStill] {
            if let s = candidate, !s.isEmpty, let url = URL(string: s) { return url }
        }
        return nil
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = identifier
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }
}
