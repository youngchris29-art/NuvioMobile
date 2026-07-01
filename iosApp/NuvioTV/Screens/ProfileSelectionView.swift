import SwiftUI
import SharedCore

/// A colored-circle avatar with the profile's initial. tvOS v1 doesn't use the cloud avatar catalog
/// (that needs Supabase), so we render `avatarColorHex` + the first letter of the name, Netflix-style.
struct ProfileAvatar: View {
    let profile: NuvioProfile
    var size: CGFloat = 170

    var body: some View {
        ZStack {
            Circle().fill(Color(hexString: profile.avatarColorHex) ?? Theme.Palette.accent)
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }
}

/// The "Who's watching?" launch gate. Shows the local profiles as a focusable row; selecting one
/// enters the app. Long-press a profile to edit/delete; the trailing tile adds a new profile.
struct ProfileSelectionView: View {
    @ObservedObject var model: ProfilesViewModel
    var onSelected: () -> Void

    @State private var editing: ProfileEditTarget?

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.sectionGap) {
                Text("Who\u{2019}s watching?")
                    .font(Theme.Font.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xl) {
                        ForEach(model.profiles, id: \.profileIndex) { profile in
                            Button {
                                model.select(profile)
                                onSelected()
                            } label: {
                                profileTile(name: profile.name) { ProfileAvatar(profile: profile) }
                            }
                            .buttonStyle(.card)
                            .contextMenu {
                                Button {
                                    editing = ProfileEditTarget(profile: profile)
                                } label: { Label("Edit Profile", systemImage: "pencil") }
                                if model.profiles.count > 1 {
                                    Button(role: .destructive) {
                                        model.deleteProfile(profile)
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
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.vertical, Theme.Spacing.lg)
                }
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(item: $editing) { target in
            ProfileEditView(model: model, target: target)
        }
    }

    private func profileTile<Content: View>(name: String, @ViewBuilder avatar: () -> Content) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            avatar()
            Text(name)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
    }
}

/// Identifiable wrapper so add (nil) / edit (existing) can drive `.fullScreenCover(item:)`.
struct ProfileEditTarget: Identifiable {
    let profile: NuvioProfile?
    var id: Int { profile.map { Int($0.profileIndex) } ?? -1 }
}

/// Add / edit form: name field + a small color palette. Saves via the shared repository (local).
struct ProfileEditView: View {
    @ObservedObject var model: ProfilesViewModel
    let target: ProfileEditTarget

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String

    private let palette = [
        "#E53935", "#1E88E5", "#8E24AA", "#43A047",
        "#FB8C00", "#D81B60", "#00ACC1", "#5E35B1",
    ]

    init(model: ProfilesViewModel, target: ProfileEditTarget) {
        self.model = model
        self.target = target
        _name = State(initialValue: target.profile?.name ?? "")
        _colorHex = State(initialValue: target.profile?.avatarColorHex ?? "#E53935")
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Text(target.profile == nil ? "Add Profile" : "Edit Profile")
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Circle()
                    .fill(Color(hexString: colorHex) ?? Theme.Palette.accent)
                    .frame(width: 150, height: 150)
                    .overlay(
                        Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: 700)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

                HStack(spacing: Theme.Spacing.lg) {
                    ForEach(palette, id: \.self) { hex in
                        Button { colorHex = hex } label: {
                            Circle()
                                .fill(Color(hexString: hex) ?? .gray)
                                .frame(width: 70, height: 70)
                                .overlay(
                                    Circle().strokeBorder(
                                        Theme.Palette.textPrimary,
                                        lineWidth: hex == colorHex ? 5 : 0
                                    )
                                )
                        }
                        .buttonStyle(.card)
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

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "Profile" : trimmed
        if let profile = target.profile {
            model.updateProfile(profile, name: finalName, colorHex: colorHex) { dismiss() }
        } else {
            model.createProfile(name: finalName, colorHex: colorHex) { dismiss() }
        }
    }
}
