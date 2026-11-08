import SwiftUI
import SharedCore

/// Stream picker A, P1: the left pane (40 % of the screen). Static, nothing focusable: the title
/// logo in the Detail logo slot, one facts line (episode marker · name · runtime, or genres · year),
/// the poster, and a live progress line that counts the fan-out ("Finding streams… 3 of 4") and
/// settles on the result ("155 sources from 4 add-ons").
///
/// The poster takes the height the rest of the pane leaves (`posterWidth(paneHeight:reserved:)`,
/// 2:3, up to 360 pt wide) and is dropped when even `posterMinimumWidth` doesn't fit, so a small
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
    /// GitHub #25 (Christian, 2026-11-08): the poster grows to 360 × 540 where the pane has the
    /// room. A 1080p box's pane is about 840 pt, which holds roughly 300–325 pt (option (a) after the
    /// device pass: a fixed 360 behind an 850 pt threshold never showed on the box).
    nonisolated static let posterMaximumWidth: CGFloat = 360
    /// The old fixed size; below it the poster is hidden (the loading cover and alerts are unaffected).
    nonisolated static let posterMinimumWidth: CGFloat = 260
    /// Height over width (2:3).
    nonisolated static let posterAspect: CGFloat = 1.5
    /// The VStack gaps while the poster shows: logo → facts → poster → progress → spacer.
    nonisolated static let posterGapCount: CGFloat = 4
    /// The pane height everything but the poster takes before the header, facts and progress
    /// line are measured: the full logo slot (180) + two facts lines + one progress line (body,
    /// about 39 pt each) + the four gaps. The measured heights replace these after the first
    /// layout; a title drawn as text when there is no logo is shorter than the slot (review p1).
    nonisolated static let estimatedTextLineHeight: CGFloat = 39
    nonisolated static var estimatedReservedHeight: CGFloat {
        reservedHeight(headerHeight: logoSlotHeight, factsHeight: estimatedTextLineHeight * 2,
                       progressHeight: estimatedTextLineHeight)
    }

    /// The pane height the title header, the facts and progress lines and the gaps take.
    nonisolated static func reservedHeight(headerHeight: CGFloat, factsHeight: CGFloat,
                                           progressHeight: CGFloat) -> CGFloat {
        headerHeight + factsHeight + progressHeight + posterGapCount * Theme.Spacing.lg
    }

    /// The poster width for a pane `paneHeight` tall: the room left after `reserved`, at 2:3, capped
    /// at `posterMaximumWidth`, whole points; nil (no poster) when that is under `posterMinimumWidth`.
    nonisolated static func posterWidth(paneHeight: CGFloat, reserved: CGFloat) -> CGFloat? {
        let room = paneHeight - reserved
        guard room.isFinite, room > 0 else { return nil }
        let width = (room / posterAspect).rounded(.down)
        guard width >= posterMinimumWidth else { return nil }
        return min(width, posterMaximumWidth)
    }

    @State private var headerHeight: CGFloat?
    @State private var factsHeight: CGFloat?
    @State private var progressHeight: CGFloat?

    private var reservedHeight: CGFloat {
        Self.reservedHeight(headerHeight: headerHeight ?? Self.logoSlotHeight,
                            factsHeight: factsHeight ?? Self.estimatedTextLineHeight * 2,
                            progressHeight: progressHeight ?? Self.estimatedTextLineHeight)
    }

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
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { headerHeight = $0 }

                StreamPickerFactsText(season: season, episode: episode, episodes: episodes, meta: meta,
                                      lineLimit: 2)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { factsHeight = $0 }

                if let poster, !poster.isEmpty,
                   let width = Self.posterWidth(paneHeight: geo.size.height, reserved: reservedHeight) {
                    let height = width * Self.posterAspect
                    CachedAsyncImage(
                        string: poster,
                        // Decoded at the largest size so a pane resize never re-fetches the art.
                        decodeSize: .points(width: Self.posterMaximumWidth,
                                            height: Self.posterMaximumWidth * Self.posterAspect),
                        upgrade: .posterLarge
                    )
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius, style: .continuous))
                    .accessibilityHidden(true)
                }

                StreamPickerProgressLine(progress: progress)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { progressHeight = $0 }

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
