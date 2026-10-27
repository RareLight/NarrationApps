import XCTest
import AVFoundation
import Darwin
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

final class AtomicAudioWriterTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("audio.wav"))
    }

    func testIncrementalOrderAndExactFloatSamplesWithoutClippingOrGain() throws {
        try fixture { destination in
            let writer = try AtomicAudioWriter(destination: destination)
            try writer.append(samples: [-2, -1, -0.5], sampleRate: 24_000)
            try writer.append(samples: [0, 0.5, 1, 2], sampleRate: 24_000)
            try writer.publish()
            let file = try AVAudioFile(forReading: destination, commonFormat: .pcmFormatFloat32, interleaved: true)
            XCTAssertEqual(file.length, 7)
            XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 7))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatFloat32)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 7)), [-2, -1, -0.5, 0, 0.5, 1, 2])
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
        }
    }

    func testInvalidAudioAndCancellationPreservePreviousOutput() throws {
        try fixture { destination in
            let original = Data("prior complete output".utf8)
            try original.write(to: destination)
            let writer = try AtomicAudioWriter(destination: destination)
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
            let writer = try AtomicAudioWriter(destination: destination)
            try writer.append(samples: [0.25], sampleRate: 24_000)
            try writer.publish()
            var info = stat()
            XCTAssertEqual(stat(destination.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o640)
            let aborted = try AtomicAudioWriter(destination: destination)
            aborted.abort(); aborted.abort()
            XCTAssertFalse(FileManager.default.fileExists(atPath: aborted.temporary.path))
            XCTAssertThrowsError(try aborted.append(samples: [0.5], sampleRate: 24_000))
            XCTAssertFalse(FileManager.default.fileExists(atPath: aborted.temporary.path))
            let complete = try AVAudioFile(forReading: destination)
            XCTAssertEqual(complete.length, 1)
        }
    }

    func testActualRIFFSizeIsCheckedBeforePublication() throws {
        try fixture { destination in
            let previous = Data("prior complete output".utf8)
            try previous.write(to: destination)
            let writer = try AtomicAudioWriter(destination: destination)
            try writer.append(samples: [0.25], sampleRate: 24_000)
            XCTAssertThrowsError(try writer.publish {
                // A sparse temporary fixture exercises the real file-size
                // boundary without allocating or synthesizing 4 GiB of audio.
                let handle = try FileHandle(forWritingTo: writer.temporary)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(UInt32.max) + 9)
            }) { error in
                guard case AudioOutputError.riffLimit = error else { return XCTFail("Expected RIFF limit") }
            }
            writer.abort()
            XCTAssertEqual(try Data(contentsOf: destination), previous)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
        }
    }
    func testExclusivePublicationPreservesLastInstantArrivalAndApprovedReplacementWorks() throws {
        try fixture { destination in
            let previous = Data("another writer's completed output".utf8)
            let writer = try AtomicAudioWriter(destination: destination)
            try writer.append(samples: [-2, 0, 2], sampleRate: 24_000)
            XCTAssertThrowsError(try writer.publish(replaceExisting: false) {
                try previous.write(to: destination)
            }) { error in
                guard case AudioOutputError.destinationExists = error else { return XCTFail("Unexpected \(error)") }
            }
            writer.abort()
            XCTAssertEqual(try Data(contentsOf: destination), previous)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
            let replacement = try AtomicAudioWriter(destination: destination)
            try replacement.append(samples: [-2, 0, 2], sampleRate: 24_000)
            try replacement.publish(replaceExisting: true)
            let file = try AVAudioFile(forReading: destination)
            XCTAssertEqual(file.length, 3)
        }
    }

}
