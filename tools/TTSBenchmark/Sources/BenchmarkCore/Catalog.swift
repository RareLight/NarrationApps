import Foundation

public enum Catalog {
    public static let codePin = "8d86630ade569728aaea3dc1a29fc44e2efa719b"
    public static let g2pRepo = "beshkenadze/kitten-tts-g2p"
    public static let g2pRevision = "9c692b92682d959d9013a9cfe6a49541997add18"
    public static func matrix() -> Matrix {
        let kokoro = "mlx-community/Kokoro-82M-bf16", soprano = "mlx-community/Soprano-1.1-80M-bf16"
        var profiles = [Profile]()
        for (voice, label) in [("af_heart", "Heart"), ("am_michael", "Michael"), ("bf_emma", "Emma")] {
            profiles.append(Profile(id: "kokoro-" + label.lowercased(), label: "Kokoro / " + label, family: "kokoro", repository: kokoro,
                revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c", voice: voice, language: voice.hasPrefix("b") ? "en-gb" : "en-us", license: "Apache-2.0", maxCharacters: 180, dependencies: [g2pRepo]))
        }
        profiles.append(Profile(id: "soprano", label: "Soprano 1.1", family: "soprano", repository: soprano,
            revision: "745350c27f356c3910eebcb49e29760dcf6a643c", voice: "soprano", license: "Apache-2.0"))
        for (size, voice, precision) in [("0.6B", "Ryan", "bf16"), ("1.7B", "Ryan", "8bit"), ("1.7B", "Aiden", "8bit")] {
            profiles.append(Profile(id: "qwen-\(size.replacingOccurrences(of: ".", with: ""))-\(voice.lowercased())", label: "Qwen3-TTS \(size) / \(voice)", family: "qwen3_tts",
                repository: "mlx-community/Qwen3-TTS-12Hz-\(size)-CustomVoice-\(precision)", voice: voice, language: "English", precision: precision, license: "Apache-2.0"))
        }
        profiles.append(Profile(id: "chatterbox-turbo", label: "Chatterbox Turbo / default", family: "chatterbox_turbo", repository: "mlx-community/chatterbox-turbo-fp16", precision: "fp16", license: "MIT upstream; conversion card Apache-2.0", dependencies: ["mlx-community/S3TokenizerV2"]))
        for voice in ["alba", "marius"] {
            profiles.append(Profile(id: "pocket-" + voice, label: "Pocket TTS / " + voice, family: "pocket_tts", repository: "mlx-community/pocket-tts", voice: voice, precision: "checkpoint default", license: "CC-BY-4.0 weights; voice-specific terms"))
        }
        for voice in ["tara", "leah"] {
            profiles.append(Profile(id: "orpheus-" + voice, label: "Orpheus 3B / " + voice, family: "orpheus", repository: "mlx-community/orpheus-3b-0.1-ft-bf16", voice: voice, license: "Apache-2.0 upstream; verify conversion", dependencies: ["mlx-community/snac_24khz"]))
        }
        profiles.append(Profile(id: "fish-s2-pro", label: "Fish Audio S2 Pro / reference", family: "fish_qwen3_omni", repository: "mlx-community/fish-audio-s2-pro-8bit", precision: "8bit", license: "Fish Audio Research License; separate commercial grant", maxCharacters: 4000,
            blockedReason: "A licensed reference WAV and accurate transcript must be configured explicitly; no substitute narrator is selected."))
        return Matrix(profiles: profiles, passages: passages)
    }
    // Original synthetic text, repository license. Calibration and held-out material
    // are intentionally distinct and never drawn from the operator's documents.
    public static let passages: [Passage] = [
        Passage(id: "calibration-short", role: "calibration", text: "I thought the station would be empty. Instead, a woman in a blue coat was waiting beside the clock. ‘You're early,’ she said. Was that a welcome, or a warning?"),
        Passage(id: "calibration-prose", role: "calibration", text: "The river did not change direction overnight. Over many winters, small floods carried soil away from the eastern bank and laid it down on the west. A bend grew wider; the water found a shorter route.\n\nFor the people who lived nearby, the change was anything but gradual. One morning their familiar footpath ended at open water. The old bridge, which had seemed permanent, now crossed a patch of reeds. They needed a new map, but first they needed to agree on what had happened. The engineer called it erosion. Her neighbour called it the day the river moved."),
        Passage(id: "heldout-facts", role: "heldout", text: "On March 12, 2026, Dr. Elena Morris returned to the field station. The sample weighed 2.5 kilograms, and the thermometer read minus seven degrees Celsius. ‘Check the label on Package A,’ she said, ‘not the number on the lid.’ At nine fifteen that evening, the second instrument gave the same result. The reading was unexpected; it was not, by itself, evidence that the earlier measurements were wrong."),
        Passage(id: "heldout-story", role: "heldout", text: "Nobody remembered who had planted the pear tree. It stood in the narrow space between the school and the post office, leaning slightly toward the morning sun. In spring its flowers covered the pavement. By autumn, children were measuring the lowest branch against the height of their shoulders.\n\nWhen the council proposed widening the road, Mina brought a photograph to the meeting. It showed her grandfather beneath the same tree, holding a bicycle that was much too large for him. She did not ask the council to keep everything unchanged. She asked them to notice what they were about to remove. For a moment, even the people at the back of the room stopped talking."),
    ]
}
