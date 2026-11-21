import SwiftUI
import SharedCore

// MARK: - Settings component kit (beta.15 §C, task C1)
//
// Every primitive below is a STOCK SwiftUI control that a native `List` styles for us — the C0
// spike (`SettingsKitPreview.swift`, commit 8c375436) proved tvOS 26's `List` renders the
// Settings.app look with zero custom chrome. Nothing here declares a `ButtonStyle`, a
// `hoverEffect`, a focus platter, or a focus-derived colour: the system draws the platter and
// flips the label colour scheme itself, which is exactly what the BUG-4/14/22/28/33/45/65
// white-on-white family of bugs came from hand-rolling.
//
// Colour rule: semantic only (`.primary` by inheritance, `.secondary` for subtitles/values).
// Never `Theme.Palette.textPrimary`-on-a-platter, never `onFocusPlatter`.
//
// Type scale (HIG 10-foot table, nothing under 23):
//   row title    → Body 29      (`Theme.Font.body`)
//   row subtitle → Caption1 25  (`Theme.Font.meta`)
//   section head → Caption2 23  (`Theme.Font.caption`)
//
// C4 (cleanup after C1-C3): the seven `*SettingsPane` files are fully converted now, so every
// legacy value+action shim, `SettingsInfoRow`, and `LanguageSelectRow` — all unreferenced once C3
// landed — are deleted from this file. The legacy focus-aware text-colour modifier moved to
// DesignSystem/FlatControlStyles.swift, since five non-Settings screens still draw the legacy
// full-width row button style and need it; those screens are out of this beta's scope.
// `settingsSection` survives here because `TmdbFilterEditorView` (also out of scope) still calls
// it.
//
// D11 visual pass (detail-settings-revamp Wave 2, Christian 2026-10-02 — the option 1 mockup):
// - V1 `SettingsSwitchToggleStyle`: the toggle row keeps a REAL `Toggle` (state, binding) drawn
//   as a Button carrying `.isToggle` and an "On"/"Off" value, with a capsule switch glyph. This is
//   the one Christian-directed exception to "stock Toggle only"; the glyph is decorative and the
//   focus platter is still the system's.
// - V2 `SettingsRestPlatter`: every kit row sits on the same subtle rounded fill at rest. The fill
//   lives INSIDE the control's label and drops to zero opacity whenever the row is on the system
//   platter, so it never paints anything over, under or instead of the focus platter. Nothing here
//   uses `listRowBackground` (on tvOS that slot is where the cell's own focus state can live).
// - V3 section headers are small uppercase letter-spaced captions in `.secondary`.
// - V4 picker / link rows end in `value ›` in `.secondary`. The `Menu { Picker }` stays with its
//   NATIVE, untinted pill; the shared rest fill (`SettingsRowChromeMetrics.restFill`) is matched to
//   that pill instead, so the picker row and every other row read as one family at rest. (Gate 2
//   sim pass: a `.tint` on the Menu also dimmed its FOCUSED pill to grey, see `tintsMenuPill`.)
// - Link rows hide the system disclosure chevron (`navigationLinkIndicatorVisibility(.hidden)`):
//   the kit draws its own `›` inside the platter, and the system one sat outside it, so the row
//   showed two chevrons and a platter that stopped short.

/// The three type-scale tokens the kit uses, named by role so a future scale change is one edit.
/// All three resolve to `Theme.Font` semantic tokens — no `Font.system(size:)` anywhere (HIG
/// hybrid contract, Typography row).
///
/// rc14 (Steven rc13 verdict, 2026-09-30): these are computed (`static var`), not `static let`.
/// A `static let` captured the resolved `SwiftUI.Font` once, so switching the typeface in
/// Appearance never reached Settings until a relaunch. `Theme.Font` tokens resolve the current
/// family on every read, so each row now picks up a switch immediately.
enum SettingsRowFont {
    /// Row titles — Body 29.
    static var title: SwiftUI.Font { Theme.Font.body }
    /// Row subtitles / trailing values — Caption1 25, regular weight (tester: Settings text "still
    /// feels too heavy"; `Theme.Font.meta` is medium weight, `Theme.Font.detail` is regular).
    static var subtitle: SwiftUI.Font { Theme.Font.detail }
    /// Section headers and footers — Caption2 23.
    static var sectionHeader: SwiftUI.Font { Theme.Font.caption }
}

// MARK: - Accent

/// How a row's leading SF Symbol is coloured.
enum SettingsRowIconTint {
    /// The theme accent while the row is at rest. The default.
    case accent
    /// Inherit whatever the row already paints — used by `SettingsDestructiveRow`, whose system
    /// red must not be overridden by the accent.
    case inherit
    /// A fixed colour, used by `SettingsDestructiveRow` while its platter is up.
    case fixed(Color)
}

/// Focus-aware theme accent for the two places the Settings kit is allowed to carry colour: a
/// row's leading glyph and an interactive row's trailing value.
///
/// The colour rule below still holds — this NEVER paints a fixed colour onto the focus platter.
/// At rest the element carries `Theme.Palette.accent`; focused, it hands the colour back to
/// `.primary` so the system's own light/dark label flip on the near-white platter applies. Pinning
/// the accent through focus is the BUG-4/33/45/65 family, and the White theme's near-white accent
/// (0xF5F5F5) would disappear into the platter outright.
///
/// BUG-65 container half: `\.isFocused` alone is not enough for a kit row hosted inside a CUSTOM
/// container (the Home Screen pane's collapsible groups) — that container is a single tvOS list
/// row, so its near-white platter is up whenever ANY of its children has focus, and an at-rest
/// accent then sits on white. `settingsRowPlatterActive` reports that; `settingsRowIsFocused`
/// reports the row's own device-proven `@FocusState`. Both default false, so the sidebar and the
/// six panes that publish neither are unchanged.
///
/// The `colorScheme` write-back is what makes handing the colour to `.primary` safe in those
/// containers: on a native list row the system flips the row's label appearance itself, but a
/// custom container's children never got that flip, so `.primary` resolved to the app's dark-mode
/// white — the failure this modifier is supposed to prevent. Writing the INHERITED value back in
/// the at-rest case (rather than a literal `.dark`) keeps it a true no-op: it can never clobber a
/// flip the system already performed.
struct SettingsAccentTint: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    @Environment(\.colorScheme) private var inheritedScheme

    private var onPlatter: Bool { isFocused || rowFocused || platterActive }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                onPlatter ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.Palette.accent)
            )
            .environment(\.colorScheme, onPlatter ? .light : inheritedScheme)
    }
}

