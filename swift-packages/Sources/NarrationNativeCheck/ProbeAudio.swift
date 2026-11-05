import Foundation
import AVFoundation
import AudioOutput
import NarrationCore

/// Probe diagnostics only; samples are never transformed to make comparisons pass.
enum ProbeAudio {
    static func publish(_ samples: [Float], rate: Int, to wav: URL) throws {
        let writer = try AtomicAudioWriter(destination: wav)
        try writer.append(samples: samples, sampleRate: rate)
        try writer.publish(replaceExisting: false)
    }
    static func verify(_ samples: [Float], rate: Int, wav: URL) throws {
        let decoded = try AVAudioFile(forReading: wav)
        guard decoded.length == samples.count, decoded.processingFormat.sampleRate == Double(rate),
              let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_384) else { throw SpeechFailure(.generation) }
        var offset = 0
        while offset < samples.count {
            try decoded.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, count <= samples.count - offset, let channel = buffer.floatChannelData?[0],
                  samples[offset..<(offset + count)].elementsEqual(UnsafeBufferPointer(start: channel, count: count)) else { throw SpeechFailure(.generation) }
            offset += count
        }
    }
    static func samples(_ file: URL) throws -> [Float] {
        let data = try Data(contentsOf: file)
        guard data.count <= 24_000 * 120 * 4, data.count % 4 == 0 else { throw SpeechFailure(.generation) }
        return data.withUnsafeBytes { bytes in (0..<(data.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }
    static func compare(_ first: URL, _ second: URL) throws -> [String: Any] {
        let a = try samples(first), b = try samples(second)
        guard a.count == b.count else { return ["sampleCountsEqual": false, "referenceFrames": a.count, "streamFrames": b.count] }
        let errors = zip(a, b).map { abs(Double($0) - Double($1)) }
        return ["sampleCountsEqual": true, "frames": a.count, "maximumAbsoluteDifference": errors.max() ?? 0,
                "meanAbsoluteDifference": errors.reduce(0, +) / Double(max(1, errors.count)),
                "diagnosticTolerance": 0.001, "withinDiagnosticTolerance": (errors.max() ?? 0) <= 0.001]
    }
}
