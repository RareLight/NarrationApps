import Foundation

/// A single-owner streaming assembly boundary. Speech frames are passed to the
/// writer without alteration. Only exactly zero frames count as existing edge
/// silence; quiet speech is never classified, trimmed or changed.
public final class ZeroFrameAudioAssembler {
    private let write: ([Float]) throws -> Void
    private let sampleRate: Int
    private var trailingZeros = 0
    private var hasSpeech = false
    public private(set) var insertedFrames: UInt64 = 0

    public convenience init(writer: AtomicAudioWriter, sampleRate: Int) throws {
        try self.init(sampleRate: sampleRate) { try writer.append(samples: $0, sampleRate: sampleRate) }
    }
    public init(sampleRate: Int, write: @escaping ([Float]) throws -> Void) throws {
        guard (1...192_000).contains(sampleRate) else { throw AudioOutputError.invalidPCM }
        self.write = write; self.sampleRate = sampleRate
    }

    public func append(samples: [Float], gapBeforeSeconds: Double = 0,
                       cancellation: () throws -> Void = { try AudioWorkCheckpoint.check() }) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), gapBeforeSeconds.isFinite,
              (0...60).contains(gapBeforeSeconds) else { throw AudioOutputError.invalidPCM }
        try cancellation()
        var inserted = 0
        if hasSpeech {
            let leading = samples.prefix(while: { $0 == 0 }).count
            let requested = Int((gapBeforeSeconds * Double(sampleRate)).rounded())
            var remaining = max(0, requested - min(requested, trailingZeros) - min(requested, leading))
            while remaining > 0 {
                try cancellation()
                let count = min(remaining, 4_096)
                try write([Float](repeating: 0, count: count))
                insertedFrames += UInt64(count); inserted += count; remaining -= count
            }
        }
        try cancellation()
        try write(samples)
        let zeros = samples.reversed().prefix(while: { $0 == 0 }).count
        // Consecutive all-zero buffers form one unchanged edge span.
        trailingZeros = zeros == samples.count ? min(Int.max - zeros - inserted, trailingZeros) + inserted + zeros : zeros
        hasSpeech = true
    }
}
