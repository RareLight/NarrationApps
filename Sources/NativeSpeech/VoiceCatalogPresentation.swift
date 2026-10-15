import Foundation

/// Presentation names never change the voice ID sent to the native worker.
public enum VoiceCatalogPresentation {
    // Hexgrad Kokoro-82M VOICES.md, c3327e9bac3dbe55779397bfa82de0f8806fb3bc.
    // Overall grades estimate training data quality/quantity, not a listening benchmark.
    private static let grades = [
        "af_heart": "A", "af_bella": "A-", "bf_emma": "B-", "af_nicole": "B-",
        "af_aoede": "C+", "af_kore": "C+", "af_sarah": "C+", "am_fenrir": "C+",
        "am_michael": "C+", "am_puck": "C+",
        "af_alloy": "C", "af_nova": "C", "bf_isabella": "C", "bm_fable": "C", "bm_george": "C",
        "af_sky": "C-", "bm_lewis": "D+",
        "af_jessica": "D", "af_river": "D", "am_echo": "D", "am_eric": "D", "am_liam": "D",
        "am_onyx": "D", "bf_alice": "D", "bf_lily": "D", "bm_daniel": "D",
        "am_santa": "D-", "am_adam": "F+",
    ]
    private static let gradeOrder = ["A", "A-", "B-", "C+", "C", "C-", "D+", "D", "D-", "F+"]

    public static func overallGrade(_ identifier: String) -> String? { grades[identifier] }

    /// Libro recommends the four strongest upstream English grades (A through B-).
    public static func isRecommended(_ identifier: String) -> Bool {
        guard let grade = grades[identifier] else { return false }
        return ["A", "A-", "B-"].contains(grade)
    }

    /// Equal grades use alphabetical names; ungraded available voices remain last.
    public static func ranked(_ identifiers: [String]) -> [String] {
        identifiers.sorted { left, right in
            let leftRank = grades[left].flatMap { gradeOrder.firstIndex(of: $0) } ?? gradeOrder.count
            let rightRank = grades[right].flatMap { gradeOrder.firstIndex(of: $0) } ?? gradeOrder.count
            if leftRank != rightRank { return leftRank < rightRank }
            let leftName = name(left).lowercased(), rightName = name(right).lowercased()
            return leftName == rightName ? left < right : leftName < rightName
        }
    }

    public static func help(_ identifier: String) -> String {
        let grade = grades[identifier].map { " Upstream overall grade: \($0)." } ?? " Unrated voice."
        let recommendation = isRecommended(identifier) ? " Recommended." : ""
        return "Voice identifier: \(identifier)." + grade + recommendation +
            " Sorted by Kokoro's published training-data grades; listening preferences vary."
    }

    public static func displayName(_ identifier: String) -> String {
        let name = name(identifier)
        guard name != identifier else { return name }
        return name + (identifier.dropFirst().hasPrefix("f") ? " · Female" : " · Male")
    }

    public static func name(_ identifier: String) -> String {
        let parts = identifier.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, ["af", "am", "bf", "bm"].contains(String(parts[0])), !parts[1].isEmpty else {
            return identifier
        }
        return String(parts[1]).capitalized
    }
}
