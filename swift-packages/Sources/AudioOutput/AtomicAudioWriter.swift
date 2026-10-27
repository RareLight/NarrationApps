import Foundation
import AVFoundation
import Darwin

public enum AudioOutputError: Error, LocalizedError {
    case invalidPCM, inconsistentFormat, riffLimit, storage, empty, encoding, encoderUnavailable, destinationExists

    public var errorDescription: String? {
        switch self {
        case .invalidPCM: "Audio must contain finite samples and a positive sample rate."
        case .inconsistentFormat: "Audio sample rate changed between chunks."
        case .riffLimit: "Audio exceeds the WAV size limit. Split the document."
        case .destinationExists: "An output appeared after approval. Review the destination before replacing it."
        case .storage: "Could not write or publish audio in the selected destination."
        case .empty: "The speech engine returned no audio."
        case .encoding: "The selected audio encoder could not finish this recording."
        case .encoderUnavailable: "The bundled MP3 encoder is unavailable. Prepare native dependencies and rebuild Libro."
        }
    }
}

/// Synchronous, single-owner writer. Call from the coordinator's executor.
/// WAV stores the model's Float32 samples exactly. Lossy encoders receive those
/// same samples without gain, clipping, normalization or integer quantization.
public final class AtomicAudioWriter {
    public let destination: URL
    public let temporary: URL
    public let format: AudioOutputFormat
    public private(set) var frames: UInt64 = 0
    private var sampleRate: Int?
    private var audioFile: AVAudioFile?
    private var mp3: MP3Encoder?
    private let mp3Library: URL?
    private let coverArtwork: CoverArtwork?
    private var artworkFinalized = false
    private let bitRate: Int
    private var published = false
    private var aborted = false
    private let previousMode: mode_t?

    public init(destination: URL, format: AudioOutputFormat = .wav, mp3Library: URL? = nil, bitRate: Int = 64_000, coverArtwork: CoverArtwork? = nil) throws {
        guard (8_000...320_000).contains(bitRate) else { throw AudioOutputError.encoding }
        self.coverArtwork = format.supportsCoverArtwork ? coverArtwork : nil
        self.bitRate = bitRate
        self.format = format; self.mp3Library = mp3Library
        self.destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let parent = self.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        temporary = parent.appendingPathComponent(".libro-audio-\(UUID().uuidString).\(format.rawValue)")
        var information = stat()
        previousMode = stat(self.destination.path, &information) == 0 ? information.st_mode & 0o7777 : nil
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_RDWR, 0o666)
        guard descriptor >= 0 else { throw AudioOutputError.storage }
        close(descriptor)
    }

    deinit { abort() }

    public func append(samples: [Float], sampleRate: Int) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), sampleRate > 0,
              sampleRate <= 192_000, samples.count <= Int(UInt32.max) else { throw AudioOutputError.invalidPCM }
        // AVFoundation includes padding (4 KiB on the acceptance machine),
        // unlike the CLI's minimal header. Reserve room and verify the actual
        // closed-file size at publication rather than assuming a 44-byte WAV.
        if format == .wav {
            guard (frames + UInt64(samples.count)) * 4 <= UInt64(UInt32.max) - 65_536 else { throw AudioOutputError.riffLimit }
        }
        if let expected = self.sampleRate, expected != sampleRate { throw AudioOutputError.inconsistentFormat }
        guard !published, !aborted else { throw AudioOutputError.storage }
        do {
            if format == .mp3 {
                if mp3 == nil { mp3 = try MP3Encoder(libraryURL: mp3Library, output: temporary, sampleRate: sampleRate, coverArtwork: coverArtwork); self.sampleRate = sampleRate }
                try mp3!.append(samples)
                frames += UInt64(samples.count)
                return
            }
            if audioFile == nil {
                var settings: [String: Any] = [AVFormatIDKey: format == .wav ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC,
                                              AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
                if format == .wav {
                    settings[AVLinearPCMBitDepthKey] = 32
                    settings[AVLinearPCMIsFloatKey] = true
                    settings[AVLinearPCMIsBigEndianKey] = false
                    settings[AVLinearPCMIsNonInterleaved] = false
                } else {
                    settings[AVEncoderBitRateKey] = bitRate
                }
                audioFile = try AVAudioFile(forWriting: temporary, settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: true)
                self.sampleRate = sampleRate
            }
            guard let file = audioFile,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { throw AudioOutputError.storage }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
            frames += UInt64(samples.count)
        } catch let error as AudioOutputError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AudioOutputError.storage }
    }

    /// The caller revalidates destinations and cancellation at this boundary.
    public func publish(replaceExisting: Bool = true, beforePublication: () throws -> Void = {}) throws {
        guard frames > 0, !published, !aborted else { throw AudioOutputError.empty }
        guard coverArtwork == nil || format == .mp3 || artworkFinalized else { throw ArtworkError.metadata }
        do {
            try Task.checkCancellation()
            try mp3?.finish(); mp3 = nil
            audioFile = nil // Finalize the native container/encoder before fsync.
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            if let mode = previousMode, fchmod(handle.fileDescriptor, mode) != 0 { throw AudioOutputError.storage }
            try handle.synchronize()
            try beforePublication()
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw AudioOutputError.storage }
            guard info.st_size > 0 else { throw AudioOutputError.empty }
            if format == .wav {
                guard info.st_size >= 44, UInt64(info.st_size) - 8 <= UInt64(UInt32.max) else { throw AudioOutputError.riffLimit }
            }
            let result = replaceExisting ? rename(temporary.path, destination.path)
                : renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL))
            guard result == 0 else {
                if !replaceExisting, errno == EEXIST { throw AudioOutputError.destinationExists }
                throw AudioOutputError.storage
            }
            published = true
        } catch let error as AudioOutputError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AudioOutputError.storage }
    }

    /// Async native metadata finalization remains inside the atomic transaction.
    public func publishWithArtwork(replaceExisting: Bool = true, beforePublication: () throws -> Void = {}) async throws {
        if let coverArtwork, format == .m4a || format == .m4b {
            guard frames > 0, !published, !aborted else { throw AudioOutputError.empty }
            audioFile = nil
            try await AudioArtworkMetadata.addAAC(coverArtwork, to: temporary)
            artworkFinalized = true
        }
        try publish(replaceExisting: replaceExisting, beforePublication: beforePublication)
    }

    public func abort() {
        guard !published, !aborted else { return }
        aborted = true
        mp3 = nil
        audioFile = nil
        try? FileManager.default.removeItem(at: temporary)
    }
}
