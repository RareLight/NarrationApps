import XCTest
import AVFoundation
import Darwin
@testable import LibroCore

final class AtomicWavWriterTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("audio.wav"))
    }

    func testIncrementalOrderAndExactCLIConversion() throws {
        try fixture { destination in
            let writer = try AtomicWavWriter(destination: destination)
            try writer.append(samples: [-2, -1, -0.5], sampleRate: 24_000)
            try writer.append(samples: [0, 0.5, 1, 2], sampleRate: 24_000)
            try writer.publish()
            let file = try AVAudioFile(forReading: destination, commonFormat: .pcmFormatInt16, interleaved: true)
            XCTAssertEqual(file.length, 7)
            XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 7))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 7)), [-32767, -32767, -16383, 0, 16383, 32767, 32767])
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
        }
    }

    func testInvalidAudioAndCancellationPreservePreviousOutput() throws {
        try fixture { destination in
            let original = Data("prior complete output".utf8)
            try original.write(to: destination)
            let writer = try AtomicWavWriter(destination: destination)
            XCTAssertThrowsError(try writer.append(samples: [.nan], sampleRate: 24_000))
            try writer.append(samples: [0.5], sampleRate: 24_000)
            XCTAssertThrowsError(try writer.append(samples: [0.5], sampleRate: 32_000))
            XCTAssertThrowsError(try writer.publish { throw CancellationError() })
            writer.abort()
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
        }
    }

    func testPermissionPreservationAndIdempotentAbort() throws {
        try fixture { destination in
            try Data("previous complete audio".utf8).write(to: destination)
            XCTAssertEqual(chmod(destination.path, 0o640), 0)
            let writer = try AtomicWavWriter(destination: destination)
            try writer.append(samples: [0.25], sampleRate: 24_000)
            try writer.publish()
            var info = stat()
            XCTAssertEqual(stat(destination.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o640)
            let aborted = try AtomicWavWriter(destination: destination)
            aborted.abort(); aborted.abort()
            XCTAssertFalse(FileManager.default.fileExists(atPath: aborted.temporary.path))
            XCTAssertThrowsError(try aborted.append(samples: [0.5], sampleRate: 24_000))
            XCTAssertFalse(FileManager.default.fileExists(atPath: aborted.temporary.path))
            let complete = try AVAudioFile(forReading: destination)
            XCTAssertEqual(complete.length, 1)
        }
    }
}
