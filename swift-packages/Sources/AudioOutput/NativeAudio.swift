import Foundation
import AVFoundation
import AudioToolbox

public struct NativeAudioInfo: Sendable {
    public let duration: Double
    public let frames: Int64
    public let byteLength: Int64
    public let sampleRate: Int
    public let channels: Int
    public let codec: String
    public let container: String
}

public struct AudioEncodingProfile: Sendable {
    public var sampleRate: Int
    public var bitRate: Int
    public var gapSeconds: Double
    public init(sampleRate: Int = 24_000, bitRate: Int = 64_000, gapSeconds: Double = 0.15) {
        self.sampleRate = sampleRate; self.bitRate = bitRate; self.gapSeconds = gapSeconds
    }
}

/// Native bounded decoding, mono conversion and streaming AAC assembly. No
/// gain/normalization is applied. The pull converter owns resampling state for
/// the complete source file; input is never repeatedly supplied as new audio.
public enum NativeAudio {
    public static func inspect(_ url: URL) throws -> NativeAudioInfo {
        try Task.checkCancellation()
        // Core Audio tolerates a partial trailing PCM frame in a truncated WAV.
        // Validate its RIFF envelope before asking the native decoder for samples.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        let fileBytes = try handle.seekToEnd()
        if header.count == 12, header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) {
            let declared = header[4..<8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
            guard declared + 8 <= fileBytes else { throw AudioOutputError.invalidPCM }
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let description = file.fileFormat.streamDescription.pointee
        let codec: String
        switch description.mFormatID {
        case kAudioFormatLinearPCM:
            let representation = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f" : "s"
            let order = description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? "be" : "le"
            codec = "pcm_\(representation)\(description.mBitsPerChannel)\(order)"
        case kAudioFormatFLAC: codec = "flac"
        case kAudioFormatAppleLossless: codec = "alac"
        case kAudioFormatMPEG4AAC: codec = "aac"
        default: throw AudioOutputError.inconsistentFormat
        }
        var nativeFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &nativeFile) == noErr, let nativeFile else { throw AudioOutputError.encoding }
        defer { AudioFileClose(nativeFile) }
        var type: AudioFileTypeID = 0, size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(nativeFile, kAudioFilePropertyFileFormat, &size, &type) == noErr else { throw AudioOutputError.encoding }
        if description.mFormatID == kAudioFormatLinearPCM {
            var audioBytes: UInt64 = 0, byteSize = UInt32(MemoryLayout<UInt64>.size)
            guard description.mBytesPerFrame > 0,
                  AudioFileGetProperty(nativeFile, kAudioFilePropertyAudioDataByteCount, &byteSize, &audioBytes) == noErr,
                  audioBytes % UInt64(description.mBytesPerFrame) == 0,
                  audioBytes / UInt64(description.mBytesPerFrame) == UInt64(file.length) else { throw AudioOutputError.invalidPCM }
        }
        let container = type == kAudioFileM4AType ? "m4a" : (type == kAudioFileMPEG4Type ? "mp4" : "lossless")
        let rate = file.fileFormat.sampleRate
        guard fileBytes <= UInt64(Int64.max) else { throw AudioOutputError.encoding }
        let bytes = Int64(fileBytes)
        guard rate.isFinite, rate > 0, rate <= 192_000, file.length > 0, bytes > 0,
              file.fileFormat.channelCount > 0 else { throw AudioOutputError.empty }
        return NativeAudioInfo(duration: Double(file.length) / rate, frames: file.length, byteLength: Int64(bytes),
                               sampleRate: Int(rate), channels: Int(file.fileFormat.channelCount), codec: codec, container: container)
    }

    public static func decode(_ url: URL, sampleRate: Int? = nil, consume: ([Float]) throws -> Void = { _ in }) throws {
        try Task.checkCancellation()
        _ = try inspect(url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = sampleRate.map(Double.init) ?? file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, rate <= 192_000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { throw AudioOutputError.encoding }
        var inputError: (any Error)?
        var decoded: Int64 = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                do {
                    try Task.checkCancellation()
                    guard file.framePosition < file.length else { inputStatus.pointee = .endOfStream; return nil }
                    let capacity = min(min(max(requested, 1), 16_384), AVAudioFrameCount(min(file.length - file.framePosition, 16_384)))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                        throw AudioOutputError.encoding
                    }
                    try file.read(into: buffer, frameCount: capacity)
                    if buffer.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    inputError = error; inputStatus.pointee = .endOfStream; return nil
                }
            }
            if let inputError { throw inputError }
            if conversionError != nil || status == .error { throw AudioOutputError.encoding }
            if output.frameLength > 0 {
                guard let channel = output.floatChannelData?[0] else { throw AudioOutputError.invalidPCM }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                guard samples.allSatisfy(\.isFinite) else { throw AudioOutputError.invalidPCM }
                try consume(samples)
                decoded += Int64(samples.count)
            }
            if status == .endOfStream { break }
            // The input callback reads synchronously until EOF; no producer can
            // later satisfy inputRanDry. A zero-output iteration is a bad file.
            guard output.frameLength > 0 else { throw AudioOutputError.empty }
        }
        guard decoded > 0 else { throw AudioOutputError.empty }
    }

    public static func encode(_ inputs: [URL], destination: URL, profile: AudioEncodingProfile, scheduledGaps: [Double]? = nil) throws {
        guard !inputs.isEmpty, (8_000...192_000).contains(profile.sampleRate),
              profile.gapSeconds.isFinite, (0...10).contains(profile.gapSeconds) else { throw AudioOutputError.invalidPCM }
        if let scheduledGaps {
            guard scheduledGaps.count == inputs.count, scheduledGaps.allSatisfy({ $0.isFinite && (0...10).contains($0) }) else {
                throw AudioOutputError.invalidPCM
            }
        }
        let writer = try AtomicAudioWriter(destination: destination, format: .m4a, bitRate: profile.bitRate)
        defer { writer.abort() }
        let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: profile.sampleRate)
        for (index, input) in inputs.enumerated() {
            var firstBuffer = true
            try decode(input, sampleRate: profile.sampleRate) { samples in
                if let scheduledGaps {
                    try assembler.append(samples: samples, gapBeforeSeconds: firstBuffer && index > 0 ? scheduledGaps[index - 1] : 0)
                    firstBuffer = false
                } else { try writer.append(samples: samples, sampleRate: profile.sampleRate) }
            }
            if scheduledGaps == nil && index < inputs.count - 1 {
                var remaining = Int(Double(profile.sampleRate) * profile.gapSeconds)
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = min(remaining, 16_384)
                    try writer.append(samples: [Float](repeating: 0, count: count), sampleRate: profile.sampleRate)
                    remaining -= count
                }
            }
        }
        try writer.publish()
    }
}
