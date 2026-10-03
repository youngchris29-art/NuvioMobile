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
// - V1 `SettingsSwitchToggleStyle`: the toggle row keeps a REAL `Toggle` (state, binding, the
//   `.switch` accessibility element the UI tests query) but draws a capsule switch glyph. This is
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

/// Pins the ink of content whose control may carry a `.tint` (the retinted `Menu` pill, V4):
/// `Color.primary` resolved against the INHERITED scheme at rest, and against `.light` on the
/// platter — the same device-proven flip `SettingsAccentTint` uses. Hierarchical `.secondary`
/// children (row subtitles, the trailing value) then resolve relative to `Color.primary`, never
/// relative to the tint. Not applied to Toggle / Button / NavigationLink rows: those keep the
/// system's own label inversion untouched.
struct SettingsPlatterInk: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    @Environment(\.colorScheme) private var inheritedScheme

    private var onPlatter: Bool { isFocused || rowFocused || platterActive }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.primary)
            .environment(\.colorScheme, onPlatter ? .light : inheritedScheme)
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
/// Accessibility: `accessibilityRepresentation` hands VoiceOver and XCUITest a REAL `Toggle`
/// (forced to `.automatic` so the representation never recurses into this style), so the element
/// keeps its `.switch` type and on/off state — the UI test harness queries `app.switches`. The
/// `SettingsToggleRow`'s own `.accessibilityValue("On"/"Off")` still sits on top.
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
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.automatic)
        }
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
        .toggleStyle(SettingsSwitchToggleStyle())
        // Kept from the pre-C1 row: the UITest harness's state-aware toggle helper reads this
        // exact value (beta.13 wave 2), and it is a friendlier VoiceOver value than "1"/"0".
        .accessibilityValue(isOn.wrappedValue ? Text("On") : Text("Off"))
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
    let label: (T) -> String

    init(
        title: String,
        subtitle: String? = nil,
        selection: Binding<T>,
        options: [T],
        descriptionID: SettingsDescriptionID? = nil,
        label: @escaping (T) -> String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selection = selection
        self.options = options
        self.descriptionID = descriptionID
        self.label = label
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
                // V4: `value ›` in `.secondary` (was the accent value). Platter-flipped through
                // `SettingsPlatterInk` below.
                SettingsTrailingValue(value: label(selection.wrappedValue))
            } label: {
                SettingsRowLabel(title: title, subtitle: subtitle, descriptionID: descriptionID)
            }
            // The Menu pill may carry the rest-fill tint; pin the label's ink so the tint never
            // reaches the text.
            .modifier(SettingsPlatterInk())
        }
        // V2/V4: the native pill IS this row's platter (same insets; `restFill` is matched to its
        // colour), so no extra `SettingsRestPlatter` here. Untinted (`tintsMenuPill` is false), so
        // the focused pill is the stock white platter.
        .modifier(SettingsMenuPillTint())
    }
}

// MARK: - Value

/// A read-only title/value row — stock `LabeledContent`. Not focusable by default (HIG: static
/// content does not take focus); every pane that uses it also carries at least one focusable row,
/// which is the BUG-47 requirement.
///
/// FEAT-50: `focusable: true` makes the row an INERT focus stop (`.focusable()`, Select does
/// nothing — the same pattern the About pane's readout anchor uses). It exists for panes whose
/// rows are all read-only values (the new About pane): without it such a pane has no focusable
/// row, which breaks BUG-47 and leaves the explainer nothing to describe.
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
            content.focusable()
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

    var body: some View {
        NavigationLink {
            destination()
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
            // `.inherit`: the destructive red is the row's whole point (HIG), and it stays red
            // under every theme. An accent glyph here would fight it.
            SettingsRowChrome {
                SettingsRowLabel(
                    title: title,
                    subtitle: subtitle,
                    systemImage: systemImage,
                    iconTint: .inherit,
                    descriptionID: descriptionID
                )
            }
        }
    }
}

// MARK: - Key entry

