import Foundation
import AVFoundation
import Darwin

public enum AudioOutputError: Error, LocalizedError {
    case invalidPCM, inconsistentFormat, riffLimit, storage, empty

    public var errorDescription: String? {
        switch self {
        case .invalidPCM: "Audio must contain finite samples and a positive sample rate."
        case .inconsistentFormat: "Audio sample rate changed between chunks."
        case .riffLimit: "Audio exceeds the WAV size limit. Split the document."
        case .storage: "Could not write or publish audio in the selected destination."
        case .empty: "The speech engine returned no audio."
        }
    }
}

/// Synchronous, single-owner writer. Call from the coordinator's executor.
/// WAV PCM16 matches the CLI: clip, multiply by 32767, truncate toward zero.
public final class AtomicWavWriter {
    public let destination: URL
    public let temporary: URL
    public private(set) var frames: UInt64 = 0
    private var sampleRate: Int?
    private var audioFile: AVAudioFile?
    private var published = false
    private var aborted = false
    private let previousMode: mode_t?

    public init(destination: URL) throws {
        self.destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let parent = self.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        temporary = parent.appendingPathComponent(".libro-audio-\(UUID().uuidString).wav")
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
        guard (frames + UInt64(samples.count)) * 2 <= UInt64(UInt32.max) - 65_536 else { throw AudioOutputError.riffLimit }
        if let expected = self.sampleRate, expected != sampleRate { throw AudioOutputError.inconsistentFormat }
        guard !published, !aborted else { throw AudioOutputError.storage }
        do {
            if audioFile == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                audioFile = try AVAudioFile(forWriting: temporary, settings: settings,
                                           commonFormat: .pcmFormatInt16, interleaved: true)
                self.sampleRate = sampleRate
            }
            guard let file = audioFile,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.int16ChannelData?[0] else { throw AudioOutputError.storage }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() { channel[index] = Int16(min(max(sample, -1), 1) * 32767) }
            try file.write(from: buffer)
            frames += UInt64(samples.count)
        } catch let error as AudioOutputError { throw error }
        catch { throw AudioOutputError.storage }
    }

    /// The caller revalidates destinations and cancellation at this boundary.
    public func publish(beforePublication: () throws -> Void = {}) throws {
        guard frames > 0, !published, !aborted else { throw AudioOutputError.empty }
        audioFile = nil // Close AVAudioFile and finalize its header before fsync.
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            if let mode = previousMode, fchmod(handle.fileDescriptor, mode) != 0 { throw AudioOutputError.storage }
            try handle.synchronize()
            try beforePublication()
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw AudioOutputError.storage }
            guard info.st_size >= 44, UInt64(info.st_size) - 8 <= UInt64(UInt32.max) else { throw AudioOutputError.riffLimit }
            guard rename(temporary.path, destination.path) == 0 else { throw AudioOutputError.storage }
            published = true
        } catch let error as AudioOutputError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AudioOutputError.storage }
    }

    public func abort() {
        guard !published, !aborted else { return }
        aborted = true
        audioFile = nil
        try? FileManager.default.removeItem(at: temporary)
    }
}
