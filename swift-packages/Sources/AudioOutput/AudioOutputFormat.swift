import Foundation

public enum AudioOutputFormat: String, CaseIterable, Codable, Sendable {
    case wav, m4a, m4b, mp3

    public var supportsCoverArtwork: Bool { self != .wav }

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
