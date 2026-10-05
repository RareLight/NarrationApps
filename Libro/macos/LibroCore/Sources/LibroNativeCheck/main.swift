import Foundation
import AVFoundation
import LibroCore
import Darwin

// Opt-in real-speech acceptance harness; never used by the fast fixtures or app.
@main
struct NativeCheck {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().dropFirst(3).first == "batch" { try await runBatch() }
            else { try run() }
        }
        catch {
            fputs("Native check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func offlineProfile(_ workspace: NativeWorkspace) -> String {
        var denied = [workspace.hubCache.path,
            workspace.nativeRoot.appendingPathComponent("hf").path,
            workspace.nativeRoot.appendingPathComponent("xet").path,
            workspace.root.appendingPathComponent("models/.hf").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/huggingface").path]
        if let source = ProcessInfo.processInfo.environment["LIBRO_CHECK_DENY_ROOT"] { denied.append(source) }
        return "(version 1)(allow default)(deny network*)" + denied.map {
            "(deny file-read* file-write* (subpath \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"))"
        }.joined()
    }

    private static func runBatch() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--offline") else { exit(2) }
        let worker = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stage = try workspace.contained(workspace.nativeRoot.appendingPathComponent("staging/check-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        // Public acceptance text exercises sentence/number/abbreviation packing
        // and Foundation Markdown paragraph projection. Listening is separate.
        let text = """
        # Libro native scheduling

        Dr. Smith paid $12.50 for three books. NASA will read them at 3 p.m. Hello, Anna! Libro makes local narration.

        The first chapter describes a quiet morning in Chicago. Readers can choose a folder and follow the progress of their documents. Each complete recording is saved only after every audio chunk has been accepted.

        A second paragraph includes punctuation, quotations, and numbers: 2026, twenty-seven, and 1.1. The café opens at noon. Paragraph boundaries survive the Markdown projection into narration.

        The final paragraph checks ordered generation. Two native workers share the document's chunks, and the coordinator puts the audio back into the original order. Existing complete files survive a failed or cancelled attempt. This is the end of the public sample.
        """
        let source = stage.appendingPathComponent("sample.md")
        try Data(text.utf8).write(to: source)
        let input = InputDocument(source: source, kind: .markdown, relativePath: "sample.md")
        var configuration = WorkerConfiguration(executable: worker)
        if arguments.last == "--offline" {
            configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", offlineProfile(workspace), worker.path, "--serve"])
        }
        let coordinator = QueueCoordinator(configuration: configuration)
        var results: [[String: Any]] = []
        for model in SpeechModel.allCases {
            let settings = SpeechSettings(model: model)
            let plan = try BatchPlanner.plan([input], output: output, names: [input.id: "\(model.rawValue).wav"])
            let request = BatchRequest(documents: plan, outputDirectory: output, workspace: workspace.root,
                                       settings: settings, serial: false)
            let progress = CheckProgress()
            let started = ContinuousClock.now
            let summary = try await coordinator.run(request) { event in
                if case .speech(let value) = event { progress.append(value) }
            }
            guard summary.successfulCount == 1, summary.failedCount == 0, !summary.cancelled else {
                throw CheckError.workerFailed(model.rawValue)
            }
            let attempts = progress.values.filter { $0.phase == .attemptStarted }
            guard attempts.count == 1, attempts[0].workerCount == 2, attempts[0].totalChunks >= 3 else {
                throw CheckError.workerFailed("Automatic path was not accepted")
            }
            let decoded = try AVAudioFile(forReading: plan[0].destination, commonFormat: .pcmFormatFloat32, interleaved: true)
            guard decoded.length > 0, decoded.fileFormat.sampleRate == Double(model.capabilities.sampleRate),
                  decoded.fileFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length)) else {
                throw CheckError.decodedFormat
            }
            try decoded.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CheckError.decodedFormat }
            let samples = UnsafeBufferPointer(start: channel, count: Int(decoded.length))
            guard samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.0001 }) else { throw CheckError.nonFiniteOrSilent }
            let duration = started.duration(to: .now).components
            let result: [String: Any] = ["model": model.rawValue, "sampleRate": model.capabilities.sampleRate,
                "frames": decoded.length, "chunks": attempts[0].totalChunks, "workers": attempts[0].workerCount,
                "attempts": attempts.count, "elapsedSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                "wav": plan[0].destination.lastPathComponent, "offline": arguments.last == "--offline"]
            results.append(result)
            print("\(model.rawValue): automatic two-worker batch, \(attempts[0].totalChunks) ordered chunks, \(decoded.length) finite nonzero WAV frames.")
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "text": text, "results": results], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"), options: [.atomic])
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
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                process.arguments = ["-p", offlineProfile(workspace), worker.path, "--speak", requestFile.path]
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

private final class CheckProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SpeechProgress] = []
    func append(_ value: SpeechProgress) { lock.withLock { storage.append(value) } }
    var values: [SpeechProgress] { lock.withLock { storage } }
}
