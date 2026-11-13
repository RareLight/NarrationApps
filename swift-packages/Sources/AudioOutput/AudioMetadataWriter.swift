import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// A seekable chapter inside a finished audio file, times in seconds.
public struct AudioChapter: Codable, Equatable, Sendable {
    public let title: String
    public let startTime: Double
    public let endTime: Double
    public init(title: String, startTime: Double, endTime: Double) {
        self.title = title; self.startTime = startTime; self.endTime = endTime
    }
}

/// Show-notes/title metadata embedded into a finished audio file.
public struct AudioFileMetadata: Codable, Equatable, Sendable {
    public let title: String?
    public let notes: String?
    public let chapters: [AudioChapter]
    public init(title: String? = nil, notes: String? = nil, chapters: [AudioChapter] = []) {
        self.title = title; self.notes = notes; self.chapters = chapters
    }
}

public enum AudioMetadataWriterError: Error, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case invalidChapters(String)
    case writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): "Metadata embedding is not supported for \(f)."
        case .invalidChapters(let m): m
        case .writeFailed(let m): m
        }
    }
}

/// Finalizes finished audio outputs with embedded chapters and show notes.
/// Runs on an owned same-directory scratch file before hash/probe/atomic
/// publication; a container/integrity failure surfaces to the caller so the
/// original completed destination is preserved.
///
/// M4A/M4B: AVMutableMovie + QuickTime 'text' chapter track (the only native
/// writer that retains chapter tracks — AVAssetWriter fails -12780 and
/// AVAssetExportSession drops them).
/// MP3: bounded ID3v2.3 CHAP + ordered CTOC + TIT2/COMM merge, preserving all
/// existing frames (APIC etc.) and every MPEG/Xing byte.
public enum AudioMetadataWriter {
    public static let maximumChapters = 255

    /// Finalize `url` in place. `format` is the container extension
    /// ("m4a"/"m4b"/"mp3"); `duration` bounds chapter end times.
    public static func finalize(url: URL, format: String, metadata: AudioFileMetadata, duration: TimeInterval) async throws {
        try Task.checkCancellation()
        guard format.lowercased() != "wav" else { return }
        guard metadata.title != nil || metadata.notes != nil || !metadata.chapters.isEmpty else { return }
        guard duration.isFinite, duration > 0, duration <= Double(UInt32.max) / 1000,
              (metadata.title?.utf8.count ?? 0) <= 4096,
              (metadata.notes?.utf8.count ?? 0) <= 32 * 1024 else {
            throw AudioMetadataWriterError.invalidChapters("Audio metadata exceeds its supported limits.")
        }
        switch format.lowercased() {
        case "m4a", "m4b":
            try await finalizeM4A(url: url, metadata: metadata, duration: duration)
        case "mp3":
            try finalizeMP3(url: url, metadata: metadata, duration: duration)
        default:
            throw AudioMetadataWriterError.unsupportedFormat(format)
        }
    }

    private static func validatedChapters(_ chapters: [AudioChapter], duration: TimeInterval) throws -> [AudioChapter] {
        var lastEnd = 0.0
        var lastStart = -1.0
        for c in chapters {
            guard c.startTime.isFinite, c.endTime.isFinite, c.startTime >= 0, c.endTime > c.startTime,
                  c.endTime <= duration + 0.000001, c.startTime > lastStart, c.startTime >= lastEnd,
                  !c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  c.title.utf8.count <= 4096 else {
                throw AudioMetadataWriterError.invalidChapters("Invalid chapter range or title.")
            }
            lastStart = c.startTime; lastEnd = c.endTime
        }
        guard chapters.count <= maximumChapters else {
            throw AudioMetadataWriterError.invalidChapters("Chapter count \(chapters.count) exceeds \(maximumChapters)")
        }
        return chapters
    }

    // MARK: - M4A/M4B via AVMutableMovie (verified native path)

