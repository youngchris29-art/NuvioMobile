import SwiftUI

// TODO(insights wave 1b): contract stub. The Cast pill's content on both engines: a horizontal
// row of person cards (headshot, name, role), and in place of it the compact actor view while
// `model.actorView` is set. Selecting a card calls `model.openPerson(_:)`; focus returns to the
// card `model.lastOpenedPersonId` names when the actor view closes. Menu is handled by the host
// (`model.menuBack()`), never here.
struct PlayerCastContent: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        EmptyView()
    }
}

// TODO(insights wave 1b): contract stub. The Up Next pill's content: `model.upNext` as one card
// (still, title, subtitle) with a Play button that calls `model.onPlayUpNext`.
struct PlayerUpNextContent: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        EmptyView()
    }
}
