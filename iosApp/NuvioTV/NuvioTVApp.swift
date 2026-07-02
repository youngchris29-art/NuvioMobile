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
        // Wire the shared provider seams for tvOS (profiles, sync platform "tv", account-data
        // cleaner, sync-backend load). The phone app does this in composeApp's App() (which tvOS
        // never runs). Runs once, before any repository is accessed.
        TvOsProviderInstallerKt.installTvOsSharedProviders()

        // Auth is started by AuthViewModel (ContentView.onAppear): existing guest installs
        // authenticate instantly from their stored anonymous id; otherwise the Supabase session is
        // restored, or the Welcome gate (Sign In / Create Account / Continue as Guest) is shown.
        // NOTE: we intentionally no longer call signInAnonymously() here — it generated a fresh
        // guest id on EVERY launch and shadowed real account sessions.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
