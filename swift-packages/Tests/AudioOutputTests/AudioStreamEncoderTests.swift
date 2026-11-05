import XCTest
import Foundation
import AVFoundation
import Darwin
@testable import AudioOutput

final class AudioStreamEncoderTests: XCTestCase {
    private final class Bytes {
        var data = Data()
        func append(_ block: Data) { data.append(block) }
    }
    private var library: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/codecs/lame/lib/libmp3lame.0.dylib")
    }
    private func feed(_ samples: [Float], encoder: AudioStreamEncoder, size: Int) throws {
        for start in stride(from: 0, to: samples.count, by: size) {
            try encoder.append(Array(samples[start..<min(start + size, samples.count)]))
        }
    }
    private func decode(_ bytes: Data) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try bytes.write(to: file)
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
        XCTAssertEqual(audio.processingFormat.sampleRate, 24_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096))
        var result: [Float] = []
        while true {
            do { try audio.read(into: buffer) }
            catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == -39 {
                // A live prefix may end within an MP3 packet. Require actual
                // decoded speech below; trailing input can arrive later.
                return result
            }
            guard buffer.frameLength > 0 else { return result }
            result += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
    }
    func testPCMIsSignedLittleEndianAndHasNoHeaderOrGainProcessing() throws {
        let bytes = Bytes(), encoder = try AudioStreamEncoder(format: .pcm, inputSampleRate: 24_000, sink: bytes.append)
        try encoder.append([-1, -0.5, 0, 0.5, 1]); try encoder.finish()
        XCTAssertEqual(bytes.data, Data([0, 128, 0, 192, 0, 0, 0, 64, 255, 127]))
        XCTAssertEqual(encoder.inputFrames, 5); XCTAssertEqual(encoder.outputBytes, 10)
        XCTAssertThrowsError(try encoder.append([0]))
        XCTAssertThrowsError(try encoder.finish())
    }
    func testNativeMP3PresetKeepsExplicitUnityScale() throws {
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Prepare the pinned MP3 codec first.") }
        let handle = try XCTUnwrap(dlopen(library.path, RTLD_NOW | RTLD_LOCAL)); defer { dlclose(handle) }
        typealias Init = @convention(c) () -> OpaquePointer?
        typealias SetInt = @convention(c) (OpaquePointer?, Int32) -> Int32
        typealias SetFloat = @convention(c) (OpaquePointer?, Float) -> Int32
        typealias GetFloat = @convention(c) (OpaquePointer?) -> Float
        typealias State = @convention(c) (OpaquePointer?) -> Int32
        func symbol<T>(_ name: String, _: T.Type) throws -> T { unsafeBitCast(try XCTUnwrap(dlsym(handle, name)), to: T.self) }
        for rate: Int32 in [24_000, 32_000, 44_100, 48_000] {
            let state = try XCTUnwrap(try symbol("lame_init", Init.self)())
            let close = try symbol("lame_close", State.self); defer { _ = close(state) }
            for (name, value) in [("lame_set_num_channels", Int32(1)), ("lame_set_in_samplerate", rate),
                                  ("lame_set_out_samplerate", rate), ("lame_set_brate", Int32(128)), ("lame_set_findReplayGain", Int32(0))] {
                XCTAssertEqual(try symbol(name, SetInt.self)(state, value), 0)
            }
            XCTAssertEqual(try symbol("lame_set_scale", SetFloat.self)(state, 1), 0)
            XCTAssertEqual(try symbol("lame_init_params", State.self)(state), 0)
            XCTAssertEqual(try symbol("lame_get_scale", GetFloat.self)(state), 1, "Native preset changed explicit unity scale at \(rate) Hz")
        }
    }
    func testPCMRejectsUnrepresentableLevelsRatherThanClipping() throws {
        let bytes = Bytes(), encoder = try AudioStreamEncoder(format: .pcm, inputSampleRate: 24_000, sink: bytes.append)
        XCTAssertThrowsError(try encoder.append([0, 1.25, 0])) { guard case AudioStreamFailure.unrepresentablePCM = $0 else { return XCTFail("\($0)") } }
        XCTAssertTrue(bytes.data.isEmpty)
        XCTAssertThrowsError(try encoder.finish())
    }
    func testNativeResamplerRetainsStateAcrossArbitraryFrameBoundaries() throws {
        let samples = (0..<96_000).map { Float(sin(Double($0) * 0.03) * 0.25) }
        let first = Bytes(), second = Bytes()
        let a = try AudioStreamEncoder(format: .pcm, inputSampleRate: 48_000, sink: first.append)
        let b = try AudioStreamEncoder(format: .pcm, inputSampleRate: 48_000, sink: second.append)
        try feed(samples, encoder: a, size: 16_384); try a.finish()
        try feed(samples, encoder: b, size: 337); try b.finish()
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.data.count, 48_000 * 2)
    }
    func testMP3IsOneNonSeekingStreamWithPlayableAudioBeforeFlush() throws {
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Prepare the pinned MP3 codec first.") }
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.11) * 0.25) }
        let first = Bytes(), second = Bytes()
        let a = try AudioStreamEncoder(format: .mp3, inputSampleRate: 24_000, mp3Library: library, sink: first.append)
        let b = try AudioStreamEncoder(format: .mp3, inputSampleRate: 24_000, mp3Library: library, sink: second.append)
        try a.append(Array(samples.prefix(16_384)))
        let early = try decode(first.data)
        XCTAssertGreaterThan(early.count, 1_152)
        XCTAssertGreaterThan(early.map { abs($0) }.max() ?? 0, 0.1)
        try feed(Array(samples.dropFirst(16_384)), encoder: a, size: 16_384); try a.finish()
        try feed(samples, encoder: b, size: 337); try b.finish()
        XCTAssertEqual(first.data, second.data, "Frame boundaries must not create independent codec delays or headers")
        let decoded = try decode(first.data)
        XCTAssertGreaterThanOrEqual(decoded.count, samples.count)
        XCTAssertLessThan(decoded.count - samples.count, 2_304)
        XCTAssertGreaterThan(decoded.map { abs($0) }.max() ?? 0, 0.2)
        XCTAssertLessThan(decoded.map { abs($0) }.max() ?? 0, 0.3)
        let middle = decoded.dropFirst(4_096).prefix(32_000)
        let rms = sqrt(middle.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(middle.count))
        XCTAssertEqual(rms / (0.25 / sqrt(2.0)), 1, accuracy: 0.01, "Preset attenuation must not become output gain processing")
        XCTAssertFalse(first.data.range(of: Data("Xing".utf8)) != nil)
        XCTAssertFalse(first.data.range(of: Data("Info".utf8)) != nil)
    }
    func testOutputLimitDisconnectInvalidFramesAndAbortAreTerminal() throws {
        struct Disconnected: Error {}
        let bytes = Bytes(), encoder = try AudioStreamEncoder(format: .pcm, inputSampleRate: 24_000, maximumOutputBytes: 3, sink: bytes.append)
        XCTAssertThrowsError(try encoder.append([0, 0])) { guard case AudioStreamFailure.outputLimit = $0 else { return XCTFail("\($0)") } }
        XCTAssertTrue(bytes.data.isEmpty)
        XCTAssertThrowsError(try encoder.append([0]))
        let disconnected = try AudioStreamEncoder(format: .pcm, inputSampleRate: 24_000) { _ in throw Disconnected() }
        XCTAssertThrowsError(try disconnected.append([0])) { XCTAssertTrue($0 is Disconnected) }
        XCTAssertThrowsError(try disconnected.finish())
        for invalid in [[Float.nan], [], [Float](repeating: 0, count: 16_385)] {
            let invalidEncoder = try AudioStreamEncoder(format: .pcm, inputSampleRate: 24_000, sink: bytes.append)
            XCTAssertThrowsError(try invalidEncoder.append(invalid))
            XCTAssertThrowsError(try invalidEncoder.append([0]))
        }
        let aborted = try AudioStreamEncoder(format: .pcm, inputSampleRate: 24_000, sink: bytes.append)
        aborted.abort(); aborted.abort()
        XCTAssertThrowsError(try aborted.append([0]))
        XCTAssertTrue(bytes.data.isEmpty)
    }
}
