import SwiftUI

/// The identity cover's content (spec 8.2): the app background, a spinner and one line. Focusable,
/// with Menu swallowed, so nothing underneath can be reached while it is up.
///
/// The two strings are decision E's: "Switching profile…" for the profile kinds and the local
/// select, "Signing out…" for sign-out, delete account, server switch and a wipe window. A publish
/// window (sign-in, launch restore, an accept) shows no cover at all (spec 4.6).
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
                Text(kind == .switching ? "Switching profile…" : "Signing out…")
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
