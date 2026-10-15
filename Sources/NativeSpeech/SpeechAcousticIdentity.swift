import Foundation
import CryptoKit
import NarrationCore

public enum SpeechAcousticIdentity {
    public static func provenance(settings: SpeechSettings, policy: SpeechPreparationPolicy) -> [String: String] {
        let soprano = settings.model == .soprano
        return ["modelRevision": NativePrimaryCatalog.specification(for: settings.model).revision,
            "locale": soprano ? "en" : settings.voice.hasPrefix("b") ? "en-GB" : "en-US",
            "frontend": soprano ? "soprano-text-1" : policy.usesPreparedPhonemes ? "misaki-aligned-3/subtoken-ranges-1/numeric-dots-1/foundation-numbers-1/currency-tags-1/strict-vocab-1" : "misaki-legacy-2/numeric-dots-1/foundation-numbers-1/currency-tags-1",
            "resourceRevision": soprano ? NativePrimaryCatalog.specification(for: .soprano).revision : settings.voice.hasPrefix("b") ? BritishG2P.revision : NativeG2P.revision,
            "styleSelection": soprano ? "soprano-native-1" : policy.usesPreparedPhonemes ? "length-minus-one-1" : "legacy-count-1",
            "packing": policy == .longformPausesCandidate ? SpeechPreparationPolicy.longformCandidate.rawValue : policy.rawValue,
            "assembly": policy.usesStructuralPauses ? NarrationPausePolicy.candidateVersion : "legacy-unchanged-pcm-1"]
    }

    public static func make(settings: SpeechSettings, policy: SpeechPreparationPolicy) -> String {
        let model = NativePrimaryCatalog.specification(for: settings.model)
        let region = settings.voice.hasPrefix("b") ? "en-GB/" + BritishG2P.revision : "en-US/" + NativeG2P.revision
        let frontend = settings.model == .soprano ? "soprano-text-1" : policy.usesPreparedPhonemes ? "misaki-aligned-3/subtoken-ranges-1/numeric-dots-1/foundation-numbers-1/currency-tags-1/strict-vocab-1/style-length-minus-one-1/" + region : "misaki-legacy-2/numeric-dots-1/foundation-numbers-1/currency-tags-1/" + region
        // Pause-only changes do not invalidate raw acoustic material.
        let packing = policy == .longformPausesCandidate ? SpeechPreparationPolicy.longformCandidate.rawValue : policy.rawValue
        let value = ["acoustic-1", model.revision, settings.voice, String(settings.speed), frontend, packing].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
