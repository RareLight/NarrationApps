import Foundation

import NativeSpeech

public typealias VoicePresentation = NativeSpeech.VoiceCatalogPresentation

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
        case .preparation: "Wait for speech setup to finish, or cancel it."
        case .intake: "Wait for the current input or diagnostic operation to finish."
        case .planning: "Checking output destinations…"
        case .workspace: "Choose or recover the Libro workspace in Settings."
        case .output: "Choose or recover the output folder with Browse."
        case .checkingModel: "Checking local model assets…"
        case .model: "Install the selected speech model or check speech setup before generating audio."
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
