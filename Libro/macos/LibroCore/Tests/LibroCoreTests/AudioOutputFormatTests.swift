import XCTest
import AVFoundation
import AudioToolbox
@testable import LibroCore

final class AudioOutputFormatTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func library() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LIBRO_TEST_MP3_LIBRARY"] else {
            throw XCTSkip("Run the optional native codec gate with a prepared LAME library.")
        }
        return URL(fileURLWithPath: path)
    }

    func testPreferenceDefaultsRestoresAndRejectsUnknownValues() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = OutputFormatPreference(defaults: defaults)
        XCTAssertEqual(preference.load(), .wav)
        for format in AudioOutputFormat.allCases {
            preference.save(format)
            XCTAssertEqual(OutputFormatPreference(defaults: defaults).load(), format)
        }
        defaults.set("unknown", forKey: "LibroOutputFormat")
        XCTAssertEqual(preference.load(), .wav)
    }

    func testPlanningUsesSelectedFormatAndKeepsCollisionProtection() throws {
        let root = try root()
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let first = InputDocument(source: root.appendingPathComponent("one.txt"), kind: .text, relativePath: "Book/one.m4b.txt")
        let second = InputDocument(source: root.appendingPathComponent("two.txt"), kind: .text, relativePath: "Book/one.txt")
        for format in AudioOutputFormat.allCases {
            XCTAssertEqual(BatchPlanner.defaultOutput(first, format: format), "Book/one.\(format.rawValue)")
            XCTAssertThrowsError(try BatchPlanner.plan([first, second], output: output, format: format))
            let plans = try BatchPlanner.plan([first, second], output: output, names: [second.id: "Book/two.\(format.rawValue)"], format: format)
            let request = BatchRequest(documents: plans, outputDirectory: output, workspace: root, settings: .init(), serial: false, outputFormat: format)
            XCTAssertEqual(request.outputFormat, format)
            XCTAssertEqual(plans.map(\.relativeOutput), ["Book/one.\(format.rawValue)", "Book/two.\(format.rawValue)"])
            XCTAssertEqual(format.replacingExtension("Book/custom.wav"), "Book/custom.\(format.rawValue)")
        }
        XCTAssertThrowsError(try BatchPlanner.plan([first], output: output, names: [first.id: "wrong.mp3"], format: .wav))
    }

    func testWavPreservesEveryFiniteFloatBitIncludingLevelsBeyondFullScale() throws {
        let pattern: [Float] = [-2.25, -1.0000001, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 0.12345679, 0.00001, 1.0000001, 2.5]
        // Exercise partial native reads and multiple writes as well as exact bits.
        let samples = (0..<200_003).map { pattern[$0 % pattern.count] }
        let url = try root().appendingPathComponent("raw.wav")
        let writer = try AtomicAudioWriter(destination: url)
        for start in stride(from: 0, to: samples.count, by: 3_000) {
            try writer.append(samples: Array(samples[start..<min(start + 3_000, samples.count)]), sampleRate: 24_000)
        }
        try writer.publish()
        let decoded = try read(url)
        XCTAssertEqual(decoded.samples.map(\.bitPattern), samples.map(\.bitPattern))
        XCTAssertEqual(decoded.rate, 24_000)
    }

    func testAACContainersPreserveRateLengthAndRelativeLevels() throws {
        for format in [AudioOutputFormat.m4a, .m4b] {
            for rate in [24_000, 32_000] { try levels(format, rate: rate) }
        }
    }

    func testMP3PreservesRateAndRelativeLevels() throws {
        let library = try library()
        for rate in [24_000, 32_000] { try levels(.mp3, rate: rate, library: library) }
    }

    func testCancelledEncodedPublicationPreservesOldFilesAndRemovesStaging() throws {
        let root = try root()
        let mp3Library = ProcessInfo.processInfo.environment["LIBRO_TEST_MP3_LIBRARY"].map { URL(fileURLWithPath: $0) }
        for format in [AudioOutputFormat.m4a, .m4b] + (mp3Library == nil ? [] : [.mp3]) {
            let url = root.appendingPathComponent("prior.\(format.rawValue)")
            let prior = Data("prior complete output".utf8)
            try prior.write(to: url)
            let writer = try AtomicAudioWriter(destination: url, format: format, mp3Library: mp3Library)
            try writer.append(samples: Array(repeating: 0.125, count: 2_048), sampleRate: 24_000)
            XCTAssertThrowsError(try writer.publish { throw CancellationError() })
            writer.abort()
            XCTAssertEqual(try Data(contentsOf: url), prior)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
        }
    }

    private func read(_ url: URL) throws -> (samples: [Float], rate: Int) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { XCTFail("Unexpected end of audio"); break }
            samples.append(contentsOf: UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        }
        return (samples, Int(file.fileFormat.sampleRate))
    }

    private func levels(_ format: AudioOutputFormat, rate: Int, library: URL? = nil) throws {
        let root = try root()
        let url = root.appendingPathComponent("levels.\(format.rawValue)")
        let samples = (0..<rate * 4).map { index in
            Float(index < rate * 2 ? 0.01 : 0.3) * sin(2 * .pi * Float(440 * index) / Float(rate))
        }
        let writer = try AtomicAudioWriter(destination: url, format: format, mp3Library: library)
        for start in stride(from: 0, to: samples.count, by: 3_000) {
            try writer.append(samples: Array(samples[start..<min(start + 3_000, samples.count)]), sampleRate: rate)
        }
        try writer.publish()
        let decoded = try read(url)
        XCTAssertEqual(decoded.rate, rate)
        XCTAssertLessThan(abs(decoded.samples.count - samples.count), rate / 10)
        func rms(_ range: Range<Int>) -> Double {
            sqrt(decoded.samples[range].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(range.count))
        }
        let quiet = rms(rate / 2..<rate * 3 / 2)
        let loud = rms(rate * 5 / 2..<rate * 7 / 2)
        XCTAssertEqual(quiet, 0.01 / sqrt(2), accuracy: 0.0005)
        XCTAssertEqual(loud, 0.3 / sqrt(2), accuracy: 0.012)
        XCTAssertEqual(loud / quiet, 30, accuracy: 1.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporary.path))
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data("iTunNORM".utf8)))
        if format == .mp3 {
            let tag = try XCTUnwrap(data.range(of: Data("LAME3.100".utf8)))
            // Peak amplitude and both ReplayGain fields in the LAME tag.
            XCTAssertEqual(Array(data[(tag.lowerBound + 11)..<(tag.lowerBound + 19)]), Array(repeating: 0, count: 8))
        }
        var file: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file), noErr)
        let opened = try XCTUnwrap(file)
        defer { AudioFileClose(opened) }
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        XCTAssertEqual(AudioFileGetProperty(opened, kAudioFilePropertyFileFormat, &size, &type), noErr)
        XCTAssertEqual(type, format == .mp3 ? kAudioFileMP3Type : format == .m4b ? kAudioFileM4BType : kAudioFileM4AType)
    }
}
