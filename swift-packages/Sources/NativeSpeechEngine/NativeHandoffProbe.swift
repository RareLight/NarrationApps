import Foundation
import NarrationCore
import NativeSpeech
import MLX
import Darwin

/// VS00 only. Holds the existing current/legacy kernel locks in the actual
/// helper from before loading through EOF cancellation/drain and process exit.
/// Hosts must not acquire those locks themselves for this opt-in mode.
final class NativeHandoffProbeBackend: SpeechProbeBackend, @unchecked Sendable {
    private let requiresAdmission: Bool
    init(requiresAdmission: Bool = false) { self.requiresAdmission = requiresAdmission }
    private var engine: LoadedEngine?
    private var workspace: NativeWorkspace?
    private var settings: SpeechSettings?
    private var stage: URL?
    private var inference: InferenceLease?
    private var storage: ModelStorageLease?
    private var scratch: SpeechScratchLease?
    var resources: SpeechProbeResources {
        .init(preparationOnly: engine?.isTextPreparationOnly ?? true, usesInference: inference != nil)
    }

    func initialize(_ command: WorkerCommand, admission: SpeechWorkerAdmission?, report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void) async throws {
        guard !requiresAdmission || admission != nil else { throw SpeechFailure(.invalidInput) }
        guard command.kind == .initialize, engine == nil, let root = command.workspace,
              let selected = command.settings, let spool = command.spoolDirectory,
              selected.isValid else { throw SpeechFailure(.invalidInput) }
        let frontend = command.textPreparationOnly == true
        guard frontend || SpeechMemoryPolicy.canLoad(selected.model) else { throw SpeechFailure(.memoryLimit) }
        let workspace = try NativeWorkspace(root: root)
        let stage = try workspace.managed(spool)
        guard stage == spool, stage.path.hasPrefix(workspace.nativeRoot.path + "/staging/attempt-"),
              (try stage.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw SpeechFailure(.invalidInput) }
        scratch = try SpeechScratchLease(directory: stage, create: false, allowUnmarked: !requiresAdmission)
        storage = try ModelStorageLease(workspace: workspace)
        if !frontend || selected.model == .kokoro { try await acquire(admission, report: report) }
        try NativeSpeechWorker.configureCache(workspace)
        try Task.checkCancellation()
        try report(.loadingModel)
        let reference = ReferenceVoiceStore.isIdentifier(selected.voice) ? stage.appendingPathComponent("reference.wav") : nil
        engine = try await NativeSpeechWorker.load(settings: selected, workspace: workspace, reference: reference, textPreparationOnly: frontend)
        self.workspace = workspace; settings = selected; self.stage = stage
    }

    private func acquire(_ admission: SpeechWorkerAdmission?, report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void) async throws {
        guard inference == nil else { return }
        guard !requiresAdmission || admission != nil else { throw SpeechFailure(.invalidInput) }
        try report(.waitingForLease)
        if let admission { inference = try await admission.acquire() }
        else { inference = try await InferenceLease.acquire(priority: .background) }
        try report(.leaseAcquired)
    }

