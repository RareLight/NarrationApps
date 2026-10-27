import Foundation
import Darwin
import AudioOutput
import NarrationCore

struct AudioProcessor: Sendable {
    static let encodingVersion = "native-float32-aac-2"
    let settings: PrototypeProfile
    let toolDirectory: URL
    private let inspection = AudioInspectionCache()
    private let diagnostics: SpeechDiagnostics
    private let observer: (@Sendable (SpeechTimingStage, URL) throws -> Void)?
    init(settings: PrototypeProfile, toolDirectory: URL, diagnostics: SpeechDiagnostics = SpeechDiagnostics(log: nil), observer: (@Sendable (SpeechTimingStage, URL) throws -> Void)? = nil) {
        self.settings = settings; self.toolDirectory = toolDirectory; self.diagnostics = diagnostics; self.observer = observer
    }
    func probe(_ url: URL, final: Bool) throws -> AudioInfo {
        try Task.checkCancellation()
        let hash = try Files.hash(url)
        let native: NativeAudioInfo
        if let cached = inspection.info(hash) { native = cached }
        else {
            try observer?(.validation, url)
            do { native = try NativeAudio.inspect(url) }
            catch is CancellationError { throw CancellationError() }
            catch { throw RelayError.artifact("Audio inspection rejected an empty or invalid artifact.") }
        }
        if final, native.container != "m4a" { throw RelayError.artifact("Final audio is not an M4A container.") }
        let info = AudioInfo(duration: native.duration, byteLength: native.byteLength, sampleRate: native.sampleRate,
                             channels: native.channels, codec: native.codec)
        try validatePolicy(info, final: final, url: url)
        inspection.save(native, hash: hash)
        return info
    }
    private func validatePolicy(_ info: AudioInfo, final: Bool, url: URL) throws {
        if final {
            guard info.codec == "aac", info.channels == 1, info.sampleRate == settings.sampleRate,
                  ["m4a", "m4b"].contains(url.pathExtension.lowercased()) || url.lastPathComponent.hasSuffix(".m4a.tmp") else {
                throw RelayError.artifact("Final output must be mono AAC-LC/M4A at the configured sample rate.")
            }
        } else {
            guard info.codec.hasPrefix("pcm_") || ["flac", "alac"].contains(info.codec) else {
                throw RelayError.artifact("Backend audio must be lossless PCM, FLAC, or ALAC.")
            }
        }
    }
    func decode(_ url: URL) throws {
        try Task.checkCancellation()
        let hash = try Files.hash(url)
        if inspection.isDecoded(hash) { return }
        do { try NativeAudio.decode(url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RelayError.artifact("Audio decoding rejected an incomplete or invalid artifact.") }
        inspection.markDecoded(hash)
    }
    func validate(_ result: SynthesisResult, within directory: URL) throws {
        guard !result.artifacts.isEmpty else { throw RelayError.artifact("Backend returned no lossless artifacts.") }
        for a in result.artifacts {
            guard Files.contains(directory, a.url), !Files.hasSymlink(a.url, below: directory) else { throw RelayError.artifact("Backend output escaped its private chunk directory.") }
            let actual = try probe(a.url, final: false)
            guard actual.channels == a.channels, actual.sampleRate == a.sampleRate else {
                throw RelayError.artifact("Lossless artifact metadata does not match the backend result.")
            }
            try decode(a.url)
        }
    }
    static func scheduledGaps(_ artifacts: [LosslessArtifact]) throws -> [Double]? {
        let policies = artifacts.compactMap(\.assemblyPolicy)
        guard !policies.isEmpty else {
            guard artifacts.allSatisfy({ $0.gapAfterSeconds == nil }) else { throw RelayError.artifact("Invalid legacy audio assembly checkpoint.") }
            return nil // explicit legacy 0.15s policy
        }
        guard policies.count == artifacts.count, Set(policies) == [NarrationPausePolicy.candidateVersion],
              artifacts.allSatisfy({ $0.gapAfterSeconds != nil && $0.gapAfterSeconds!.isFinite && (0...10).contains($0.gapAfterSeconds!) }) else {
            throw RelayError.artifact("Incompatible audio assembly checkpoints must be prepared again; completed media is preserved.")
        }
        return artifacts.map { $0.gapAfterSeconds! }
    }

    func encode(_ artifacts: [LosslessArtifact], in directory: URL,
                timeline: ([AudioSegmentTiming]) throws -> Void = { _ in }) throws -> (URL, AudioInfo) {
        guard !artifacts.isEmpty else { throw RelayError.artifact("No lossless audio to encode.") }
        let partial = directory.appendingPathComponent("episode.partial.m4a")
        let start = ProcessInfo.processInfo.systemUptime
        try observer?(.encoding, partial)
        let numericBitrate = Int(settings.bitrate.replacingOccurrences(of: "k", with: ""))
        guard let numericBitrate else { throw RelayError.setup("The AAC bitrate is invalid.") }
        do {
            let positions = try diagnostics.measure(.encoding) {
                try NativeAudio.encode(artifacts.map(\.url), destination: partial,
                                       profile: .init(sampleRate: settings.sampleRate, bitRate: numericBitrate * 1_000, gapSeconds: settings.gapSeconds),
                                       scheduledGaps: try Self.scheduledGaps(artifacts))
            }
            try timeline(positions)
        } catch is CancellationError { throw CancellationError() }
        catch { throw RelayError.artifact("Native AAC encoding could not finish this recording.") }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let info = try diagnostics.measure(.validation) {
            let info = try probe(partial, final: true); try decode(partial); return info
        }
        diagnostics.recordEncoding(seconds: elapsed, audioDuration: info.duration)
        let complete = directory.appendingPathComponent("episode.m4a")
        try Files.moveValidatedScratch(partial, to: complete)
        return (complete, info)
    }
    func publish(_ source: URL, destination: URL, expectedHash: String, inMediaDirectory: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw RelayError.setup("The audio folder is unavailable. Reconnect its volume before resuming; it was not recreated.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Files.hash(destination, description: "saved audio") == expectedHash else {
                throw RelayError.artifact("Conflicting media already exists; inspect it before repair.")
            }
            _ = try probe(destination, final: true); try decode(destination); return
        }
        let staging = inMediaDirectory ? destination.deletingLastPathComponent()
            : destination.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".media-staging")
        if !inMediaDirectory { try Files.directory(staging) }
        var stagedStat = stat(); var outputStat = stat()
        guard stat(staging.path, &stagedStat) == 0,
              stat(destination.deletingLastPathComponent().path, &outputStat) == 0,
              stagedStat.st_dev == outputStat.st_dev else {
            throw RelayError.setup("Publication staging and media must be on the same filesystem.")
        }
        let candidate = staging.appendingPathComponent(inMediaDirectory ? ".\(UUID().uuidString).m4a.tmp" : destination.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: candidate) }
        try Files.copy(source, to: candidate)
        guard try Files.hash(candidate, description: "staged audio") == expectedHash else { throw RelayError.artifact("Staged media integrity check failed.") }
        _ = try probe(candidate, final: true); try decode(candidate)
        try Task.checkCancellation()
        guard rename(candidate.path, destination.path) == 0 else { throw RelayError.storage("Atomic media publication failed.") }
        try Files.syncDirectory(destination.deletingLastPathComponent())
        try Files.syncDirectory(staging)
    }
}
