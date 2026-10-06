#if DEBUG
import Combine
import SwiftUI

/// DEBUG-only probe for the mpv transport legs (`debug_seekProbe`): what the controller last
/// committed and what it last wrote to mpv. Always present in DEBUG builds.
@MainActor final class SeekProbe: ObservableObject {
    @Published var commits = 0
    @Published var lastTarget: Double = 0
    @Published var stages = "-"
    @Published var speed: Double = 1
    @Published var chip = false
    @Published var paused = false
    @Published var modeName = "idle"
    @Published var pos: Double = 0

    func note(commit target: Double, stages: String) {
        commits += 1
        lastTarget = target
        self.stages = stages
    }
}

struct SeekProbeLabel: View {
    @ObservedObject var probe: SeekProbe

    var body: some View {
        Text(verbatim: "commits=\(probe.commits) lastTarget=\(String(format: "%.0f", probe.lastTarget)) stages=\(probe.stages) speed=\(String(format: "%.1f", probe.speed)) mode=\(probe.modeName) chip=\(probe.chip ? 1 : 0) paused=\(probe.paused ? 1 : 0) pos=\(String(format: "%.1f", probe.pos))")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_seekProbe")
            .allowsHitTesting(false)
    }
}
#endif
