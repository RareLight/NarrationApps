import Foundation
import LibroCore
import MLX
import MLXAudioCore
import MLXAudioTTS
import HuggingFace
import Darwin

@main
struct LibroSpeechWorker {
    static func main() async {
        // Reserve stdout for bounded control records; upstream prints go to stderr.
        let control = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--serve"] {
                try await serve(control: control)
                return
            }
            let response: [String: Any]
            if arguments == ["--probe"] {
                let result = (MLXArray([Float(1), 2, 3]) * 2).asArray(Float.self)
                guard result == [2, 4, 6] else { throw WorkerError.metalProbeFailed }
                response = ["metal": "ready", "worker": "LibroSpeechWorker"]
            } else if arguments.count == 2, arguments[0] == "--prepare-g2p" {
                let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
                try configureCache(workspace)
                try await prepareG2P(workspace)
                response = ["prepared": NativeG2P.repository, "revision": NativeG2P.revision]
            } else if arguments.count == 2, arguments[0] == "--speak" {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                guard data.count <= 65_536 else { throw WorkerError.invalidRequest }
                let request = try JSONDecoder().decode(SpikeRequest.self, from: data)
                response = try await synthesize(request)
            } else {
                throw WorkerError.unsupportedCommand
            }
            var record = response
            record["protocolVersion"] = 1
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try control.write(contentsOf: data + Data([10]))
        } catch {
            // Library errors may contain narration; only controlled failures
            // are emitted by Libro. Upstream diagnostics have their own pipe.
            try? FileHandle.standardError.write(contentsOf: Data("Libro speech worker failed.\n".utf8))
            exit(1)
        }
    }

    private static func serve(control: FileHandle) async throws {
        let reader = WorkerCommandReader()
        var context: WorkerContext?
        while let command = try reader.next() {
            do {
                guard command.protocolVersion == 1 else { throw SpeechFailure(.invalidInput) }
                switch command.kind {
                case .initialize:
                    guard context == nil, command.chunk == nil, let root = command.workspace,
                          let settings = command.settings, let spool = command.spoolDirectory else {
                        throw SpeechFailure(.invalidInput)
                    }
                    let workspace = try NativeWorkspace(root: root)
                    try configureCache(workspace)
                    let staging = try workspace.contained(spool)
                    guard staging.path.hasPrefix(workspace.nativeRoot.path + "/staging/attempt-"),
                          staging == spool, (try staging.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                          settings.speed.isFinite, settings.speed > 0 else { throw SpeechFailure(.invalidInput) }
                    let engine = try await load(settings: settings, workspace: workspace)
                    context = WorkerContext(identity: command.identity, spool: staging, settings: settings, engine: engine)
                    try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .ready, identity: command.identity)))
                case .generate:
                    guard let context, context.identity == command.identity,
                          let chunk = command.chunk, chunk >= 0, let text = command.text else {
                        throw SpeechFailure(.invalidInput)
                    }
                    try validate(text: text, settings: context.settings)
                    let (samples, rate) = try await context.engine.generate(text: text, settings: context.settings)
                    let file = SpeechIPC.chunkFile(in: context.spool, index: chunk)
                    try writePCM(samples, to: file)
                    let event = WorkerEvent(kind: .chunk, identity: context.identity, chunk: chunk,
                                            sampleRate: rate, frames: samples.count, channels: 1, pcmFile: file.path)
                    try control.write(contentsOf: SpeechIPC.encode(event))
                case .cancel, .shutdown:
                    guard context == nil || context?.identity == command.identity else { continue }
                    return
                }
            } catch {
                let code: SpeechFailureCode
                if let failure = error as? SpeechFailure { code = failure.code }
                else if error is NativeAssetError || error is DecodingError { code = .invalidInput }
                else if let failure = error as? AudioGenerationError {
                    // Includes Kokoro's actual phoneme-token ceiling. A serial
                    // replay of the same invalid text cannot fix that input.
                    if case .invalidInput = failure { code = .invalidInput }
                    else { code = .generation }
                }
                else if let failure = error as? WorkerError {
                    code = failure == .storage ? .storage : (failure == .invalidRequest ? .invalidInput : .generation)
                } else if (error as NSError).domain == NSCocoaErrorDomain { code = .storage }
                else { code = .generation }
                try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure, identity: command.identity,
                                                                           chunk: command.chunk, failure: code)))
                return // Failed model state is never reused for more inference.
            }
        }
    }

    private static func validate(text: String, settings: SpeechSettings) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 1_000, settings.speed.isFinite,
              settings.speed > 0 else { throw WorkerError.invalidRequest }
    }

    private static func load(settings: SpeechSettings, workspace: NativeWorkspace) async throws -> LoadedEngine {
        let primary = try workspace.primaryDirectory(for: settings.model, voice: settings.voice)
        switch settings.model {
        case .kokoro:
            try NativeG2P.validate(directory: workspace.g2pDirectory, workspace: workspace)
            let processor = MisakiTextProcessor(resourceDirectory: workspace.g2pDirectory)
            let model = try await KokoroModel.fromModelDirectory(primary, textProcessor: processor)
            model.speed = settings.speed
            return .kokoro(model)
        case .soprano:
            return .soprano(try await SopranoModel.fromModelDirectory(primary, repo: settings.model.repository))
        }
    }

    private static func configureCache(_ workspace: NativeWorkspace) throws {
        _ = try workspace.managed(workspace.hubCache)
        for name in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "TRANSFORMERS_CACHE"] {
            setenv(name, workspace.hubCache.path, 1)
        }
        setenv("HF_HOME", workspace.nativeRoot.appendingPathComponent("hf").path, 1)
        setenv("HF_XET_CACHE", workspace.nativeRoot.appendingPathComponent("xet").path, 1)
        setenv("HF_ASSETS_CACHE", workspace.nativeRoot.appendingPathComponent("hf-assets").path, 1)
    }

    private static func prepareG2P(_ workspace: NativeWorkspace) async throws {
        let target = try workspace.managed(workspace.g2pDirectory)
        let staging = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/g2p-\(NativeG2P.revision)"))
        let lockURL = try workspace.managed(workspace.nativeRoot.appendingPathComponent("locks/g2p.lock"))
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw WorkerError.storage }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw WorkerError.storage }
        if (try? NativeG2P.validate(directory: target, workspace: workspace)) != nil { return }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let client = HubClient(session: URLSession(configuration: configuration), host: HubClient.defaultHost,
                               cache: HubCache(cacheDirectory: workspace.hubCache))
        guard let repo = Repo.ID(rawValue: NativeG2P.repository) else { throw WorkerError.invalidRequest }
        _ = try await client.downloadSnapshot(of: repo, to: staging, revision: NativeG2P.revision,
                                             matching: Array(NativeG2P.requiredFiles.keys), maxConcurrentDownloads: 2)
        try NativeG2P.record(directory: staging, workspace: workspace)
        try NativeG2P.validate(directory: staging, workspace: workspace)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            // Only the explicitly GUI-owned namespace is eligible for replacement.
            let quarantine = target.appendingPathExtension("invalid-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: target, to: quarantine)
        }
        try FileManager.default.moveItem(at: staging, to: target)
    }

    private static func synthesize(_ request: SpikeRequest) async throws -> [String: Any] {
        try validate(text: request.text, settings: request.settings)
        let workspace = try NativeWorkspace(root: request.workspace)
        try configureCache(workspace)
        let staging = try workspace.contained(request.spoolDirectory)
        guard staging.path.hasPrefix(workspace.nativeRoot.path + "/staging/") else { throw WorkerError.invalidRequest }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let started = Date()
        let engine = try await load(settings: request.settings, workspace: workspace)
        let (samples, rate) = try await engine.generate(text: request.text, settings: request.settings)
        let file = staging.appendingPathComponent("\(UUID().uuidString).f32")
        try writePCM(samples, to: file)
        return ["model": request.settings.model.rawValue, "sampleRate": rate, "frames": samples.count,
                "channels": 1, "pcmFile": file.path, "elapsedSeconds": Date().timeIntervalSince(started)]
    }

    private static func writePCM(_ samples: [Float], to file: URL) throws {
        let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw WorkerError.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try samples.withUnsafeBytes { try handle.write(contentsOf: $0) }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw WorkerError.storage
        }
    }
}