extension View {
    /// Internal, not private: `SettingsView`'s sidebar builds its own `Label` rather than going
    /// through `SettingsRowLabel`, and its icon column is the most visible place the theme shows.
    func settingsAccentTint() -> some View { modifier(SettingsAccentTint()) }
}

// MARK: - Row chrome (D11 visual pass: V2 / V4)

/// One place for the rest-platter geometry, so a screenshot-driven tune is one edit.
///
/// The insets copy the native `Menu` label pill (Wave 0 sim capture `g1-settings-pane-homescreen-
/// row2.png`: ≈29 pt from pill edge to text, ≈65 pt tall for a single Body line), which is what
/// makes a toggle row's rest platter line up with a picker row's pill edge for edge.
enum SettingsRowChromeMetrics {
    /// Text inset from the rest platter's leading/trailing edge.
    static let horizontalInset: CGFloat = 28
    /// Text inset from the rest platter's top/bottom edge.
    static let verticalInset: CGFloat = 14
    /// Close to the system list focus platter's corner (≈28 pt in the Wave 0 capture).
    static let cornerRadius: CGFloat = 28
    /// Mockup `.s-row` asks for white at ~6 %; this is ~9.5 % so it MATCHES the native `Menu`
    /// label pill, which we can no longer retint (see `tintsMenuPill`). Measured on the sim: the
    /// native pill is ≈ rgb(36,37,37) over the rgb(13,13,13) pane background, i.e. white ≈ 9.7 %;
    /// the old 6 % fill rendered rgb(28,28,28), visibly darker than a picker row beside it.
    static let restFill = Color.white.opacity(0.095)
    /// V4: retint the native `Menu` label pill to `restFill`. OFF since the Gate 2 sim pass
    /// (`g2-pane-7-subtitles-row.png`): with the tint on, the FOCUSED picker row rendered a
    /// light-grey platter (≈ rgb(201,201,201)) instead of the white system focus platter every
    /// other row gets — the tint reaches the focused pill too, and a `.tint` cannot be scoped to
    /// the rest state from outside the Menu. The rest fill above is matched to the native pill
    /// instead. Leave this `false`; flipping it back reintroduces the grey focus platter.
    static let tintsMenuPill = false
}

/// V2 — the subtle rounded fill every kit row carries at rest.
///
/// "On the platter" means: the row's own focus (`\.isFocused`, populated inside a control's
/// label), the row's published `@FocusState` (BUG-65 device half), or a custom container's
/// platter (BUG-65 container half).
///
/// Drawn as a background of the row's content INSIDE the control's label and faded to zero the
/// moment that content is on the focus platter. Focused, the only thing behind the label is the
/// system platter; at rest the fill reads like the mockup. No fixed colour ever sits on the
/// platter (BUG-4/33/45/65 family). `explicitFocus` is for content that is not inside a single
/// control's label (the debrid key row: a field plus a button), where `\.isFocused` is not
/// populated.
struct SettingsRestPlatter: ViewModifier {
    var explicitFocus: Bool? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive

    private var onPlatter: Bool { (explicitFocus ?? isFocused) || rowFocused || platterActive }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SettingsRowChromeMetrics.horizontalInset)
            .padding(.vertical, SettingsRowChromeMetrics.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsRowChromeMetrics.cornerRadius, style: .continuous)
                    .fill(SettingsRowChromeMetrics.restFill)
                    .opacity(onPlatter ? 0 : 1)
            )
    }
}

/// Ink for the `Menu` picker row's label (V4).
///
/// Gate 2 sim pass, second round (`g2-pane-6-sources-row.png`): with the pill tint already off,
/// the FOCUSED picker row still rendered a light-grey (≈ rgb 201) platter where every Toggle /
/// Button / NavigationLink row gets the white system platter. The one thing left that only the
/// picker row did was this modifier pinning `Color.primary` and forcing `.light` on the label off
/// the Menu's OWN focus (`\.isFocused`). The Menu draws its focused pill and flips its label
/// itself, exactly like the other kit rows, so on its own focus this is now a no-op: no
/// foreground pin, the inherited scheme written straight back.
///
/// What it still does is the BUG-65 container half: inside a custom container that publishes
/// `settingsRowIsFocused` / `settingsRowPlatterActive`, the system never flips the children, so
/// the label (including the trailing `value ›`, which sits outside `SettingsRowLabel`'s own flip)
/// resolves against `.light` there. Both keys default false, so in a native settings `List` this
/// modifier changes nothing.
struct SettingsPlatterInk: ViewModifier {
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    @Environment(\.colorScheme) private var inheritedScheme

    private var onContainerPlatter: Bool { rowFocused || platterActive }

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, onContainerPlatter ? .light : inheritedScheme)
    }
}

/// Applies `SettingsRowChromeMetrics.tintsMenuPill` to a `Menu`.
private struct SettingsMenuPillTint: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if SettingsRowChromeMetrics.tintsMenuPill {
            content.tint(SettingsRowChromeMetrics.restFill)
        } else {
            content
        }
    }
}

/// Leading label + trailing accessory on the rest platter. Used as the LABEL of a Toggle-style
/// Button, a Button, a NavigationLink or the root category Button, so `\.isFocused` inside it is
/// the control's own focus.
struct SettingsRowChrome<Leading: View, Trailing: View>: View {
    var explicitFocus: Bool?
    let leading: Leading
    let trailing: Trailing

