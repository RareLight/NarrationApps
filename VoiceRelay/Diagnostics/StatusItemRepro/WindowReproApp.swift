import SwiftUI
import AppKit

// Control: ordinary SwiftUI window, no menu-bar item and no VoiceRelay code.
@main
struct WindowReproApp: App {
    var body: some Scene {
        WindowGroup("Window diagnostic") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Window diagnostic").font(.headline)
                Text("This control app creates an ordinary window. It reads no VoiceRelay configuration or data.")
                Button("Quit diagnostic") { NSApp.terminate(nil) }
            }
            .padding(16)
            .frame(width: 390, height: 180)
        }
    }
}
