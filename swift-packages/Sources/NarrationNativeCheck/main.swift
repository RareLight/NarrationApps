import Foundation
import AVFoundation
import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import ProcessingPipeline
import Darwin

// Opt-in real-speech acceptance harness; never used by the fast fixtures or app.
@main
struct NativeCheck {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().dropFirst(3).first == "prepare" { try await prepare() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "contention" { try await ContentionCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "models" { try await ExpandedModelCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "catalog" { try await CatalogCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "frontend" { try await FrontendCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "pdf-word-joins" { try await PDFWordJoinCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "longform" { try await LongformCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "mixed" { try await MixedDocumentCheck.run() }
            else if CommandLine.arguments.dropFirst().dropFirst(3).first == "batch" { try await runBatch() }
            else { try run() }
        }
        catch {
            fputs("Native check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func offlineProfile(_ workspace: NativeWorkspace, allowNativeCache: Bool = false) -> String {
        var denied = [
            workspace.root.appendingPathComponent("models/.hf").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/huggingface").path]
        if !allowNativeCache {
            denied += [workspace.hubCache.path, workspace.nativeRoot.appendingPathComponent("hf").path,
                       workspace.nativeRoot.appendingPathComponent("xet").path]
        }
        if let source = ProcessInfo.processInfo.environment["NARRATION_CHECK_DENY_ROOT"] { denied.append(source) }
        return "(version 1)(allow default)(deny network*)" + denied.map {
            "(deny file-read* file-write* (subpath \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"))"
        }.joined()
    }