    init(
        explicitFocus: Bool? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.explicitFocus = explicitFocus
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            leading
            Spacer(minLength: Theme.Spacing.md)
            trailing
        }
        .modifier(SettingsRestPlatter(explicitFocus: explicitFocus))
    }
}

extension SettingsRowChrome where Trailing == EmptyView {
    init(explicitFocus: Bool? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(explicitFocus: explicitFocus, leading: leading, trailing: { EmptyView() })
    }
}

/// V4 — `value ›` in `.secondary` (mockup `.s-row .v`). Either half is optional: link rows and
/// root category rows show the chevron alone. The chevron is decorative and hidden from
/// accessibility, so the row's accessible label/value are unchanged.
struct SettingsTrailingValue: View {
    var value: String?
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let value, !value.isEmpty {
                Text(value)
                    .font(SettingsRowFont.subtitle)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(SettingsRowFont.subtitle)
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Shared row label

/// The title (+ optional subtitle, + optional SF Symbol) block every kit row puts on its leading
/// side. Deliberately sets NO foreground colour on the title: it inherits the list row's label
/// colour, which the system inverts on the focus platter for free. The GLYPH does take the theme
/// accent at rest (`SettingsAccentTint`) — it is one of only two coloured elements on the screen,
/// and the one that makes the chosen theme legible in Settings at all.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var iconTint: SettingsRowIconTint = .accent
    /// FEAT-50: the explainer description this row reports while focused (`nil` = none; the pane
    /// explainer then keeps showing the last described row, or the pane summary). Read from
    /// inside the label, the one place `\.isFocused` is populated — see
    /// `SettingsDescriptionModifier`.
    var descriptionID: SettingsDescriptionID? = nil

    /// BUG-65 container half. In a native list row this stays false and the block below is a
    /// no-op — the system inverts the row's label colour and the kit's colour rule holds as
    /// written. Inside a CUSTOM container (the Home Screen pane's collapsible groups) the
    /// container is one list row whose platter is up whenever any child has focus, and its
    /// children never got that inversion, so `.primary`/`.secondary` resolved white-on-white.
    /// See `settingsRowPlatterActive` / `settingsRowIsFocused` in FlatControlStyles.swift.
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    /// Written straight back when the platter is down, so this can never clobber a `colorScheme`
    /// flip the system already applied to a native row — the over-correction the kit's header
    /// comment warns about. Nothing here pins a fixed colour onto the platter either: the label
    /// stays semantic and only the SCHEME it resolves against changes.
    @Environment(\.colorScheme) private var inheritedScheme

    private var onPlatter: Bool { rowFocused || platterActive }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let systemImage {
                switch iconTint {
                case .accent:
                    Image(systemName: systemImage)
                        .font(SettingsRowFont.title)
                        .settingsAccentTint()
                case .inherit:
                    Image(systemName: systemImage)
                        .font(SettingsRowFont.title)
                case .fixed(let color):
                    Image(systemName: systemImage)
                        .font(SettingsRowFont.title)
                        .foregroundStyle(color)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(SettingsRowFont.title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .environment(\.colorScheme, onPlatter ? .light : inheritedScheme)
        .settingsDescription(descriptionID, title: title, systemImage: systemImage)
    }
}

// MARK: - Section

/// One grouped block of rows inside a settings `List` — a stock `Section` with a Caption2 header
/// and an optional Caption2 footer. Use inside a `List` only (that is where `Section` earns its
/// native header/footer treatment).
struct SettingsSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    /// Unlabelled convenience so a call reads `SettingsSection("Playback") { … }`.
    init(_ title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, content: content)
    }

    var body: some View {
        Section {
            content
        } header: {
            if let title, !title.isEmpty {
                Text(title)
                    .font(SettingsRowFont.sectionHeader)
                    // V3 (mockup `.s-row.hd`): small uppercase, letter-spaced, secondary. Never on
                    // a platter (headers do not take focus), so a semantic colour is safe here.
                    .textCase(.uppercase)
                    .tracking(2)
                    .foregroundStyle(.secondary)
                    // The focused row's platter scales up past the row bounds and was covering the
                    // header at the stock distance (device pass 2026-08-28: "Account" clipped behind
                    // the focused Sign Out row). `sm` of extra bottom padding keeps the header clear
                    // of the platter without visibly loosening the section rhythm.
                    .padding(.bottom, Theme.Spacing.sm)
            }
        } footer: {
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(SettingsRowFont.sectionHeader)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Set on the settings detail `List` (task C2) so the transitional `settingsSection(_:)` helper
/// below knows it is inside a native list and can emit a real `Section`. Default `false` keeps
/// every other caller — notably `TmdbFilterEditorView`, which stacks the same helper inside a
/// plain `ScrollView`/`VStack` and is NOT part of the Settings conversion — on the pre-C1
/// hand-rolled layout, byte-for-byte.
private struct SettingsUsesNativeListKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsUsesNativeList: Bool {
        get { self[SettingsUsesNativeListKey.self] }
        set { self[SettingsUsesNativeListKey.self] = newValue }
    }
}

/// LEGACY SHIM (C3) — the free function every `*SettingsPane` (and `TmdbFilterEditorView`) still
/// calls. Inside the settings detail `List` it becomes a native `SettingsSection`; anywhere else
/// it keeps the old title + `.focusSection()` stack so unconverted screens are untouched.
/// C3 replaces the pane call sites with `SettingsSection`; C4 deletes this once
/// `TmdbFilterEditorView` has its own copy or is converted too.
func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    LegacySettingsSection(title: title, content: content())
}

private struct LegacySettingsSection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.settingsUsesNativeList) private var usesNativeList

    var body: some View {
        if usesNativeList {
            SettingsSection(title: title) { content }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                content
            }
            .focusSection()
        }
    }
}

// MARK: - Toggle

