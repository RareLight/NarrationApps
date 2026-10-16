import Foundation

public struct NarrationOptions: Codable, Equatable, Sendable {
    public enum NotePlacement: String, Codable, CaseIterable, Sendable {
        case current, endOfDocument, omit
        public var label: String {
            switch self { case .current: "Current Placement"; case .endOfDocument: "End of Document"; case .omit: "Omit" }
        }
    }
    public var notes: NotePlacement
    public var includeAuxiliary: Bool
    public init(notes: NotePlacement = .current, includeAuxiliary: Bool = true) { self.notes = notes; self.includeAuxiliary = includeAuxiliary }
    public var versionSuffix: String { "/notes-" + notes.rawValue + (includeAuxiliary ? "/aux-included" : "/aux-excluded") }
    public static func acousticCompatibleVersion(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "/document-structure-1", with: "")
        for mode in NotePlacement.allCases { result = result.replacingOccurrences(of: "/notes-" + mode.rawValue, with: "") }
        return result.replacingOccurrences(of: "/aux-included", with: "").replacingOccurrences(of: "/aux-excluded", with: "")
    }
}

/// Whole-block decisions only when structural evidence or an explicit policy applies.
/// Original blocks remain untouched and every omitted span is previewable.
enum NarrationStructure {
    static func omissions(_ document: SemanticDocument, options: NarrationOptions) -> [Int: NarrationOmission] {
        var result: [Int: NarrationOmission] = [:]
        var previousHeading: Int?
        for (index, block) in document.blocks.enumerated() {
            var rule: String?, reason = ""
            if options.notes == .omit, block.kind == .footnote || block.footnoteID != nil {
                rule = "notes-omitted"; reason = "Note omitted by the narration setting."
            } else if !options.includeAuxiliary, block.role == .auxiliary {
                rule = "auxiliary-omitted"; reason = "Explicitly marked auxiliary section omitted by the narration setting."
            } else if block.kind == .heading, let priorIndex = previousHeading {
                let prior = document.blocks[priorIndex]
                let sameLocation = prior.resourcePath == block.resourcePath && prior.pdfPageIndex == block.pdfPageIndex
                let sameExplicitID = block.sourceID != nil && block.sourceID == prior.sourceID
                let adjacentAnonymous = priorIndex == index - 1 && block.sourceID == nil && prior.sourceID == nil
                if sameLocation, sameExplicitID || adjacentAnonymous,
                   prior.headingLevel == block.headingLevel,
                   NarrationText.normalizeWhitespace(prior.text) == NarrationText.normalizeWhitespace(block.text) {
                    rule = "duplicate-heading"; reason = "Adjacent duplicate structural heading omitted from narration."
                }
            }
            if block.kind == .heading { previousHeading = index } else { previousHeading = nil }
            if let rule { result[index] = .init(source: .init(blockIndex: index, location: 0, length: block.text.utf16.count), pageIndex: block.pdfPageIndex, rule: rule, reason: reason) }
        }
        return result
    }
}
