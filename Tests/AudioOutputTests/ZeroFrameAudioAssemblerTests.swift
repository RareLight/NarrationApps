import XCTest
import AVFoundation
@testable import AudioOutput
import NarrationCore

final class ZeroFrameAudioAssemblerTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("audio.wav"))
    }
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
        var result: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw AudioOutputError.empty }
            result += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return result
    }
    func testSpeechBitsPreservedAndExactEdgeZerosCountOnce() throws {
        try fixture { url in
            let writer = try AtomicAudioWriter(destination: url)
            let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: 24_000)
            let first: [Float] = [Float(bitPattern: 0x80000000), -2, -0.000001, 0, 0]
            let second: [Float] = [0, 2, Float.leastNonzeroMagnitude]
            try assembler.append(samples: first, gapBeforeSeconds: 1)
            try assembler.append(samples: second, gapBeforeSeconds: 6.0 / 24_000)
            try writer.publish()
            let expected = first + [Float](repeating: 0, count: 3) + second
            XCTAssertEqual(try samples(url).map(\.bitPattern), expected.map(\.bitPattern))
            XCTAssertEqual(assembler.insertedFrames, 3)
        }
    }
    func testNoLeadingOrTrailingGapAndExplicitZeroRemainsZero() throws {
        try fixture { url in
            let writer = try AtomicAudioWriter(destination: url)
            let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: 24_000)
            try assembler.append(samples: [0.25], gapBeforeSeconds: 60)
            try assembler.append(samples: [0.5], gapBeforeSeconds: NarrationPausePolicy.seconds(after: .heading, explicitGap: 0))
            try writer.publish()
            XCTAssertEqual(try samples(url), [0.25, 0.5])
            XCTAssertEqual(assembler.insertedFrames, 0)
        }
    }
    func testCancellationDuringBoundedLongGapPreservesExistingOutput() throws {
        try fixture { url in
            let original = Data("completed recording".utf8); try original.write(to: url)
            let writer = try AtomicAudioWriter(destination: url)
            let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: 24_000)
            try assembler.append(samples: [1])
            var checks = 0
            XCTAssertThrowsError(try assembler.append(samples: [1], gapBeforeSeconds: 60) {
                checks += 1; if checks == 3 { throw CancellationError() }
            })
            writer.abort()
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertLessThanOrEqual(assembler.insertedFrames, 4_096)
        }
    }
    func testEmptyAndInvalidInputsCannotPublish() throws {
        try fixture { url in
            let writer = try AtomicAudioWriter(destination: url)
            let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: 24_000)
            XCTAssertThrowsError(try assembler.append(samples: []))
            XCTAssertThrowsError(try assembler.append(samples: [.nan]))
            XCTAssertThrowsError(try writer.publish())
            writer.abort()
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

extension ZeroFrameAudioAssemblerTests {
    func testEntirelySilentSegmentDoesNotForgetAlreadyInsertedZeros() throws {
        try fixture { url in
            let writer = try AtomicAudioWriter(destination: url)
            let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: 24_000)
            try assembler.append(samples: [1, 0])
            try assembler.append(samples: [0, 0], gapBeforeSeconds: 6.0 / 24_000)
            try assembler.append(samples: [2], gapBeforeSeconds: 6.0 / 24_000)
            try writer.publish()
            XCTAssertEqual(try samples(url), [1] + [Float](repeating: 0, count: 6) + [2])
            XCTAssertEqual(assembler.insertedFrames, 3)
        }
    }
}

extension ZeroFrameAudioAssemblerTests {
    func testExplicitNativeCapturedSpeechBitsSurviveAssembly() throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATION_NATIVE_PCM_WAV"] else {
            throw XCTSkip("Opt-in: supply an isolated native-generated Float32 WAV.")
        }
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(input.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(input.processingFormat.channelCount, 1)
        input.framePosition = 12_000
        func read() throws -> [Float] {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384))
            try input.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let first = try read(), second = try read()
        XCTAssertTrue((1...16_384).contains(first.count)); XCTAssertTrue((1...16_384).contains(second.count))
        XCTAssertTrue(first.contains { $0 != 0 } && second.contains { $0 != 0 })
        try fixture { url in
            let writer = try AtomicAudioWriter(destination: url)
            let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: 24_000)
            try assembler.append(samples: first)
            try assembler.append(samples: second, gapBeforeSeconds: 0.28)
            try writer.publish()
            let expected = first + [Float](repeating: 0, count: Int(assembler.insertedFrames)) + second
            XCTAssertEqual(try samples(url).map(\.bitPattern), expected.map(\.bitPattern))
        }
    }
}