/// V1 (D11, Christian-directed exception to the native-Toggle-only rule): the row is drawn as a
/// `Button` that flips `configuration.isOn` — inside a settings `List` that is the same system
/// list-row button as `SettingsActionRow`, so the focus platter and the label inversion are still
/// the system's. The trailing capsule glyph is decorative (`accessibilityHidden`).
///
/// Accessibility: the Button itself carries the state — `.accessibilityValue("On"/"Off")` plus the
/// `.isToggle` trait — so VoiceOver announces it as a toggle with its state, and the UI test
/// harness's state-aware toggle helper reads that exact "On"/"Off" value (beta.13 wave 2). This is
/// the row's only accessibility value; `SettingsToggleRow` does not add a second one. (An
/// `accessibilityRepresentation` Toggle was tried first and exposed an EMPTY value, review round 1.)
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            SettingsRowChrome {
                configuration.label
            } trailing: {
                SettingsSwitchGlyph(isOn: configuration.isOn)
            }
        }
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// The capsule switch (mockup `.toggle`). On: green track `#34C759`, white knob right. Off: grey
/// track, white knob left. On the white focus platter the off track darkens so it stays visible;
/// the on track stays green (D11). Read inside the Button's label, where `\.isFocused` is the
/// row's own focus.
struct SettingsSwitchGlyph: View {
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onPlatter: Bool { isFocused || rowFocused || platterActive }

    static let trackWidth: CGFloat = 72
    static let trackHeight: CGFloat = 42
    static let knobInset: CGFloat = 4
    static let onTrack = Color(hex: 0x34C759)

    private var track: Color {
        if isOn { return Self.onTrack }
        return onPlatter ? Color.black.opacity(0.28) : Color.white.opacity(0.26)
    }

    var body: some View {
        Capsule()
            .fill(track)
            .frame(width: Self.trackWidth, height: Self.trackHeight)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: Self.trackHeight - 2 * Self.knobInset,
                        height: Self.trackHeight - 2 * Self.knobInset
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
                    .padding(Self.knobInset)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isOn)
            .accessibilityHidden(true)
    }
}

/// A real `Toggle` (binding, VoiceOver state) drawn with `SettingsSwitchToggleStyle`.
struct SettingsToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let isOn: Binding<Bool>
    private let descriptionID: SettingsDescriptionID?

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>, descriptionID: SettingsDescriptionID? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
        self.descriptionID = descriptionID
    }

    var body: some View {
        Toggle(isOn: isOn) {
            SettingsRowLabel(title: title, subtitle: subtitle, descriptionID: descriptionID)
        }
        // The "On"/"Off" accessibility value the UITest harness reads comes from the style's
        // Button (review r2 #6: one value, not two).
        .toggleStyle(SettingsSwitchToggleStyle())
    }
}

// MARK: - Picker

/// A choice row: `Menu { Picker }` over a `LabeledContent` label — the native grey pill that pops
/// the system radio-checkmark popover (C0-proven). Replaces the horizontal chip rows.
struct SettingsPickerRow<T: Hashable>: View {
    let title: String
    var subtitle: String?
    let selection: Binding<T>
    let options: [T]
    var descriptionID: SettingsDescriptionID?
    /// A menu item's text.
    let label: (T) -> String
    /// The closed row's value for the selection; nil uses `label`. Set when the row shows a resolved
    /// value that two items could share (Disk Cache: "Up to 10 GB" for both a clamped 20 GB and Maximum).
    let value: ((T) -> String)?

    init(
        title: String,
        subtitle: String? = nil,
        selection: Binding<T>,
        options: [T],
        descriptionID: SettingsDescriptionID? = nil,
        label: @escaping (T) -> String,
        value: ((T) -> String)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selection = selection
        self.options = options
        self.descriptionID = descriptionID
        self.label = label
        self.value = value
    }

    var body: some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            // The pill tint below must not reach the popover's checkmarks: `nil` restores the
            // system default for the menu content.
            .tint(nil)
        } label: {
            // `LabeledContent` stays so the Menu's accessible label/value are unchanged (UI tests
            // and VoiceOver read title + value, the chevron is hidden).
            LabeledContent {
                // V4: `value ›` in `.secondary` (was the accent value). Inherits the Menu's own
                // label ink, like the title.
                SettingsTrailingValue(value: (value ?? label)(selection.wrappedValue))
            } label: {
                SettingsRowLabel(title: title, subtitle: subtitle, descriptionID: descriptionID)
            }
            // Container-only scheme flip (BUG-65); on the Menu's own focus the system's label
            // inversion is left alone so the focused pill is the stock white platter. See
            // `SettingsPlatterInk`.
            .modifier(SettingsPlatterInk())
        }
        // V2/V4: the native pill IS this row's platter (same insets; `restFill` is matched to its
        // colour), so no extra `SettingsRestPlatter` here. Untinted (`tintsMenuPill` is false), so
        // the focused pill is the stock white platter.
        .modifier(SettingsMenuPillTint())
    }
}

// MARK: - List picker (long lists)

/// A choice row for a LONG list (the 75–80-entry language pickers): a `NavigationLink` row
/// (`title`, `value ›`) that pushes `SettingsListPickerPage`, where the current value is checked
/// and focused.
///
/// FEAT-84 sim check (`docs/research/wave3b-sim-2026-10-21/wb-5b-size-menu-open.png`): a tvOS
/// `Menu { Picker }` opens with focus on its FIRST entry, not on the checked one (the Size menu,
/// Medium checked, opened on Small). With Zulu checked in an 80-entry menu that is 79 presses
/// back to it, so the language rows use this pushed page instead (the Custom Posters shape: a
/// pushed `List` of kit rows). Short pickers stay `SettingsPickerRow`.
struct SettingsListPickerRow: View {
    let title: String
    var subtitle: String?
    let selection: Binding<String>
    let options: [String]
    var descriptionID: SettingsDescriptionID?
    let label: (String) -> String

    init(
        title: String,
        subtitle: String? = nil,
        selection: Binding<String>,
        options: [String],
        descriptionID: SettingsDescriptionID? = nil,
        label: @escaping (String) -> String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selection = selection
        self.options = options
        self.descriptionID = descriptionID
        self.label = label
    }

