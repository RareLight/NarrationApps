import Foundation

public struct NarrationOptions: Codable, Equatable, Sendable {
    public enum NotePlacement: String, Codable, CaseIterable, Sendable {
        case current, endOfDocument, omit
        public var label: String {
            switch self { case .current: "Read with the text"; case .endOfDocument: "Read at the end"; case .omit: "Do not read" }
        }
    }
    public var notes: NotePlacement
    public var includeAuxiliary: Bool
    public var experimentalPDFWordJoining: Bool
    public var stripInlineCitations: Bool
    public var stripEndnoteCitations: Bool
    public init(notes: NotePlacement = .current, includeAuxiliary: Bool = true, experimentalPDFWordJoining: Bool = false,
                stripInlineCitations: Bool = false, stripEndnoteCitations: Bool = false) {
        self.notes = notes; self.includeAuxiliary = includeAuxiliary
        self.experimentalPDFWordJoining = experimentalPDFWordJoining
        self.stripInlineCitations = stripInlineCitations; self.stripEndnoteCitations = stripEndnoteCitations
    }
    private enum CodingKeys: String, CodingKey { case notes, includeAuxiliary, experimentalPDFWordJoining, stripInlineCitations, stripEndnoteCitations }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        notes = try values.decodeIfPresent(NotePlacement.self, forKey: .notes) ?? .current
        includeAuxiliary = try values.decodeIfPresent(Bool.self, forKey: .includeAuxiliary) ?? true
        experimentalPDFWordJoining = try values.decodeIfPresent(Bool.self, forKey: .experimentalPDFWordJoining) ?? false
        stripInlineCitations = try values.decodeIfPresent(Bool.self, forKey: .stripInlineCitations) ?? false
        stripEndnoteCitations = try values.decodeIfPresent(Bool.self, forKey: .stripEndnoteCitations) ?? false
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(notes, forKey: .notes)
        try values.encode(includeAuxiliary, forKey: .includeAuxiliary)
        if experimentalPDFWordJoining { try values.encode(true, forKey: .experimentalPDFWordJoining) }
        if stripInlineCitations { try values.encode(true, forKey: .stripInlineCitations) }
        if stripEndnoteCitations { try values.encode(true, forKey: .stripEndnoteCitations) }
    }
    public var versionSuffix: String {
        "/notes-" + notes.rawValue + (includeAuxiliary ? "/aux-included" : "/aux-excluded") +
            (experimentalPDFWordJoining ? "/pdf-word-joins-readium-1" : "") +
            (stripInlineCitations ? "/inline-citations-1" : "") + (stripEndnoteCitations ? "/endnote-citations-1" : "")
    }
    public static func acousticCompatibleVersion(_ value: String) -> String {
        // Policy 2 changes selected text/cues, not the voice frontend. Retain
        // policy 1's existing backend identity for identical completed requests.
        var result = value.replacingOccurrences(of: "/document-structure-1", with: "")
            .replacingOccurrences(of: "/scientific-text-2", with: "/scientific-text-1")
        for mode in NotePlacement.allCases { result = result.replacingOccurrences(of: "/notes-" + mode.rawValue, with: "") }
        return result.replacingOccurrences(of: "/aux-included", with: "").replacingOccurrences(of: "/aux-excluded", with: "")
            .replacingOccurrences(of: "/pdf-word-joins-readium-1", with: "")
            .replacingOccurrences(of: "/inline-citations-1", with: "").replacingOccurrences(of: "/endnote-citations-1", with: "")
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
