import Foundation
import Darwin

/// Strict streaming reader for the helper's IEEE float WAV. Other lossless
/// formats continue through FFmpeg. No gain changes or sample conversion.
struct FloatWave {
    let url: URL
    let offset: UInt64
    let length: UInt64
    let rate: Int
    let channels: Int
    let size: Int64
    var info: AudioInfo {
        AudioInfo(duration: Double(length) / Double(4 * channels * rate), byteLength: size,
                  sampleRate: rate, channels: channels, codec: "pcm_f32le")
    }
    static func inspect(_ url: URL) throws -> FloatWave? {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        func read(_ count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw RelayError.artifact("Lossless WAV is truncated.")
            }
            return data
        }
        guard size >= 12 else { return nil }
        let header = try read(12)
        guard String(decoding: header.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: header.suffix(4), as: UTF8.self) == "WAVE" else { return nil }
        guard UInt64(header.u32(4)) + 8 == size else { throw RelayError.artifact("Lossless WAV has an invalid size.") }
        var position: UInt64 = 12
        var format: Data?
        var payload: (UInt64, UInt64)?
        while position < size {
            try Task.checkCancellation()
            guard size - position >= 8 else { throw RelayError.artifact("Lossless WAV has an incomplete chunk header.") }
            try handle.seek(toOffset: position)
            let chunk = try read(8), length = UInt64(chunk.u32(4))
            let start = position + 8
            guard length <= size - start, length + (length & 1) <= size - start else {
                throw RelayError.artifact("Lossless WAV has a truncated chunk.")
            }
            switch String(decoding: chunk.prefix(4), as: UTF8.self) {
            case "fmt ":
                guard format == nil, (16...4096).contains(length) else { throw RelayError.artifact("Lossless WAV has an invalid format header.") }
                format = try read(Int(length))
            case "data":
                guard payload == nil else { throw RelayError.artifact("Lossless WAV contains duplicate audio data.") }
                payload = (start, length)
            default: break
            }
            position = start + length + (length & 1)
        }
        guard let format, let payload else { throw RelayError.artifact("Lossless WAV is missing its format or audio data.") }
        let tag = format.u16(0)
        let floatGUID: [UInt8] = [3,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113]
        let isFloat = tag == 3 || (tag == 0xfffe && format.count >= 40 && format.u16(16) >= 22
            && Array(format[24..<40]) == floatGUID && format.u16(18) == 32)
        guard isFloat, format.u16(14) == 32 else { return nil }
        let channels = Int(format.u16(2)), rate = Int(format.u32(4))
        guard (1...32).contains(channels), (1...384_000).contains(rate), format.u16(12) == channels * 4,
              Int(format.u32(8)) == channels * 4 * rate, payload.1 > 0, payload.1 % UInt64(channels * 4) == 0 else {
            throw RelayError.artifact("Lossless float WAV has invalid audio metadata.")
        }
        return FloatWave(url: url, offset: payload.0, length: payload.1, rate: rate, channels: channels, size: Int64(size))
    }
    func stream(to output: FileHandle? = nil) throws {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        try input.seek(toOffset: offset)
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, 65_536))
            guard let data = try input.read(upToCount: count), data.count == count else {
                throw RelayError.artifact("Lossless WAV audio data is truncated.")
            }
            let finite = data.withUnsafeBytes { bytes in
                for position in stride(from: 0, to: count, by: 4) {
                    let word = bytes.loadUnaligned(fromByteOffset: position, as: UInt32.self)
                    if !Float(bitPattern: UInt32(littleEndian: word)).isFinite { return false }
                }
                return true
            }
            guard finite else { throw RelayError.artifact("Lossless WAV contains non-finite samples.") }
            try output?.write(contentsOf: data)
            remaining -= UInt64(count)
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}

/// Scoped to one article. Byte-identical staged/final copies reuse a full AAC
/// inspection; altered bytes always require fresh probe/decode validation.
final class AudioInspectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var information: [String: AudioInfo] = [:]
    private var decoded: Set<String> = []
    func info(_ hash: String) -> AudioInfo? { lock.withLock { information[hash] } }
    func save(_ info: AudioInfo, hash: String) { lock.withLock { information[hash] = info } }
    func isDecoded(_ hash: String) -> Bool { lock.withLock { decoded.contains(hash) } }
    func markDecoded(_ hash: String) { _ = lock.withLock { decoded.insert(hash) } }
}