    /// BUG-219: set by the pushed page as it leaves; the row takes focus back one runloop later.
    @State private var reclaimFocus = false

    var body: some View {
        NavigationLink {
            SettingsListPickerPage(title: title, selection: selection, options: options, label: label)
                .onDisappear { reclaimFocus = true }
        } label: {
            SettingsRowChrome {
                SettingsRowLabel(title: title, subtitle: subtitle, descriptionID: descriptionID)
            } trailing: {
                SettingsTrailingValue(value: label(selection.wrappedValue))
            }
        }
        // One chevron, inside the platter (see `SettingsLinkRow`). No `.accessibilityValue`:
        // `SettingsTrailingValue` already renders the value as accessible text, so VoiceOver
        // would read it twice (review r1 P3-4).
        .navigationLinkIndicatorVisibility(.hidden)
        .modifier(ReclaimsFocusAfterPop(pending: $reclaimFocus))
    }
}

/// BUG-219 (2026-10-22, the Apple TV): Menu from a pushed Settings page landed focus on the pane's
/// FIRST realized row, not on the row that pushed the page (Audio → the language list → Menu came
/// back on Bold; the simulator came back on Audio). The pane `List` has no focus state of its own,
/// so the return relied on tvOS's focus memory alone, which the root pane already records as
/// unreliable (`SettingsRootView`'s landing correction). Same rule as `ClaimsFocusAfterSwap`
/// (`FocusRow.swift`): a flag the departing view sets, consumed once, the claim one runloop late so
/// it lands after the engine's own fallback. `onChange`, not `onAppear`: a List cell does not
/// re-fire `onAppear` on a pop.
struct ReclaimsFocusAfterPop: ViewModifier {
    @Binding var pending: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: pending) { _, now in
                guard now else { return }
                pending = false
                DispatchQueue.main.async { focused = true }
            }
    }
}

/// The pushed page behind `SettingsListPickerRow`: one kit row per option, the current one
/// checked. Select stores the option and pops back to the row that pushed the page.
///
/// Focus starts on the checked row. The `List` is lazy, so a row far down the list does not exist
/// until it is scrolled to, and focus alone cannot reach it (sim: with no scroll, focus opened on
/// None). On appear the page scrolls the checked row into view (top rows: no scroll; middle rows:
/// centred; the last half-screen: to the bottom; a `defaultScrollAnchor(.bottom)` start is ignored
/// by a tvOS `List`), then claims focus one runloop later, with `.defaultFocus` at
/// `.userInitiated` priority for the engine's own initial pick. The push transition can still hand
/// initial focus to the first row in view after that claim (it did with Zulu), so the page looks
/// again once the push has settled and re-claims if focus is on another row.
///
/// The page scrolls ONCE, before any focus lands. The settle check does nothing when the checked
/// row already has focus, and when it re-claims it only moves focus: the row is still on screen
/// from the first scroll, so the list never moves under a committed focus. It scrolls again only
/// if the checked row has left the realized range (`checkedRowOnScreen`), the one case focus
/// alone cannot reach.
///
/// Sim evidence (`docs/research/wave3b-sim-2026-10-21/wb-10*`, `wb-11*`, `wb-12*`): the page
/// opens focused on the checked row for None, English and Zulu. Known quirk before review r1,
/// last half-screen only: from a row focused this way the FIRST Up jumped five or six rows (the
/// focus engine's frames sat ~460 pt below where the rows are drawn until focus moved once), then
/// every press moved one row. A walk down to Zulu by hand did not show it. Zulu was the case where
/// the transition took the first claim, so focus arrived through the re-claim, which then scrolled
/// the end-clamped list a second time under it; review r1 P3-1 dropped that second scroll. Not yet
/// re-checked: the device pass settles whether the jump is gone.
struct SettingsListPickerPage: View {
    let title: String
    let selection: Binding<String>
    let options: [String]
    let label: (String) -> String

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?
    /// Whether the checked row's cell is realized (between its `onAppear` and `onDisappear`); only
    /// that one row writes it, so the page body is not re-evaluated as other rows scroll by.
    @State private var checkedRowOnScreen = false

    /// About half a screen of rows (a kit row is ~93 pt of a 1080 pt screen).
    private static let edgeRows = 6

    /// Where the checked row sits in the list (see the type comment).
    private enum Placement { case top, middle, end }

    private func placement(of value: String) -> Placement {
        let index = options.firstIndex(of: value) ?? 0
        if index < Self.edgeRows { return .top }
        if options.count - index <= Self.edgeRows { return .end }
        return .middle
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(options, id: \.self) { option in
                    let isChecked = option == selection.wrappedValue
                    Button {
                        if !isChecked { selection.wrappedValue = option }
                        dismiss()
                    } label: {
                        SettingsRowChrome {
                            SettingsRowLabel(title: label(option))
                        } trailing: {
                            if isChecked {
                                Image(systemName: "checkmark")
                                    .font(SettingsRowFont.subtitle)
                                    .fontWeight(.semibold)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(isChecked ? .isSelected : [])
                    .focused($focused, equals: option)
                    .id(option)
                    .onAppear { if isChecked { checkedRowOnScreen = true } }
                    .onDisappear { if isChecked { checkedRowOnScreen = false } }
                }
            }
            .defaultFocus($focused, selection.wrappedValue, priority: .userInitiated)
            .onAppear { claimCheckedRow(proxy) }
        }
        // Pushed stack destinations do not inherit the root's background (`SettingsView`), so the
        // page draws its own: OLED True Black and the theme background reach it (review r1 P2-1,
        // the BUG-214 defect).
        .background(Theme.Palette.background.ignoresSafeArea())
        .navigationTitle(title)
    }

    /// Scrolls the checked row into view, then focuses it one runloop later. After the push
    /// transition (0.45 s) it looks once more: nothing to do when the checked row has focus or
    /// when focus has left the page (nil, the page is closing); when focus sits on another row it
    /// moves to the checked row WITHOUT a second scroll (see the type comment), unless that row is
    /// no longer realized.
    private func claimCheckedRow(_ proxy: ScrollViewProxy) {
        let current = selection.wrappedValue
        scrollIntoView(current, proxy)
        DispatchQueue.main.async { focused = current }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            // Re-claim only when focus sits on ANOTHER row of this page (the push transition's
            // pick). Nil means focus has left the page (Menu or Select inside the window, the page
            // is closing): never write focus into a page that is being popped (review r2 P3-1).
            guard let now = focused, now != current else { return }
            if checkedRowOnScreen {
                focused = current
            } else {
                scrollIntoView(current, proxy)
                DispatchQueue.main.async { focused = current }
            }
        }
    }

