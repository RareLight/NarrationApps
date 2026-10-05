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
            let response: [String: Any]
            if arguments == ["--probe"] {
                let result = (MLXArray([Float(1), 2, 3]) * 2).asArray(Float.self)
                guard result == [2, 4, 6] else { throw WorkerError.metalProbeFailed }
                response = ["metal": "ready", "worker": "LibroSpeechWorker"]
            } else if arguments.count == 2, arguments[0] == "--prepare-g2p" {
                let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
                configureCache(workspace)
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
            // Never echo narration text. M3 will add categorized, attempt-scoped events.
            try? FileHandle.standardError.write(contentsOf: Data("Worker failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func configureCache(_ workspace: NativeWorkspace) {
        for name in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "TRANSFORMERS_CACHE"] {
            setenv(name, workspace.hubCache.path, 1)
        }
        setenv("HF_HOME", workspace.nativeRoot.appendingPathComponent("hf").path, 1)
        setenv("HF_XET_CACHE", workspace.nativeRoot.appendingPathComponent("xet").path, 1)
        setenv("HF_ASSETS_CACHE", workspace.nativeRoot.appendingPathComponent("hf-assets").path, 1)
    }

    private static func prepareG2P(_ workspace: NativeWorkspace) async throws {
        let target = try workspace.contained(workspace.g2pDirectory)
        let staging = try workspace.contained(workspace.nativeRoot.appendingPathComponent("staging/g2p-\(NativeG2P.revision)"))
        let lockURL = try workspace.contained(workspace.nativeRoot.appendingPathComponent("locks/g2p.lock"))
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
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.unicodeScalars.count <= 1_000, request.settings.speed.isFinite,
              request.settings.speed > 0 else { throw WorkerError.invalidRequest }
        let workspace = try NativeWorkspace(root: request.workspace)
        configureCache(workspace)
        let primary = try workspace.primaryDirectory(for: request.settings.model, voice: request.settings.voice)
        let staging = try workspace.contained(request.spoolDirectory)
        guard staging.path.hasPrefix(workspace.nativeRoot.path + "/staging/") else { throw WorkerError.invalidRequest }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let started = Date()
        let audio: MLXArray
        let rate: Int
        switch request.settings.model {
        case .kokoro:
            try NativeG2P.validate(directory: workspace.g2pDirectory, workspace: workspace)
            let processor = MisakiTextProcessor(resourceDirectory: workspace.g2pDirectory)
            let model = try await KokoroModel.fromModelDirectory(primary, textProcessor: processor)
            model.speed = request.settings.speed
            audio = try await model.generate(text: request.text, voice: request.settings.voice,
                refAudio: nil, refText: nil, language: request.settings.voice.hasPrefix("b") ? "en-gb" : "en-us",
                generationParameters: model.defaultGenerationParameters)
            rate = model.sampleRate
        case .soprano:
            let model = try await SopranoModel.fromModelDirectory(primary, repo: request.settings.model.repository)
            audio = try await model.generate(text: request.text)
            rate = model.sampleRate
        }
        guard audio.ndim == 1, audio.size > 0, rate > 0 else { throw WorkerError.invalidPCM }
        let samples = audio.asArray(Float.self)
        guard samples.allSatisfy(\.isFinite), samples.count <= rate * 120 else { throw WorkerError.invalidPCM }
        let file = staging.appendingPathComponent("\(UUID().uuidString).f32")
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
            throw error
        }
        return ["model": request.settings.model.rawValue, "sampleRate": rate, "frames": samples.count,
                "channels": 1, "pcmFile": file.path, "elapsedSeconds": Date().timeIntervalSince(started)]
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