    private static func prepare() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 4, let model = SpeechModel(rawValue: arguments[2]),
              arguments.dropFirst(4).allSatisfy({ $0 == "--offline" || $0 == "--workspace-writes-only" || $0.hasPrefix("--cancel-after=") || $0.hasPrefix("--cancel-after-bytes=") }) else { exit(2) }
        let worker = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        var configuration = WorkerConfiguration(executable: worker, requestTimeout: .seconds(1_800))
        if arguments.contains("--offline") || arguments.contains("--workspace-writes-only") {
            var profile = arguments.contains("--offline") ? offlineProfile(workspace, allowNativeCache: true) : "(version 1)(allow default)"
            if arguments.contains("--workspace-writes-only") {
                let escaped = workspace.root.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                profile += "(deny file-write*)(allow file-write* (subpath \"\(escaped)\"))"
            }
            configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", profile, worker.path, "--serve"], requestTimeout: .seconds(1_800))
        }
        let specification = NativePrimaryCatalog.specification(for: model)
        print("Preparing \(specification.repository) at \(specification.revision)")
        configuration.debugLog = ProcessInfo.processInfo.environment["NARRATION_CHECK_DEBUG_LOG"] == "1" ? try DebugLog(workspace: workspace.root) : nil
        let checkConfiguration = configuration
        let observed = PreparationCheckProgress()
        let task = Task {
            try await ModelPreparation.run(configuration: checkConfiguration, workspace: workspace.root, settings: .init(model: model)) { value in
                observed.append(value)
                print("\(value.scope.rawValue) \(value.phase.rawValue): \(value.completedBytes)/\(value.totalBytes) bytes")
            }
        }
        let cancellation: Task<Void, Never>?
        if let argument = arguments.first(where: { $0.hasPrefix("--cancel-after=") }),
           let seconds = Double(argument.dropFirst("--cancel-after=".count)), seconds > 0, seconds.isFinite {
            cancellation = Task {
                do { try await Task.sleep(for: .seconds(seconds)); task.cancel() } catch {}
            }
        } else if let argument = arguments.first(where: { $0.hasPrefix("--cancel-after-bytes=") }),
                  let bytes = Int64(argument.dropFirst("--cancel-after-bytes=".count)), bytes > 0 {
            cancellation = Task {
                while !Task.isCancelled {
                    if observed.receivedBytes >= bytes { task.cancel(); return }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        } else { cancellation = nil }
        defer { cancellation?.cancel() }
        do { try await task.value }
        catch is CancellationError where cancellation != nil { print("Preparation cancelled; owned helper reaped."); return }
        _ = try workspace.primaryDirectory(for: model)
        if model == .kokoro { try NativeG2P.validate(directory: workspace.g2pDirectory, workspace: workspace) }
        print("Preparation inventory accepted; owned helper reaped.")
    }

    private static func runBatch() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--offline") else { exit(2) }
        let worker = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let outputFormat = AudioOutputFormat(rawValue: ProcessInfo.processInfo.environment["NARRATION_CHECK_OUTPUT_FORMAT"] ?? "wav") ?? .wav
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/check-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        // Public acceptance text exercises sentence/number/abbreviation packing
        // and Foundation Markdown paragraph projection. Listening is separate.
        let text = """
        # Libro native scheduling

        Dr. Smith paid $12.50 for three books. NASA will read them at 3 p.m. Hello, Anna! Libro makes local narration.

        The first chapter describes a quiet morning in Chicago. Readers can choose a folder and follow the progress of their documents. Each complete recording is saved only after every audio chunk has been accepted.

        A second paragraph includes punctuation, quotations, and numbers: 2026, twenty-seven, and 1.1. The café opens at noon. Paragraph boundaries survive the Markdown projection into narration.

        The final paragraph checks ordered generation. One native worker processes the document's chunks, and the coordinator puts the audio back into the original order. Existing complete files survive a failed or cancelled attempt. This is the end of the public sample.
        """
        let source = stage.appendingPathComponent("sample.md")
        try Data(text.utf8).write(to: source)
        let input = InputDocument(source: source, kind: .markdown, relativePath: "sample.md")
        var configuration = WorkerConfiguration(executable: worker)
        if arguments.last == "--offline" {
            configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", offlineProfile(workspace), worker.path, "--serve"])
        }
        configuration.mp3Library = worker.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks/libmp3lame.0.dylib")
        let coordinator = QueueCoordinator(configuration: configuration)
        let debugLog = ProcessInfo.processInfo.environment["NARRATION_CHECK_DEBUG_LOG"] == "1" ? try DebugLog(workspace: workspace.root) : nil
        var results: [[String: Any]] = []
        for model in [SpeechModel.kokoro, .soprano] {
            let settings = SpeechSettings(model: model)
            let plan = try BatchPlanner.plan([input], output: output, names: [input.id: "\(model.rawValue).\(outputFormat.rawValue)"], format: outputFormat)
            let request = BatchRequest(documents: plan, outputDirectory: output, workspace: workspace.root,
                                       settings: settings, replaceExisting: true, outputFormat: outputFormat)
            let progress = CheckProgress()
            let started = ContinuousClock.now
            let summary = try await coordinator.run(request, debugLog: debugLog) { event in
                if case .speech(let value) = event { progress.append(value) }
            }
            guard summary.successfulCount == 1, summary.failedCount == 0, !summary.cancelled else {
                throw CheckError.workerFailed(model.rawValue)
            }
            let attempts = progress.values.filter { $0.phase == .started }
            guard attempts.count == 1, attempts[0].totalChunks >= 3 else {
                throw CheckError.workerFailed("Generation path was not accepted")
            }
            let decoded = try AVAudioFile(forReading: plan[0].destination, commonFormat: .pcmFormatFloat32, interleaved: true)
            guard decoded.length > 0, decoded.fileFormat.sampleRate == Double(model.capabilities.sampleRate),
                  decoded.fileFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_384) else {
                throw CheckError.decodedFormat
            }
            var decodedFrames: Int64 = 0
            var nonzero = false
            while decoded.framePosition < decoded.length {
                try decoded.read(into: buffer)
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw CheckError.decodedFormat }
                let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                guard samples.allSatisfy(\.isFinite) else { throw CheckError.nonFiniteOrSilent }
                nonzero = nonzero || samples.contains(where: { abs($0) > 0.0001 })
                decodedFrames += Int64(buffer.frameLength)
            }
            guard decodedFrames == decoded.length, nonzero else { throw CheckError.nonFiniteOrSilent }
            let duration = started.duration(to: .now).components
            let result: [String: Any] = ["model": model.rawValue, "sampleRate": model.capabilities.sampleRate,
                "frames": decoded.length, "chunks": attempts[0].totalChunks, "workers": 1,
                "attempts": attempts.count, "elapsedSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                "file": plan[0].destination.lastPathComponent, "format": outputFormat.rawValue, "offline": arguments.last == "--offline"]
            results.append(result)
            print("\(model.rawValue): single-worker batch, \(attempts[0].totalChunks) ordered chunks, \(decoded.length) finite nonzero \(outputFormat.rawValue.uppercased()) frames.")
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "text": text, "results": results], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"), options: [.atomic])
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 || arguments.count == 4 else {
            print("Usage: NarrationNativeCheck WORKER WORKSPACE OUTPUT_DIRECTORY [--offline]")
            exit(2)
        }
        guard arguments.count == 3 || arguments[3] == "--offline" else { exit(2) }
        let worker = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/check-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let text = "Dr. Smith paid $12.50 for three books. NASA will read them at 3 p.m. Hello, Anna! Libro makes local narration."
        var results: [[String: Any]] = []
        for model in [SpeechModel.kokoro, .soprano] {
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
            // Public acceptance text only: retain the worker's raw output as the
            // golden sample stream so failures can be diagnosed without inference.
            try pcm.write(to: output.appendingPathComponent("\(model.rawValue).f32"), options: [.atomic])
            guard samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.0001 }) else {
                throw CheckError.nonFiniteOrSilent
            }
            let destination = output.appendingPathComponent("\(model.rawValue).wav")
            let writer = try AtomicAudioWriter(destination: destination)
            try writer.append(samples: samples, sampleRate: rate)
            try writer.publish()
            let decoded = try AVAudioFile(forReading: destination, commonFormat: .pcmFormatFloat32, interleaved: true)
            guard decoded.length == frames, decoded.fileFormat.sampleRate == Double(rate),
                  decoded.fileFormat.channelCount == 1 else { throw CheckError.decodedFormat }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_384) else { throw CheckError.decodedFormat }
            var decodedSamples: [Float] = []
            while decoded.framePosition < decoded.length {
                try decoded.read(into: buffer)
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw CheckError.decodedFormat }
                decodedSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            guard decodedSamples.map(\.bitPattern) == samples.map(\.bitPattern) else { throw CheckError.decodedFormat }
            var result = record
            result.removeValue(forKey: "pcmFile")
            result["wav"] = destination.lastPathComponent
            result["peak"] = samples.map { abs($0) }.max()
            result["exactModelSamples"] = true
            result["offline"] = arguments.last == "--offline"
            results.append(result)
            print("\(model.rawValue): \(rate) Hz, \(frames) frames, finite nonzero PCM; WAV published with bit-identical model samples.")
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

private final class PreparationCheckProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func append(_ value: ModelPreparationProgress) {
        if value.phase == .downloading { lock.withLock { bytes = value.completedBytes } }
    }
    var receivedBytes: Int64 { lock.withLock { bytes } }
}
