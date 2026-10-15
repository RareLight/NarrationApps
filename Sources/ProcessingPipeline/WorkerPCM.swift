import Foundation
import Darwin
import NarrationCore

enum WorkerPCM {
    static func read(_ event: WorkerEvent, index: Int, spool: URL, model: SpeechModel) throws -> [Float] {
        let expected = SpeechIPC.chunkFile(in: spool, index: index)
        let rate = model.capabilities.sampleRate
        guard event.kind == .chunk, event.chunk == index, event.channels == 1, event.sampleRate == rate,
              let frames = event.frames, frames > 0, frames <= rate * 120,
              event.pcmFile == expected.path else { throw SpeechFailure(.generation) }
        var info = stat()
        guard lstat(expected.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size == frames * MemoryLayout<Float>.size,
              try OutputPaths.resolved(expected) == expected else { throw SpeechFailure(.generation) }
        let data: Data
        do { data = try Data(contentsOf: expected) }
        catch { throw SpeechFailure(.storage) }
        var after = stat()
        guard lstat(expected.path, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              info.st_size == after.st_size, data.count == frames * MemoryLayout<Float>.size else {
            throw SpeechFailure(.generation)
        }
        let samples = data.withUnsafeBytes { bytes in
            (0..<frames).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw SpeechFailure(.generation) }
        return samples
    }
}
