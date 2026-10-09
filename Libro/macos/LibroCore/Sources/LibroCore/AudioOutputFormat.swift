import Foundation

public enum AudioOutputFormat: String, CaseIterable, Codable, Sendable {
    case wav, m4a, m4b, mp3

    public var label: String {
        switch self {
        case .wav: "WAV — uncompressed"
        case .m4a: "M4A — AAC-LC"
        case .m4b: "M4B — AAC-LC audiobook"
        case .mp3: "MP3"
        }
    }

    public func replacingExtension(_ path: String) -> String {
        (path as NSString).deletingPathExtension + "." + rawValue
    }
}

public struct OutputFormatPreference {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AudioOutputFormat {
        AudioOutputFormat(rawValue: defaults.string(forKey: "LibroOutputFormat") ?? "") ?? .wav
    }
    public func save(_ format: AudioOutputFormat) { defaults.set(format.rawValue, forKey: "LibroOutputFormat") }
}
