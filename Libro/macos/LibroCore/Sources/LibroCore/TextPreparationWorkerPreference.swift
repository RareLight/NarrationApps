import Foundation
import NarrationCore

/// Operational CPU preference; changing it never changes the voice or audio identity.
public struct TextPreparationWorkerPreference {
    public static let key = "LibroTextPreparationWorkers"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> Int {
        let value = defaults.integer(forKey: Self.key)
        return (0...CPUTextPreparation.maximumWorkers).contains(value) ? value : 0
    }
    public func save(_ value: Int) {
        guard (0...CPUTextPreparation.maximumWorkers).contains(value) else { return }
        defaults.set(value, forKey: Self.key)
    }
}
