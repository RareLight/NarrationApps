import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput

/// Writes are serial and may apply bounded backpressure on a CPU queue. Failure
/// sends JSON only before audio headers; after headers it closes the response.
public protocol VoiceServerAudioSink: Sendable {
    func begin(format: VoiceServerFormat, contentLength: UInt64?) throws
    func write(_ bytes: Data) throws
    func finish() throws
    func fail(_ error: VoiceServerError)
    func abort()
}
public protocol VoiceServerRenderer: Sendable {
    func render(_ request: VoiceServerSpeechRequest, selection: VoiceServerSelection, job: SpeechWorkJob,
                control: VoiceServerRequestControl, sink: any VoiceServerAudioSink) async throws
}

/// API work owns no article, database, feed, transcript or retained review. Only
/// bounded prepared utterances and private response scratch cross this boundary.
public struct NativeVoiceServerRenderer: VoiceServerRenderer {
    private let coordinator: SpeechWorkCoordinator
    private let limits: VoiceServerLimits
    private let mp3Library: URL?
    private let responseRoot: URL
    public init(coordinator: SpeechWorkCoordinator, limits: VoiceServerLimits = .init(), mp3Library: URL? = nil,
                responseRoot: URL = FileManager.default.temporaryDirectory) {
        self.coordinator = coordinator; self.limits = limits; self.mp3Library = mp3Library
        self.responseRoot = responseRoot
    }
    public func render(_ request: VoiceServerSpeechRequest, selection: VoiceServerSelection, job: SpeechWorkJob,
                       control: VoiceServerRequestControl, sink: any VoiceServerAudioSink) async throws {
        try control.check(); try Task.checkCancellation()
        let policy = SpeechPreparationPolicy.selected(settings: selection.settings, requested: .current)
        let windows = try await SpeechCPUWork.run(job: job) {
            let blocks = request.input.components(separatedBy: "\n\n").map {
                ContentBlock(kind: .paragraph, text: $0, origin: .authored)
            }
            let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "voiceserver-text-1"),
                settings: selection.settings, pronunciations: selection.pronunciations, policy: policy, options: selection.narrationOptions)
            var windows = try SpeechTextWindows.boundedForControl(SpeechTextWindows.make(from: projection))
            guard !windows.isEmpty, windows.count <= 128 else { throw SpeechFailure(.textPreparation) }
            if request.streaming {
                windows.replaceSubrange(0..<1, with: try LiveSpeechFirstUnit.split(windows[0], language: selection.settings.languageCode))
            }
            return windows
        }
        // Readiness includes the actual selected model/reference load. Known
        // initialization errors remain JSON errors, before any audio headers.
        _ = try await coordinator.perform(.initialize, job: job)
        let output = try await SpeechCPUWork.run(job: job) {
            try VoiceServerResponseAudio(request: request, sampleRate: selection.settings.model.capabilities.sampleRate,
                limits: limits, mp3Library: mp3Library, parent: responseRoot, control: control, sink: sink)
        }
        do {
            var previous: SpeechBoundary?, units = 0
            for window in windows {
                try control.check(); try Task.checkCancellation()
                let payload = SpeechTextWindow(text: window.text, source: .init(blockIndices: window.source.blockIndices,
                    location: window.source.location, length: window.source.length, origin: window.source.origin,
                    pronunciationApplications: window.source.pronunciationApplications?.filter { $0.phonemes != nil }), boundaryAfter: window.boundaryAfter)
                let prepared = try await coordinator.perform(.prepare(payload, policy), job: job)
                guard case .prepared(let utterances) = prepared.value, !utterances.isEmpty else { throw SpeechFailure(.protocolViolation) }
                try PreparedSpeechCoverage.validate(utterances, window: payload)
                for utterance in utterances {
                    units += 1
                    guard units <= 256 else { throw SpeechFailure(.textPreparation) }
                    let transfer = PreparedUtterance(text: utterance.text, phonemes: utterance.phonemes, tokenCount: utterance.tokenCount,
                        source: .init(blockIndices: utterance.source.blockIndices, location: utterance.source.location,
                            length: utterance.source.length, origin: utterance.source.origin),
                        boundaryAfter: utterance.boundaryAfter, acousticIdentity: utterance.acousticIdentity)
                    let result = try await coordinator.perform(.generate(transfer, policy), job: job)
                    let gap = policy.usesStructuralPauses ? previous.map { NarrationPausePolicy.seconds(after: $0) } ?? 0 : 0
                    try await append(result, gap: gap, output: output, job: job)
                    previous = utterance.boundaryAfter
                }
            }
            try await SpeechCPUWork.run(job: job) { try output.finish() }
        } catch {
            // No codec flush/replay on cancellation, slow writes or generation failure.
            output.abort(); throw error
        }
    }
    private func append(_ result: SpeechUnitResult, gap: Double, output: VoiceServerResponseAudio, job: SpeechWorkJob) async throws {
        defer { job.discardResult(result) }
        guard case .audio(let pcm) = result.value else { throw SpeechFailure(.protocolViolation) }
        try await SpeechCPUWork.run(job: job) { try output.append(pcm, gap: gap) }
    }
}

