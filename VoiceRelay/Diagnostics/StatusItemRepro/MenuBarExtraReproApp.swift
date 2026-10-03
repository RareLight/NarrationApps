import SwiftUI
import AppKit

// Minimal reproduction: no VoiceRelay core, package, profile, or pipeline.
@main
struct MenuBarExtraReproApp: App {
    var body: some Scene {
        MenuBarExtra("Status item diagnostic", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Menu bar diagnostic").font(.headline)
                Text("This app only creates a menu-bar item. It reads no VoiceRelay configuration or data.")
                Button("Quit diagnostic") { NSApp.terminate(nil) }
            }
            .padding(16)
            .frame(width: 390)
        }
        .menuBarExtraStyle(.window)
    }
}
