import Foundation
import AVFoundation

public enum AudioStreamFormat: String, Sendable { case mp3, pcm }
public enum AudioStreamFailure: Error, Sendable { case closed, outputLimit, unrepresentablePCM }

/// One response owns this state and calls it serially on its CPU queue. The sink
/// applies bounded backpressure and may throw on disconnect; errors are terminal.
/// No files, seeks, independent MP3 fragments or gain processing are involved.
public final class AudioStreamEncoder {
    public static let maximumFrameSamples = 16_384
    public static let outputSampleRate = 24_000
    public let format: AudioStreamFormat
    public private(set) var inputFrames: UInt64 = 0
    public private(set) var outputBytes: UInt64 = 0
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let sink: (Data) throws -> Void
    private let maximumOutputBytes: UInt64
    private var mp3: MP3Encoder?
    private var terminal = false

    public init(format: AudioStreamFormat, inputSampleRate: Int, mp3Library: URL? = nil,
                maximumOutputBytes: UInt64 = 64 * 1_024 * 1_024,
                sink: @escaping (Data) throws -> Void) throws {
        guard (8_000...192_000).contains(inputSampleRate), maximumOutputBytes > 0,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(inputSampleRate), channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.outputSampleRate), channels: 1, interleaved: false)
        else { throw AudioOutputError.invalidPCM }
        self.format = format; self.inputFormat = input; self.outputFormat = output
        self.sink = sink; self.maximumOutputBytes = maximumOutputBytes
        if inputSampleRate != Self.outputSampleRate {
            guard let converter = AVAudioConverter(from: input, to: output) else { throw AudioOutputError.encoding }
            self.converter = converter
        } else { self.converter = nil }
        if format == .mp3 {
            mp3 = try MP3Encoder(libraryURL: mp3Library, sampleRate: Self.outputSampleRate) { [weak self] in
                guard let self else { throw AudioStreamFailure.closed }; try self.emit($0)
            }
        }
    }

    public func append(_ samples: [Float]) throws {
        try perform {
            guard !samples.isEmpty, samples.count <= Self.maximumFrameSamples, samples.allSatisfy(\.isFinite) else { throw AudioOutputError.invalidPCM }
            try AudioWorkCheckpoint.check()
            let total = inputFrames.addingReportingOverflow(UInt64(samples.count))
            guard !total.overflow else { throw AudioStreamFailure.outputLimit }
            if converter != nil { try convert(samples, finishing: false) }
            else { try encode(samples) }
            inputFrames = total.partialValue
        }
    }

    public func finish() throws {
        try perform {
            guard inputFrames > 0 else { throw AudioOutputError.empty }
            if converter != nil { try convert([], finishing: true) }
            try mp3?.finish()
            terminal = true; mp3 = nil
        }
    }

    /// Abort emits nothing further, including no codec flush after disconnect.
    public func abort() { terminal = true; mp3 = nil }

    private func perform(_ body: () throws -> Void) throws {
        guard !terminal else { throw AudioStreamFailure.closed }
        do { try body() }
        catch { abort(); throw error }
    }

    private func emit(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        try AudioWorkCheckpoint.check()
        let total = outputBytes.addingReportingOverflow(UInt64(bytes.count))
        guard !total.overflow, total.partialValue <= maximumOutputBytes else { throw AudioStreamFailure.outputLimit }
        try sink(bytes); outputBytes = total.partialValue
    }

    private func encode(_ samples: [Float]) throws {
        guard samples.allSatisfy(\.isFinite) else { throw AudioOutputError.invalidPCM }
        if let mp3 { try mp3.append(samples); return }
        // Signed 16-bit conversion is the only amplitude quantization. Fail on
        // unrepresentable samples instead of clipping, limiting or changing gain.
        guard samples.allSatisfy({ $0.isFinite && $0 >= -1 && $0 <= 1 }) else { throw AudioStreamFailure.unrepresentablePCM }
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let integer = sample == 1 ? Int16.max : Int16((Double(sample) * 32_768).rounded(.towardZero))
            let bits = UInt16(bitPattern: integer)
            bytes.append(UInt8(truncatingIfNeeded: bits)); bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        try emit(bytes)
    }

    private func convert(_ samples: [Float], finishing: Bool) throws {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { throw AudioOutputError.encoding }
        var position = 0
        // A bounded append can require at most 13 native output buffers at 8kHz.
        // The larger limit also bounds a broken converter's drain behavior.
        for _ in 0..<64 {
            try AudioWorkCheckpoint.check()
            var conversionError: NSError?
            var inputFailed = false
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                guard position < samples.count else {
                    state.pointee = finishing ? .endOfStream : .noDataNow; return nil
                }
                let count = min(Int(requested), samples.count - position)
                guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: AVAudioFrameCount(count)),
                      let channel = input.floatChannelData?[0] else { inputFailed = true; state.pointee = .noDataNow; return nil }
                input.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + position, count: count) }
                position += count; state.pointee = .haveData; return input
            }
            guard !inputFailed, conversionError == nil, status != .error else { throw AudioOutputError.encoding }
            if output.frameLength > 0 {
                guard let channel = output.floatChannelData?[0] else { throw AudioOutputError.encoding }
                try encode(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            switch status {
            case .inputRanDry:
                guard !finishing, position == samples.count else { throw AudioOutputError.encoding }; return
            case .endOfStream:
                guard finishing else { throw AudioOutputError.encoding }; return
            case .haveData: continue
            case .error: throw AudioOutputError.encoding
            @unknown default: throw AudioOutputError.encoding
            }
        }
        throw AudioOutputError.encoding
    }
}
