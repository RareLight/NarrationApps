import Foundation

public enum SpeechModel: String, Codable, CaseIterable, Sendable {
    case kokoro, soprano, qwen3, chatterbox, orpheus

    public var repository: String {
        switch self {
        case .kokoro: "mlx-community/Kokoro-82M-bf16"
        case .soprano: "mlx-community/Soprano-1.1-80M-bf16"
        case .qwen3: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
        case .chatterbox: "mlx-community/chatterbox-turbo-fp16"
        case .orpheus: "mlx-community/orpheus-3b-0.1-ft-bf16"
        }
    }

    public var label: String {
        switch self {
        case .kokoro: "Kokoro"
        case .soprano: "Soprano"
        case .qwen3: "Qwen3-TTS 1.7B"
        case .chatterbox: "Chatterbox Turbo"
        case .orpheus: "Orpheus 3B"
        }
    }
    public var usesNativeText: Bool { self != .kokoro }
    public var isLarge: Bool { self == .qwen3 || self == .chatterbox || self == .orpheus }
    /// Frozen benchmark-matched LM generation caps. Other engines retain their
    /// validated architecture/configuration limits.
    public var maximumGeneratedTokens: Int? { self == .qwen3 || self == .orpheus ? 4096 : nil }
    public var defaultVoice: String {
        switch self {
        case .kokoro: "af_heart"
        case .soprano: "soprano"
        case .qwen3: "Ryan"
        case .chatterbox: "default"
        case .orpheus: "leah"
        }
    }
    public var presetVoices: [String] {
        switch self {
        case .kokoro: [] // NativeSpeech supplies the pinned voice-file inventory.
        case .soprano: ["soprano"]
        case .qwen3: ["Ryan", "Aiden", "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ono_Anna", "Sohee"]
        case .chatterbox: ["default"]
        case .orpheus: ["tara", "leah", "jess", "leo", "dan", "mia", "zac", "zoe"]
        }
    }
    public var languages: [String] {
        self == .qwen3 ? ["English", "Chinese", "Japanese", "Korean", "German", "French", "Russian", "Portuguese", "Spanish", "Italian"] : ["English"]
    }

    /// Native-language metadata from Qwen's CustomVoice speaker catalog.
    /// This describes the speaker; narration language remains independently selected.
    public func nativeLanguage(for voice: String) -> String? {
        guard self == .qwen3 else { return nil }
        switch voice {
        case "Ryan", "Aiden": return "English"
        case "Vivian", "Serena", "Uncle_Fu": return "Chinese"
        case "Dylan": return "Chinese · Beijing"
        case "Eric": return "Chinese · Sichuan"
        case "Ono_Anna": return "Japanese"
        case "Sohee": return "Korean"
        default: return nil
        }
    }

    public var primaryRelativePath: String {
        "models/\(rawValue)/\(repository.replacingOccurrences(of: "/", with: "__"))"
    }

    public var capabilities: SpeechCapabilities {
        SpeechCapabilities(sampleRate: self == .soprano ? 32_000 : 24_000)
    }
}

public struct SpeechCapabilities: Sendable {
    public let sampleRate: Int
}

public struct SpeechSettings: Codable, Equatable, Sendable {
    public static let defaultKokoroVoice = "af_heart"
    public var model: SpeechModel
    public var voice: String
    public var speed: Float
    public var language: String?
    public var styleInstruction: String?
    public var savedChoices: [String: SpeechChoice]?

    public init(model: SpeechModel = .kokoro, voice: String = SpeechSettings.defaultKokoroVoice, speed: Float = 1.0, language: String? = nil, styleInstruction: String? = nil) {
        self.model = model
        self.voice = voice
        self.speed = speed
        self.language = language; self.styleInstruction = styleInstruction; self.savedChoices = nil
    }
}

public extension SpeechSettings {
    var effectiveLanguage: String { language ?? "English" }
    var languageCode: String {
        if model == .kokoro { return voice.hasPrefix("b") ? "en-GB" : "en-US" }
        return ["English": "en", "Chinese": "zh", "Japanese": "ja", "Korean": "ko", "German": "de", "French": "fr", "Russian": "ru", "Portuguese": "pt", "Spanish": "es", "Italian": "it"][effectiveLanguage] ?? "und"
    }
    var isValid: Bool {
        speed.isFinite && speed > 0 && (model == .kokoro || model == .soprano || speed == 1) &&
        (model == .kokoro || model == .soprano || model.presetVoices.contains(voice) || (model == .chatterbox && voice.hasPrefix("reference:") && voice.count == 74 && voice.dropFirst(10).allSatisfy { $0.isASCII && ($0.isNumber || "abcdef".contains($0)) })) && model.languages.contains(effectiveLanguage) &&
        (styleInstruction == nil || (model == .qwen3 && styleInstruction!.utf8.count <= 512))
    }
}

public struct SpeechChoice: Codable, Equatable, Sendable {
    public let voice: String
    public let speed: Float
    public let language: String?
    public let style: String?
}
public extension SpeechSettings {
    func switching(to model: SpeechModel) -> Self {
        var history = savedChoices ?? [:]
        history[self.model.rawValue] = .init(voice: voice, speed: speed, language: language, style: styleInstruction)
        let prior = history[model.rawValue]
        var result = Self(model: model, voice: prior?.voice ?? model.defaultVoice, speed: prior?.speed ?? 1,
                          language: prior?.language, styleInstruction: prior?.style)
        result.savedChoices = history
        return result
    }
}
