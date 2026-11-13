import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import AudioOutput
@testable import NarrationCore

final class AudioMetadataWriterTests: XCTestCase {
    private var root: URL!
    private let rate = 24_000
    private var lame: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/codecs/lame/lib/libmp3lame.0.dylib")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - fixtures

    /// 4 s mono PCM: 0.5 s leading zeros, tone, then trailing zeros, at 24 kHz.
    private func pcm(seconds: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(0.5 * Double(rate)))
        while Double(out.count) / Double(rate) < seconds - 0.5 {
            let t = Double(out.count) / Double(rate)
            out.append(Float(sin(2 * .pi * 440 * t) * 0.3))
        }
        out += [Float](repeating: 0, count: Int(seconds) * rate - out.count)
        return out
    }

    private func makeJPEG() throws -> Data {
        let jpeg = NSMutableData()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        return jpeg as Data
    }

    /// Real writer flow: append → finishEncoding → optional artwork → finalize → publish.
    private func write(format: AudioOutputFormat, cover: CoverArtwork? = nil,
                       metadata: AudioFileMetadata = .init(), duration: Double = 4) async throws -> (file: URL, temp: URL, writer: AtomicAudioWriter) {
        let dest = root.appendingPathComponent("out-\(UUID().uuidString).\(format.rawValue)")
        let writer = try AtomicAudioWriter(destination: dest, format: format,
                                           mp3Library: FileManager.default.fileExists(atPath: lame.path) ? lame : nil,
                                           coverArtwork: cover)
        try writer.append(samples: pcm(seconds: 4), sampleRate: rate)
        try writer.finishEncoding()
        if cover != nil, format != .mp3 { try await writer.prepareArtwork() }
        // Returns CLOSED, artwork-finalized but UNTAGGED audio: baselines are
        // measured on the untagged file, then callers finalize explicitly.
        return (dest, writer.temporary, writer)
    }

    // MARK: - readback helpers

    private func compressedPackets(_ url: URL) throws -> (packets: Int, bytes: Int, sha: String) {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { XCTFail("no audio"); return (0, 0, "") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var packets = 0, bytes = 0
        var ctx = SHA256()
        while let buffer = output.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(buffer)
            packets += n
            // Zero-sample stream markers legitimately carry no data; any
            // sample-bearing buffer without a data block fails closed here.
            guard n > 0 else { continue }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
            let data = try blockBytes(block, count: CMBlockBufferGetDataLength(block))
            bytes += data.count; ctx.update(data: data)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(packets, 0); XCTAssertGreaterThan(bytes, 0)
        return (packets, bytes, ctx.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Exactly `count` bytes from the start of a block buffer, fail-closed
    /// for non-contiguous storage and short buffers.
    private func blockBytes(_ block: CMBlockBuffer, count: Int) throws -> Data {
        XCTAssertGreaterThanOrEqual(CMBlockBufferGetDataLength(block), count)
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: raw.baseAddress!)
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        return data
    }

    private func chapters(_ url: URL) throws -> [(title: String, start: Double)] {
        let asset = AVURLAsset(url: url)
        let locale = asset.availableChapterLocales.first ?? Locale(identifier: "en")
        return asset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: nil).map { group in
            (group.items.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue ?? "",
             group.timeRange.start.seconds)
        }
    }

    private func mediaDuration(_ url: URL) -> Double {
        AVURLAsset(url: url).duration.seconds
    }

    /// Actual decoder output via AVAssetReader (Float32 interleaved).
    /// Returns total decoded frame count and the SHA-256 of the FIRST
    /// `prefixFrames` frames' interleaved PCM bytes: the metadata pass may
    /// expose up to one trailing AAC packet, so preservation is proven by an
    /// exact prefix hash plus bounded growth, not whole-length equality.
    private func decodedPrefix(_ url: URL, prefixFrames: Int) throws -> (frames: Int, prefixSHA: String) {
        let asset = AVAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let channels = Int(track.formatDescriptions.compactMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mChannelsPerFrame
        }.first ?? 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var total = 0, remaining = prefixFrames, hashedFrames = 0
        var hasher = SHA256()
        while let buffer = output.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(buffer)
            total += n
            let take = min(n, remaining)
            guard take > 0 else { continue }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
            let data = try blockBytes(block, count: take * channels * 4)
            hasher.update(data: data)
            remaining -= take; hashedFrames += take
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(hashedFrames, min(total, prefixFrames))
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private struct ContentBaseline {
        let packets: Int, packetSHA: String
        let frames: Int, prefixSHA: String
        let duration: Double
    }

    /// Baseline captured BEFORE metadata on the untagged file.
    private func captureBaseline(_ url: URL) throws -> ContentBaseline {
        let packets = try compressedPackets(url)
        let (frames, sha) = try decodedPrefix(url, prefixFrames: .max)
        return ContentBaseline(packets: packets.packets, packetSHA: packets.sha,
                               frames: frames, prefixSHA: sha, duration: mediaDuration(url))
    }

    /// Bounded-native-tail assertion: exact decoded prefix, packet identity,
    /// and <1 AAC-LC packet (1024 source frames @24kHz) of extra presentation.
    private func assertContentPreserved(_ before: ContentBaseline, after: URL) throws {
        let postPackets = try compressedPackets(after)
        XCTAssertEqual(postPackets.packets, before.packets)
        XCTAssertEqual(postPackets.sha, before.packetSHA)
        let (postFrames, postHash) = try decodedPrefix(after, prefixFrames: before.frames)
        XCTAssertEqual(postHash, before.prefixSHA, "decoded PCM prefix must be byte-identical")
        XCTAssertGreaterThanOrEqual(postFrames, before.frames)
        XCTAssertLessThan(postFrames - before.frames, 1_024)
        let postDuration = mediaDuration(after)
        XCTAssertGreaterThanOrEqual(postDuration, before.duration)
        XCTAssertLessThan(postDuration - before.duration, 1_024.0 / 24_000.0)
    }

    private func coverBytes(_ url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        return AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first?.dataValue
    }

    private func sha(_ url: URL) throws -> String {
        var ctx = SHA256(); ctx.update(data: try Data(contentsOf: url))
        return ctx.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - minimal ID3v2.3 parser (independent of production merge code)

    private struct Tag { var frames: [(id: String, body: Data)]; var audioOffset: Int }
    private func parseID3(_ file: URL) throws -> Tag {
        let data = try Data(contentsOf: file)
        guard data.count > 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33, data[3] == 3 else {
            return Tag(frames: [], audioOffset: 0) // no tag; audio begins at 0
        }
        let size = Int(data[6]) << 21 | Int(data[7]) << 14 | Int(data[8]) << 7 | Int(data[9])
        var frames: [(String, Data)] = []
        var i = 10
        while i + 10 <= 10 + size, data[i] != 0 {
            let id = String(bytes: data[i..<i + 4], encoding: .ascii)!
            let fsize = Int(data[i + 4]) << 24 | Int(data[i + 5]) << 16 | Int(data[i + 6]) << 8 | Int(data[i + 7])
            frames.append((id, data.subdata(in: i + 10..<min(i + 10 + fsize, data.count))))
            i += 10 + fsize
        }
        return Tag(frames: frames, audioOffset: 10 + size)
    }

    private func utf16Text(_ body: Data, offset: Int = 0) -> String {
        guard body.count > offset, body[offset] == 0x01 || body[offset] == 0x03 else { return "" }
        let encoding: String.Encoding = body[offset] == 0x03 ? .utf8 : .utf16
        return String(data: body.subdata(in: offset + 1..<body.count), encoding: encoding)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) ?? ""
    }

    private func commText(_ body: Data) -> String {
        // COMM: 0x01 + "eng" + empty UTF16 desc (FF FE 00 00) + text (FF FE + UTF16-LE).
        guard body.count > 8, body[0] == 0x01, String(decoding: body[1...3], as: UTF8.self) == "eng" else { return "" }
        return String(data: body.subdata(in: 8..<body.count), encoding: .utf16)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) ?? ""
    }

    private func be32(_ body: Data, _ at: Int) -> UInt32 {
        UInt32(body[body.startIndex + at]) << 24 | UInt32(body[body.startIndex + at + 1]) << 16
            | UInt32(body[body.startIndex + at + 2]) << 8 | UInt32(body[body.startIndex + at + 3])
    }

    // MARK: - M4A / M4B

    func testM4AChaptersMetadataAndPassthrough() async throws {
        let (dest, temp, writer) = try await write(format: .m4a)
        // Baseline on the CLOSED, untagged file before metadata runs.
        let preCover = coverBytes(temp)
        let baseline = try captureBaseline(temp)
        try await AudioMetadataWriter.finalize(url: temp, format: "m4a", metadata: .init(
            title: "Fixture Title", notes: "Notes body — a résumé, see https://ref.example/x.",
            chapters: [AudioChapter(title: "Caf\u{e9} \u{1F4D6}", startTime: 0, endTime: 1.25),
                       AudioChapter(title: "Two", startTime: 1.25, endTime: 4)]), duration: 4)
        try writer.publish()
        let read = try chapters(dest)
        XCTAssertEqual(read.count, 2)
        // Exact Unicode chapter-title readback via the 'encd' UTF-8 extension.
        XCTAssertEqual(read[0].title, "Caf\u{e9} \u{1F4D6}")
        XCTAssertEqual(read[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(read[1].title, "Two"); XCTAssertEqual(read[1].start, 1.25, accuracy: 0.001)
        // Content preservation: identical decoded prefix + compressed packets,
        // with at most one native AAC packet of extra presentation tail.
        try assertContentPreserved(baseline, after: dest)
        let meta = AVURLAsset(url: dest).commonMetadata
        XCTAssertEqual(AVMetadataItem.metadataItems(from: meta, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common).first?.stringValue, "Fixture Title")
        let desc = AVMetadataItem.metadataItems(from: meta, withKey: AVMetadataKey.commonKeyDescription, keySpace: .common).first?.stringValue
        XCTAssertTrue(desc?.contains("résumé") == true && desc?.contains("ref.example") == true, "notes text persisted")
        XCTAssertEqual(preCover, coverBytes(dest))
    }

    func testM4AHeaderOnlyPreservesContent() async throws {
        let (dest, temp, writer) = try await write(format: .m4a)
        let baseline = try captureBaseline(temp)
        try await AudioMetadataWriter.finalize(url: temp, format: "m4a",
            metadata: .init(title: "Header Only"), duration: 4)
        try writer.publish()
        try assertContentPreserved(baseline, after: dest)
    }

    func testM4AReapplyReplacesChaptersNoDuplicates() async throws {
        let (dest, temp, writer) = try await write(format: .m4a)
        let baseline = try captureBaseline(temp)
        try await AudioMetadataWriter.finalize(url: temp, format: "m4a", metadata: .init(
            title: "T1", notes: "n1",
            chapters: [AudioChapter(title: "First", startTime: 0, endTime: 4)]), duration: 4)
        try await AudioMetadataWriter.finalize(url: temp, format: "m4a", metadata: .init(
            title: "T2", notes: "n2",
            chapters: [AudioChapter(title: "Replacement", startTime: 0, endTime: 4)]), duration: 4)
        try writer.publish()
        let read = try chapters(dest)
        XCTAssertEqual(read.count, 1, "second finalize replaces, not appends")
        XCTAssertEqual(read[0].title, "Replacement")
        try assertContentPreserved(baseline, after: dest)
        XCTAssertEqual(AVMetadataItem.metadataItems(from: AVURLAsset(url: dest).commonMetadata,
            withKey: AVMetadataKey.commonKeyTitle, keySpace: .common).first?.stringValue, "T2")
    }

    func testM4BCarriesChaptersAndCover() async throws {
        let art = try CoverArtwork(data: makeJPEG())
        let (dest, temp, writer) = try await write(format: .m4b, cover: art)
        XCTAssertEqual(coverBytes(temp), art.data, "cover lands before chapters")
        let baseline = try captureBaseline(temp)
        try await AudioMetadataWriter.finalize(url: temp, format: "m4b", metadata: .init(
            title: "Book", notes: "n",
            chapters: [AudioChapter(title: "Caf\u{e9} \u{1F4D6}", startTime: 0, endTime: 2),
                       AudioChapter(title: "B", startTime: 2, endTime: 4)]), duration: 4)
        try writer.publish()
        XCTAssertEqual(try chapters(dest).map { $0.title }, ["Caf\u{e9} \u{1F4D6}", "B"])
        XCTAssertEqual(coverBytes(dest), art.data, "cover bytes survive chapter rewrite")
        try assertContentPreserved(baseline, after: dest)
    }

    func testM4AEmptyMetadataLeavesUnknownFiles() async throws {
        let dest = root.appendingPathComponent("plain.m4a")
        let writer = try AtomicAudioWriter(destination: dest, format: .m4a)
        try writer.append(samples: pcm(seconds: 1), sampleRate: rate)
        try writer.finishEncoding()
        // A foreign fixed-name file must never be removed by metadata steps.
        let foreign = root.appendingPathComponent(".meta.tmp"); try "keep".write(to: foreign, atomically: true, encoding: .utf8)
        let before = try sha(writer.temporary)
        try await AudioMetadataWriter.finalize(url: writer.temporary, format: "m4a", metadata: .init(), duration: 1)
        try writer.publish()
        XCTAssertEqual(try sha(dest), before)
        XCTAssertEqual(try String(contentsOf: foreign), "keep")
    }

    // MARK: - MP3 via real LAME writer

    func testMP3NoCoverChaptersAndByteEquality() async throws {
        guard FileManager.default.fileExists(atPath: lame.path) else { throw XCTSkip("bundled LAME missing") }
        let (dest, temp, writer) = try await write(format: .mp3)
        let tagBefore = try parseID3(temp)
        let beforeData = try Data(contentsOf: temp)
        try await AudioMetadataWriter.finalize(url: temp, format: "mp3", metadata: .init(
            title: "MP3 Title", notes: "plain notes",
            chapters: [AudioChapter(title: "Caf\u{e9} \u{1F4D6}", startTime: 0, endTime: 2), AudioChapter(title: "Two", startTime: 2, endTime: 4)]), duration: 4)
        let tempHash = try sha(temp)
        try writer.publish()
        XCTAssertEqual(try sha(dest), tempHash, "publish renames without mutating MPEG/Xing bytes")
        let tag = try parseID3(dest)
        let chap = tag.frames.filter { $0.id == "CHAP" }
        XCTAssertEqual(chap.count, 2)
        // CHAP body: elementID + start/end ms + 8 offset bytes + nested TIT2
        var body = chap[0].body
        let nul = body.firstIndex(of: 0)!; let elemID = String(data: body[..<nul], encoding: .ascii)!
        body = body.subdata(in: nul + 1..<body.count)
        XCTAssertEqual(elemID, "ch0")
        XCTAssertEqual(be32(body, 0), 0)
        XCTAssertEqual(be32(body, 4), 2_000)
        // 16 bytes timing/offset, then nested frame header (10) + TIT2 body.
        XCTAssertEqual(String(decoding: body[16...19], as: UTF8.self), "TIT2")
        XCTAssertEqual(body[body.startIndex + 26], 0x01, "nested TIT2 uses UTF-16, not invalid UTF-8")
        XCTAssertEqual(utf16Text(body.subdata(in: 26..<body.count)), "Caf\u{e9} \u{1F4D6}")
        let ctoc = try XCTUnwrap(tag.frames.first { $0.id == "CTOC" })
        let ctocBody = ctoc.body
        let tocNul = ctocBody.firstIndex(of: 0)!
        XCTAssertEqual(ctocBody[tocNul + 1], 0x03, "CTOC top-level AND ordered")
        XCTAssertEqual(ctocBody[tocNul + 2], 2)
        // Ordered child element IDs decode and match the CHAP elements.
        var children: [String] = []
        var cursor = ctocBody.startIndex + tocNul + 3
        while cursor < ctocBody.endIndex, let nulAt = ctocBody[cursor...].firstIndex(of: 0) {
            children.append(String(decoding: ctocBody[cursor..<nulAt], as: UTF8.self)); cursor = nulAt + 1
        }
        XCTAssertEqual(children, ["ch0", "ch1"])
        XCTAssertEqual(utf16Text(try XCTUnwrap(tag.frames.first { $0.id == "TIT2" })?.body ?? Data()), "MP3 Title")
        XCTAssertEqual(commText(try XCTUnwrap(tag.frames.first { $0.id == "COMM" })?.body ?? Data()), "plain notes")
        // Audio bytes after the tag are identical to the pre-tag audio.
        let after = try Data(contentsOf: dest)
        XCTAssertEqual(after.suffix(from: tag.audioOffset), beforeData.suffix(from: tagBefore.audioOffset))
    }

    func testMP3CoverAPICRetainedAndReapply() async throws {
        guard FileManager.default.fileExists(atPath: lame.path) else { throw XCTSkip("bundled LAME missing") }
        let art = try CoverArtwork(data: makeJPEG())
        let (dest, temp, writer) = try await write(format: .mp3, cover: art)
        let before = try parseID3(temp)
        let apic = try XCTUnwrap(before.frames.first { $0.id == "APIC" }, "cover APIC frame present")
        try await AudioMetadataWriter.finalize(url: temp, format: "mp3", metadata: .init(
            title: "First Title", notes: "first notes",
            chapters: [AudioChapter(title: "Only", startTime: 0, endTime: 4)]), duration: 4)
        let merged = try parseID3(temp)
        XCTAssertEqual(merged.frames.first { $0.id == "APIC" }?.body, apic.body, "APIC bytes identical")
        try writer.publish()
        let first = try parseID3(dest)
        XCTAssertTrue(first.frames.contains { $0.id == "APIC" }, "APIC retained after merge")
        XCTAssertEqual(first.frames.filter { $0.id == "CHAP" }.count, 1)
        // Re-applying metadata must not duplicate CHAP/CTOC; nil title/notes keep originals.
        try await AudioMetadataWriter.finalize(url: dest, format: "mp3", metadata: .init(
            chapters: [AudioChapter(title: "Again", startTime: 0, endTime: 4)]), duration: 4)
        let second = try parseID3(dest)
        XCTAssertEqual(second.frames.filter { $0.id == "CHAP" }.count, 1)
        XCTAssertEqual(second.frames.filter { $0.id == "CTOC" }.count, 1)
        XCTAssertEqual(second.frames.first { $0.id == "APIC" }?.body, apic.body)
        XCTAssertEqual(utf16Text(try XCTUnwrap(second.frames.first { $0.id == "TIT2" })?.body ?? Data()), "First Title")
        XCTAssertEqual(commText(try XCTUnwrap(second.frames.first { $0.id == "COMM" })?.body ?? Data()), "first notes")
    }

    func testMP3InvalidChaptersAndCancellationPreserveBytes() async throws {
        guard FileManager.default.fileExists(atPath: lame.path) else { throw XCTSkip("bundled LAME missing") }
        let (dest, temp, writer) = try await write(format: .mp3)
        let baseline = try sha(temp)
        let badLists: [[AudioChapter]] = [
            [AudioChapter(title: "x", startTime: 2, endTime: 1)],
            [AudioChapter(title: "x", startTime: 0, endTime: .nan)],
            [AudioChapter(title: "x", startTime: 0, endTime: 9)],
            [AudioChapter(title: "B", startTime: 2, endTime: 4), AudioChapter(title: "A", startTime: 0, endTime: 2)],
        ]
        for bad in badLists {
            do {
                try await AudioMetadataWriter.finalize(url: temp, format: "mp3",
                    metadata: .init(chapters: bad), duration: 4)
                XCTFail("invalid chapters accepted")
            } catch {}
            XCTAssertEqual(try sha(temp), baseline)
        }
        // Duplicate/overlapping chapters are rejected without touching bytes.
        for overlap in [
            [AudioChapter(title: "a", startTime: 0, endTime: 2), AudioChapter(title: "b", startTime: 0, endTime: 2)],
            [AudioChapter(title: "a", startTime: 0, endTime: 3), AudioChapter(title: "b", startTime: 2, endTime: 4)],
        ] {
            do {
                try await AudioMetadataWriter.finalize(url: temp, format: "mp3",
                    metadata: .init(chapters: overlap), duration: 4)
                XCTFail("overlapping chapters accepted")
            } catch {}
            XCTAssertEqual(try sha(temp), baseline)
        }
        // Pre-cancelled task: CancellationError, identical bytes, no scratch left.
        let dirBefore = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let cancelled = Task { () async throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try await AudioMetadataWriter.finalize(url: temp, format: "mp3",
                metadata: .init(title: "t"), duration: 4)
        }
        do { _ = try await cancelled.value; XCTFail("cancellation did not propagate") }
        catch is CancellationError {}
        XCTAssertEqual(try sha(temp), baseline)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), dirBefore)
        try writer.publish(); _ = dest
    }

    func testWAVNoOpPreservesBytes() async throws {
        let (dest, temp, writer) = try await write(format: .wav, metadata: .init(
            title: "ignored", notes: "ignored",
            chapters: [AudioChapter(title: "c", startTime: 0, endTime: 4)]))
        let baseline = try sha(temp)
        try await AudioMetadataWriter.finalize(url: temp, format: "wav", metadata: .init(title: "x"), duration: 4)
        try writer.publish()
        XCTAssertEqual(try sha(dest), baseline)
        _ = dest
    }
}