    func generate(_ command: WorkerCommand, mode: SpeechProbeAudioMode, admission: SpeechWorkerAdmission?,
                  report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void, started: @escaping @Sendable () throws -> Void,
                  emit: @escaping @Sendable (WorkerEvent) throws -> Void) async throws {
        guard let workspace, let initializedSettings = settings, let stage,
              [.loadSpeech, .generate, .prepareText, .generatePrepared].contains(command.kind) else { throw SpeechFailure(.invalidInput) }
        let settings = command.settings ?? initializedSettings
        guard settings.isValid, settings.model == initializedSettings.model,
              (!ReferenceVoiceStore.isIdentifier(settings.voice) && !ReferenceVoiceStore.isIdentifier(initializedSettings.voice)) ||
                settings.voice == initializedSettings.voice else { throw SpeechFailure(.invalidInput) }
        guard mode != .qwenIncremental || settings.model == .qwen3 else { throw SpeechFailure(.invalidInput) }
        if command.kind != .prepareText, engine?.isTextPreparationOnly != false {
            guard SpeechMemoryPolicy.canLoad(settings.model) else { throw SpeechFailure(.memoryLimit) }
            try await acquire(admission, report: report)
            let drain = engine?.usesInference == true
            engine = nil
            if drain { Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache() }
            try report(.loadingModel)
            let reference = ReferenceVoiceStore.isIdentifier(settings.voice) ? stage.appendingPathComponent("reference.wav") : nil
            engine = try await NativeSpeechWorker.load(settings: settings, workspace: workspace, reference: reference)
            try Task.checkCancellation()
        }
        guard let engine else { throw SpeechFailure(.invalidInput) }
        if let admission {
            let registry = try SpeechWorkAdmission(root: admission.root)
            guard try registry.withHighest(admission.demand, operation: { true }) == true else { throw SpeechProbePriorityYield() }
        }
        if command.kind == .loadSpeech { return }
        let spool = try workspace.managed(stage.appendingPathComponent("job-\(command.identity.attempt.uuidString)"))
        guard mkdir(spool.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        let policy = SpeechPreparationPolicy.selected(settings: settings, requested: command.policy ?? .current)
        if command.kind == .prepareText {
            guard let window = command.textWindow, command.chunk == 0,
                  !window.text.isEmpty, window.text.unicodeScalars.count <= 1_000 else { throw SpeechFailure(.invalidInput) }
            try started()
            let utterances = try engine.prepare(window: window, settings: settings, policy: policy, workers: command.textPreparationWorkers ?? 1)
            try PreparedSpeechCoverage.validate(utterances, window: window)
            let reference = try PreparedSpeechTransfer.write(utterances, index: 0, spool: spool)
            try Task.checkCancellation()
            try emit(.init(kind: .textPrepared, identity: command.identity, chunk: 0, preparedFile: reference))
            return
        }
        let writer = ProbeFrameWriter(spool: spool, identity: command.identity, emit: emit)
        if command.kind == .generatePrepared {
            guard let utterance = command.utterance, command.chunk == 0 else { throw SpeechFailure(.invalidInput) }
            try utterance.validate(identity: SpeechAcousticIdentity.make(settings: settings, policy: policy), prepared: policy.usesPreparedPhonemes)
            try Task.checkCancellation(); try started()
            let (samples, rate) = try await policy.usesPreparedPhonemes
                ? engine.generate(utterance: utterance, settings: settings)
                : engine.generate(text: utterance.text, settings: settings)
            try Task.checkCancellation()
            try writer.write(samples, rate: rate, source: utterance.source)
            return
        }
        guard let text = command.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 1_000 else { throw SpeechFailure(.invalidInput) }
        let blocks = text.components(separatedBy: "\n\n").map { ContentBlock(kind: .paragraph, text: $0, origin: .authored) }
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "synthetic-handoff-probe-1"), settings: settings)
        var windows = try SpeechTextWindows.boundedForControl(SpeechTextWindows.make(from: projection))
        guard !windows.isEmpty, windows.count <= 16 else { throw SpeechFailure(.invalidInput) }
        if mode != .paragraphs {
            windows.replaceSubrange(0..<1, with: try LiveSpeechFirstUnit.split(windows[0], language: settings.languageCode))
        }
        try Task.checkCancellation()
        var didStart = false
        // Match normal preparation's authored paragraph windows. Preparing the
        // entire prompt as one window can legitimately produce one indivisible
        // utterance; it cannot establish first audio before request completion.
        for window in windows {
            try Task.checkCancellation()
            let utterances = try engine.prepare(window: window, settings: settings, policy: policy)
            guard !utterances.isEmpty, utterances.count <= 16 else { throw SpeechFailure(.invalidInput) }
            try PreparedSpeechCoverage.validate(utterances, window: window)
            for utterance in utterances {
                try Task.checkCancellation()
                if !didStart { try started(); didStart = true }
                if mode == .qwenIncremental {
                    try engine.streamQwen(text: utterance.text, settings: settings) { pcm, rate in
                        try writer.write(pcm, rate: rate, source: utterance.source)
                    }
                    continue
                }
                let (samples, rate) = try await policy.usesPreparedPhonemes
                    ? engine.generate(utterance: utterance, settings: settings)
                    : engine.generate(text: utterance.text, settings: settings)
                try Task.checkCancellation()
                try writer.write(samples, rate: rate, source: utterance.source)
            }
        }
    }

    func quiesceAndReset() async throws {
        // Direct calls join all producers, including Soprano's patched internal
        // token task. Lazy evaluation/default-stream GPU submissions settle before
        // the host may start the next job or unload this model.
        if inference != nil {
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
        }
        // A cancelled/failed promotion can leave no reusable engine. Never
        // acknowledge ready for that half-loaded state; the owner must reap it.
        if workspace != nil, storage != nil, engine == nil { throw SpeechFailure(.generation) }
        // Per-call KV/conditioning/seed contexts live in the direct adapters.
        // Qwen's owned callback resets streaming state in its adapter defer.
        // Native measurements determine whether these paths can actually reuse.
    }

    func shutdown(report: @escaping @Sendable (SpeechProbeEvent.Kind) -> Void) async {
        let loaded = inference != nil
        engine = nil
        if loaded { Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache() }
        storage = nil
        if loaded { report(.unloaded) }
        inference = nil // Unload/drain precedes compatibility-lock release.
        scratch = nil
    }
}

private final class ProbeFrameWriter: @unchecked Sendable {
    let spool: URL
    let identity: AttemptIdentity
    let emit: @Sendable (WorkerEvent) throws -> Void
    private let lock = NSLock()
    private var index = 0
    private var frames = 0
    init(spool: URL, identity: AttemptIdentity, emit: @escaping @Sendable (WorkerEvent) throws -> Void) {
        self.spool = spool; self.identity = identity; self.emit = emit
    }
    func write(_ samples: [Float], rate: Int, source: SpokenSourceRange) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard index < 256, frames + samples.count <= rate * 120 else { throw SpeechFailure(.generation) }
            let file = SpeechIPC.chunkFile(in: spool, index: index)
            try NativeSpeechWorker.writePCM(samples, to: file)
            do {
                try emit(.init(kind: .chunk, identity: identity, chunk: index, sampleRate: rate,
                    frames: samples.count, channels: 1, pcmFile: file.path, source: source))
            } catch { try? FileManager.default.removeItem(at: file); throw error }
            frames += samples.count; index += 1
        }
    }
}
