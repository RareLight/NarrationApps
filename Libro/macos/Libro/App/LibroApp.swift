import SwiftUI
import LibroCore

@main
struct LibroApp: App {
    var body: some Scene {
        Window("Libro", id: "main") {
            FeasibilityView()
                .frame(minWidth: 600, minHeight: 360)
        }
        .defaultSize(width: 760, height: 480)
    }
}

private struct FeasibilityView: View {
    @State private var status = "Native runtime feasibility — M1"
    @State private var probing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Libro", systemImage: "waveform")
                .font(.largeTitle)
            Text("Kokoro and Soprano • Local native speech")
                .foregroundStyle(.secondary)
            Text(status).textSelection(.enabled)
                .accessibilityLabel("Native worker status: \(status)")
            Button("Verify Embedded Worker") {
                probing = true
                Task {
                    status = await Task.detached { probeWorker() }.value
                    probing = false
                }
            }
            .disabled(probing)
            if probing { ProgressView("Checking Metal runtime…") }
            Spacer()
            Text("The document workflow will follow native speech validation.")
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

private func probeWorker() -> String {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        return "Embedded worker is missing."
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = ["--probe"]
    process.standardOutput = output
    // M1 probe emits only one bounded record; speech IPC will drain diagnostics.
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "Worker probe failed (\(process.terminationStatus))." }
        return "Embedded worker: Metal ready\n" + (String(data: data, encoding: .utf8) ?? "")
    } catch {
        return "Unable to launch the embedded worker: \(error.localizedDescription)"
    }
}
