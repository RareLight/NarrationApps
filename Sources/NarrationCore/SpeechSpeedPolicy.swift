import Foundation

/// Kokoro's common user-facing range. Presentation does not round stored settings.
/// New Kokoro settings use 1.0×; stored speeds remain unchanged.
/// Soprano has no adjustable speed.
public enum SpeechSpeedPolicy {
    public static let range: ClosedRange<Double> = 0.5...2
    public static let step: Double = 0.05
    public static func contains(_ speed: Double) -> Bool { speed.isFinite && range.contains(speed) }
}
