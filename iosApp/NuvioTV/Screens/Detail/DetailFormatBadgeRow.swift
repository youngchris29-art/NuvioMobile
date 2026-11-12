import SharedCore
import SwiftUI

// Manual key rather than `@Entry`, like every other environment key in this target.
private struct DetailCoverPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a full-screen cover (stream picker, player, trailer) is up over the Detail page.
    /// `.fullScreenCover` leaves the page in the hierarchy, so `.onDisappear` never fires under it;
    /// `DetailView` sets this from its own cover state and the badge row stops its probe on it.
    var detailCoverPresented: Bool {
        get { self[DetailCoverPresentedKey.self] }
        set { self[DetailCoverPresentedKey.self] = newValue }
    }
}

/// Detail-page format badges ("Available in 4K, Dolby Vision, ..."). Outlined text chips in a
/// fixed-height slot so the hero's bottom-anchored stack never moves when badges land late.
/// Never focusable: plain text, no buttons.
struct DetailFormatBadgeRow: View {
    let request: TitleFormatRequest?
    /// False while the page's metadata (re)loads: the probe waits, since embedded streams replace
    /// the add-on fan-out and are only known once it has loaded. The slot stays laid out.
    var ready: Bool = true

    @AppStorage(DetailSettingsKeys.formatBadges) private var enabled = true
    @Environment(\.detailCoverPresented) private var covered
    @StateObject private var model = DetailFormatBadgesModel()

    var body: some View {
        Group {
            if enabled, request != nil {
                chips
            } else {
                EmptyView()
            }
        }
        .task(id: DetailFormatBadgesModel.taskID(request: request, enabled: enabled, ready: ready,
                                                           covered: covered)) {
            await model.run(request: request, enabled: enabled, ready: ready, covered: covered)
        }
        .onDisappear { model.disappear() }
    }

    private var labels: [String] { model.badges.map(\.label) }

    private var chips: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Theme.Spacing.sm)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .stroke(Theme.Palette.textSecondary, lineWidth: 1)
                    }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.reservedHeight(enabled: enabled, hasRequest: request != nil),
               maxHeight: Self.reservedHeight(enabled: enabled, hasRequest: request != nil),
               alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: labels)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: labels) ?? "")
        .accessibilityHidden(labels.isEmpty)
        .accessibilityIdentifier("detail_format_badges")
    }

    /// "Available in 4K, Dolby Vision and HDR"; nil when there is nothing to announce.
    static func accessibilityLabel(for labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: labels)
        return String(localized: "Available in \(list)")
    }

    /// 0 when the setting is off or the title has no request; the fixed slot otherwise.
    static func reservedHeight(enabled: Bool, hasRequest: Bool) -> CGFloat {
        enabled && hasRequest ? DetailCinematicLayout.formatBadgeRowHeight : 0
    }
}
