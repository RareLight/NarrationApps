import Foundation
import CryptoKit
import NarrationCore

public enum SpeechAcousticIdentity {
    public static func provenance(settings: SpeechSettings, policy: SpeechPreparationPolicy) -> [String: String] {
        if settings.model.isLarge {
            let spec = NativePrimaryCatalog.specification(for: settings.model)
            return ["modelRevision": spec.revision, "variant": settings.model.repository,
                "adapter": "mlx-audio-swift-8d86630/native-adapters-1",
                "generation": "native-product-defaults-20261027-2",
                "maximumGeneratedTokens": settings.model.maximumGeneratedTokens.map(String.init) ?? "model-config",
                "generatedTokenizer": NativePrimaryCatalog.generatedFiles(for: spec).map(\.sha256).joined(separator: "/"),
                "locale": settings.effectiveLanguage, "frontend": "native-text-1",
                "pcmPolicy": settings.model == .chatterbox ? "raw-vocoder-no-gain-or-fade-1" : "native-pcm-1",
                "resources": NativePrimaryCatalog.dependencies(for: settings.model).map(\.revision).joined(separator: "/"),
                "assembly": NarrationPausePolicy.candidateVersion]
        }
        let soprano = settings.model == .soprano
        var result = ["modelRevision": NativePrimaryCatalog.specification(for: settings.model).revision,
            "locale": soprano ? "en" : settings.voice.hasPrefix("b") ? "en-GB" : "en-US",
            "frontend": soprano ? "soprano-text-1" : policy.usesPreparedPhonemes ? "misaki-aligned-3/subtoken-ranges-1/numeric-dots-1/foundation-numbers-1/currency-tags-1/strict-vocab-1" : "misaki-legacy-2/numeric-dots-1/foundation-numbers-1/currency-tags-1",
            "resourceRevision": soprano ? NativePrimaryCatalog.specification(for: .soprano).revision : settings.voice.hasPrefix("b") ? BritishG2P.revision : NativeG2P.revision,
            "styleSelection": soprano ? "soprano-native-1" : policy.usesPreparedPhonemes ? "length-minus-one-1" : "legacy-count-1",
            "packing": policy == .longformPausesCandidate ? SpeechPreparationPolicy.longformCandidate.rawValue : policy.rawValue,
            "assembly": policy.usesStructuralPauses ? NarrationPausePolicy.candidateVersion : "legacy-unchanged-pcm-1"]
        result["textFlow"] = "text-flow-1"
        if !soprano { result["spokenForms"] = "spoken-forms-2-" + (settings.voice.hasPrefix("b") ? "en_GB" : "en_US") }
        return result
    }

    public static func make(settings: SpeechSettings, policy: SpeechPreparationPolicy) -> String {
        if settings.model.isLarge {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var acoustic = settings; acoustic.savedChoices = nil
            let value = try! encoder.encode(acoustic) + encoder.encode(provenance(settings: settings, policy: policy))
            return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
        }
        let model = NativePrimaryCatalog.specification(for: settings.model)
        let region = settings.voice.hasPrefix("b") ? "en-GB/" + BritishG2P.revision : "en-US/" + NativeG2P.revision
        let frontend = settings.model == .soprano ? "soprano-text-1" : policy.usesPreparedPhonemes ? "misaki-aligned-3/subtoken-ranges-1/numeric-dots-1/foundation-numbers-1/currency-tags-1/strict-vocab-1/style-length-minus-one-1/" + region : "misaki-legacy-2/numeric-dots-1/foundation-numbers-1/currency-tags-1/" + region
        // Pause-only changes do not invalidate raw acoustic material.
        let packing = policy == .longformPausesCandidate ? SpeechPreparationPolicy.longformCandidate.rawValue : policy.rawValue
        let value = ["acoustic-1", model.revision, settings.voice, String(settings.speed), frontend, packing].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
