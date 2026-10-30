import Foundation
import NarrationCore
import NativeSpeech
import MLX
import MLXAudioCore
import MLXAudioTTS
import HuggingFace
import Darwin
import CryptoKit

public enum NativeSpeechWorker {
    public static func main() async {
        Memory.cacheLimit = SpeechMemoryPolicy.cacheLimitBytes
        Memory.memoryLimit = SpeechMemoryPolicy.workingLimitBytes
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
                response = ["metal": "ready", "worker": "NativeSpeechWorker"]
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
            try? FileHandle.standardError.write(contentsOf: Data("Native speech worker failed.\n".utf8))
            exit(1)
        }
    }

    private static func serve(control: FileHandle) async throws {
        let reader = WorkerCommandReader()
        var context: WorkerContext?
        while let command = try reader.next() {
            do {
                guard command.protocolVersion == SpeechIPC.protocolVersion else { throw SpeechFailure(.invalidInput) }
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
                    if settings.model == .kokoro {
                        try await prepareG2P(workspace, report: report)
                        if settings.voice.hasPrefix("b") { try await prepareBritishG2P(workspace, report: report) }
                    }
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
                    let engine = try await load(settings: settings, workspace: workspace, reference: staging.appendingPathComponent("reference.wav"))
                    context = WorkerContext(identity: command.identity, spool: staging, settings: settings, engine: engine,
                        policy: settings.model == .kokoro ? .current : command.policy ?? .legacy)
                    try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .ready, identity: command.identity)))
                case .generate:
                    guard let context, context.identity == command.identity, !context.policy.usesPreparedPhonemes,
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
                case .prepareText:
                    guard let context, context.identity == command.identity,
                          (context.policy.usesPreparedPhonemes || context.settings.planning != nil),
                          let window = command.textWindow, let index = command.chunk, index >= 0,
                          window.text.unicodeScalars.count <= 1_000, !window.text.isEmpty else {
                        throw SpeechFailure(.invalidInput)
                    }
                    let utterances = try context.engine.prepare(window: window, settings: context.settings, policy: context.policy)
                    let reference = try PreparedSpeechTransfer.write(utterances, index: index, spool: context.spool)
                    try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .textPrepared,
                        identity: context.identity, chunk: index, preparedFile: reference)))
                case .generatePrepared:
                    guard let context, context.identity == command.identity,
                          context.policy.usesPreparedPhonemes, let utterance = command.utterance,
                          let chunk = command.chunk, chunk >= 0 else { throw SpeechFailure(.invalidInput) }
                    try utterance.validate(identity: SpeechAcousticIdentity.make(settings: context.settings, policy: context.policy), prepared: true)
                    let (samples, rate) = try await context.engine.generate(utterance: utterance, settings: context.settings)
                    let file = SpeechIPC.chunkFile(in: context.spool, index: chunk)
                    try writePCM(samples, to: file)
                    try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .chunk, identity: context.identity,
                        chunk: chunk, sampleRate: rate, frames: samples.count, channels: 1, pcmFile: file.path)))
                case .cancel, .shutdown:
                    guard context == nil || context?.identity == command.identity else { continue }
                    return
                }
            } catch {
                debugError(error)
                let code: SpeechFailureCode
                if command.kind == .prepare { code = .acquisition }
                else if error is SpeechPreparationError { code = .textPreparation }
                else if let failure = error as? SpeechFailure { code = failure.code }
                else if error is NativeAssetError || error is DecodingError { code = .invalidInput }
                else if let failure = error as? AudioGenerationError {
                    // Includes Kokoro's actual phoneme-token ceiling. Replaying
                    // the same invalid text cannot fix that input.
                    if case .invalidInput = failure { code = .invalidInput }
                    else { code = .generation }
                }
                else if let failure = error as? WorkerError {
                    code = failure == .storage ? .storage : (failure == .invalidRequest ? .invalidInput : .generation)
                } else if (error as NSError).domain == NSCocoaErrorDomain { code = .storage }
                else { code = .generation }
                try control.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure, identity: command.identity,
                                                                           chunk: command.chunk, failure: code, source: (error as? SpeechPreparationError)?.source)))
                return // Failed model state is never reused for more inference.
            }
        }
    }

    private static func debugError(_ error: any Error) {
        guard ProcessInfo.processInfo.environment["NARRATION_DEBUG_LOG"] == "1" else { return }
        let description = "Native speech debug error: \(String(reflecting: error))\n"
        try? FileHandle.standardError.write(contentsOf: Data(description.prefix(8_192).utf8))
    }

    private static func validate(text: String, settings: SpeechSettings) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 1_000, settings.speed.isFinite,
              settings.speed > 0 else { throw WorkerError.invalidRequest }
    }

    private static func load(settings: SpeechSettings, workspace: NativeWorkspace, reference: URL? = nil) async throws -> LoadedEngine {
        guard settings.isValid else { throw SpeechFailure(.invalidInput) }
        Memory.memoryLimit = SpeechMemoryPolicy.workingLimit(for: settings.model)
        let primary = try workspace.primaryDirectory(for: settings.model, voice: settings.voice)
        switch settings.model {
        case .kokoro:
            let directory: URL
            do { directory = try workspace.pronunciationDirectory(for: settings) }
            catch where settings.voice.hasPrefix("b") { throw SpeechFailure(.regionalAssets) }
            let processor = MisakiTextProcessor(resourceDirectory: directory)
            let model = try await KokoroModel.fromModelDirectory(primary, textProcessor: processor)
            model.speed = settings.speed
            return .kokoro(model)
        case .soprano:
            return .soprano(try await SopranoModel.fromModelDirectory(primary, repo: settings.model.repository))
        case .qwen3:
            let model = try await Qwen3TTSModel.fromModelDirectory(primary)
            model.narrationMaximumTokens = settings.model.maximumGeneratedTokens
            try NativePrimaryStore.validateGenerated(directory: primary, specification: NativePrimaryCatalog.specification(for: .qwen3))
            return .qwen3(model)
        case .chatterbox:
            let dependency = NativePrimaryCatalog.dependencies(for: .chatterbox)[0]
            let folder = try NativePrimaryStore.directory(specification: dependency, workspace: workspace, voice: settings.voice)
            let model = try await ChatterboxModel.fromModelDirectory(primary, hfToken: nil, narrationTokenizerDirectory: folder)
            try NativePrimaryStore.validateGenerated(directory: primary, specification: NativePrimaryCatalog.specification(for: .chatterbox))
            model.preserveNarrationPCM = true
            guard model.s3Tokenizer != nil, let defaults = model.defaultConditioning, defaults.condPromptSpeechTokens.size > 0 else { throw SpeechFailure(.invalidInput) }
            var referenceAudio: MLXArray?
            if ReferenceVoiceStore.isIdentifier(settings.voice) {
                guard let reference else { throw NativeAssetError.missing("reference recording") }
                try workspace.validateFile(reference)
                let bytes = try Data(contentsOf: reference)
                guard bytes.count <= 20_000_000, settings.voice == "reference:" + SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() else { throw NativeAssetError.changed("reference recording") }
                let (_, audio) = try loadAudioArray(from: reference, sampleRate: model.sampleRate)
                referenceAudio = audio
            }
            return .chatterbox(model, referenceAudio)
        case .orpheus:
            let dependency = NativePrimaryCatalog.dependencies(for: .orpheus)[0]
            let folder = try NativePrimaryStore.directory(specification: dependency, workspace: workspace, voice: settings.voice)
            return .orpheus(try await LlamaTTSModel.fromModelDirectory(primary, narrationCodecDirectory: folder))
        }
    }

    private static func configureCache(_ workspace: NativeWorkspace) throws {
        if !workspace.usesSharedHub { _ = try workspace.managed(workspace.hubCache) }
        for url in [workspace.nativeRoot.appendingPathComponent("hf"),
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
        let specs = [NativePrimaryCatalog.specification(for: settings.model)] + NativePrimaryCatalog.dependencies(for: settings.model)
        let total = NativePrimaryCatalog.totalBytes(for: settings.model)
        var completed: Int64 = 0
        for spec in specs {
            let offset = completed
            try await prepareSpecification(spec, workspace: workspace, settings: settings) { value in
                report(.init(scope: .primary, phase: value.phase, completedBytes: offset + value.completedBytes, totalBytes: total))
            }
            completed += spec.files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        }
    }

    private static func prepareSpecification(_ specification: NativePrimarySpecification, workspace: NativeWorkspace, settings: SpeechSettings,
        report: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        let total = specification.files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        report(.init(scope: .primary, phase: .waiting, totalBytes: total))
        let lock = try acquisitionLock(workspace, name: settings.model.rawValue + "-" + specification.revision)
        defer { flock(lock, LOCK_UN); close(lock) }
        report(.init(scope: .primary, phase: .checking, totalBytes: total))
        let shared = workspace.root.appendingPathComponent("models/\(settings.model.rawValue)/\(specification.repository.replacingOccurrences(of: "/", with: "__"))")
        if (try? NativePrimaryStore.validate(directory: shared, specification: specification, workspace: workspace, sharedVoice: settings.voice)) != nil {
            try NativePrimaryStore.recordReuse(directory: shared, specification: specification, workspace: workspace, voice: settings.voice)
            report(.init(scope: .primary, phase: .reusing, completedBytes: total, totalBytes: total))
            return
        }
        let target = try NativePrimaryStore.nativeDirectory(specification, workspace: workspace)
        if (try? NativePrimaryStore.validateStaged(directory: target, specification: specification, workspace: workspace)) != nil { return }
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/primary-\(settings.model.rawValue)-\(specification.revision)"))
        let files = specification.files.map { NativeAcquisitionFile(path: $0.path, bytes: $0.bytes, hash: $0.sha256, gitOID: $0.gitOID.isEmpty ? nil : $0.gitOID) }
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
        let files = NativeG2P.requiredFiles.map { NativeAcquisitionFile(path: $0.key, bytes: $0.value, hash: NativeG2P.sha256ByFile[$0.key]!, gitOID: nil) }
        try await acquire(repository: NativeG2P.repository, revision: NativeG2P.revision, files: files,
                          stage: staging, workspace: workspace, scope: .g2p, report: report)
        report(.init(scope: .g2p, phase: .validating, completedBytes: total, totalBytes: total))
        try NativeG2P.record(directory: staging, workspace: workspace)
        try NativeG2P.validate(directory: staging, workspace: workspace)
        report(.init(scope: .g2p, phase: .publishing, completedBytes: total, totalBytes: total))
        try publishAssets(staging, to: target, workspace: workspace)
    }

    /// Explicit installation only. Download bounded pinned files with native
    /// URLSession; no network access exists in load/preparation-for-generation.
    private static func prepareBritishG2P(_ workspace: NativeWorkspace,
        report: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        let total = BritishG2P.totalBytes
        report(.init(scope: .g2p, phase: .waiting, totalBytes: total))
        let lock = try acquisitionLock(workspace, name: "g2p-gb")
        defer { flock(lock, LOCK_UN); close(lock) }
        let target = try workspace.managed(BritishG2P.directory(in: workspace))
        report(.init(scope: .g2p, phase: .checking, totalBytes: total))
        if (try? BritishG2P.validate(directory: target, workspace: workspace)) != nil { return }
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/g2p-gb-\(BritishG2P.revision)"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in BritishG2P.requiredFiles {
            let destination = try workspace.managed(stage.appendingPathComponent(file.path))
            if try !file.quarantineInvalidCopy(at: destination, workspace: workspace) {
                let (bytes, response) = try await session.bytes(from: BritishG2P.sourceURL(for: file))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      response.expectedContentLength == -1 || response.expectedContentLength == file.bytes else {
                    throw NativeAssetError.changed(file.path)
                }
                // Bounded temporary buffer and exact received-byte ceiling.
                var data = Data(); data.reserveCapacity(file.bytes)
                for try await byte in bytes {
                    if data.count % 65_536 == 0 { try Task.checkCancellation() }
                    guard data.count < file.bytes else { throw NativeAssetError.changed(file.path) }
                    data.append(byte)
                }
                try NativeAtomicFile.write(data, to: destination, workspace: workspace)
                guard try file.matches(destination) else { throw NativeAssetError.changed(file.path) }
            }
            completed += Int64(file.bytes)
            report(.init(scope: .g2p, phase: .downloading, completedBytes: completed, totalBytes: total))
        }
        report(.init(scope: .g2p, phase: .validating, completedBytes: total, totalBytes: total))
        try BritishG2P.record(directory: stage, workspace: workspace)
        try BritishG2P.validate(directory: stage, workspace: workspace)
        report(.init(scope: .g2p, phase: .publishing, completedBytes: total, totalBytes: total))
        try publishAssets(stage, to: target, workspace: workspace)
    }

    private static func acquisitionLock(_ workspace: NativeWorkspace, name: String) throws -> Int32 {
        let url = try workspace.managed(workspace.nativeRoot.appendingPathComponent("locks/\(name).lock"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkerError.storage }
        guard flock(descriptor, LOCK_EX) == 0 else { close(descriptor); throw WorkerError.storage }
        return descriptor // Reaped helper exit releases a blocked/held OS lock.
    }

    private static func acquire(repository: String, revision: String, files: [NativeAcquisitionFile], stage: URL,
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
        var missing: [NativeAcquisitionFile] = []
        var requiresNetwork = false
        let total = files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        let progress = NativeAcquisitionProgress(total: total)
        for file in files {
            let destination = try workspace.managed(stage.appendingPathComponent(file.path))
            if try file.quarantineInvalidCopy(at: destination, workspace: workspace) {
                progress.value.completedUnitCount += Int64(file.bytes); continue
            }
            if let cached = cache.cachedFilePath(repo: repo, kind: .model, revision: revision, filename: file.path) {
                let blob = try workspace.cached(cached.resolvingSymlinksInPath())
                guard blob.path.hasPrefix(workspace.hubCache.path + "/") else { throw NativeAssetError.outsideWorkspace }
                if workspace.usesSharedHub {
                    guard try file.matches(blob) else { throw NativeAssetError.changed(file.path) }
                } else if try !file.quarantineInvalidCopy(at: blob, workspace: workspace) { requiresNetwork = true }
            } else { requiresNetwork = true }
            missing.append(file)
        }
        if requiresNetwork {
            let tree = try await client.listFiles(in: repo, revision: revision)
            for file in files {
                guard let entry = tree.first(where: { $0.path == file.path }), entry.type == .file,
                      entry.size == file.bytes, file.gitOID == nil || entry.oid == file.gitOID else { throw NativeAssetError.changed(file.path) }
                // Hub may find an orphan blob by ETag even with no snapshot
                // entry. Git files use their blob OID; LFS uses SHA-256.
                // Validate both possible identities before Hub's fast path.
                for etag in Set([entry.oid, file.hash].compactMap { $0 }) {
                    let blob = try cache.blobPath(repo: repo, kind: .model, etag: etag)
                    if workspace.usesSharedHub {
                        _ = try workspace.cached(blob)
                        if FileManager.default.fileExists(atPath: blob.path), try !file.matches(blob) { throw NativeAssetError.changed(file.path) }
                    } else { _ = try file.quarantineInvalidCopy(at: blob, workspace: workspace) }
                }
            }
        }
        let updates = Task {
            while !Task.isCancelled {
                report(.init(scope: scope, phase: .downloading,
                             completedBytes: progress.completedBytes, totalBytes: total))
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        defer { updates.cancel() }
        // Hub owns HTTP, cache locks and workspace-local incomplete blobs.
        // File APIs avoid the snapshot shortcut copying unrequested files.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func submit(_ file: NativeAcquisitionFile) {
                let child = NativeAcquisitionProgress(total: Int64(file.bytes))
                progress.value.addChild(child.value, withPendingUnitCount: Int64(file.bytes))
                group.addTask {
                    let destination = try workspace.managed(stage.appendingPathComponent(file.path))
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let cached = try await client.downloadFile(at: file.path, from: repo, to: workspace.usesSharedHub ? nil : destination, revision: revision,
                                                      progress: child.value, transport: .lfs, downloadInCache: true)
                    if workspace.usesSharedHub {
                        let blob = try workspace.cached(cached.resolvingSymlinksInPath())
                        guard try file.matches(blob) else { throw NativeAssetError.changed(file.path) }
                        // Immutable Hub bytes stay shareable. Runtime-generated
                        // tokenizer metadata is written only in this overlay.
                        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: blob)
                    }
                    guard try file.matches(destination) else { throw NativeAssetError.changed(file.path) }
                    if ProcessInfo.processInfo.environment["NARRATION_DEBUG_LOG"] == "1" {
                        let offset = child.value.userInfo[ProgressUserInfoKey("cacheDownloadResumeOffset")] as? Int64 ?? 0
                        try? FileHandle.standardError.write(contentsOf: Data("Native prepared asset: \(file.path), resumedBytes=\(offset)\n".utf8))
                    }
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

private struct WorkerContext {
    let identity: AttemptIdentity
    let spool: URL
    let settings: SpeechSettings
    let engine: LoadedEngine
    let policy: SpeechPreparationPolicy
}

/// Exactly one engine is owned by the worker's sequential command loop. It is
/// never sent to the GUI, a task group, or a second inference task.
private enum LoadedEngine {
    case kokoro(KokoroModel)
    case soprano(SopranoModel)
    case qwen3(Qwen3TTSModel), chatterbox(ChatterboxModel, MLXArray?), orpheus(LlamaTTSModel)

    func prepare(window: SpeechTextWindow, settings: SpeechSettings, policy: SpeechPreparationPolicy) throws -> [PreparedUtterance] {
        defer { Memory.clearCache() }
        let identity = SpeechAcousticIdentity.make(settings: settings, policy: policy)
        if case .kokoro(let model) = self {
            guard let processor = model.textProcessor as? MisakiTextProcessor else { throw SpeechFailure(.invalidInput) }
            let aligned = try processor.processAligned(text: window.text, language: settings.voice.hasPrefix("b") ? "en-gb" : "en-us")
            let tokens = try PronunciationPhoneOverrides.apply(window: window,
                tokens: aligned.map { .init(range: $0.sourceRange, phonemes: $0.phonemes, whitespace: $0.whitespace) })
            return try PhonemeUtterancePacker.pack(window: window, tokens: tokens,
                vocabulary: model.supportedPhonemeVocabulary, identity: identity, semantic: true)
        }
        guard settings.planning != nil else { throw SpeechFailure(.invalidInput) }
        let measure: (String) throws -> Int
        switch self {
        case .qwen3(let model):
            measure = { try model.narrationTokenCount($0) }
        case .chatterbox(let model, _):
            guard let tokenizer = model.tokenizer else { throw SpeechFailure(.invalidInput) }
            measure = { tokenizer.encode(text: $0).count }
        case .orpheus(let model):
            guard let tokenizer = model.tokenizer else { throw SpeechFailure(.invalidInput) }
            measure = { tokenizer.encode(text: $0).count }
        case .soprano:
            // Soprano's public frontend owns its tokenizer; retain a scalar
            // budget rather than pretending to expose native token counts.
            measure = { $0.unicodeScalars.count }
        default: throw SpeechFailure(.invalidInput)
        }
        let target = settings.model == .soprano ? 180 : settings.model == .chatterbox ? 80 : 96
        let slices = try SemanticSpeechSegmentation.slices(window.text, language: settings.languageCode,
            target: target, maximum: settings.model == .soprano ? 480 : 512, measure: measure)
        return slices.compactMap { slice in
            let raw = window.text[slice.range]
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let range = raw.range(of: text) else { return nil }
            return PreparedUtterance(text: text, phonemes: nil, tokenCount: 0,
                source: .init(blockIndices: window.source.blockIndices, location: window.source.location + NSRange(range, in: window.text).location,
                              length: text.utf16.count, origin: window.source.origin),
                boundaryAfter: slice.range.upperBound == window.text.endIndex ? window.boundaryAfter : slice.boundary,
                acousticIdentity: identity)
        }
    }

    func generate(utterance: PreparedUtterance, settings: SpeechSettings) async throws -> ([Float], Int) {
        defer { Memory.clearCache() }
        if let seed = settings.seed { MLXRandom.seed(seed) }
        guard case .kokoro(let model) = self, let phonemes = utterance.phonemes else { throw SpeechFailure(.invalidInput) }
        let audio = try await model.generatePrepared(phonemes: phonemes, voice: settings.voice, speed: settings.speed)
        return try samples(audio, rate: model.sampleRate, settings: settings)
    }

    private func samples(_ audio: MLXArray, rate: Int, settings: SpeechSettings) throws -> ([Float], Int) {
        guard (audio.ndim == 1 || (audio.ndim == 2 && audio.dim(0) == 1)), audio.size > 0, audio.size <= rate * 120,
              rate == settings.model.capabilities.sampleRate else { throw WorkerError.invalidPCM }
        let samples = audio.reshaped([-1]).asArray(Float.self)
        guard samples.allSatisfy(\.isFinite), !settings.model.isLarge || samples.contains(where: { $0 != 0 }) else { throw WorkerError.invalidPCM }
        return (samples, rate)
    }

    func generate(text: String, settings: SpeechSettings) async throws -> ([Float], Int) {
        // generatePCM returns owned CPU samples after its MLX arrays leave scope.
        // Clearing only free buffers preserves the model, voice and RNG state.
        defer { Memory.clearCache() }
        return try await generatePCM(text: text, settings: settings)
    }

    private func generatePCM(text: String, settings: SpeechSettings) async throws -> ([Float], Int) {
        if let seed = settings.seed { MLXRandom.seed(seed) }
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
        case .qwen3(let model):
            try model.validateNarrationInput(text)
            let voice = settings.voice + (settings.styleInstruction.map { ", " + $0 } ?? "")
            var parameters = model.defaultGenerationParameters; parameters.seed = settings.seed
            audio = try await model.generate(text: text, voice: voice, refAudio: nil, refText: nil, language: settings.effectiveLanguage, generationParameters: parameters)
            guard model.narrationCompleted else { throw SpeechFailure(.generation) }
            rate = model.sampleRate
        case .chatterbox(let model, let reference):
            try model.validateNarrationInput(text)
            var parameters = model.defaultGenerationParameters; parameters.seed = settings.seed
            audio = try await model.generate(text: text, voice: nil, refAudio: reference, refText: nil, language: "en", generationParameters: parameters)
            guard model.narrationCompleted else { throw SpeechFailure(.generation) }
            rate = model.sampleRate
        case .orpheus(let model):
            try model.validateNarrationInput(text)
            var parameters = model.defaultGenerationParameters
            parameters.seed = settings.seed
            parameters.maxTokens = settings.model.maximumGeneratedTokens
            audio = try await model.generate(text: text, voice: settings.voice, refAudio: nil, refText: nil, language: "en", generationParameters: parameters)
            guard model.narrationCompleted else { throw SpeechFailure(.generation) }
            rate = model.sampleRate
        }
        return try samples(audio, rate: rate, settings: settings)
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