    private func scrollIntoView(_ value: String, _ proxy: ScrollViewProxy) {
        switch placement(of: value) {
        case .top: break
        case .middle: proxy.scrollTo(value, anchor: .center)
        case .end: proxy.scrollTo(value, anchor: .bottom)
        }
    }
}

// MARK: - Value

/// A read-only title/value row — stock `LabeledContent`. Not focusable by default (HIG: static
/// content does not take focus); every pane that uses it also carries at least one focusable row,
/// which is the BUG-47 requirement.
///
/// FEAT-50: `focusable: true` makes the row an INERT focus stop: a no-op `Button` (Select does
/// nothing) whose label is the kit chrome. It exists for panes whose rows are all read-only
/// values (the new About pane): without it such a pane has no focusable row, which breaks BUG-47
/// and leaves the explainer nothing to describe. Review r1 (`g2-pane-8-about-row.png`): the
/// earlier bare `.focusable()` took focus but drew no platter, so the explainer named a row that
/// did not look focused. As a Button label it gets the system focus platter, the label ink flip
/// and the rest-platter fade, like every other kit row.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var subtitle: String?
    var systemImage: String?
    var descriptionID: SettingsDescriptionID?
    var focusable: Bool

    init(
        title: String,
        value: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        descriptionID: SettingsDescriptionID? = nil,
        focusable: Bool = false
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.descriptionID = descriptionID
        self.focusable = focusable
    }

    var body: some View {
        if focusable {
            Button(action: {}) {
                SettingsRowChrome {
                    SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, descriptionID: descriptionID)
                } trailing: {
                    SettingsTrailingValue(value: value, showsChevron: false)
                }
            }
            // Review r2 #7: Select does nothing, so VoiceOver must not call it a button. It stays
            // focusable and keeps the system platter.
            .accessibilityRemoveTraits(.isButton)
        } else {
            content
        }
    }

    private var content: some View {
        LabeledContent {
            // V4: same treatment as a picker value, without the chevron (nothing to open).
            SettingsTrailingValue(value: value, showsChevron: false)
        } label: {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, descriptionID: descriptionID)
        }
        .modifier(SettingsRestPlatter())
    }
}

// MARK: - Link

/// A pushed sub-page row — stock `NavigationLink` inside the settings `NavigationStack`. Menu on
/// the pushed page pops exactly one level, back to this list.
struct SettingsLinkRow<Destination: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var descriptionID: SettingsDescriptionID?
    @ViewBuilder let destination: () -> Destination

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        descriptionID: SettingsDescriptionID? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.descriptionID = descriptionID
        self.destination = destination
    }

    /// BUG-219: see `ReclaimsFocusAfterPop`.
    @State private var reclaimFocus = false

    var body: some View {
        NavigationLink {
            destination()
                .onDisappear { reclaimFocus = true }
        } label: {
            SettingsRowChrome {
                SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, descriptionID: descriptionID)
            } trailing: {
                // V4: a link has no value, so the chevron alone.
                SettingsTrailingValue(value: nil)
            }
        }
        // Gate 2 sim pass (`g2-pane-1-services-row.png`): inside a `List` the system adds its own
        // disclosure chevron OUTSIDE the label, so the row showed two chevrons and the rest
        // platter stopped short of the row's trailing edge. Hide the system one; the kit's `›`
        // inside the platter is the only chevron, and the label (with its platter) spans the row.
        .navigationLinkIndicatorVisibility(.hidden)
        .modifier(ReclaimsFocusAfterPop(pending: $reclaimFocus))
    }
}

// MARK: - Action

/// A plain `Button` in default list-row style: no `ButtonStyle`, no chevron glyph (the system
/// draws the row treatment). `systemImage` is optional and only kept because pre-C3 panes pass it.
struct SettingsActionRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var descriptionID: SettingsDescriptionID?
    let action: () -> Void

    init(
        title: String,
        subtitle: String = "",
        systemImage: String? = nil,
        descriptionID: SettingsDescriptionID? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle.isEmpty ? nil : subtitle
        self.systemImage = systemImage
        self.descriptionID = descriptionID
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRowChrome {
                SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, descriptionID: descriptionID)
            }
        }
    }
}

/// Destructive variant — `Button(role: .destructive)`, so the system paints it red and VoiceOver
/// announces it. Pair with the screen's `.alert` confirmation (SettingsView already owns those).
struct SettingsDestructiveRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var descriptionID: SettingsDescriptionID?
    let action: () -> Void

    init(
        title: String,
        subtitle: String = "",
        systemImage: String? = nil,
        descriptionID: SettingsDescriptionID? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle.isEmpty ? nil : subtitle
        self.systemImage = systemImage
        self.descriptionID = descriptionID
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            SettingsRowChrome {
                SettingsDestructiveLabel(
                    title: title,
                    subtitle: subtitle,
                    systemImage: systemImage,
                    descriptionID: descriptionID
                )
            }
        }
    }
}

