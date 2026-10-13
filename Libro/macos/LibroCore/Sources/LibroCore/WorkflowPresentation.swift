import Foundation

/// Presentation names never change the voice ID sent to the native worker.
public enum VoicePresentation {
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

    public static func name(_ identifier: String) -> String {
        let parts = identifier.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, ["af", "am", "bf", "bm"].contains(String(parts[0])), !parts[1].isEmpty else {
            return identifier
        }
        return String(parts[1]).capitalized
    }
}

public struct SerialGenerationPreference {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> Bool { defaults.object(forKey: "LibroSerialGeneration") as? Bool ?? false }
    public func save(_ serial: Bool) { defaults.set(serial, forKey: "LibroSerialGeneration") }
}

/// The focused queue surface supports arrows and anchored Shift-arrow ranges.
/// Text fields handle their own editing keys before focus returns to this surface.
public struct QueueKeyboardSelection {
    private var cursor: UUID?
    private var anchor: UUID?
    private var lastSelection = Set<UUID>()
    public init() {}

    public mutating func move(rows: [UUID], selection: Set<UUID>, forward: Bool, extending: Bool) -> Set<UUID> {
        guard !rows.isEmpty else { cursor = nil; anchor = nil; lastSelection = []; return [] }
        if selection != lastSelection || cursor.map({ !rows.contains($0) }) == true {
            cursor = rows.first { selection.contains($0) }; anchor = cursor
        }
        let current = cursor.flatMap { rows.firstIndex(of: $0) } ?? (forward ? -1 : rows.count)
        let target = max(0, min(rows.count - 1, current + (forward ? 1 : -1)))
        if !extending || anchor == nil || !rows.contains(anchor!) { anchor = rows[target] }
        cursor = rows[target]
        let start = rows.firstIndex(of: anchor!) ?? target
        lastSelection = extending ? Set(rows[min(start, target)...max(start, target)]) : [rows[target]]
        return lastSelection
    }
}

/// One reason drives both the disabled Start action and its recovery guidance.
public enum GenerationBlocker: Equatable, Sendable {
    case activeBatch, preparation, intake, planning, workspace, output, checkingModel, model, documents, destinations

    public var message: String {
        switch self {
        case .activeBatch: "Processing the current batch. Changes apply to the next batch."
        case .preparation: "Wait for model preparation to finish, or cancel it."
        case .intake: "Wait for the current input or diagnostic operation to finish."
        case .planning: "Checking output destinations…"
        case .workspace: "Choose or recover the Libro workspace in Settings."
        case .output: "Choose or recover the output folder with Browse."
        case .checkingModel: "Checking local model assets…"
        case .model: "Prepare the selected model before generating audio."
        case .documents: "Add documents, or queue unfinished documents again."
        case .destinations: "Resolve the output destination error before generating audio."
        }
    }

    public static func evaluate(isGenerating: Bool, isPreparing: Bool, busy: Bool, planning: Bool,
                                workspaceAvailable: Bool, outputAvailable: Bool, checkingAssets: Bool,
                                assetsReady: Bool, queuedCount: Int, plannedCount: Int,
                                hasPlanningError: Bool) -> Self? {
        if isGenerating { return .activeBatch }
        if isPreparing { return .preparation }
        if busy { return .intake }
        if !workspaceAvailable { return .workspace }
        if !outputAvailable { return .output }
        if checkingAssets { return .checkingModel }
        if !assetsReady { return .model }
        if queuedCount == 0 { return .documents }
        if planning { return .planning }
        if hasPlanningError || plannedCount != queuedCount { return .destinations }
        return nil
    }
}
