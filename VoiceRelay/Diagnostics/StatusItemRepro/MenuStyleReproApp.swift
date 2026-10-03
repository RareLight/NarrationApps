import SwiftUI
import AppKit

// Native-menu comparison. No VoiceRelay core, configuration, or pipeline work.
@main
struct MenuStyleReproApp: App {
    var body: some Scene {
        MenuBarExtra("Menu style diagnostic", systemImage: "waveform") {
            MenuStyleReproContent(quit: { NSApp.terminate(nil) })
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuStyleReproContent: View {
    let quit: () -> Void

    var body: some View {
        Group {
            Text("Menu style diagnostic")
            Text("Isolated UI; no data or services")
            Divider()
            Button("Quit diagnostic", action: quit)
        }
    }
}

#if DEBUG
// Content preview only; Canvas does not reproduce the native menu lifecycle.
struct MenuStyleDiagnosticInertContent_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuStyleReproContent(quit: {})
        }
        .padding(16)
    }
}
#endif