/// The destructive row's colour choice, pure so it can be unit tested; the label applies exactly
/// what this returns (one source of truth). At rest the title is `.red` (systemRed, what the
/// destructive role draws in the dark scheme) and the glyph inherits it. On the always-white focus
/// platter the red title washes out, so the title flips to `.primary` (resolved dark: the label
/// switches to the `.light` scheme there) and the glyph takes a dark red, 5.4:1 on white.
nonisolated enum SettingsDestructiveInk {
    /// `title`: the label's foreground for the state. `glyph`: the symbol colour (applied on the
    /// platter; at rest the symbol inherits `title`, the same `.red`).
    static func colors(focused: Bool) -> (title: Color, glyph: Color) {
        focused ? (Color.primary, platterRed) : (Color.red, Color.red)
    }

    static let platterRed = Color(red: 0xD7 / 255, green: 0, blue: 0x15 / 255)
}

/// Reads focus from inside the button label (the one place `\.isFocused` is populated) and
/// applies `SettingsDestructiveInk`. Same flip the other kit rows use on the platter: the
/// `.light` scheme so `.primary` / `.secondary` resolve dark.
private struct SettingsDestructiveLabel: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var descriptionID: SettingsDescriptionID?

    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    @Environment(\.colorScheme) private var inheritedScheme

    private var onPlatter: Bool { isFocused || rowFocused || platterActive }

    var body: some View {
        let ink = SettingsDestructiveInk.colors(focused: onPlatter)
        SettingsRowLabel(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            iconTint: onPlatter ? .fixed(ink.glyph) : .inherit,
            descriptionID: descriptionID
        )
        .foregroundStyle(ink.title)
        .environment(\.colorScheme, onPlatter ? .light : inheritedScheme)
    }
}

// MARK: - Key entry

/// Manual API-key entry (debrid fallback, MDBList, TMDB and similar key-gated services). Shared
/// between the Services pane's per-provider debrid rows and the Sources pane's TMDB and MDBList
/// rows. C1: the hand-rolled `glassEffect` capsule around the field is gone — inside a native
/// `List` the row already has the system's own background and focus treatment, and glass belongs
/// to floating chrome (HIG hybrid contract, Overlay surfaces).
///
/// BUG-213 (GitHub #10): this used to be ONE List row holding the field and the Save button, and a
/// tvOS List row is one focus target (the BUG-197 diagnosis), so the two highlighted as one block
/// and Select did not reach the field. The `Group` body now yields TWO List rows, the shape
/// `PluginRepoEntryRow` and `BadgeUrlEntryRow` use: the key field row (its rest platter follows the
/// field's `@FocusState`; a `TextField` has no label to read `\.isFocused` from) and a Save Key kit
/// row. `@State key` stays owned by this struct, so both rows share it.
///
/// Focus hand-off: at every call site Save swaps both rows out for a Remove (or Connected) row and
/// Remove swaps them back, so the focused control leaves the hierarchy both ways. The call site
/// arms `ClaimsFocusAfterSwap` on the row that replaces these two from its `onSave` closure;
/// `fieldFocusHandOff` is the reverse direction, armed by the call site's Remove so the field takes
/// focus when the rows come back. Same rule as `ClaimsFocusAfterSwap` (gated on the flag, never on
/// appearance alone, cleared once used, claimed one runloop late), run on the field's own
/// `@FocusState` because the field already binds it.
struct DebridKeyEntryRow: View {
    let providerName: String
    var placeholder: String?
    /// FEAT-50. Declared between `placeholder` and `onSave` so trailing-closure call sites still
    /// compile. A `TextField` has no label descendant to read `\.isFocused` from, so the field
    /// reports through its own `@FocusState` (`focused:` variant of the modifier).
    var descriptionID: SettingsDescriptionID? = nil
    /// The reverse hand-off (Remove → field); see the type comment. Also declared before `onSave`.
    var fieldFocusHandOff: Binding<Bool> = .constant(false)
    let onSave: (String) -> Void
    @State private var key = ""
    @FocusState private var fieldFocused: Bool

    private var fieldPlaceholder: String {
        placeholder ?? String(localized: "Or paste your \(providerName) API key")
    }

    var body: some View {
        Group {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField(fieldPlaceholder, text: $key)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
                    .focused($fieldFocused)
            }
            .modifier(SettingsRestPlatter(explicitFocus: fieldFocused))
            .settingsDescription(descriptionID, title: fieldPlaceholder, systemImage: "key", focused: fieldFocused)
            .onAppear {
                guard fieldFocusHandOff.wrappedValue else { return }
                fieldFocusHandOff.wrappedValue = false
                DispatchQueue.main.async { fieldFocused = true }
            }

            // Not disabled while the field is empty: saving clears the field, which disabled the
            // focused button and threw focus elsewhere. The action already ignores an empty key.
            SettingsActionRow(
                title: String(localized: "Save Key"),
                systemImage: "checkmark",
                descriptionID: descriptionID
            ) {
                if !key.isEmpty {
                    onSave(key)
                    key = ""
                }
            }
        }
    }
}

// MARK: - Legacy support (deleted in C4 once nothing references it)
//
// The legacy focus-aware text-colour modifier moved out to DesignSystem/FlatControlStyles.swift
// in C4 — it is still used by five non-Settings screens (`StreamPickerView`, `DetailView`,
// `CloudLibraryUI`, `AddonsView`, `TmdbFilterEditorView`) that draw the legacy full-width row
// button style, so it belongs next to `SettingsRowButtonStyle`/`RowAccentTint` rather than in the
// Settings kit, which no longer uses it anywhere.

