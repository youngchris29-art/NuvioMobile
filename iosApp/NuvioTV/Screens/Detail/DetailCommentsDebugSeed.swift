import Foundation
import SharedCore

#if DEBUG
/// BUG-244: a DEBUG-only, guest-only, in-memory Trakt comments seed for the Detail UI legs. The
/// guest fixture has no Trakt account, so without this no comment card can ever be on the page
/// (the device-only bug needed a connected Trakt). Modelled on `ContinueWatchingDebugSeed`:
///
///     -debug.detailCommentsSeedB64 <base64 of a JSON array>
///
/// Base64 because the launch-argument domain parses a bracket-led value as an old-style plist and
/// drops raw JSON. Each element:
///
///     {"id":1,"author":"Seed One","text":"...","spoiler":false,"review":false,
///      "likes":57,"rating":7,"createdAt":"2026-10-18T00:00:00Z"}
///
/// `id`, `author` and `text` are required; the rest are optional with the Kotlin defaults.
/// Refused on a signed-in cloud account with the collections seed's own rule
/// (`HomeViewModel.collectionsSeedRefusal`), so test data never shows on a real account's page.
/// In memory only: nothing is written to Trakt, settings or disk.
@MainActor
enum DetailCommentsDebugSeed {
    static let argumentKey = "debug.detailCommentsSeedB64"

    /// The seeded comments, or nil when no seed was requested or it was refused (the normal fetch runs).
    static func commentsIfRequested() -> [TraktCommentReview]? {
        guard let b64 = UserDefaults.standard.string(forKey: argumentKey), !b64.isEmpty else { return nil }
        if let refusal = HomeViewModel.collectionsSeedRefusal(authState: AuthRepository.shared.state.value_) {
            NSLog("[CommentsSeed] applied=false refused=%@", refusal)
            return nil
        }
        guard let data = Data(base64Encoded: b64),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            NSLog("[CommentsSeed] applied=false error=the payload is not base64 of a JSON array")
            return nil
        }
        var comments: [TraktCommentReview] = []
        for entry in entries {
            guard let id = (entry["id"] as? NSNumber)?.int64Value,
                  let author = entry["author"] as? String, !author.isEmpty,
                  let text = entry["text"] as? String else { continue }
            let spoiler = (entry["spoiler"] as? Bool) ?? false
            comments.append(TraktCommentReview(
                id: id,
                authorDisplayName: author,
                authorUsername: entry["username"] as? String,
                comment: text,
                spoiler: spoiler,
                containsInlineSpoilers: (entry["inlineSpoilers"] as? Bool) ?? false,
                review: (entry["review"] as? Bool) ?? false,
                likes: Int32(truncatingIfNeeded: (entry["likes"] as? NSNumber)?.intValue ?? 0),
                rating: (entry["rating"] as? NSNumber).map { KotlinInt(int: Int32(truncatingIfNeeded: $0.intValue)) },
                createdAt: entry["createdAt"] as? String,
                updatedAt: entry["updatedAt"] as? String
            ))
        }
        NSLog("[CommentsSeed] applied=true count=%d", comments.count)
        return comments
    }
}
#endif
