import XCTest
import AVFoundation
@testable import AudioOutput

final class NativeAudioTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testNativeResamplingAndGapEncodingPreservesDurationAndRate() throws {
        let root = try root(), source = root.appendingPathComponent("soprano-rate.wav"), output = root.appendingPathComponent("podcast.m4a")
        let writer = try AtomicAudioWriter(destination: source)
        let sourceSamples = (0..<32_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 32_000) * 0.1) }
        try writer.append(samples: sourceSamples, sampleRate: 32_000); try writer.publish()
        var converted: [Float] = []
        try NativeAudio.decode(source, sampleRate: 24_000) { converted += $0 }
        XCTAssertEqual(converted.count, 24_000, accuracy: 32)
        XCTAssertTrue(converted.allSatisfy(\.isFinite))
        let crossings = zip(converted, converted.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count
        XCTAssertEqual(crossings, 440, accuracy: 2)
        XCTAssertEqual(converted.map { abs($0) }.max()!, 0.1, accuracy: 0.005)
        try NativeAudio.encode([source, source], destination: output, profile: .init(sampleRate: 24_000, bitRate: 64_000, gapSeconds: 0.15))
        let info = try NativeAudio.inspect(output)
        XCTAssertEqual(info.codec, "aac"); XCTAssertEqual(info.channels, 1); XCTAssertEqual(info.sampleRate, 24_000)
        XCTAssertEqual(info.duration, 2.15, accuracy: 0.08)
        var decoded: [Float] = []
        try NativeAudio.decode(output) { decoded += $0 }
        let gap = decoded[25_000..<26_000]
        XCTAssertLessThan(gap.map { abs($0) }.max()!, 0.002)
    }
    func testNativeDecodePreservesFloatBitsAndRejectsTruncatedAudio() throws {
        let root = try root(), source = root.appendingPathComponent("float.wav")
        let samples: [Float] = [-2.25, -0.0, .leastNonzeroMagnitude, 0.12345679, 2.5]
        let writer = try AtomicAudioWriter(destination: source)
        try writer.append(samples: samples, sampleRate: 24_000); try writer.publish()
        var decoded: [Float] = []
        try NativeAudio.decode(source) { decoded += $0 }
        XCTAssertEqual(decoded.map(\.bitPattern), samples.map(\.bitPattern))
        let info = try NativeAudio.inspect(source)
        XCTAssertEqual(info.codec, "pcm_f32le")
// Reuse the same URL after reading metadata: URL resource values can be
        // cached, so integrity must come from the currently opened file.
        var truncated = try Data(contentsOf: source); truncated.removeLast()
        try truncated.write(to: source)
        XCTAssertThrowsError(try NativeAudio.inspect(source))
        XCTAssertThrowsError(try NativeAudio.decode(source))
        try Data([0, 1, 2]).write(to: source)
        XCTAssertThrowsError(try NativeAudio.decode(source))
    }
    func testInvalidNativeAudioPreservesPreviouslyCompleteOutput() throws {
        let root = try root(), source = root.appendingPathComponent("bad.wav"), output = root.appendingPathComponent("episode.m4a")
        let original = Data([2, 3, 4]); try original.write(to: output); try Data([0]).write(to: source)
        XCTAssertThrowsError(try NativeAudio.encode([source], destination: output, profile: .init()))
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".libro-audio-") })
    }

    func testAACRetainsOriginalLevelsAndLoudToQuietRatioWithoutLeveling() throws {
        let root = try root()
        var inputs: [URL] = []
        for (index, amplitude) in [0.03, 0.3].enumerated() {
            let url = root.appendingPathComponent("level-\(index).wav")
            let writer = try AtomicAudioWriter(destination: url)
            try writer.append(samples: (0..<24_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 24_000) * amplitude) }, sampleRate: 24_000)
            try writer.publish(); inputs.append(url)
        }
        let output = root.appendingPathComponent("dynamic.m4a")
        try NativeAudio.encode(inputs, destination: output, profile: .init(gapSeconds: 0))
        var decoded: [Float] = []
        try NativeAudio.decode(output) { decoded += $0 }
        func rms(_ samples: ArraySlice<Float>) -> Double {
            sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        }
        let quiet = rms(decoded[8_000..<16_000]), loud = rms(decoded[32_000..<40_000])
        XCTAssertEqual(quiet, 0.03 / sqrt(2), accuracy: 0.002)
        XCTAssertEqual(loud, 0.3 / sqrt(2), accuracy: 0.008)
        XCTAssertEqual(loud / quiet, 10, accuracy: 0.4)
    }

}