/// Accessed only by the request's sequential, joined CPU operations. The sink's
/// cancellation wakeup may close a socket but never mutates codec/file state.
final class VoiceServerResponseAudio: @unchecked Sendable {
    let request: VoiceServerSpeechRequest
    let sampleRate: Int
    let limits: VoiceServerLimits
    let control: VoiceServerRequestControl
    let sink: any VoiceServerAudioSink
    let directory: URL
    let file: URL
    private var encoder: AudioStreamEncoder?
    private var wav: AtomicAudioWriter?
    private var handle: FileHandle?
    private var assembler: ZeroFrameAudioAssembler?
    private var scratch: SpeechScratchLease?
    private var began = false
    private var frames: UInt64 = 0
    init(request: VoiceServerSpeechRequest, sampleRate: Int, limits: VoiceServerLimits, mp3Library: URL?, parent: URL,
         control: VoiceServerRequestControl, sink: any VoiceServerAudioSink) throws {
        self.request = request; self.sampleRate = sampleRate; self.limits = limits; self.control = control; self.sink = sink
        _ = try? SpeechScratchLease.sweep(parent.resolvingSymlinksInPath(), prefix: "VoiceRelay-API-")
        directory = parent.resolvingSymlinksInPath().appendingPathComponent("VoiceRelay-API-\(UUID())")
        file = directory.appendingPathComponent("response." + request.format.rawValue)
        guard mkdir(directory.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        do {
            scratch = try SpeechScratchLease(directory: directory, create: true)
            if request.format == .wav { wav = try AtomicAudioWriter(destination: file) }
            else {
                if !request.streaming {
                    let fd = open(file.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw SpeechFailure(.storage) }
                    handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                }
                encoder = try AudioStreamEncoder(format: request.format == .mp3 ? .mp3 : .pcm, inputSampleRate: sampleRate,
                    mp3Library: mp3Library, maximumOutputBytes: limits.maximumOutputBytes) { [weak self] bytes in
                        guard let self else { throw CancellationError() }
                        try self.control.check()
                        if self.request.streaming {
                            if !self.began { try self.sink.begin(format: self.request.format, contentLength: nil); self.began = true }
                            var offset = 0
                            while offset < bytes.count {
                                try self.control.check()
                                let end = min(bytes.count, offset + 16_384)
                                try self.sink.write(bytes.subdata(in: offset..<end)); offset = end
                            }
                        } else { try self.handle?.write(contentsOf: bytes) }
                    }
            }
            assembler = try ZeroFrameAudioAssembler(sampleRate: sampleRate) { [weak self] samples in
                guard let self else { throw CancellationError() }; try self.consume(samples)
            }
        } catch {
            if scratch == nil { try? FileManager.default.removeItem(at: directory) }
            abort(); throw error
        }
    }
    deinit { abort() }
    func append(_ samples: [Float], gap: Double) throws {
        try control.check(); try assembler?.append(samples: samples, gapBeforeSeconds: gap)
    }
    private func consume(_ samples: [Float]) throws {
        try control.check(); try AudioWorkCheckpoint.check()
        let total = frames.addingReportingOverflow(UInt64(samples.count))
        guard !total.overflow else { throw AudioStreamFailure.outputLimit }
        if let wav {
            guard limits.maximumOutputBytes > 65_536, total.partialValue <= (limits.maximumOutputBytes - 65_536) / 4 else { throw AudioStreamFailure.outputLimit }
            try wav.append(samples: samples, sampleRate: sampleRate)
        } else {
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + AudioStreamEncoder.maximumFrameSamples)
                try encoder?.append(Array(samples[offset..<end])); offset = end
            }
        }
        frames = total.partialValue
    }
    func finish() throws {
        try control.check(); try AudioWorkCheckpoint.check()
        guard frames > 0 else { throw AudioOutputError.empty }
        if let wav { try wav.publish() } else { try encoder?.finish() }
        if !request.streaming {
            try handle?.synchronize(); try handle?.close(); handle = nil
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, UInt64(size) <= limits.maximumOutputBytes else { throw AudioStreamFailure.outputLimit }
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            try sink.begin(format: request.format, contentLength: UInt64(size)); began = true
            while let bytes = try input.read(upToCount: 16_384), !bytes.isEmpty {
                try control.check(); try AudioWorkCheckpoint.check(); try sink.write(bytes)
            }
        }
        guard began else { throw AudioOutputError.empty }
        try sink.finish(); abort()
    }
    func abort() {
        encoder?.abort(); encoder = nil; wav?.abort(); wav = nil
        try? handle?.close(); handle = nil
        scratch?.close(); scratch = nil
        _ = try? SpeechScratchLease.removeIfUnowned(directory)
    }
}
