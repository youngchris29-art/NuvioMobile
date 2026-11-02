import SharedCore
import SwiftUI

/// Subtitles tab: Off, then the file's embedded text tracks, then addon-fetched subtitles — one
/// checkmark row each, plus (when the engine supports it) a "Timing" row to nudge subtitle sync.
/// Sections are labelled only when both embedded and addon rows exist.
struct PlayerSubtitlesTab: View {
    @ObservedObject var model: PlayerTopPanelModel

    /// Sync Line (P5 B19) session: the position is captured when the row is pressed, never when a
    /// cue is picked (the panel does not pause playback).
    private struct SyncSession {
        let id = UUID()
        let capturedMs: Int64
        let delayAtCaptureMs: Int
        var cues: [SubtitleSyncCue]?
        var failed: Bool
    }

    private enum SyncFocus: Hashable { case row, cancel, cue(Int) }

    @State private var syncSession: SyncSession?
    @FocusState private var syncFocus: SyncFocus?

    var body: some View {
        if let session = syncSession {
            syncLineList(session)
        } else {
            tabBody
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        let options = model.subtitles
        let embedded = options.filter { $0.group == .embedded }
        let addon = options.filter { $0.group == .addon }
        let off = options.first { $0.group == .off }
        let labelled = !embedded.isEmpty && !addon.isEmpty

        // Scrolls with focus (addon lists can run to a dozen+ rows); we own the container now, so
        // lazy/scrolling content no longer breaks the panel's height measurement.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                PlayerPanelSectionCaption(text: String(localized: "Subtitles"))
                if let off { row(off) }
                if labelled { PlayerPanelSectionCaption(text: String(localized: "Embedded")).padding(.top, Theme.Spacing.sm) }
                ForEach(embedded) { row($0) }
                if labelled { PlayerPanelSectionCaption(text: String(localized: "From addons")).padding(.top, Theme.Spacing.sm) }
                ForEach(addon) { row($0) }
                if embedded.isEmpty && addon.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        if model.subtitlesSearching { ProgressView().scaleEffect(0.6) }
                        Text(model.subtitlesSearching
                             ? String(localized: "Searching addon subtitles…")
                             : String(localized: "No subtitles for this title"))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
                if model.supportsSubtitleDelay {
                    PlayerPanelSectionCaption(text: String(localized: "Timing")).padding(.top, Theme.Spacing.sm)
                    subtitleDelayRow
                    if model.syncLineAvailable { syncLineRow }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 520, alignment: .top)
    }

    private func row(_ option: PlayerPanelOption) -> some View {
        PlayerPanelOptionRow(option: option, identifierPrefix: "player.panel.subtitle") {
            model.onSelectSubtitle?(option.group == .off ? nil : option)
        }
    }

    // MARK: - Timing (subtitle delay)

    /// One row: coarse ±1s chips flank fine ±0.1s chips around a monospaced value label, mirroring
    /// mobile's step (`SUBTITLE_DELAY_STEP_MS` = 100ms) with tvOS-friendly ±1s jumps for the remote.
    /// D-pad friendly: five focusable buttons (default tvOS button style, matching every other
    /// panel row — `PlayerPanelOptionRow`'s doc comment explains why a custom style would be
    /// invisible here) plus a conditional Reset.
    private var subtitleDelayRow: some View {
        let delayMs = model.subtitleDelayMs
        let delaySec = Double(delayMs) / 1000.0
        // Device pass 2026-11-01: label above the chips (it used to take a 200 pt column in the
        // same row, which with the chips ran past the popover's right edge). Every chip stays in
        // ONE HStack: Sync Line must remain one Right past Reset (P5 device pass, below).
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(String(localized: "Subtitle Delay"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            subtitleDelayChips(delayMs: delayMs, delaySec: delaySec)
        }
    }

    private func subtitleDelayChips(delayMs: Int, delaySec: Double) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            delayButton(String(localized: "−1 s")) { applyDelay(delayMs - 1000) }
                .accessibilityIdentifier("player.panel.subtitleDelay.minus1")
            delayButton(String(localized: "−0.1 s")) { applyDelay(delayMs - 100) }
                .accessibilityIdentifier("player.panel.subtitleDelay.minus")
            Text(String(format: "%+.2f s", delaySec))
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 90)
                .accessibilityIdentifier("player.panel.subtitleDelay.value")
            delayButton(String(localized: "+0.1 s")) { applyDelay(delayMs + 100) }
                .accessibilityIdentifier("player.panel.subtitleDelay.plus")
            delayButton(String(localized: "+1 s")) { applyDelay(delayMs + 1000) }
                .accessibilityIdentifier("player.panel.subtitleDelay.plus1")
            // Always mounted: removing Reset when it reached 0 took the focused control away and
            // the engine dropped focus somewhere else in the panel. At 0 it is a no-op.
            Button { if delayMs != 0 { applyDelay(0) } } label: { Text(String(localized: "Reset")).font(Theme.Font.meta).lineLimit(1).fixedSize() }
                .accessibilityIdentifier("player.panel.subtitleDelay.reset")
            // P5 device pass (2026-10-20): a Sync Line button on its own row below the chips was
            // unreachable on hardware (Down from any chip went nowhere; the focus engine never
            // crossed into it). In the same HStack it is one Right past Reset.
            if model.syncLineAvailable {
                Button(action: startSyncLine) { Text(String(localized: "Sync Line")).font(Theme.Font.meta).lineLimit(1).fixedSize() }
                    .focused($syncFocus, equals: .row)
                    .accessibilityIdentifier("player.panel.syncLine")
            }
        }
    }

    private func delayButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(Theme.Font.meta).lineLimit(1).fixedSize() }
    }

    private func applyDelay(_ ms: Int) {
        let clamped = min(Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MAX_MS),
                          max(Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MIN_MS), ms))
        model.onSubtitleDelayChange?(clamped)
    }

    // MARK: - Sync Line (P5 B19)

    /// The caption under the Timing row; the button itself lives in `subtitleDelayRow`.
    private var syncLineRow: some View {
        Text(String(localized: "Press Sync Line while a line is spoken, then pick that line."))
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.top, Theme.Spacing.xxs)
    }

    private func startSyncLine() {
        let captured = model.syncLineCapturePositionMs?() ?? 0
        let delayAtCapture = model.subtitleDelayMs
        let session = SyncSession(capturedMs: captured, delayAtCaptureMs: delayAtCapture, cues: nil, failed: false)
        let sessionID = session.id
        syncSession = session
        // Cancel exists as soon as the list does; park focus there so the engine never falls back
        // to the tab row (which selects on focus) while the cues load.
        focusAfterDelay(.cancel)
        Task { @MainActor in
            let loaded = await withTimeoutOrNil(seconds: 12) { await model.syncLineCues?() }
            guard syncSession?.id == sessionID else { return }
            if let loaded {
                syncSession?.cues = loaded
                let windowed = SubtitleSyncLine.shared.window(cues: loaded, capturedPositionMs: captured,
                                                              currentDelayMs: Int32(delayAtCapture))
                let anchor = SubtitleSyncLine.shared.anchorIndex(windowed: windowed, capturedPositionMs: captured,
                                                                 currentDelayMs: Int32(delayAtCapture))
                print("[SyncLine] captured=\(captured)ms delay=\(delayAtCapture)ms cues=\(loaded.count) window=\(windowed.count) anchor=\(anchor.map { "\($0)" } ?? "-")")
                focusAfterDelay(anchor.map { .cue(Int(truncating: $0)) } ?? .cancel)
            } else {
                syncSession?.failed = true
                focusAfterDelay(.cancel)
            }
        }
    }

    /// A cue fetch that hangs or fails must not hang the panel: nil after `seconds`.
    private func withTimeoutOrNil(seconds: Double,
                                  _ work: @escaping @Sendable () async -> [SubtitleSyncCue]?) async -> [SubtitleSyncCue]? {
        await withTaskGroup(of: [SubtitleSyncCue]?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func focusAfterDelay(_ target: SyncFocus) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            syncFocus = target
        }
    }

    private func syncLineList(_ session: SyncSession) -> some View {
        let windowed: [SubtitleSyncCue] = session.cues.map {
            SubtitleSyncLine.shared.window(cues: $0, capturedPositionMs: session.capturedMs,
                                           currentDelayMs: Int32(session.delayAtCaptureMs))
        } ?? []
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                PlayerPanelSectionCaption(text: String(localized: "Sync Line"))
                Button(action: endSyncSession) {
                    Text(String(localized: "Cancel")).font(Theme.Font.body)
                }
                .focused($syncFocus, equals: .cancel)
                .accessibilityIdentifier("player.panel.syncLine.cancel")
                if session.failed {
                    syncMessage(String(localized: "Unable to load subtitle lines"), id: "player.panel.syncLine.unavailable")
                } else if session.cues == nil {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView().scaleEffect(0.6)
                        Text(String(localized: "Loading subtitle lines…"))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                } else if windowed.isEmpty {
                    syncMessage(String(localized: "No subtitle lines found"), id: "player.panel.syncLine.empty")
                } else {
                    ForEach(Array(windowed.enumerated()), id: \.offset) { index, cue in
                        Button {
                            let delay = Int(SubtitleSyncLine.shared.delayMs(capturedPositionMs: session.capturedMs,
                                                                           cueStartMs: cue.startTimeMs))
                            model.onSubtitleDelayChange?(delay)
                            endSyncSession()
                        } label: {
                            Text(verbatim: "\(Self.clock(cue.startTimeMs))  \(Self.firstLine(cue.text))")
                                .font(Theme.Font.body)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .focused($syncFocus, equals: .cue(index))
                        .accessibilityIdentifier("player.panel.syncLine.cue.\(index)")
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 520, alignment: .top)
        .defaultFocus($syncFocus, .cancel)
    }

    private func syncMessage(_ text: String, id: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.top, Theme.Spacing.xs)
            .accessibilityIdentifier(id)
    }

    private func endSyncSession() {
        syncSession = nil
        focusAfterDelay(.row)
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
