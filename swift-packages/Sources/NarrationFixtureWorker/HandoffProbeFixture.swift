import Foundation
import NarrationCore
import NativeSpeech
import Darwin

/// Uses the exact probe control/producer/credit seam without native models.
final class HandoffProbeFixture: SpeechProbeBackend, @unchecked Sendable {
    private var stage: URL?
    private var lease: InferenceLease?
    private var settings = SpeechSettings()
    private var preparationOnly = false
    private var scratch: SpeechScratchLease?
    var resources: SpeechProbeResources { .init(preparationOnly: preparationOnly, usesInference: lease != nil) }
    private func waitIgnoringCancellation(_ flag: URL) {
        while FileManager.default.fileExists(atPath: flag.path) { Thread.sleep(forTimeInterval: 0.005) }
    }
    func initialize(_ command: WorkerCommand, admission: SpeechWorkerAdmission?, report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void) async throws {
        guard let stage = command.spoolDirectory else { throw SpeechFailure(.invalidInput) }
        self.stage = stage
        scratch = try SpeechScratchLease(directory: stage, create: false, allowUnmarked: admission == nil)
        settings = command.settings ?? .init()
        preparationOnly = command.textPreparationOnly == true
        if ProcessInfo.processInfo.environment["NARRATION_FIXTURE_LOAD_BARRIER"] == "1" {
            try Data().write(to: stage.appendingPathComponent("delay-load"))
        }
        if !preparationOnly || settings.model == .kokoro { try await acquire(admission, stage: stage, report: report) }
        try report(.loadingModel)
        if FileManager.default.fileExists(atPath: stage.appendingPathComponent("stall-load").path) {
            // Intentionally ignores cancellation to exercise owned reap fallback.
            waitIgnoringCancellation(stage.appendingPathComponent("stall-load"))
        }
        do {
            while FileManager.default.fileExists(atPath: stage.appendingPathComponent("delay-load").path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            if FileManager.default.fileExists(atPath: stage.appendingPathComponent("fail-load").path) { throw SpeechFailure(.generation) }
            try Data().write(to: stage.appendingPathComponent(preparationOnly ? "frontend-initialized" : "speech-loaded"))
        } catch {
            waitIgnoringCancellation(stage.appendingPathComponent("delay-load-drain"))
            throw error
        }
    }
    private func acquire(_ admission: SpeechWorkerAdmission?, stage: URL, report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void) async throws {
        guard lease == nil else { return }
        try report(.waitingForLease)
        if let admission { lease = try await admission.acquire() }
        else { lease = try await InferenceLease.acquire(at: stage.appendingPathComponent("fixture-inference.lock")) }
        try report(.leaseAcquired)
    }
    func generate(_ command: WorkerCommand, mode: SpeechProbeAudioMode, admission: SpeechWorkerAdmission?,
                  report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void, started: @escaping @Sendable () throws -> Void,
                  emit: @escaping @Sendable (WorkerEvent) throws -> Void) async throws {
        guard let stage else { throw SpeechFailure(.invalidInput) }
        if preparationOnly, command.kind != .prepareText {
            try Data().write(to: stage.appendingPathComponent("promotion-started"))
            try await acquire(admission, stage: stage, report: report)
            try report(.loadingModel)
            while FileManager.default.fileExists(atPath: stage.appendingPathComponent("delay-promotion").path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try Data().write(to: stage.appendingPathComponent("speech-loaded")); preparationOnly = false
        }
        if let admission {
            let registry = try SpeechWorkAdmission(root: admission.root)
            guard try registry.withHighest(admission.demand, operation: { true }) == true else { throw SpeechProbePriorityYield() }
        }
        if command.kind == .loadSpeech { return }
        try started()
        try Data(command.identity.job.uuidString.utf8).write(to: stage.appendingPathComponent("generation-started"))
        if FileManager.default.fileExists(atPath: stage.appendingPathComponent("stall-generation").path) {
            waitIgnoringCancellation(stage.appendingPathComponent("stall-generation"))
        }
        do {
            while FileManager.default.fileExists(atPath: stage.appendingPathComponent("hold-generation").path) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            try? Data().write(to: stage.appendingPathComponent("generation-cancelled")); throw error
        }
        if command.text == "stall" || command.utterance?.text == "stall" { try await Task.sleep(for: .seconds(60)) }
        if command.kind == .prepareText || command.kind == .generatePrepared {
            let spool = stage.appendingPathComponent("job-\(command.identity.attempt.uuidString)")
            guard mkdir(spool.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
            let selected = command.settings ?? settings
            let policy = SpeechPreparationPolicy.selected(settings: selected, requested: command.policy ?? .current)
            if command.kind == .prepareText {
                if ProcessInfo.processInfo.environment["NARRATION_FIXTURE_FAIL_PREPARATION"] == "1" { throw SpeechFailure(.invalidInput) }
                guard let window = command.textWindow else { throw SpeechFailure(.invalidInput) }
                let utterance = PreparedUtterance(text: window.text, phonemes: policy.usesPreparedPhonemes ? "a" : nil,
                    tokenCount: policy.usesPreparedPhonemes ? 1 : 0, source: window.source, boundaryAfter: window.boundaryAfter,
                    acousticIdentity: SpeechAcousticIdentity.make(settings: selected, policy: policy))
                let file = try PreparedSpeechTransfer.write([utterance], index: 0, spool: spool)
                try emit(.init(kind: .textPrepared, identity: command.identity, chunk: 0, preparedFile: file)); return
            }
            let file = SpeechIPC.chunkFile(in: spool, index: 0)
            let samples: [Float]
            if ProcessInfo.processInfo.environment["NARRATION_FIXTURE_SYNTHETIC_PCM"] == "1" {
                // Distinct deterministic fixture tones keep inspection caches
                // from hiding per-chunk validation barriers in pipeline tests.
                let seed = (command.utterance?.text ?? "").unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 300 }
                let rate = Double(selected.model.capabilities.sampleRate), frequency = Double(200 + seed)
                samples = (0..<2_400).map { Float(sin(Double($0) * 2 * .pi * frequency / rate) * 0.1) }
            } else { samples = [0, 0.1, -0.1, 0] }
            try samples.withUnsafeBytes { try Data($0).write(to: file, options: .withoutOverwriting) }
            try emit(.init(kind: .chunk, identity: command.identity, chunk: 0, sampleRate: selected.model.capabilities.sampleRate,
                frames: samples.count, channels: 1, pcmFile: file.path, source: command.utterance?.source)); return
        }
        for index in 0..<(mode == .qwenIncremental ? 12 : 3) {
            try Task.checkCancellation()
            let file = stage.appendingPathComponent("\(command.identity.attempt.uuidString)-\(index).f32")
            let samples: [Float] = [0, 0.1, -0.1, 0]
            try samples.withUnsafeBytes { try Data($0).write(to: file, options: .withoutOverwriting) }
            try emit(.init(kind: .chunk, identity: command.identity, chunk: index,
                sampleRate: 24_000, frames: 4, channels: 1, pcmFile: file.path))
        }
    }
    func quiesceAndReset() async throws {
        if let stage { try Data().write(to: stage.appendingPathComponent("reset-started")) }
        if let stage, FileManager.default.fileExists(atPath: stage.appendingPathComponent("fail-reset").path) { throw SpeechFailure(.generation) }
        if let stage, FileManager.default.fileExists(atPath: stage.appendingPathComponent("delay-reset").path) {
            while !FileManager.default.fileExists(atPath: stage.appendingPathComponent("allow-reset").path) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    func shutdown(report: @escaping @Sendable (SpeechProbeEvent.Kind) -> Void) async {
        if lease != nil { report(.unloaded) }; lease = nil
        scratch = nil
    }
}
