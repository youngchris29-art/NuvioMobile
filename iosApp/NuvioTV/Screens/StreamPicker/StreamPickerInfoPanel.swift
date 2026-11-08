import SwiftUI
import SharedCore

/// Stream picker A, P1: the left pane (40 % of the screen). Static, nothing focusable: the title
/// logo in the Detail logo slot, one facts line (episode marker · name · runtime, or genres · year),
/// the poster, and a live progress line that counts the fan-out ("Finding streams… 3 of 4") and
/// settles on the result ("155 sources from 4 add-ons").
///
/// The poster is dropped when the pane is under `posterMinimumHeight` points tall, so a small
/// window (the simulator at a reduced scale, a sheet) never pushes the progress line off the pane.
struct StreamPickerInfoPanel: View {
    let title: String
    let logoUrl: String?
    let poster: String?
    let season: Int?
    let episode: Int?
    let episodes: [MetaVideo]
    let meta: PlaybackMeta?
    let progress: StreamFanOutProgress
    /// The user's poster corners (Settings › Appearance), the same value `PosterCard` reads.
    @Environment(\.posterStyle) private var posterStyle

    /// The Detail logo slot: 180 pt high; `TitleLogoHeader` caps the width at its own
    /// `heroLogoMaxWidth` (520 pt), which the pane's 40 % share (768 pt at 1080p) holds with room.
    nonisolated static let logoSlotHeight: CGFloat = 180
    nonisolated static let logoDecodeWidth: CGFloat = 600
    /// GitHub #25 (Christian on the mockup, 2026-11-08): 360 × 540, up from 260 × 390.
    nonisolated static let posterWidth: CGFloat = 360
    nonisolated static var posterHeight: CGFloat { posterWidth * 1.5 }
    /// Below this pane height the poster is hidden (the loading cover and alerts are unaffected).
    /// Logo slot 180 + facts (two lines) + poster 540 + progress line + the gaps: about 850, raised
    /// from 700 with the larger poster so the progress line never falls off the pane.
    nonisolated static let posterMinimumHeight: CGFloat = 850

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                TitleLogoHeader(
                    title: title,
                    logoUrl: logoUrl,
                    textFont: Theme.Font.screenTitle,
                    slotHeight: Self.logoSlotHeight,
                    decodeSize: .points(width: Self.logoDecodeWidth, height: Self.logoSlotHeight),
                    upgrade: .logo
                )
                .frame(maxWidth: Self.logoDecodeWidth, alignment: .leading)

                StreamPickerFactsText(season: season, episode: episode, episodes: episodes, meta: meta,
                                      lineLimit: 2)

                if geo.size.height >= Self.posterMinimumHeight, let poster, !poster.isEmpty {
                    CachedAsyncImage(
                        string: poster,
                        decodeSize: .points(width: Self.posterWidth, height: Self.posterHeight),
                        upgrade: .posterLarge
                    )
                    .frame(width: Self.posterWidth, height: Self.posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius, style: .continuous))
                    .accessibilityHidden(true)
                }

                StreamPickerProgressLine(progress: progress)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.leading, Theme.Spacing.screen)
        .padding(.vertical, Theme.Spacing.screen)
        .padding(.trailing, Theme.Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream_picker_info_panel")
    }

    /// Episode: "S1 · E3 · Double Cross · 45 min" (marker and name from
    /// `PlayerLoadingOverlay.episodeLine`; the episode's own runtime when the catalog has it, else
    /// the title's). Movie: "Drama · Sci-Fi · 2024" (up to three genres, then the year). nil when
    /// nothing is known.
    nonisolated static func factsLine(
        season: Int?,
        episode: Int?,
        episodes: [MetaVideo],
        meta: PlaybackMeta?
    ) -> String? {
        let separator = " \u{00B7} "
        if let season, let episode {
            var parts = [PlayerLoadingOverlay.episodeLine(season: season, episode: episode, episodes: episodes) ?? ""]
            let episodeMinutes: Int? = episodes
                .first { $0.season?.intValue == season && $0.episode?.intValue == episode }?
                .runtime?.intValue
            if let episodeMinutes, episodeMinutes > 0 {
                parts.append(String(localized: "\(episodeMinutes) min"))
            } else if let runtime = meta?.runtime, !runtime.isEmpty {
                parts.append(runtime)
            }
            return parts.filter { !$0.isEmpty }.joined(separator: separator)
        }
        var parts = Array((meta?.genres ?? []).prefix(3))
        if let year = meta?.year, !year.isEmpty { parts.append(year) }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// Before the first emission and while loading: "Finding streams…", with "3 of 4" once the
    /// fan-out knows its size. Done: "155 sources from 3 add-ons" (the add-ons that returned
    /// sources; singular forms kept), or "No sources" when nothing is listable (the empty-state
    /// reason beside the list says why).
    nonisolated static func progressText(_ progress: StreamFanOutProgress) -> String {
        if !progress.hasOutcome || progress.isLoading {
            guard progress.expected > 0, progress.isLoading else { return String(localized: "Finding streams\u{2026}") }
            return String(localized: "Finding streams\u{2026} \(progress.answered) of \(progress.expected)")
        }
        guard progress.sources > 0 else { return String(localized: "No sources") }
        let sources = progress.sources == 1
            ? String(localized: "1 source")
            : String(localized: "\(progress.sources) sources")
        let addons = progress.addonsWithSources == 1
            ? String(localized: "1 add-on")
            : String(localized: "\(progress.addonsWithSources) add-ons")
        return String(localized: "\(sources) from \(addons)")
    }
}

