import Foundation

public enum SpeechModel: String, Codable, CaseIterable, Sendable {
    case kokoro, soprano

    public var repository: String {
        switch self {
        case .kokoro: "mlx-community/Kokoro-82M-bf16"
        case .soprano: "mlx-community/Soprano-1.1-80M-bf16"
        }
    }

    public var primaryRelativePath: String {
        "models/\(rawValue)/\(repository.replacingOccurrences(of: "/", with: "__"))"
    }

    public var capabilities: SpeechCapabilities {
        SpeechCapabilities(sampleRate: self == .kokoro ? 24_000 : 32_000, supportsParallel: true)
    }
}

public struct SpeechCapabilities: Sendable {
    public let sampleRate: Int
    public let supportsParallel: Bool
}

public struct SpeechSettings: Codable, Equatable, Sendable {
    public static let defaultKokoroVoice = "af_heart"
    public var model: SpeechModel
    public var voice: String
    public var speed: Float

    public init(model: SpeechModel = .kokoro, voice: String = SpeechSettings.defaultKokoroVoice, speed: Float = 1.1) {
        self.model = model
        self.voice = voice
        self.speed = speed
    }
}

public enum SchedulingPolicy {
    public static let parallelThreshold = 3
    public static let workerCount = 2
    public static let batchSize = 12
}
