import SwiftUI
import SharedCore

/// The Add-ons tab. Add-ons hub v2 (A2): the body is `AddonsHubSplitView` (sections on the left,
/// content on the right, each content column with its own NavigationStack). This view keeps what
/// must outlive a section switch: the stores the hub and its panes read (started and stopped here,
/// so a push inside the content column never stops them) and the remove confirmation (raised by
/// an Installed row's context menu or the add-on's page).
struct AddonsView: View {
    @StateObject private var model = AddonsViewModel()
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var debrid = DebridViewModel()
    @StateObject private var plugins = PluginsViewModel()
    /// Addon pending a remove confirmation (drives the alert below).
    @State private var addonPendingRemoval: ManagedAddon?
    /// The neighbours of the card whose removal was requested, so focus can follow the removal.
    /// Owned here so the alert's Cancel can clear it (a later sync removal must not toast or
    /// move focus).
    @State private var removal: AddonsHubSplitView.RemovalIntent?

    var body: some View {
        AddonsHubSplitView(
            model: model, settings: settings, debrid: debrid, plugins: plugins,
            pendingRemoval: $addonPendingRemoval, removal: $removal
        )
            // FEAT-30 / H9 / D6: the rail's Menu reveal sits on the hub's SIDEBAR, not here: the
            // content column's stack is nested inside this view, so a reveal here would catch Menu
            // on a pushed page instead of letting the stack pop (A2 sim leg, Rail mode).
            // BUG-214: the app background (`Theme.Palette.background` is what OLED True Black swaps
            // to pure black).
            .background(Theme.Palette.background.ignoresSafeArea())
        // On the hub root: a push inside the content column must NOT stop the stores.
        .onAppear {
            model.start()
            settings.start()
            debrid.start()
            plugins.start()
        }
        .onDisappear {
            model.stop()
            settings.stop()
            debrid.stop()
            plugins.stop()
        }
        .alert(
            "Remove \(addonPendingRemoval.map { model.displayName($0) } ?? "")?",
            isPresented: Binding(
                get: { addonPendingRemoval != nil },
                set: { if !$0 { addonPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let addon = addonPendingRemoval { model.remove(addon) }
                addonPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                // Review r1: a cancelled removal must not leave its intent behind.
                removal = nil
                addonPendingRemoval = nil
            }
        } message: {
            Text("Its catalogs and streams will no longer appear.")
        }
    }
}
