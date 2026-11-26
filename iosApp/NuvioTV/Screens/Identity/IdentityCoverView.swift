import SwiftUI

/// The identity cover's content (spec 8.2): the app background, a spinner and one line. Focusable,
/// with Menu swallowed, so nothing underneath can be reached while it is up.
///
/// Departure (W2): the spec's two new strings ("Switching profile…", "Signing out…") are not added
/// (no new user-visible string in W2); the cover reuses the catalog's existing "Switching…" and
/// "Loading…" keys until the two strings are approved.
struct IdentityCoverView: View {
    let kind: IdentityCoverKind
    #if DEBUG
    @State private var laidOutFrame = ""
    #endif

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                ProgressView()
                    .tint(Theme.Palette.accent)
                Text(kind == .switching ? "Switching…" : "Loading…")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        #if DEBUG
        // The UI leg reads the laid-out frame from here, never from the element's accessibility frame.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { laidOutFrame = Self.describe(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in laidOutFrame = Self.describe(frame) }
            }
            .ignoresSafeArea()
        )
        #endif
        .ignoresSafeArea()
        .focusable()
        .onExitCommand {}
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("identity.cover")
        #if DEBUG
        .accessibilityValue(laidOutFrame)
        #endif
    }

    #if DEBUG
    private static func describe(_ frame: CGRect) -> String {
        "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
    }
    #endif
}
