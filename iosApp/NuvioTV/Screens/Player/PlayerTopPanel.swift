import SwiftUI

enum PlayerPanelTab: String, CaseIterable, Identifiable {
    case info, subtitles, audio
    /// Engine-specific fourth tab (the mpv player's Playback: speed · timing · episodes · sources).
    case playback
    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return String(localized: "Info")
        case .subtitles: return String(localized: "Subtitles")
        case .audio: return String(localized: "Audio")
        case .playback: return String(localized: "Playback")
        }
    }
}

/// Content for the optional fourth tab; supplied by the engine that has one.
struct PlayerPanelExtraTab {
    let content: AnyView
    init<V: View>(@ViewBuilder content: () -> V) { self.content = AnyView(content()) }
}

/// The app-drawn swipe-down top panel (Infuse-style rendition of the classic tvOS player panel):
/// full width, anchored to the top, glass over the live video, a centred tab row (Info · Subtitles ·
/// Audio) whose selection follows focus, and the tab's content below. Presented by
/// `NativePlayerHostController` (which also owns Menu-to-close); playback continues underneath.
///
/// Focus: the tab row and the content are separate focus sections, so Down from a tab enters the
/// content list and Up returns to the tabs. Left/Right on the tab row switches tabs. Everything
/// uses system focus (docs/design/hig-hybrid-contract.md) — no custom rings.
struct PlayerTopPanel: View {
    @ObservedObject var model: PlayerTopPanelModel
    var extraTab: PlayerPanelExtraTab? = nil
    @State private var tab: PlayerPanelTab = .info
    @State private var shown = false
    @FocusState private var focusedTab: PlayerPanelTab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen clear layer so the hosting view fills the window (focus + gestures).
            Color.clear.ignoresSafeArea()
            if shown {
                panel
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(reduceMotion ? nil : PlayerChipStyle.animation) { shown = true }
            focusedTab = tab
        }
        .onChange(of: focusedTab) { oldValue, newValue in
            guard let newValue else { return }
            if oldValue == nil, newValue != tab {
                // Focus came back UP from the content list: land on the current tab (the focus
                // engine picks the geometrically nearest one, which would silently switch tabs).
                focusedTab = tab
            } else {
                tab = newValue
            }
        }
        .onExitCommand { model.onClose?() }
    }

    private var panel: some View {
        VStack(spacing: Theme.Spacing.md) {
            tabRow
                .focusSection()
            content
                .focusSection()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .top)
        // Same recipe as the mpv transport bar (PlayerControlsOverlay): dark-tinted glass keeps text
        // legible over bright scenes; only the bottom corners are rounded (the top edge is the screen edge).
        .glassEffect(.regular.tint(.black.opacity(0.35)),
                     in: UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.hero,
                                                bottomTrailingRadius: Theme.Radius.hero, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var tabRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(tabs) { item in
                Button(item.title) { tab = item }
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(item == tab ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .focused($focusedTab, equals: item)
                    .accessibilityIdentifier("player.panel.tab.\(item.rawValue)")
                    .accessibilityValue(Text(verbatim: item == tab ? "selected" : ""))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tabs: [PlayerPanelTab] {
        extraTab == nil ? [.info, .subtitles, .audio] : PlayerPanelTab.allCases
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info:
            PlayerInfoTab(info: model.info)
        case .subtitles:
            PlayerSubtitlesTab(model: model)
        case .audio:
            PlayerAudioTab(model: model)
        case .playback:
            if let extraTab { extraTab.content } else { EmptyView() }
        }
    }
}

/// One checkmark row of the Subtitles / Audio tab. DEFAULT tvOS button style on purpose: it draws
/// the white focus platter (the classic panel's focused-row look) and recolors the label itself.
/// `.borderless` would only brighten the label — invisible on an already-bright label (BUG-58
/// lesson) — and no explicit foreground color is set here so the platter's dark text wins.
struct PlayerPanelOptionRow: View {
    let option: PlayerPanelOption
    let identifierPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark")
                    .font(Theme.Font.body.weight(.semibold))
                    .opacity(option.isSelected ? 1 : 0)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(Theme.Font.body)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("\(identifierPrefix).\(option.id)")
        .accessibilityValue(Text(verbatim: option.isSelected ? "selected" : ""))
    }
}

/// Small uppercase column/section caption ("LANGUAGE", "SPEAKERS & HEADPHONES") — the classic
/// tvOS panel's column headers.
struct PlayerPanelSectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.bottom, Theme.Spacing.xxs)
    }
}
