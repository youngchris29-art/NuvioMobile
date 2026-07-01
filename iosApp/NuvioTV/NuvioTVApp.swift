//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Created by Christian Turnbull on 6/29/26.
//

import SwiftUI
import SharedCore

@main
struct NuvioTVApp: App {
    init() {
        // Wire the shared provider seams for tvOS. The phone app does this in composeApp's App()
        // (which tvOS never runs), so without this the profile seams fall back to defaults and
        // nothing is profile-scoped. Runs once, before any repository is accessed.
        TvOsProviderInstallerKt.installTvOsSharedProviders()

        // Enter local "guest" mode (random id in NSUserDefaults, no network) so ProfileRepository
        // writes persist locally — this is what makes on-device multi-profile management work
        // without a sign-in. Purely local; no Supabase call.
        AuthRepository.shared.signInAnonymously()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
