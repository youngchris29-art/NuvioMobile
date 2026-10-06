import SharedCore
import SwiftUI

// Search & Discover batch 2026-10-06 (O3 Stage Discover, plan A2): the stage Discover page's top
// band. Three pills over the stage, trailing-aligned where the folder page's Edit band sits:
//
//     [ Movies ▾ ]  [ Popular ▾ ]  [ ⊞ Grid ]
//       Type          Catalog        Grid
//       discover.     discover.      discover.
//       typePicker    catalogPicker  gridButton
//
//  - Type and Catalog are the shared `PillMenu` (stock `Menu { Picker }`, Library's look). Catalog
//    is hidden while the type has one catalog. A pick goes to the view model (persist, cancel the
//    fetches, rebuild the rows); the page re-mounts its pager on the new selection key, and focus
//    stays on the menu (the system hands it back when the popover closes).
//  - Grid is the shared `PillButton`: today's `CatalogGridView` for the focused row's genre (the
//    first loaded row when focus is on the band), disabled until a row has posters. No new grid.
//
// Trailing, not leading: in Tabs mode the centred system tab bar shows while the strip rests on
// row 0, and a leading band would run under it (the options board's mock reads left-aligned;
// check on the simulator and flip if it clears the bar).
//
// The gate is `FolderEditMenuBand`'s (`CollectionsUI.swift`), unchanged in kind: active while the
// strip's focused row is its top row (or no row has had focus yet), and then a focus section; when
// inactive it keeps its place HIDDEN, never a faded section, because a section holding only a
// disabled control still caught Up from a lower row (end-of-Wave-2 FA87 walk). Until a row loads,
// the band is the page's focus anchor (BUG-47).

/// See the file header.
struct DiscoverPillBand: View {
    @ObservedObject var model: DiscoverRowsViewModel
    /// The page's `rowsAtTop`: the strip's focused row is its top row, or none has had focus yet.
    let isActive: Bool
    /// The Grid pill's target, read at press time (the page's focused row lives in a reference box).
    let gridSection: () -> HomeCatalogSection?
    let onOpenGrid: (CatalogRoute) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isActive {
                band.focusSection()
            } else {
                band.hidden()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
    }

    private var band: some View {
        HStack(spacing: Theme.Spacing.md) {
            Spacer(minLength: 0)
            if let type = model.selectedType {
                PillMenu(title: DiscoverRowsPlan.typeLabel(type),
                         systemImage: "film.stack",
                         selection: typeBinding(current: type),
                         options: model.typeOptions,
                         id: "discover.typePicker",
                         pickerTitle: String(localized: "Type"),
                         label: { DiscoverRowsPlan.typeLabel($0) })
                let catalogs = model.catalogOptions(for: type)
                if catalogs.count > 1, let selected = model.selectedOption {
                    PillMenu(title: DiscoverRowsPlan.catalogLabel(selected, among: catalogs),
                             systemImage: "square.stack",
                             selection: catalogBinding(current: selected.key),
                             options: catalogs.map(\.key),
                             id: "discover.catalogPicker",
                             pickerTitle: String(localized: "Catalog"),
                             label: { key in
                                 catalogs.first { $0.key == key }
                                     .map { DiscoverRowsPlan.catalogLabel($0, among: catalogs) } ?? key
                             })
                }
                PillButton(title: String(localized: "Grid"),
                           systemImage: "square.grid.3x3",
                           id: "discover.gridButton") {
                    guard let section = gridSection() else { return }
                    onOpenGrid(CatalogRoute(section: section))
                }
                .disabled(!model.hasLoadedRow)
            }
        }
        .disabled(!isActive)
        .padding(.top, FolderHeaderGeometry.restTop)
        .padding(.trailing, Theme.Spacing.screen)
    }

    private func typeBinding(current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { model.select(type: $0) }
        )
    }

    private func catalogBinding(current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { model.select(catalogKey: $0) }
        )
    }
}
