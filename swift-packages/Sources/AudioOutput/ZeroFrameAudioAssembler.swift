import Foundation

/// A single-owner streaming assembly boundary. Speech frames are passed to the
/// writer without alteration. Only exactly zero frames count as existing edge
/// silence; quiet speech is never classified, trimmed or changed.
public final class ZeroFrameAudioAssembler {
    private let writer: AtomicAudioWriter
    private let sampleRate: Int
    private var trailingZeros = 0
    private var hasSpeech = false
    public private(set) var insertedFrames: UInt64 = 0

    public init(writer: AtomicAudioWriter, sampleRate: Int) throws {
        guard (1...192_000).contains(sampleRate) else { throw AudioOutputError.invalidPCM }
        self.writer = writer; self.sampleRate = sampleRate
    }

    public func append(samples: [Float], gapBeforeSeconds: Double = 0,
                       cancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
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
                try writer.append(samples: [Float](repeating: 0, count: count), sampleRate: sampleRate)
                insertedFrames += UInt64(count); inserted += count; remaining -= count
            }
        }
        try cancellation()
        try writer.append(samples: samples, sampleRate: sampleRate)
        let zeros = samples.reversed().prefix(while: { $0 == 0 }).count
        // Consecutive all-zero buffers form one unchanged edge span.
        trailingZeros = zeros == samples.count ? min(Int.max - zeros - inserted, trailingZeros) + inserted + zeros : zeros
        hasSpeech = true
    }
}