private struct WorkerContext {
    let identity: AttemptIdentity
    let spool: URL
    let settings: SpeechSettings
    let engine: LoadedEngine
}

/// Exactly one engine is owned by the worker's sequential command loop. It is
/// never sent to the GUI, a task group, or a second inference task.
private enum LoadedEngine {
    case kokoro(KokoroModel)
    case soprano(SopranoModel)

    func generate(text: String, settings: SpeechSettings) async throws -> ([Float], Int) {
        let audio: MLXArray
        let rate: Int
        switch self {
        case .kokoro(let model):
            audio = try await model.generate(text: text, voice: settings.voice, refAudio: nil, refText: nil,
                language: settings.voice.hasPrefix("b") ? "en-gb" : "en-us",
                generationParameters: model.defaultGenerationParameters)
            rate = model.sampleRate
        case .soprano(let model):
            audio = try await model.generate(text: text)
            rate = model.sampleRate
        }
        guard audio.ndim == 1, audio.size > 0, rate == settings.model.capabilities.sampleRate else {
            throw WorkerError.invalidPCM
        }
        let samples = audio.asArray(Float.self)
        guard samples.allSatisfy(\.isFinite), samples.count <= rate * 120 else { throw WorkerError.invalidPCM }
        return (samples, rate)
    }
}

private struct SpikeRequest: Decodable {
    let workspace: URL
    let settings: SpeechSettings
    let text: String
    let spoolDirectory: URL
}

enum WorkerError: Error {
    case unsupportedCommand, metalProbeFailed, invalidRequest, invalidPCM, storage
}
