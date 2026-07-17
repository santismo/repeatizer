import SwiftUI

@main
struct RepeatizerHostApp: App {
    var body: some Scene {
        WindowGroup("Repeatizer") {
            VStack(alignment: .leading, spacing: 12) {
                Text("REPEATIZER").font(.system(size: 28, weight: .black, design: .rounded)).tracking(1.5)
                Text("Repeatizer is installed as an Audio Unit MIDI FX extension.")
                Text("Open Logic Pro, add Repeatizer in a MIDI FX slot, then use the plug-in window to edit per-pad repeat, swing, velocity, and modulation settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(30)
            .frame(width: 480)
        }
    }
}