    private static func finalizeM4A(url: URL, metadata: AudioFileMetadata, duration: TimeInterval) async throws {
        let chapters = try validatedChapters(metadata.chapters, duration: duration)
        let dest = try scratch(beside: url)
        defer { try? FileManager.default.removeItem(at: dest) }

        // Byte-copy the original into owned scratch with bounded streaming:
        // the copy keeps the compressed AAC media bytes identical. writeHeader
        // normalizes track presentation to full packet extent, which can
        // expose at most one already-existing AAC tail packet (+<1024 source
        // frames) — decoded prefix content is unchanged, and no audio is
        // re-encoded, resampled or leveled.
        let input = try FileHandle(forReadingFrom: url)
        let output = try FileHandle(forWritingTo: dest)
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try input.close(); try output.close()
        } catch {
            try? input.close(); try? output.close()
            throw error
        }

        // AVMutableMovie loads the copy in place; appended chapter samples go
        // into the same file's mdat via defaultMediaDataStorage, and
        // writeHeader only rewrites the header. Native appending to an
        // existing file is the documented AVMovie path — no track copying.
        let movie = AVMutableMovie(url: dest, options: nil)
        let source = AVURLAsset(url: dest, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let srcDur = try await source.load(.duration)
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: dest, options: nil)

        // The original audio track's sample data is preserved verbatim;
        // writeHeader normalizes only the trailing-packet presentation. A
        // chapter-associated text track from a previous pass is replaced.
        var audioTrack: AVMutableMovieTrack?
        for track in movie.tracks where track.mediaType == .audio {
            for associated in track.associatedTracks(ofType: .chapterList)
            where associated.mediaType == .text {
                if let stale = movie.tracks.first(where: { $0.trackID == associated.trackID }) {
                    movie.removeTrack(stale)
                }
            }
            audioTrack = track
        }
        guard let audioTrack else { throw AudioMetadataWriterError.writeFailed("No audio track could be copied") }

        if !chapters.isEmpty {
            guard let cTrack = movie.addMutableTrack(withMediaType: .text, copySettingsFrom: nil) else {
                throw AudioMetadataWriterError.writeFailed("Could not create chapter text track")
            }
            cTrack.extendedLanguageTag = Locale.preferredLanguages.first ?? "en"
            let fmt = try makeTextFormatDescription()
            let ts = CMTimeScale(1_000)
            for ch in chapters {
                try Task.checkCancellation()
                let range = CMTimeRange(start: CMTime(seconds: ch.startTime, preferredTimescale: ts),
                                        duration: CMTime(seconds: ch.endTime - ch.startTime, preferredTimescale: ts))
                do {
                    let sample = try makeTextSample(ch.title, range: range, fmt: fmt)
                    _ = try cTrack.append(CMReadySampleBuffer(unsafeBuffer: sample))
                } catch {
                    throw AudioMetadataWriterError.writeFailed("Chapter sample append failed: \(error)")
                }
            }
            let movieRange = CMTimeRange(start: .zero, duration: srcDur)
            cTrack.insertMediaTimeRange(movieRange, into: movieRange)
            audioTrack.addTrackAssociation(to: cTrack, type: .chapterList)
            cTrack.isEnabled = false
        }