/// Language options for the audio / subtitle preference pickers, their two fallback pickers and
/// the TMDB metadata-language picker (Subtitles & Audio pane, Sources pane).
///
/// FEAT-84 (GitHub #10 item 4): the language block is the shared `AvailableLanguageOptionCodes`,
/// mobile's own list: 78 tags, the 74 bare ISO 639-1 codes plus `zh-CN`, `zh-TW`, `pt-BR` and
/// `es-419`. It is sorted A–Z by label, with each picker's sentinels pinned on top. Rules:
/// - An option's CODE is `normalizeLanguageCode` of the shared tag. The shared setters store the
///   normalized form (`pt-BR` → `pt-br`), so a raw tag would never show as selected.
/// - Its LABEL comes from the original tag, in the localization the app runs in
///   (`Bundle.main.preferredLocalizations`), not `Locale.current`: a device language the app does
///   not ship would otherwise put, say, Japanese names into an English screen. The first letter
///   is capitalised with that locale (French returns "anglais"), and the sort uses that locale's
///   collation. `zh-CN` / `zh-TW` are labelled through `zh-Hans` / `zh-Hant` (Chinese, Simplified
///   / Traditional) and keep their codes.
/// - TMDB takes the 74 bare codes only: the metadata-language readback keeps the primary subtag
///   (`SettingsViewModel.tmdbLanguageSelection`), so a regional row would leave the checkmark on
///   the wrong row, and TMDB has no `es-419`.
/// - The lists are built once (`static let`: a UI-language change relaunches the app), and labels
///   come from one code → name dictionary, since the Menu draws a label for every entry.
/// Sentinel codes are the shared `AudioLanguageOption` / `SubtitleLanguageOption` constants; ""
/// is the fallback pickers' None (the shared setters take nil for it).
nonisolated enum LanguageOptions {
    typealias Option = (name: String, code: String)

    // MARK: Pure builders (unit-tested with an injected locale)

    /// The 78 shared tags, in the shared order.
    static var sharedTags: [String] { PlayerLanguageOptionCodesKt.AvailableLanguageOptionCodes }

    /// The stored form of a shared tag: what the shared setters write, so what a picker reads back.
    static func code(forTag tag: String) -> String {
        PlayerLanguagePreferencesKt.normalizeLanguageCode(language: tag) ?? tag.lowercased()
    }

    /// `tag`'s language name in `locale`, first letter capitalised with that locale; the tag itself
    /// when the locale has no name for it.
    static func displayName(forTag tag: String, locale: Locale) -> String {
        let labelTag: String
        switch tag.lowercased() {
        case "zh-cn": labelTag = "zh-Hans"
        case "zh-tw": labelTag = "zh-Hant"
        default: labelTag = tag
        }
        guard let name = locale.localizedString(forIdentifier: labelTag), !name.isEmpty else { return tag }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The A–Z language block for `tags` (no sentinels), labelled and collated in `locale`
    /// (`localizedStandardCompare`'s options, with the locale passed in rather than the current one).
    static func buildLanguages(tags: [String], locale: Locale) -> [Option] {
        tags.map { (name: displayName(forTag: $0, locale: locale), code: code(forTag: $0)) }
            .sorted {
                $0.name.compare(
                    $1.name,
                    options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering],
                    locale: locale
                ) == .orderedAscending
            }
    }

    /// `codes`, plus `current` right after the `pinned` sentinels when it is not one of them: a
    /// value mobile synced that tvOS has no row for (audio `default`, subtitle `forced`). The
    /// Menu's Picker then still has a tag for its selection and shows it checked and labelled.
    static func codes(_ codes: [String], keeping current: String, pinned: Int) -> [String] {
        guard !codes.contains(current) else { return codes }
        var out = codes
        out.insert(current, at: min(pinned, out.count))
        return out
    }

    // MARK: Lists, built once in the app's UI locale

    /// The localization the app runs in (see the type comment).
    static let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    private static let device: Option = (String(localized: "Device"), AudioLanguageOption.shared.DEVICE)
    /// Its own catalog key (review r1 P3-5): the bare "Original" key is the TMDB sort order's
    /// ("Ordre original" in French), not a language.
    private static let original: Option = (
        String(
            localized: "settings.language.original",
            defaultValue: "Original",
            comment: "Audio language choice: play the title's original-language audio track. Not the sort order."
        ),
        AudioLanguageOption.shared.ORIGINAL
    )
    private static let off: Option = (String(localized: "Off"), SubtitleLanguageOption.shared.NONE)
    private static let none: Option = (String(localized: "None"), "")

    /// All 78 languages, A–Z.
    static let languages: [Option] = buildLanguages(tags: sharedTags, locale: uiLocale)
    /// The 74 bare codes, A–Z (TMDB).
    static let bareLanguages: [Option] = buildLanguages(tags: sharedTags.filter { !$0.contains("-") }, locale: uiLocale)

    static let audio: [Option] = [device, original] + languages
    static let subtitle: [Option] = [off, device] + languages
    /// TMDB metadata language: Device = no stored language (the shared repo derives it from the
    /// Apple TV's language).
    static let tmdbMetadata: [Option] = [device] + bareLanguages
    /// Fallback Audio Language: None, Original (mobile parity), then the languages.
    static let fallbackAudio: [Option] = [none, original] + languages
    /// Fallback Subtitle Language: None, then the languages.
    static let fallbackSubtitle: [Option] = [none] + languages

    static let audioCodes = audio.map(\.code)
    static let subtitleCodes = subtitle.map(\.code)
    static let tmdbMetadataCodes = tmdbMetadata.map(\.code)
    static let fallbackAudioCodes = fallbackAudio.map(\.code)
    static let fallbackSubtitleCodes = fallbackSubtitle.map(\.code)

    /// Every code any list offers, plus the sentinels mobile can sync that tvOS offers no row for.
    /// Each code has one label in every list (`none` is Off, "" is None).
    static let names: [String: String] = {
        var names = [
            AudioLanguageOption.shared.DEFAULT: String(localized: "Default"),
            SubtitleLanguageOption.shared.FORCED: String(localized: "Forced"),
        ]
        for option in audio + subtitle + fallbackAudio + tmdbMetadata where names[option.code] == nil {
            names[option.code] = option.name
        }
        return names
    }()

    /// The label for a stored language code: the lists' name, else the UI locale's name for it,
    /// else the code.
    static func name(forCode code: String) -> String {
        names[code] ?? displayName(forTag: code, locale: uiLocale)
    }

    /// Label lookup in a short local table (the Sources pane's Library / Watch Progress Source
    /// pickers use it with their own tables).
    static func name(forCode code: String, in options: [Option]) -> String {
        options.first { $0.code == code }?.name ?? code
    }
}
