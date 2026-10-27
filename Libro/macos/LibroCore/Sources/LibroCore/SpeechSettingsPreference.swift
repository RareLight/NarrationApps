import Foundation
import NarrationCore
import NativeSpeech

/// App-owned preferences, independent of installed model inventories. A missing
/// or unsupported record uses defaults without destroying the saved record.
public struct SpeechSettingsPreference {
    public static let key = "LibroSpeechSettings"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> SpeechSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(SpeechSettings.self, from: data), Self.isValid(settings) else { return .init() }
        return settings
    }

    public func save(_ settings: SpeechSettings) {
        guard Self.isValid(settings), let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func isValid(_ settings: SpeechSettings) -> Bool {
        // Voice/speed remain the user's Kokoro choices while Soprano is selected.
        NativePrimaryCatalog.specification(for: .kokoro).voices.contains(settings.voice) &&
            SpeechSpeedPolicy.contains(Double(settings.speed))
    }
}
