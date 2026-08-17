import AVKit
import SwiftUI

/// Audio tab, laid out like the classic tvOS panel: a LANGUAGE column (one checkmark row per audio
/// track) and a SPEAKERS & HEADPHONES column (current output route + the system route picker).
/// Enhance Dialogue / Reduce Loud Sounds have no public API — they stay in the native transport-bar
/// Audio popover, and the column says so.
struct PlayerAudioTab: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.screen) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    PlayerPanelSectionCaption(text: String(localized: "Language"))
                    ForEach(model.audio) { option in
                        PlayerPanelOptionRow(option: option, identifierPrefix: "player.panel.audio") {
                            model.onSelectAudio?(option)
                        }
                    }
                    if model.audio.isEmpty {
                        Text("No stream details yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Full-width rows: Down from the (centred) tab row must land on the first language row,
            // not on the route picker in the trailing column — the focus engine prefers overlap.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                PlayerPanelSectionCaption(text: String(localized: "Speakers & Headphones"))
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "checkmark").font(Theme.Font.body.weight(.semibold)).frame(width: 34)
                    Image(systemName: "hifispeaker.and.appletv")
                    Text(model.outputRouteName.isEmpty ? "Apple TV" : model.outputRouteName)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                }
                if model.canPickRoute {
                    AudioRoutePickerButton()
                        .frame(height: 70)
                        .padding(.top, Theme.Spacing.xs)
                        .accessibilityIdentifier("player.panel.audio.route")
                }
                Text("Enhance Dialogue and sound options are in the player's Audio button.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.sm)
            }
            .frame(width: 520, alignment: .leading)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
    }
}

/// System AirPlay / Bluetooth output picker (opens the tvOS route sheet). Wrapped so it takes part
/// in the SwiftUI focus layout like any other control.
struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.routePickerButtonStyle = .system
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