/// The facts line ("S1 · E3 · Double Cross · 45 min" / "Drama · Sci-Fi · 2024"), shared by the
/// two-pane info panel and the full-width header strip (GitHub #25) so the two never drift apart.
/// Draws nothing when nothing is known.
struct StreamPickerFactsText: View {
    let season: Int?
    let episode: Int?
    let episodes: [MetaVideo]
    let meta: PlaybackMeta?
    let lineLimit: Int

    var body: some View {
        if let facts = StreamPickerInfoPanel.factsLine(season: season, episode: episode, episodes: episodes, meta: meta) {
            Text(facts)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(lineLimit)
        }
    }
}

/// The fan-out progress line ("Finding streams… 3 of 4" / "155 sources from 4 add-ons"), with the
/// spinner while it counts. Shared by both layouts (GitHub #25); the UI legs find it by its
/// identifier in either one.
struct StreamPickerProgressLine: View {
    let progress: StreamFanOutProgress

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if progress.isLoading || !progress.hasOutcome {
                ProgressView()
            }
            Text(StreamPickerInfoPanel.progressText(progress))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
        .accessibilityIdentifier("stream_picker_progress")
    }
}

/// GitHub #25 "Source Layout = Full Width": the one-line strip above the full-width list. The title
/// logo in a 64 pt slot (else the title text), the facts line, and the fan-out progress at the
/// trailing edge. No poster; the backdrop stays. Static, nothing focusable, like the info panel.
struct StreamPickerHeaderStrip: View {
    let title: String
    let logoUrl: String?
    let season: Int?
    let episode: Int?
    let episodes: [MetaVideo]
    let meta: PlaybackMeta?
    let progress: StreamFanOutProgress

    nonisolated static let logoSlotHeight: CGFloat = 64
    /// A wide wordmark at 64 pt is about 360 pt across; the slot caps it there.
    nonisolated static let logoMaxWidth: CGFloat = 360

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            TitleLogoHeader(
                title: title,
                logoUrl: logoUrl,
                textFont: Theme.Font.sectionTitle,
                slotHeight: Self.logoSlotHeight,
                decodeSize: .points(width: Self.logoMaxWidth, height: Self.logoSlotHeight),
                upgrade: .logo
            )
            .frame(maxWidth: Self.logoMaxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            StreamPickerFactsText(season: season, episode: episode, episodes: episodes, meta: meta,
                                  lineLimit: 1)
                .layoutPriority(-1)
            Spacer(minLength: Theme.Spacing.lg)
            StreamPickerProgressLine(progress: progress)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: Self.logoSlotHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream_picker_header_strip")
    }
}
