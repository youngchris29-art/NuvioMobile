import SharedCore
import SwiftUI

/// Sync Line (P5 B19) on the native route, opened from its transport-bar tool button: the
/// position was captured when the button was pressed; this sheet loads the selected add-on
/// subtitle's cues around it and sets the delay from the line the viewer picks. Same rules and
/// lists as the mpv Subtitles tab's Sync Line session (`PlayerSubtitlesTab`). Presented by
/// `NativePlayerHostController.present(panel:)`, whose host controller closes it on Menu.
struct NativeSyncLineSheet: View {
    let model: PlayerTopPanelModel
    let capturedMs: Int64
    let delayAtCaptureMs: Int
    let onDone: () -> Void

    private enum Focus: Hashable { case cancel, cue(Int) }

    @State private var cues: [SubtitleSyncCue]?
    @State private var failed = false
    @FocusState private var focus: Focus?

    private var windowed: [SubtitleSyncCue] {
        cues.map {
            SubtitleSyncLine.shared.window(cues: $0, capturedPositionMs: capturedMs,
                                           currentDelayMs: Int32(delayAtCaptureMs))
        } ?? []
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                PlayerPanelSectionCaption(text: String(localized: "Sync Line"))
                Text(String(localized: "Pick the line that was spoken when you pressed Sync Line."))
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.bottom, Theme.Spacing.xs)
                Button(action: onDone) { Text(String(localized: "Cancel")).font(Theme.Font.body) }
                    .focused($focus, equals: .cancel)
                    .accessibilityIdentifier("player.syncLine.cancel")
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 1100, maxHeight: 620, alignment: .top)
        .padding(Theme.Spacing.xl)
        .playerSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, .cancel)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if failed {
            message(String(localized: "Unable to load subtitle lines"), id: "player.syncLine.unavailable")
        } else if cues == nil {
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().scaleEffect(0.6)
                Text(String(localized: "Loading subtitle lines…"))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.top, Theme.Spacing.xs)
        } else if windowed.isEmpty {
            message(String(localized: "No subtitle lines found"), id: "player.syncLine.empty")
        } else {
            ForEach(Array(windowed.enumerated()), id: \.offset) { index, cue in
                Button {
                    let delay = Int(SubtitleSyncLine.shared.delayMs(capturedPositionMs: capturedMs,
                                                                   cueStartMs: cue.startTimeMs))
                    model.onSubtitleDelayChange?(delay)
                    onDone()
                } label: {
                    Text(verbatim: "\(Self.clock(cue.startTimeMs))  \(Self.firstLine(cue.text))")
                        .font(Theme.Font.body)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focused($focus, equals: .cue(index))
                .accessibilityIdentifier("player.syncLine.cue.\(index)")
            }
        }
    }

    private func load() async {
        // A fetch that hangs must not hang the sheet: give up after 12 s, like the mpv tab.
        let loader = model.syncLineCues
        let loaded = await withTaskGroup(of: [SubtitleSyncCue]?.self) { group in
            group.addTask { await loader?() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let loaded else { failed = true; return }
        cues = loaded
        let anchor = SubtitleSyncLine.shared.anchorIndex(windowed: windowed, capturedPositionMs: capturedMs,
                                                         currentDelayMs: Int32(delayAtCaptureMs))
        print("[SyncLine] native captured=\(capturedMs)ms delay=\(delayAtCaptureMs)ms cues=\(loaded.count) window=\(windowed.count) anchor=\(anchor.map { "\($0)" } ?? "-")")
        try? await Task.sleep(nanoseconds: 350_000_000)
        focus = anchor.map { .cue(Int(truncating: $0)) } ?? .cancel
    }

    private func message(_ text: String, id: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.top, Theme.Spacing.xs)
            .accessibilityIdentifier(id)
    }

    private static func clock(_ ms: Int64) -> String {
        let total = max(0, Int(ms / 1000))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
