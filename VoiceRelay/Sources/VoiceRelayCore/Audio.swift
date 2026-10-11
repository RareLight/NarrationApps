import Foundation
import Darwin

struct AudioProcessor: Sendable {
    static let encodingVersion = "float32-unprocessed-aac-1"
    let settings: PrototypeProfile
    let toolDirectory: URL
    private let inspection = AudioInspectionCache()
    private let diagnostics: SpeechDiagnostics
    init(settings: PrototypeProfile, toolDirectory: URL, diagnostics: SpeechDiagnostics = SpeechDiagnostics(log: nil)) {
        self.settings = settings; self.toolDirectory = toolDirectory; self.diagnostics = diagnostics
    }
    func probe(_ url: URL, final: Bool) throws -> AudioInfo {
        try Task.checkCancellation()
        if !final, let wave = try FloatWave.inspect(url) { return wave.info }
        let hash = final ? try Files.hash(url) : nil
        if let hash, let cached = inspection.info(hash) { return cached }
        let data = try ToolRunner.run(settings.ffprobe,
            ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path],
            timeout: settings.toolTimeoutSeconds, directory: toolDirectory, invalidInputIsArtifact: true)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = obj["streams"] as? [[String: Any]], streams.count == 1,
              let stream = streams.first, stream["codec_type"] as? String == "audio",
              let codec = stream["codec_name"] as? String,
              let channels = stream["channels"] as? Int,
              let rateText = stream["sample_rate"] as? String, let rate = Int(rateText),
              let format = obj["format"] as? [String: Any], let durationText = format["duration"] as? String,
              let duration = Double(durationText), duration.isFinite, duration > 0,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw RelayError.artifact("Audio inspection rejected an empty or invalid artifact.")
        }
        if final {
            guard codec == "aac", stream["profile"] as? String == "LC", channels == 1, rate == settings.sampleRate,
                  (format["format_name"] as? String)?.contains("mp4") == true else {
                throw RelayError.artifact("Final output must be mono AAC-LC/M4A at the configured sample rate.")
            }
        } else {
            guard codec.hasPrefix("pcm_") || ["flac", "alac"].contains(codec) else {
                throw RelayError.artifact("Backend audio must be lossless PCM, FLAC, or ALAC.")
            }
        }
        let info = AudioInfo(duration: duration, byteLength: Int64(size), sampleRate: rate, channels: channels, codec: codec)
        if let hash { inspection.save(info, hash: hash) }
        return info
    }
    func decode(_ url: URL) throws {
        try Task.checkCancellation()
        if let wave = try FloatWave.inspect(url) { try wave.stream(); return }
        let hash = try Files.hash(url)
        if inspection.isDecoded(hash) { return }
        _ = try ToolRunner.run(settings.ffmpeg,
            ["-nostdin", "-v", "error", "-xerror", "-i", url.path, "-map", "0:a:0", "-f", "null", "-"],
            timeout: settings.toolTimeoutSeconds, directory: toolDirectory, invalidInputIsArtifact: true)
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
    func encode(_ artifacts: [LosslessArtifact], in directory: URL) throws -> (URL, AudioInfo) {
        guard !artifacts.isEmpty else { throw RelayError.artifact("No lossless audio to encode.") }
        let assemblyStart = ProcessInfo.processInfo.systemUptime
        let combined = directory.appendingPathComponent("combined.pcm")
        try Files.write(Data(), to: combined)
        let output = try FileHandle(forWritingTo: combined); defer { try? output.close() }
        for (index, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            if let wave = try FloatWave.inspect(artifact.url), wave.channels == 1, wave.rate == settings.sampleRate {
                try wave.stream(to: output)
            } else {
                let pcm = directory.appendingPathComponent("pcm-\(index).raw")
                _ = try ToolRunner.run(settings.ffmpeg,
                    ["-nostdin", "-v", "error", "-y", "-xerror", "-i", artifact.url.path, "-map", "0:a:0", "-vn", "-map_metadata", "-1", "-ac", "1", "-ar", String(settings.sampleRate), "-c:a", "pcm_f32le", "-f", "f32le", pcm.path],
                    timeout: settings.toolTimeoutSeconds, directory: toolDirectory)
                let input = try FileHandle(forReadingFrom: pcm)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 65_536), !data.isEmpty {
                    try Task.checkCancellation(); try output.write(contentsOf: data)
                }
            }
            if index < artifacts.count - 1 {
                try output.write(contentsOf: Data(repeating: 0, count: Int(Double(settings.sampleRate) * settings.gapSeconds) * 4))
            }
        }
        try output.synchronize(); try output.close()
        diagnostics.record(.pcmAssembly, seconds: ProcessInfo.processInfo.systemUptime - assemblyStart)
        let partial = directory.appendingPathComponent("episode.partial.m4a")
        let encodingStart = ProcessInfo.processInfo.systemUptime
        _ = try diagnostics.measure(.encoding) { try ToolRunner.run(settings.ffmpeg,
            ["-nostdin", "-v", "error", "-y", "-xerror", "-f", "f32le", "-ar", String(settings.sampleRate), "-ac", "1", "-i", combined.path,
             "-map", "0:a:0", "-vn", "-map_metadata", "-1", "-map_chapters", "-1",
             "-c:a", "aac", "-profile:a", "aac_low", "-b:a", settings.bitrate, "-ac", "1", "-ar", String(settings.sampleRate), "-movflags", "+faststart", partial.path],
            timeout: settings.toolTimeoutSeconds, directory: toolDirectory)
        }
        let encodingSeconds = ProcessInfo.processInfo.systemUptime - encodingStart
        let info = try diagnostics.measure(.validation) {
            let info = try probe(partial, final: true); try decode(partial); return info
        }
        diagnostics.recordEncoding(seconds: encodingSeconds, audioDuration: info.duration)
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
