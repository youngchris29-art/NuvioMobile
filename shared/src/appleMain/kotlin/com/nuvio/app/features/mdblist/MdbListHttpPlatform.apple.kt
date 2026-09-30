package com.nuvio.app.features.mdblist

// Upstream 8fe994bd (iosMain) ported to :shared appleMain (iOS + tvOS). Verbatim.

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout

internal actual fun createMdbListHttpClient(): HttpClient = HttpClient(Darwin) {
    followRedirects = false
    expectSuccess = false
    install(HttpTimeout) {
        requestTimeoutMillis = 30_000
        connectTimeoutMillis = 15_000
        socketTimeoutMillis = 30_000
    }
}
