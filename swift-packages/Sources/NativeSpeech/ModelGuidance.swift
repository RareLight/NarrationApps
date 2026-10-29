import Foundation
import NarrationCore

/// Static editorial selection guidance, not a local benchmark or acoustic input.
public struct ModelGuidance: Sendable {
    public static let version = "editorial-guide-20261029-1"
    /// A general starting recommendation; saved model choices retain precedence.
    public static let recommendedModel: SpeechModel = .kokoro
    public static func selectionLabel(for model: SpeechModel) -> String {
        model == recommendedModel ? "\(model.label) (Recommended)" : model.label
    }
    public let speed: Int
    public let quality: Int?
    public let summary: String
    public static let explanation = "Relative estimates for model selection, not measured on this Mac. Speed varies with your Mac, text, language and settings. Quality is an initial editorial estimate of typical English narration naturalness and prosody, informed by representative listening; individual voices vary. It is not an accuracy score. Play a sample to compare."
    /// Fixed logarithmic bands; adding another model cannot rescale the guide.
    public static func speedTier(referenceRTF: Double) -> Int? {
        guard referenceRTF.isFinite, referenceRTF > 0 else { return nil }
        switch 1 / referenceRTF { case 20...: return 5; case 7...: return 4; case 3...: return 3; case 1...: return 2; default: return 1 }
    }
    public static func guide(for model: SpeechModel, language: String = "English") -> Self {
        let value: Self
        switch model {
        case .kokoro: value = .init(speed: 5, quality: 4, summary: "Recommended for its balance of narration quality, speed and low memory use. A broad choice of English voices.")
        case .soprano: value = .init(speed: 4, quality: nil, summary: "Fast, compact narration with one voice.")
        case .qwen3: value = .init(speed: 2, quality: 5, summary: "Expressive multilingual narration; more generation time and memory.")
        case .chatterbox: value = .init(speed: 3, quality: 4, summary: "Natural English narration with moderate generation speed.")
        case .orpheus: value = .init(speed: 1, quality: 4, summary: "Expressive English voices; slow generation and high memory demand.")
        }
        return language == "English" ? value : .init(speed: value.speed, quality: nil, summary: value.summary)
    }
    public static func speedLabel(_ tier: Int) -> String { ["Very slow", "Slow", "Moderate", "Fast", "Very fast"][max(1, min(tier, 5)) - 1] }
    public static func qualityLabel(_ tier: Int?) -> String { tier.map { ["Basic", "Fair", "Good", "High", "Very high"][max(1, min($0, 5)) - 1] } ?? "Not rated" }
}

public extension NativePrimaryCatalog {
    static func validates(_ settings: SpeechSettings) -> Bool {
        settings.isValid && (settings.model == .chatterbox && ReferenceVoiceStore.isIdentifier(settings.voice) || (settings.model == .soprano ? settings.voice == "soprano" || specification(for: .kokoro).voices.contains(settings.voice) : specification(for: settings.model).voices.contains(settings.voice)))
    }
}
