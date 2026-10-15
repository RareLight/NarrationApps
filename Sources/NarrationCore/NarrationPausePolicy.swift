import Foundation

/// Operator-accepted structural timings. Exact edge zeros count toward these targets; model
/// near-silence remains untouched and may make the perceived pause longer.
public enum NarrationPausePolicy {
    public static let candidateVersion = "structural-exact-zero-candidate-1"
    public static func seconds(after boundary: SpeechBoundary, explicitGap: Double? = nil) -> Double {
        if explicitGap == 0 { return 0 }
        let desired: Double = switch boundary {
        case .continuation: 0
        case .sentence: 0.12
        case .paragraph: 0.28
        case .heading: 0.45
        case .footnote: 0.20
        }
        return max(desired, explicitGap ?? 0)
    }
}
