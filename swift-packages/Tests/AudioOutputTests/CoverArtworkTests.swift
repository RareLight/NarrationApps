import XCTest
import AVFoundation
import AudioToolbox
import ImageIO
import UniformTypeIdentifiers
@testable import AudioOutput

final class CoverArtworkTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func image(_ width: Int = 80, _ height: Int = 120, alpha: Bool = false) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, (alpha ? UTType.png : .jpeg).identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    func testProfilesAndDurableDigestIntegrity() throws {
        let book = try CoverArtwork(data: image())
        XCTAssertEqual(book.width * 3, book.height * 2)
        XCTAssertLessThanOrEqual(book.data.count, 120 * 1024)
        XCTAssertThrowsError(try CoverArtwork(data: Data([0, 1, 2])))
        XCTAssertThrowsError(try CoverArtwork(data: image(), profile: .podcast))
        XCTAssertThrowsError(try CoverArtwork(data: image(1400, 1400, alpha: true), profile: .podcast))
        let podcast = try CoverArtwork(data: image(1500, 1500), profile: .podcast)
        XCTAssertEqual(podcast.width, 1500)
        let store = CoverArtworkStore(root: try root())
        let digest = try store.save(book)
        _ = try store.save(podcast)
        let unknown = store.root.appendingPathComponent("original-user-file.txt")
        try Data("untouched".utf8).write(to: unknown)
        let link = store.root.appendingPathComponent(String(repeating: "f", count: 64) + ".jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unknown)
        try store.removeUnreferenced(keeping: [digest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: podcast.digest).path))
        XCTAssertEqual(try Data(contentsOf: unknown), Data("untouched".utf8))
        XCTAssertEqual(try store.load(digest), book)
        XCTAssertThrowsError(try store.url(for: "../escape"))
        try Data([1, 2]).write(to: store.url(for: digest))
        XCTAssertThrowsError(try store.load(digest))
        XCTAssertFalse(AudioOutputFormat.wav.supportsCoverArtwork)
    }
    // Core Audio returns elementary encoded packets independently of the tag writer.
    private func packets(_ url: URL) throws -> [Data] {
        var file: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file), noErr)
        let id = try XCTUnwrap(file); defer { AudioFileClose(id) }
        var count: UInt64 = 0, size = UInt32(MemoryLayout<UInt64>.size)
        XCTAssertEqual(AudioFileGetProperty(id, kAudioFilePropertyAudioDataPacketCount, &size, &count), noErr)
        var result: [Data] = []
        for index in 0..<count {
            var bytes = [UInt8](repeating: 0, count: 65536), length: UInt32 = 65536, number: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = bytes.withUnsafeMutableBytes { AudioFileReadPacketData(id, false, &length, &description, Int64(index), &number, $0.baseAddress!) }
            XCTAssertEqual(status, noErr); XCTAssertEqual(number, 1)
            result.append(Data(bytes.prefix(Int(length))))
        }
        return result
    }
    func testAACCoverPassthroughPreservesEveryEncodedPacketAndDecodedSample() async throws {
        let root = try root(), cover = try CoverArtwork(data: image())
        let samples = (0..<48000).map { Float(sin(Double($0) * 0.1) * 0.15) }
        for format in [AudioOutputFormat.m4a, .m4b] {
            let baseline = root.appendingPathComponent("plain.\(format.rawValue)")
            let tagged = root.appendingPathComponent("cover.\(format.rawValue)")
            let writer = try AtomicAudioWriter(destination: baseline, format: format)
            try writer.append(samples: samples, sampleRate: 24000); try writer.publish()
            try FileManager.default.copyItem(at: baseline, to: tagged)
            try await AudioArtworkMetadata.addAAC(cover, to: tagged)
            let readCover = try await AudioArtworkMetadata.embeddedCover(in: tagged)
            XCTAssertEqual(readCover, cover.data)
            XCTAssertEqual(try packets(tagged), try packets(baseline))
            var a: [Float] = [], b: [Float] = []
            try NativeAudio.decode(baseline) { a += $0 }; try NativeAudio.decode(tagged) { b += $0 }
            XCTAssertEqual(a.map(\.bitPattern), b.map(\.bitPattern))
            let atomic = try AtomicAudioWriter(destination: root.appendingPathComponent("atomic.\(format.rawValue)"), format: format, coverArtwork: cover)
            try atomic.append(samples: samples, sampleRate: 24000)
            try await atomic.publishWithArtwork()
            let embedded = try await AudioArtworkMetadata.embeddedCover(in: atomic.destination)
            XCTAssertEqual(embedded, cover.data)
        }
    }
    func testMP3CoverPreservesPacketsAndGaplessSeekHeader() async throws {
        let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/codecs/lame/lib/libmp3lame.0.dylib")
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Prepare the pinned MP3 codec first.") }
        let root = try root(), cover = try CoverArtwork(data: image())
        let samples = (0..<48000).map { Float(sin(Double($0) * 0.1) * 0.15) }
        var urls: [URL] = []
        for art in [nil, cover] {
            let output = root.appendingPathComponent(art == nil ? "plain.mp3" : "cover.mp3")
            let writer = try AtomicAudioWriter(destination: output, format: .mp3, mp3Library: library, coverArtwork: art)
            try writer.append(samples: samples, sampleRate: 24000); try await writer.publishWithArtwork(); urls.append(output)
        }
        let embedded = try await AudioArtworkMetadata.embeddedCover(in: urls[1])
        XCTAssertEqual(embedded, cover.data)
        let taggedBytes = try Data(contentsOf: urls[1])
        let frame = try XCTUnwrap(taggedBytes.range(of: Data("APIC".utf8)))
        let payload = frame.lowerBound + 10
        XCTAssertEqual(taggedBytes[payload], 0) // LAME's ISO-8859-1 APIC text encoding.
        XCTAssertEqual(taggedBytes[(payload + 1)..<(payload + 11)], Data("image/jpeg".utf8))
        XCTAssertEqual(taggedBytes[payload + 12], 3) // ID3 front cover, not Other.
        XCTAssertEqual(try packets(urls[0]), try packets(urls[1]))
        for url in urls {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, 48000, accuracy: 1152)
            file.framePosition = file.length / 2
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512))
            try file.read(into: buffer); XCTAssertEqual(buffer.frameLength, 512)
        }
    }
    func testAsyncMetadataCancellationPreservesExistingOutput() async throws {
        let output = try root().appendingPathComponent("previous.m4a"), previous = Data("previous".utf8)
        try previous.write(to: output)
        let writer = try AtomicAudioWriter(destination: output, format: .m4a, coverArtwork: CoverArtwork(data: image()))
        try writer.append(samples: Array(repeating: 0.01, count: 24000), sampleRate: 24000)
        do { try await writer.publishWithArtwork { throw CancellationError() }; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        writer.abort(); XCTAssertEqual(try Data(contentsOf: output), previous)
    }
}