/// Manual API-key entry row (debrid fallback, MDBList, and similar key-gated services). Shared
/// between the Account & Services pane's per-provider debrid rows and the Content Sources pane's
/// MDBList row. C1: the hand-rolled `glassEffect` capsule around the field is gone — inside a
/// native `List` the row already has the system's own background and focus treatment, and glass
/// belongs to floating chrome (HIG hybrid contract, Overlay surfaces).
struct DebridKeyEntryRow: View {
    let providerName: String
    var placeholder: String?
    /// FEAT-50. Declared between `placeholder` and `onSave` so trailing-closure call sites still
    /// compile. A `TextField` has no label descendant to read `\.isFocused` from, so the field
    /// reports through its own `@FocusState` (`focused:` variant of the modifier).
    var descriptionID: SettingsDescriptionID? = nil
    let onSave: (String) -> Void
    @State private var key = ""
    @FocusState private var fieldFocused: Bool
    /// V2: the row holds two focusables (field + Save), so its rest platter is not inside one
    /// control's label and `\.isFocused` is not populated at its level; it reads both FocusStates.
    @FocusState private var saveFocused: Bool

    private var fieldPlaceholder: String {
        placeholder ?? String(localized: "Or paste your \(providerName) API key")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField(fieldPlaceholder, text: $key)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
                    .focused($fieldFocused)
            }
            .settingsDescription(descriptionID, title: fieldPlaceholder, systemImage: "key", focused: fieldFocused)

            Button {
                if !key.isEmpty {
                    onSave(key)
                    key = ""
                }
            } label: {
                Label("Save Key", systemImage: "checkmark")
                    .font(SettingsRowFont.subtitle)
                    .settingsDescription(descriptionID, title: String(localized: "Save Key"), systemImage: "checkmark")
            }
            .disabled(key.isEmpty)
            .focused($saveFocused)
        }
        .modifier(SettingsRestPlatter(explicitFocus: fieldFocused || saveFocused))
    }
}

// MARK: - Legacy support (deleted in C4 once nothing references it)
//
// The legacy focus-aware text-colour modifier moved out to DesignSystem/FlatControlStyles.swift
// in C4 — it is still used by five non-Settings screens (`StreamPickerView`, `DetailView`,
// `CloudLibraryUI`, `AddonsView`, `TmdbFilterEditorView`) that draw the legacy full-width row
// button style, so it belongs next to `SettingsRowButtonStyle`/`RowAccentTint` rather than in the
// Settings kit, which no longer uses it anywhere.

/// Language options for the audio/subtitle preference pickers. Special sentinels (`device`,
/// `original`, `none`) match the shared `AudioLanguageOption`/`SubtitleLanguageOption` constants;
/// labels are local since the shared label table lives in the mobile module. Shared between the
/// Playback pane (Audio & Subtitle Language) and the Content Sources pane (TMDB Metadata Language).
enum LanguageOptions {
    static let languages: [(name: String, code: String)] = [
        (String(localized: "English"), "en"), (String(localized: "Spanish"), "es"),
        (String(localized: "French"), "fr"), (String(localized: "German"), "de"),
        (String(localized: "Italian"), "it"), (String(localized: "Portuguese"), "pt"),
        (String(localized: "Japanese"), "ja"), (String(localized: "Korean"), "ko"),
        (String(localized: "Chinese"), "zh"), (String(localized: "Russian"), "ru"),
        (String(localized: "Hindi"), "hi"), (String(localized: "Arabic"), "ar"),
        // FEAT-19 (beta.12): rode along with the Vietnamese UI localization so vi is also
        // selectable for TMDB metadata and audio/subtitle track preference.
        (String(localized: "Vietnamese"), "vi")
    ]
    static var audio: [(name: String, code: String)] {
        [(String(localized: "Device"), "device"), (String(localized: "Original"), "original")] + languages
    }
    static var subtitle: [(name: String, code: String)] {
        [(String(localized: "Off"), "none"), (String(localized: "Device"), "device")] + languages
    }
    /// TMDB metadata language: Device = no stored language (the shared repo derives it from the
    /// Apple TV's language). TMDB accepts the same bare ISO 639-1 codes the track pickers use.
    static var tmdbMetadata: [(name: String, code: String)] {
        [(String(localized: "Device"), "device")] + languages
    }

    /// Label lookup for the `SettingsPickerRow` conversions C3 does — the picker stores the code
    /// and needs the display name back.
    static func name(forCode code: String, in options: [(name: String, code: String)]) -> String {
        options.first { $0.code == code }?.name ?? code
    }
}
