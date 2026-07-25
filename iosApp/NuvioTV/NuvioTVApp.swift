//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Created by Christian Turnbull on 6/29/26.
//

import AVFAudio
import SwiftUI
import SharedCore

@main
struct NuvioTVApp: App {
    init() {
        // Wire the shared provider seams for tvOS (profiles, sync platform "tv", account-data
        // cleaner, sync-backend load). The phone app does this in composeApp's App() (which tvOS
        // never runs). Runs once, before any repository is accessed.
        TvOsProviderInstallerKt.installTvOsSharedProviders()

        // Localize shared-module strings (toasts, month names, error messages…) through the
        // Shared string catalog. Without this, shared code uses its inline English fallbacks.
        LocalizedStrings.shared.provider = SharedStringProvider()

        // Wire the JS plugin stack (QuickJS runtime, tvosMain-only): scraper host for
        // StreamsRepository, cloud sync controller (plugin repos sync from mobile), and
        // profile-change/sign-out lifecycle hooks.
        TvOsPluginsInstallerKt.installTvOsPlugins()

        // Configure + activate the audio session off the main thread once at startup. libmpv /
        // AVFoundation otherwise activate it lazily on the main thread at first playback, which
        // trips Xcode's "AVAudioSession Hang Risk" runtime diagnostic.
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }

        // Sweep remux session dirs orphaned by a jetsam kill or crash (cleanup normally runs on
        // playback stop, so anything under Caches/nuvio-remux at launch is a leak — and a single
        // remux-bitrate session can be several GB). Async on a utility queue; live sessions are
        // shielded via a registry.
        RemuxCacheJanitor.sweepAtLaunch()

        #if DEBUG
        // Phase 2 headless remux/HLS-server validation, gated on the `debug.remuxSmokeURL` default.
        RemuxSmokeTest.runIfRequested()
        #endif

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
