import Foundation
import AudioOutput

public struct OutputFormatPreference {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AudioOutputFormat {
        AudioOutputFormat(rawValue: defaults.string(forKey: "LibroOutputFormat") ?? "") ?? .wav
    }
    public func save(_ format: AudioOutputFormat) { defaults.set(format.rawValue, forKey: "LibroOutputFormat") }
}
