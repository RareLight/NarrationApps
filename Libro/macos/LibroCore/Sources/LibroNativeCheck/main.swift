import Foundation
import AVFoundation
import LibroCore
import Darwin

// Opt-in real-speech acceptance harness; never used by the fast fixtures or app.
@main
struct NativeCheck {
    static func main() {
        do { try run() }
        catch {
            fputs("Native check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4 || arguments.count == 5 else {
            print("Usage: LibroNativeCheck WORKER WORKSPACE OUTPUT_DIRECTORY serial [--offline]")
            exit(2)
        }
        guard arguments[3] == "serial", arguments.count == 4 || arguments[4] == "--offline" else { exit(2) }
        let worker = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stage = try workspace.contained(workspace.nativeRoot.appendingPathComponent("staging/check-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let text = "Dr. Smith paid $12.50 for three books. NASA will read them at 3 p.m. Hello, Anna! Libro makes local narration."
        var results: [[String: Any]] = []
        for model in SpeechModel.allCases {
            let settings = SpeechSettings(model: model)
            let request: [String: Any] = [
                "workspace": workspace.root.absoluteString,
                "settings": ["model": model.rawValue, "voice": settings.voice, "speed": settings.speed],
                "text": text, "spoolDirectory": stage.absoluteString
            ]
            let requestFile = stage.appendingPathComponent("request.json")
            try JSONSerialization.data(withJSONObject: request).write(to: requestFile, options: [.atomic])
            let diagnostic = output.appendingPathComponent("\(model.rawValue).diagnostics.log")
            FileManager.default.createFile(atPath: diagnostic.path, contents: nil)
            let errorHandle = try FileHandle(forWritingTo: diagnostic)
            defer { try? errorHandle.close() }
            let process = Process()
            let control = Pipe()
            if arguments.last == "--offline" {
                // Fresh process, networking blocked, no access to Hub/global model caches.
                var denied = [workspace.hubCache.path,
                    workspace.nativeRoot.appendingPathComponent("hf").path,
                    workspace.nativeRoot.appendingPathComponent("xet").path,
                    workspace.root.appendingPathComponent("models/.hf").path,
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path,
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/huggingface").path]
                if let source = ProcessInfo.processInfo.environment["LIBRO_CHECK_DENY_ROOT"] { denied.append(source) }
                let profile = "(version 1)(allow default)(deny network*)" + denied.map {
                    "(deny file-read* file-write* (subpath \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"))"
                }.joined()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                process.arguments = ["-p", profile, worker.path, "--speak", requestFile.path]
            } else {
                process.executableURL = worker
                process.arguments = ["--speak", requestFile.path]
            }
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardOutput = control
            process.standardError = errorHandle // File sink cannot fill a diagnostic pipe.
            try process.run()
            let data = control.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count < 65_536,
                  let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["protocolVersion"] as? Int == 1, record["model"] as? String == model.rawValue,
                  record["channels"] as? Int == 1,
                  let rate = record["sampleRate"] as? Int, let frames = record["frames"] as? Int,
                  rate == (model == .kokoro ? 24_000 : 32_000), frames > 0, frames <= rate * 120,
                  let pcmPath = record["pcmFile"] as? String else {
                throw CheckError.workerFailed(model.rawValue)
            }
            let pcmURL = try workspace.contained(URL(fileURLWithPath: pcmPath))
            guard pcmURL.deletingLastPathComponent().path == stage.path else { throw CheckError.invalidSpoolPath }
            let pcm = try Data(contentsOf: pcmURL)
            guard pcm.count == frames * 4 else { throw CheckError.invalidSpoolLength }
            let samples = pcm.withUnsafeBytes { $0.bindMemory(to: Float.self).map { $0 } }
            guard samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.0001 }) else {
                throw CheckError.nonFiniteOrSilent
            }
            let destination = output.appendingPathComponent("\(model.rawValue).wav")
            let writer = try AtomicWavWriter(destination: destination)
            try writer.append(samples: samples, sampleRate: rate)
            try writer.publish()
            let decoded = try AVAudioFile(forReading: destination)
            guard decoded.length == frames, decoded.fileFormat.sampleRate == Double(rate),
                  decoded.fileFormat.channelCount == 1 else { throw CheckError.decodedFormat }
            var result = record
            result.removeValue(forKey: "pcmFile")
            result["wav"] = destination.lastPathComponent
            result["peak"] = samples.map { abs($0) }.max()
            result["offline"] = arguments.last == "--offline"
            results.append(result)
            print("\(model.rawValue): \(rate) Hz, \(frames) frames, finite nonzero PCM; WAV published.")
        }
        let record: [String: Any] = ["version": 1, "text": text, "results": results]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"), options: [.atomic])
    }
}

private enum CheckError: Error {
    case workerFailed(String), invalidSpoolPath, invalidSpoolLength, nonFiniteOrSilent, decodedFormat
}
