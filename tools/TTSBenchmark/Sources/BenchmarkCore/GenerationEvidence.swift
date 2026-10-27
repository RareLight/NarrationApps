import Foundation

public enum GenerationEvidence {
    /// The pinned SDK's shared info field is not uniform: Chatterbox puts PCM
    /// frame count there, while Qwen/Soprano/Orpheus report generated tokens.
    /// Unknown families abstain; an audio-sample count is never a token ceiling.
    public static func tokenCount(family: String, info: Int?, events: Int) -> Int? {
        if events > 0 { return events }
        guard ["qwen3_tts", "soprano", "orpheus", "llama_tts", "fish_qwen3_omni"].contains(family),
              let info, info >= 0 else { return nil }
        return info
    }
    public static func verifyCeiling(family: String, count: Int?, maximum: Int) throws {
        // Fish's info aggregates multiple internally capped segments; its total
        // cannot be compared to the per-segment generation ceiling.
        if family != "fish_qwen3_omni", let count, count >= maximum {
            throw BenchError("Output token ceiling reached; completion unverified")
        }
    }
}
