import SwiftUI
import SharedCore

/// Profile avatar: renders the cloud avatar image (custom `avatarUrl` or catalog `avatarId`,
/// resolved via the shared `profileAvatarImageUrl`) when available, otherwise the colored circle
/// with the profile's initial (guest-mode / pre-cloud behavior).
struct ProfileAvatar: View {
    let profile: NuvioProfile
    var size: CGFloat = 170
    /// The avatar catalog (for `avatarId` lookups). Empty is fine — falls back to color+initial.
    var avatars: [AvatarCatalogItem] = []

    var body: some View {
        ZStack {
            if let url = imageUrl {
                CachedAsyncImage(string: url)
                    .clipShape(Circle())
            } else {
                Circle().fill(Color(hexString: profile.avatarColorHex) ?? Theme.Palette.accent)
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var imageUrl: String? {
        let catalogItem = avatars.first { $0.id == profile.avatarId }
        return ProfileModelsKt.profileAvatarImageUrl(profile: profile, avatar: catalogItem)
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }
}

/// The "Who's watching?" launch gate. Shows the profiles as a focusable row; selecting one enters
/// the app — PIN-locked profiles prompt for their 4-digit PIN first (as do edit/delete on them).
/// Long-press a profile to edit/delete; the trailing tile adds a new profile.
struct ProfileSelectionView: View {
    @ObservedObject var model: ProfilesViewModel
    var onSelected: () -> Void

    @State private var editing: ProfileEditTarget?
    @State private var pinPrompt: PinPrompt?

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            // Accent-derived wash (mobile reference: color-graded backdrop behind the picker).
            LinearGradient(
                colors: [Theme.Palette.accent.opacity(0.22), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.sectionGap) {
                VStack(spacing: Theme.Spacing.md) {
                    Text("Who\u{2019}s watching?")
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Select a profile to continue")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                // Max 6 profiles + Add tile fit on screen, so no ScrollView — a plain HStack
                // centers the row in the middle of the screen (a ScrollView would pin it left).
                HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                        ForEach(model.profiles, id: \.profileIndex) { profile in
                            Button {
                                requirePin(for: profile, action: .select)
                            } label: {
                                profileTile(name: profile.name, isPrimary: profile.profileIndex == 1) {
                                    ZStack(alignment: .bottomTrailing) {
                                        ProfileAvatar(profile: profile, avatars: model.avatars)
                                        if profile.pinEnabled {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 28))
                                                .foregroundStyle(Theme.Palette.textPrimary)
                                                .padding(10)
                                                .glassEffect(.regular, in: Circle())
                                        } else if profile.profileIndex == 1 {
                                            // Primary-profile star badge (mobile reference).
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 22))
                                                .foregroundStyle(.black)
                                                .padding(8)
                                                .background(Theme.Palette.star, in: Circle())
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.poster)
                            .contextMenu {
                                Button {
                                    requirePin(for: profile, action: .edit)
                                } label: { Label("Edit Profile", systemImage: "pencil") }
                                if model.profiles.count > 1 {
                                    Button(role: .destructive) {
                                        requirePin(for: profile, action: .delete)
                                    } label: { Label("Delete Profile", systemImage: "trash") }
                                }
                            }
                        }

                        if model.profiles.count < model.maxProfiles {
                            Button {
                                editing = ProfileEditTarget(profile: nil)
                            } label: {
                                profileTile(name: "Add Profile") {
                                    ZStack {
                                        Circle().strokeBorder(Theme.Palette.textSecondary, lineWidth: 3)
                                        Image(systemName: "plus")
                                            .font(.system(size: 64, weight: .semibold))
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                    }
                                    .frame(width: 170, height: 170)
                                }
                            }
                            .buttonStyle(.poster)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.vertical, Theme.Spacing.lg)
                    .focusSection()

                Text("Hold to manage profile")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs + 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(item: $editing) { target in
            ProfileEditView(model: model, target: target)
        }
        .fullScreenCover(item: $pinPrompt) { prompt in
            PinEntryView(
                title: "Enter PIN for \(prompt.profile.name)",
                subtitle: prompt.action == .select ? nil : "This profile is locked.",
                onCancel: { pinPrompt = nil },
                onSubmit: { pin, done in
                    model.verifyPin(prompt.profile, pin: pin) { result in
                        if result?.unlocked == true {
                            pinPrompt = nil
                            perform(prompt.action, on: prompt.profile)
                        } else {
                            done(pinErrorMessage(result))
                        }
                    }
                }
            )
        }
    }

    // MARK: - PIN gating

    private struct PinPrompt: Identifiable {
        enum Action { case select, edit, delete }
        let profile: NuvioProfile
        let action: Action
        var id: String { "\(profile.profileIndex)-\(action)" }
    }

    private func requirePin(for profile: NuvioProfile, action: PinPrompt.Action) {
        if profile.pinEnabled {
            pinPrompt = PinPrompt(profile: profile, action: action)
        } else {
            perform(action, on: profile)
        }
    }

    private func perform(_ action: PinPrompt.Action, on profile: NuvioProfile) {
        switch action {
        case .select:
            model.select(profile)
            onSelected()
        case .edit:
            editing = ProfileEditTarget(profile: profile)
        case .delete:
            model.deleteProfile(profile)
        }
    }

    private func profileTile<Content: View>(
        name: String,
        isPrimary: Bool = false,
        @ViewBuilder avatar: () -> Content
    ) -> some View {
        ProfileTileLabel(name: name, isPrimary: isPrimary, avatar: avatar)
    }
}

/// Focus-aware profile tile label used with the platter-free `.poster` button style: no grey
/// border — the focused avatar zooms slightly and gets a soft white + accent glow, and the name
/// brightens. `@Environment(\.isFocused)` reflects the enclosing Button's focus.
private struct ProfileTileLabel<Content: View>: View {
    let name: String
    var isPrimary: Bool = false
    let avatar: Content

    @Environment(\.isFocused) private var isFocused

    init(name: String, isPrimary: Bool = false, @ViewBuilder avatar: () -> Content) {
        self.name = name
        self.isPrimary = isPrimary
        self.avatar = avatar()
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            avatar
                .scaleEffect(isFocused ? 1.12 : 1)
                .shadow(color: .white.opacity(isFocused ? 0.4 : 0), radius: 26)
                .shadow(color: Theme.Palette.accent.opacity(isFocused ? 0.35 : 0), radius: 44)
            Text(name)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
            if isPrimary {
                Text("PRIMARY")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.Palette.star)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// Formats a failed `PinVerifyResult` for display (server message, lockout countdown, or default).
func pinErrorMessage(_ result: PinVerifyResult?) -> String {
    if let message = result?.message, !message.isEmpty { return message }
    if let retry = result?.retryAfterSeconds, retry > 0 {
        return "Too many attempts. Try again in \(retry)s."
    }
    return "Incorrect PIN. Try again."
}

/// Identifiable wrapper so add (nil) / edit (existing) can drive `.fullScreenCover(item:)`.
struct ProfileEditTarget: Identifiable {
    let profile: NuvioProfile?
    var id: Int { profile.map { Int($0.profileIndex) } ?? -1 }
}

/// Add / edit form: name, avatar (cloud catalog picker when available, else color palette), and —
/// for cloud accounts editing an existing profile — the PIN lock (set / change / remove).
struct ProfileEditView: View {
    @ObservedObject var model: ProfilesViewModel
    let target: ProfileEditTarget

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var avatarId: String?
    @State private var pinFlow: PinFlow?

    /// A custom avatar URL set elsewhere (e.g. on mobile); preserved unless a catalog avatar or
    /// the color tile is picked here.
    private let originalCustomAvatarUrl: String?

    private let palette = [
        "#E53935", "#1E88E5", "#8E24AA", "#43A047",
        "#FB8C00", "#D81B60", "#00ACC1", "#5E35B1",
    ]

    init(model: ProfilesViewModel, target: ProfileEditTarget) {
        self.model = model
        self.target = target
        _name = State(initialValue: target.profile?.name ?? "")
        _colorHex = State(initialValue: target.profile?.avatarColorHex ?? "#E53935")
        _avatarId = State(initialValue: target.profile?.avatarId)
        originalCustomAvatarUrl = target.profile?.avatarId == nil ? target.profile?.avatarUrl : nil
    }

    /// Live copy of the profile being edited (PIN state refreshes after set/clear → pullProfiles).
    private var liveProfile: NuvioProfile? {
        guard let index = target.profile?.profileIndex else { return nil }
        return model.profiles.first { $0.profileIndex == index }
    }

    private var selectedCatalogItem: AvatarCatalogItem? {
        model.avatars.first { $0.id == avatarId }
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Theme.Spacing.xl) {
                    Text(target.profile == nil ? "Add Profile" : "Edit Profile")
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    // Preview
                    ZStack {
                        if let item = selectedCatalogItem {
                            CachedAsyncImage(string: ProfileModelsKt.avatarStorageUrl(storagePath: item.storagePath))
                                .clipShape(Circle())
                        } else if let url = originalCustomAvatarUrl, avatarId == nil {
                            CachedAsyncImage(string: url)
                                .clipShape(Circle())
                        } else {
                            Circle().fill(Color(hexString: colorHex) ?? Theme.Palette.accent)
                            Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                                .font(.system(size: 64, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 150, height: 150)

                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(Theme.Spacing.lg)
                        .frame(maxWidth: 700)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

                    // Cloud avatar catalog (hidden when empty — guest mode / offline).
                    if !model.avatars.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.lg) {
                                // "Color" tile — clears the catalog avatar.
                                Button { avatarId = nil } label: {
                                    ZStack {
                                        Circle().fill(Color(hexString: colorHex) ?? Theme.Palette.accent)
                                        Image(systemName: "paintpalette")
                                            .font(.system(size: 32))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 100, height: 100)
                                    .overlay(
                                        Circle().strokeBorder(
                                            Theme.Palette.textPrimary,
                                            lineWidth: avatarId == nil ? 5 : 0
                                        )
                                    )
                                }
                                .buttonStyle(.card)

                                ForEach(model.avatars, id: \.id) { item in
                                    Button { avatarId = item.id } label: {
                                        CachedAsyncImage(string: ProfileModelsKt.avatarStorageUrl(storagePath: item.storagePath))
                                            .frame(width: 100, height: 100)
                                            .clipShape(Circle())
                                            .overlay(
                                                Circle().strokeBorder(
                                                    Theme.Palette.textPrimary,
                                                    lineWidth: avatarId == item.id ? 5 : 0
                                                )
                                            )
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                    }

                    // Color palette (used when no catalog avatar is selected).
                    HStack(spacing: Theme.Spacing.lg) {
                        ForEach(palette, id: \.self) { hex in
                            Button {
                                colorHex = hex
                                avatarId = nil
                            } label: {
                                Circle()
                                    .fill(Color(hexString: hex) ?? .gray)
                                    .frame(width: 70, height: 70)
                                    .overlay(
                                        Circle().strokeBorder(
                                            Theme.Palette.textPrimary,
                                            lineWidth: (hex == colorHex && avatarId == nil) ? 5 : 0
                                        )
                                    )
                            }
                            .buttonStyle(.card)
                        }
                    }

                    // PIN lock — existing profiles on cloud accounts only (RPCs need a session).
                    if let profile = liveProfile, model.isCloudAccount {
                        HStack(spacing: Theme.Spacing.lg) {
                            if profile.pinEnabled {
                                Button {
                                    pinFlow = .enterCurrent(remove: false)
                                } label: {
                                    Label("Change PIN", systemImage: "lock.rotation")
                                        .font(Theme.Font.body)
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    pinFlow = .enterCurrent(remove: true)
                                } label: {
                                    Label("Remove PIN", systemImage: "lock.slash")
                                        .font(Theme.Font.body)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button {
                                    pinFlow = .enterNew(current: nil)
                                } label: {
                                    Label("Set PIN Lock", systemImage: "lock")
                                        .font(Theme.Font.body)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Button { save() } label: {
                        Text("Save")
                            .font(Theme.Font.meta)
                            .padding(.horizontal, Theme.Spacing.xl)
                            .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .disabled(model.isBusy)

                    if let profile = target.profile, model.profiles.count > 1 {
                        Button(role: .destructive) {
                            model.deleteProfile(profile) { dismiss() }
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                                .font(Theme.Font.body)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(Theme.Spacing.screen)
            }
        }
        .fullScreenCover(item: $pinFlow) { flow in
            pinFlowView(flow)
        }
    }

    // MARK: - PIN flows

    private enum PinFlow: Identifiable {
        /// Verify the current PIN, then either remove the lock or continue to a new PIN.
        case enterCurrent(remove: Bool)
        /// Set a new PIN (with the verified current PIN when changing).
        case enterNew(current: String?)

        var id: String {
            switch self {
            case .enterCurrent(let remove): return "current-\(remove)"
            case .enterNew(let current): return "new-\(current ?? "none")"
            }
        }
    }

    @ViewBuilder
    private func pinFlowView(_ flow: PinFlow) -> some View {
        switch flow {
        case .enterCurrent(let remove):
            PinEntryView(
                title: "Enter current PIN",
                subtitle: remove ? "Confirm the PIN to remove the lock." : "Confirm the PIN before choosing a new one.",
                onCancel: { pinFlow = nil },
                onSubmit: { pin, done in
                    guard let profile = liveProfile else { pinFlow = nil; return }
                    if remove {
                        model.clearPin(profileIndex: profile.profileIndex, currentPin: pin) { result in
                            if result?.unlocked == true {
                                pinFlow = nil
                            } else {
                                done(pinErrorMessage(result))
                            }
                        }
                    } else {
                        model.verifyPin(profile, pin: pin) { result in
                            if result?.unlocked == true {
                                pinFlow = .enterNew(current: pin)
                            } else {
                                done(pinErrorMessage(result))
                            }
                        }
                    }
                }
            )
        case .enterNew(let current):
            PinEntryView(
                title: "Choose a 4-digit PIN",
                subtitle: "This profile will require the PIN to open.",
                onCancel: { pinFlow = nil },
                onSubmit: { pin, done in
                    guard let profile = liveProfile else { pinFlow = nil; return }
                    model.setPin(profileIndex: profile.profileIndex, pin: pin, currentPin: current) { result in
                        if result?.unlocked == true {
                            pinFlow = nil
                        } else {
                            done(pinErrorMessage(result))
                        }
                    }
                }
            )
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "Profile" : trimmed

        // Catalog avatar → store BOTH id and resolved URL (cross-device renderable without a
        // catalog lookup). Color tile → clear both. Untouched custom URL → preserve it.
        let finalAvatarUrl: String?
        if let item = selectedCatalogItem {
            finalAvatarUrl = ProfileModelsKt.avatarStorageUrl(storagePath: item.storagePath)
        } else {
            finalAvatarUrl = originalCustomAvatarUrl
        }

        if let profile = target.profile {
            model.updateProfile(
                profile,
                name: finalName,
                colorHex: colorHex,
                avatarId: avatarId,
                avatarUrl: finalAvatarUrl
            ) { dismiss() }
        } else {
            model.createProfile(
                name: finalName,
                colorHex: colorHex,
                avatarId: avatarId,
                avatarUrl: finalAvatarUrl
            ) { dismiss() }
        }
    }
}