        // .common keyspace items are silently dropped by writeHeader(.m4a);
        // .iTunes keyspace persists and reads back as common metadata.
        func itunesItem(_ key: AVMetadataKey, _ value: String) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes; item.key = key.rawValue as NSString; item.value = value as NSString
            return item
        }
        var meta = try await source.load(.metadata)
        let replaced: Set<AVMetadataIdentifier> = Set(
            (metadata.title == nil ? [] : [AVMetadataIdentifier.iTunesMetadataSongName]) +
            (metadata.notes == nil ? [] : [AVMetadataIdentifier.iTunesMetadataDescription]))
        // The SDK exposes no named long-description constant; match the raw
        // iTunes 'ldes' atom key directly when dropping/adding it.
        meta.removeAll { $0.identifier.map(replaced.contains) == true
            || (metadata.notes != nil && ($0.key as? String) == "ldes") }
        if let title = metadata.title { meta.append(itunesItem(.iTunesMetadataKeySongName, title)) }
        if let notes = metadata.notes {
            meta.append(itunesItem(.iTunesMetadataKeyDescription, notes))
            let long = AVMutableMetadataItem()
            long.keySpace = .iTunes; long.key = "ldes" as NSString; long.value = notes as NSString
            meta.append(long)
        }
        movie.metadata = meta

        do {
            try movie.writeHeader(to: dest, fileType: .m4a, options: .addMovieHeaderToDestination)
        } catch {
            throw AudioMetadataWriterError.writeFailed("Movie header write failed: \(error)")
        }
        try Task.checkCancellation()
        guard rename(dest.path, url.path) == 0 else { throw AudioMetadataWriterError.writeFailed("Could not commit audio metadata.") }
    }

    /// QuickTime 'text' sample description as a complete 60-byte stsd atom.
    /// The bridge requires the full atom; a bare record errors -12717.
    private static func makeTextFormatDescription() throws -> CMTextFormatDescription {
        let desc: [UInt8] = [
            0x00, 0x00, 0x00, 0x3C, 0x74, 0x65, 0x78, 0x74,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00,
        ]
        var fmt: CMTextFormatDescription?
        let st = desc.withUnsafeBytes { ptr -> OSStatus in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: desc.count, flavor: nil, mediaType: kCMMediaType_Text, formatDescriptionOut: &fmt)
        }
        guard st == noErr, let fmt else { throw AudioMetadataWriterError.writeFailed("Text format description OSStatus \(st)") }
        return fmt
    }

    /// QTFF 'text' sample: 16-bit big-endian UTF-8 byte count + UTF-8 text +
    /// a 12-byte 'encd' sample-extension atom declaring encoding 0x0100 (UTF-8).
    /// Without the extension AVFoundation decodes MacRoman and mojibakes
    /// non-ASCII titles; this is the established FFmpeg QTFF layout.
    private static func makeTextSample(_ title: String, range: CMTimeRange, fmt: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = [UInt8](title.utf8)
        var data = Data()
        data.append(contentsOf: [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)])
        data.append(contentsOf: utf8)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0C, 0x65, 0x6E, 0x63, 0x64, 0x00, 0x00, 0x01, 0x00])
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard st == kCMBlockBufferNoErr, let block else { throw AudioMetadataWriterError.writeFailed("Block buffer \(st)") }
        st = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard st == kCMBlockBufferNoErr else { throw AudioMetadataWriterError.writeFailed("Block fill \(st)") }
        var timing = CMSampleTimingInfo(duration: range.duration, presentationTimeStamp: range.start, decodeTimeStamp: .invalid)
        var size = CMBlockBufferGetDataLength(block)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else {
            throw AudioMetadataWriterError.writeFailed("Text sample creation failed")
        }
        return sb
    }

    // MARK: - MP3 ID3v2.3 CHAP/CTOC/TIT2/COMM merge

    private static func finalizeMP3(url: URL, metadata: AudioFileMetadata, duration: TimeInterval) throws {
        let chapters = try validatedChapters(metadata.chapters, duration: duration)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 10) ?? Data()
        guard header.count == 10 else { throw AudioMetadataWriterError.writeFailed("Incomplete MP3.") }
        var frames = Data()
        if header.starts(with: Data("ID3".utf8)) {
            guard header[3] == 3, header[4] == 0, header[5] == 0, header[6...9].allSatisfy({ $0 < 128 }) else {
                throw AudioMetadataWriterError.writeFailed("Unsupported ID3 tag.")
            }
            let size = syncsafe(header, at: 6)
            guard size <= 1_048_576 else { throw AudioMetadataWriterError.writeFailed("ID3 tag exceeds its size limit.") }
            frames = try input.read(upToCount: size) ?? Data()
            guard frames.count == size else { throw AudioMetadataWriterError.writeFailed("Incomplete ID3 tag.") }
        } else {
            guard header[0] == 0xFF, header[1] & 0xE0 == 0xE0 else {
                throw AudioMetadataWriterError.writeFailed("MP3 audio frames are unavailable.")
            }
            try input.seek(toOffset: 0)
        }
        var replaced = ["CHAP", "CTOC"]
        if metadata.title != nil { replaced.append("TIT2") }
        if metadata.notes != nil { replaced.append("COMM") }
        frames = try removingFrames(frames, ids: replaced)

        var newFrames = Data()
        if let title = metadata.title {
            newFrames.append(frame("TIT2", body: textFrameBody(title)))
        }
        if let notes = metadata.notes {
            newFrames.append(frame("COMM", body: commentFrameBody(notes)))
        }
        if !chapters.isEmpty {
            let ms = { (s: Double) -> UInt32 in UInt32((s * 1000).rounded()) }
            for (i, ch) in chapters.enumerated() {
                var body = Data("ch\(i)".utf8); body.append(0)
                body.append(contentsOf: ms(ch.startTime).bigEndianBytes)
                body.append(contentsOf: ms(ch.endTime).bigEndianBytes)
                body.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
                body.append(frame("TIT2", body: textFrameBody(ch.title)))
                newFrames.append(frame("CHAP", body: body))
            }
            var toc = Data("toc".utf8); toc.append(0)
            toc.append(0x03) // Top-level and ordered.
            toc.append(UInt8(chapters.count))
            for i in 0..<chapters.count { toc.append(contentsOf: "ch\(i)".utf8); toc.append(0) }
            newFrames.append(frame("CTOC", body: toc))
        }

        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        let merged = frames + newFrames
        guard merged.count <= 1_048_576 else { throw AudioMetadataWriterError.writeFailed("ID3 tag exceeds its size limit.") }
        let ss = merged.count
        for shift in [21, 14, 7, 0] { tag.append(UInt8((ss >> shift) & 0x7F)) }
        tag.append(merged)
        let dest = try scratch(beside: url)
        defer { try? FileManager.default.removeItem(at: dest) }
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        try output.write(contentsOf: tag)
        while true {
            try AudioWorkCheckpoint.check()
            let part = try input.read(upToCount: 1_048_576) ?? Data()
            if part.isEmpty { break }
            try output.write(contentsOf: part)
        }
        try output.synchronize()
        try Task.checkCancellation()
        guard rename(dest.path, url.path) == 0 else { throw AudioMetadataWriterError.writeFailed("Could not commit MP3 metadata.") }
    }

    private static func syncsafe(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 21 | Int(data[offset + 1]) << 14 | Int(data[offset + 2]) << 7 | Int(data[offset + 3])
    }

    private static func frame(_ id: String, body: Data) -> Data {
        var f = Data(id.utf8.prefix(4))
        f.append(contentsOf: UInt32(body.count).bigEndianBytes)
        f.append(contentsOf: [0x00, 0x00])
        f.append(body)
        return f
    }

    private static func textFrameBody(_ text: String) -> Data {
        var d = Data([0x01, 0xFF, 0xFE])
        for unit in text.utf16 { d.append(UInt8(unit & 0xff)); d.append(UInt8(unit >> 8)) }
        return d
    }

    private static func commentFrameBody(_ text: String) -> Data {
        var d = Data([0x01])
        d.append(contentsOf: "eng".utf8)
        d.append(contentsOf: [0xFF, 0xFE, 0, 0]) // Empty UTF-16 short description.
        d.append(textFrameBody(text).dropFirst())
        return d
    }

    private static func removingFrames(_ data: Data, ids: [String]) throws -> Data {
        var out = Data(); var i = data.startIndex
        while i + 10 <= data.endIndex, data[i] != 0 {
            let id = String(bytes: data[i..<i + 4], encoding: .ascii) ?? ""
            let size = Int(data[i + 4]) << 24 | Int(data[i + 5]) << 16 | Int(data[i + 6]) << 8 | Int(data[i + 7])
            let end = i + 10 + size
            guard size >= 0, end <= data.endIndex, id.utf8.count == 4,
                  id.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
                throw AudioMetadataWriterError.writeFailed("Invalid ID3 frame.")
            }
            if !ids.contains(id) { out.append(data[i..<end]) }
            i = end
        }
        guard data[i..<data.endIndex].allSatisfy({ $0 == 0 }) else { throw AudioMetadataWriterError.writeFailed("Invalid ID3 padding.") }
        return out
    }

    private static func scratch(beside url: URL) throws -> URL {
        let path = url.deletingLastPathComponent().appendingPathComponent(".audio-metadata-\(UUID().uuidString).m4a")
        let fd = open(path.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AudioMetadataWriterError.writeFailed("Could not create metadata scratch.") }
        close(fd)
        return path
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8(self >> 16 & 0xff), UInt8(self >> 8 & 0xff), UInt8(self & 0xff)] }
}
