import Foundation
import AVFoundation

public enum Wave {
    public struct Info: Sendable {
        public let frames: Int
        public let rate: Int
        public let peak: Float
        public let clipped: Int
        public var duration: Double { Double(frames) / Double(rate) }
    }
    public static func write(_ samples: [Float], rate: Int, to url: URL) throws -> Info {
        let info = try inspectSamples(samples, rate: rate)
        guard !FileManager.default.fileExists(atPath: url.path), samples.count <= (Int(UInt32.max) - 36) / 4 else { throw BenchError("Output exists or exceeds WAV limit") }
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + samples.count * 4)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(3)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 4)); word(UInt16(4)); word(UInt16(32))
        data.append(contentsOf: "data".utf8); word(UInt32(samples.count * 4))
        for sample in samples { word(sample.bitPattern) }
        try data.write(to: url, options: .atomic)
        return info
    }
    public static func inspectSamples(_ samples: [Float], rate: Int) throws -> Info {
        guard (8000...192000).contains(rate), !samples.isEmpty, samples.allSatisfy(\.isFinite),
              let peak = samples.map({ abs($0) }).max(), peak > 0 else { throw BenchError("Empty, non-finite or silent PCM") }
        return Info(frames: samples.count, rate: rate, peak: peak, clipped: samples.filter { abs($0) >= 1 }.count)
    }
    public static func inspect(_ url: URL) throws -> Info {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.channelCount == 1, file.length > 0, file.length < 400_000_000 else { throw BenchError("Invalid WAV format/length") }
        var peak: Float = 0, clipped = 0, frames = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { throw BenchError("PCM buffer allocation failed") }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw BenchError("Invalid PCM") }
            for i in 0..<Int(buffer.frameLength) {
                let value = channel[i]; guard value.isFinite else { throw BenchError("Non-finite PCM") }
                peak = max(peak, abs(value)); if abs(value) >= 1 { clipped += 1 }
            }
            frames += Int(buffer.frameLength)
        }
        guard peak > 0 else { throw BenchError("Silent PCM") }
        return Info(frames: frames, rate: Int(file.fileFormat.sampleRate), peak: peak, clipped: clipped)
    }
}
