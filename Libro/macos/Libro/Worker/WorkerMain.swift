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
                // Exercise non-leading scalar gather as well as basic arithmetic.
                let gathered = take(MLXArray(0..<12, [3, 4]), MLXArray(Int32(2)), axis: 1)
                    .asArray(Int32.self)
                guard result == [2, 4, 6], gathered == [2, 6, 10] else { throw WorkerError.metalProbeFailed }
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
            debugError(error)
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
                case .prepare:
                    guard context == nil, command.chunk == nil, command.text == nil, command.spoolDirectory == nil,
                          let root = command.workspace, let settings = command.settings else { throw SpeechFailure(.invalidInput) }
                    let workspace = try NativeWorkspace(root: root)
                    try configureCache(workspace)
                    let report: @Sendable (ModelPreparationProgress) -> Void = { value in
                        if let data = try? SpeechIPC.encode(WorkerEvent(kind: .assetProgress, identity: command.identity, preparation: value)) {
                            try? control.write(contentsOf: data)
                        }
                    }
                    try await preparePrimary(workspace, settings: settings, report: report)
                    if settings.model == .kokoro { try await prepareG2P(workspace, report: report) }
                    try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .prepared, identity: command.identity)))
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
                debugError(error)
                let code: SpeechFailureCode
                if command.kind == .prepare { code = .acquisition }
                else if let failure = error as? SpeechFailure { code = failure.code }
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

    private static func debugError(_ error: any Error) {
        guard ProcessInfo.processInfo.environment["LIBRO_DEBUG_LOG"] == "1" else { return }
        let description = "Libro debug error: \(String(reflecting: error))\n"
        try? FileHandle.standardError.write(contentsOf: Data(description.prefix(8_192).utf8))
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
        for url in [workspace.hubCache, workspace.nativeRoot.appendingPathComponent("hf"),
                    workspace.nativeRoot.appendingPathComponent("xet"), workspace.nativeRoot.appendingPathComponent("hf-assets")] {
            _ = try workspace.managed(url)
        }
        for name in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "TRANSFORMERS_CACHE"] {
            setenv(name, workspace.hubCache.path, 1)
        }
        setenv("HF_HOME", workspace.nativeRoot.appendingPathComponent("hf").path, 1)
        setenv("HF_XET_CACHE", workspace.nativeRoot.appendingPathComponent("xet").path, 1)
        setenv("HF_ASSETS_CACHE", workspace.nativeRoot.appendingPathComponent("hf-assets").path, 1)
    }

    private static func preparePrimary(_ workspace: NativeWorkspace, settings: SpeechSettings,
                                       report: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        let specification = NativePrimaryCatalog.specification(for: settings.model)
        let total = specification.files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        report(.init(scope: .primary, phase: .waiting, totalBytes: total))
        let lock = try acquisitionLock(workspace, name: settings.model.rawValue)
        defer { flock(lock, LOCK_UN); close(lock) }
        report(.init(scope: .primary, phase: .checking, totalBytes: total))
        let shared = workspace.root.appendingPathComponent(settings.model.primaryRelativePath)
        if (try? NativePrimaryStore.validate(directory: shared, specification: specification, workspace: workspace, sharedVoice: settings.voice)) != nil {
            try NativePrimaryStore.recordReuse(directory: shared, specification: specification, workspace: workspace, voice: settings.voice)
            report(.init(scope: .primary, phase: .reusing, completedBytes: total, totalBytes: total))
            return
        }
        let target = try NativePrimaryStore.nativeDirectory(specification, workspace: workspace)
        if (try? NativePrimaryStore.validateStaged(directory: target, specification: specification, workspace: workspace)) != nil { return }
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/primary-\(settings.model.rawValue)-\(specification.revision)"))
        let files = specification.files.map { AcquisitionFile(path: $0.path, bytes: $0.bytes, hash: $0.sha256, gitOID: $0.gitOID) }
        try await acquire(repository: specification.repository, revision: specification.revision, files: files,
                          stage: stage, workspace: workspace, scope: .primary, report: report)
        report(.init(scope: .primary, phase: .validating, completedBytes: total, totalBytes: total))
        try NativePrimaryStore.recordStaged(directory: stage, specification: specification, workspace: workspace)
        try NativePrimaryStore.validateStaged(directory: stage, specification: specification, workspace: workspace)
        report(.init(scope: .primary, phase: .publishing, completedBytes: total, totalBytes: total))
        try publishAssets(stage, to: target, workspace: workspace)
    }

    private static func prepareG2P(_ workspace: NativeWorkspace,
                                   report: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }) async throws {
        let target = try workspace.managed(workspace.g2pDirectory)
        let staging = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/g2p-\(NativeG2P.revision)"))
        let total = NativeG2P.requiredFiles.values.reduce(Int64(0)) { $0 + Int64($1) }
        report(.init(scope: .g2p, phase: .waiting, totalBytes: total))
        let lock = try acquisitionLock(workspace, name: "g2p")
        defer { flock(lock, LOCK_UN); close(lock) }
        report(.init(scope: .g2p, phase: .checking, totalBytes: total))
        if (try? NativeG2P.validate(directory: target, workspace: workspace)) != nil { return }
        let files = NativeG2P.requiredFiles.map { AcquisitionFile(path: $0.key, bytes: $0.value, hash: NativeG2P.sha256ByFile[$0.key]!, gitOID: nil) }
        try await acquire(repository: NativeG2P.repository, revision: NativeG2P.revision, files: files,
                          stage: staging, workspace: workspace, scope: .g2p, report: report)
        report(.init(scope: .g2p, phase: .validating, completedBytes: total, totalBytes: total))
        try NativeG2P.record(directory: staging, workspace: workspace)
        try NativeG2P.validate(directory: staging, workspace: workspace)
        report(.init(scope: .g2p, phase: .publishing, completedBytes: total, totalBytes: total))
        try publishAssets(staging, to: target, workspace: workspace)
    }

    private static func acquisitionLock(_ workspace: NativeWorkspace, name: String) throws -> Int32 {
        let url = try workspace.managed(workspace.nativeRoot.appendingPathComponent("locks/\(name).lock"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkerError.storage }
        guard flock(descriptor, LOCK_EX) == 0 else { close(descriptor); throw WorkerError.storage }
        return descriptor // Reaped helper exit releases a blocked/held OS lock.
    }

    private static func acquire(repository: String, revision: String, files: [AcquisitionFile], stage: URL,
                                workspace: NativeWorkspace, scope: ModelPreparationProgress.Scope,
                                report: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        _ = try workspace.managed(stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let cache = HubCache(cacheDirectory: workspace.hubCache)
        let client = HubClient(session: URLSession(configuration: configuration), host: HubClient.defaultHost,
                               cache: cache)
        guard let repo = Repo.ID(rawValue: repository) else { throw WorkerError.invalidRequest }
        var missing: [AcquisitionFile] = []
        var requiresNetwork = false
        let total = files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        let progress = AcquisitionProgress(total: total)
        for file in files {
            let destination = try workspace.managed(stage.appendingPathComponent(file.path))
            if file.matches(destination) { progress.value.completedUnitCount += Int64(file.bytes); continue }
            if FileManager.default.fileExists(atPath: destination.path) { try quarantine(destination, workspace: workspace) }
            if let cached = cache.cachedFilePath(repo: repo, kind: .model, revision: revision, filename: file.path) {
                let blob = try workspace.managed(cached.resolvingSymlinksInPath())
                guard blob.path.hasPrefix(workspace.hubCache.path + "/") else { throw NativeAssetError.outsideWorkspace }
                if !file.matches(blob) { try quarantine(blob, workspace: workspace); requiresNetwork = true }
            } else { requiresNetwork = true }
            missing.append(file)
        }
        if requiresNetwork {
            let tree = try await client.listFiles(in: repo, revision: revision)
            for file in files {
                guard let entry = tree.first(where: { $0.path == file.path }), entry.type == .file,
                      entry.size == file.bytes, file.gitOID == nil || entry.oid == file.gitOID else { throw NativeAssetError.changed(file.path) }
            }
        }
        let updates = Task {
            while !Task.isCancelled {
                report(.init(scope: scope, phase: .downloading,
                             completedBytes: min(total, max(0, progress.value.completedUnitCount)), totalBytes: total))
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        defer { updates.cancel() }
        // Hub owns HTTP and cache locks. Completed-file reuse is verified;
        // interrupted-file byte resumption remains an acceptance gate.
        // File APIs avoid the snapshot shortcut copying unrequested files.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func submit(_ file: AcquisitionFile) {
                let child = AcquisitionProgress(total: Int64(file.bytes))
                progress.value.addChild(child.value, withPendingUnitCount: Int64(file.bytes))
                group.addTask {
                    let destination = try workspace.managed(stage.appendingPathComponent(file.path))
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try await client.downloadFile(at: file.path, from: repo, to: destination, revision: revision, progress: child.value, transport: .lfs)
                    guard file.matches(destination) else { throw NativeAssetError.changed(file.path) }
                    child.value.completedUnitCount = child.value.totalUnitCount
                }
            }
            for _ in 0..<min(2, missing.count) { submit(missing[next]); next += 1 }
            while try await group.next() != nil {
                if next < missing.count { submit(missing[next]); next += 1 }
            }
        }
    }

    private static func quarantine(_ url: URL, workspace: NativeWorkspace) throws {
        _ = try workspace.managed(url)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("invalid-\(UUID().uuidString)"))
    }

    private static func publishAssets(_ stage: URL, to target: URL, workspace: NativeWorkspace) throws {
        _ = try workspace.managed(stage); _ = try workspace.managed(target)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try quarantine(target, workspace: workspace)
        }
        try FileManager.default.moveItem(at: stage, to: target)
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

private struct AcquisitionFile: Sendable {
    let path: String
    let bytes: Int
    let hash: String
    let gitOID: String?
    func matches(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes && (try? NativeG2P.sha256(url)) == hash
    }
}

/// Foundation Progress synchronizes its counters; only that object crosses
/// the SDK download/progress tasks. No model state is involved.
private final class AcquisitionProgress: @unchecked Sendable {
    let value: Progress
    init(total: Int64) { value = Progress(totalUnitCount: total) }
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
