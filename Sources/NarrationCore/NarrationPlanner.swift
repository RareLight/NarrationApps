import Foundation
import Pronunciation

public enum NarrationError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    public var errorDescription: String? { switch self { case .invalidInput(let message): message } }
}

public struct NarrationProfile: Sendable {
    public let opening: String?
    public let closing: String?
    public init(opening: String? = nil, closing: String? = nil) { self.opening = opening; self.closing = closing }
    public static let document = NarrationProfile()
    public static func article(title: String, source: String) -> NarrationProfile {
        let title = NarrationText.normalizeWhitespace(title)
        let spokenTitle = title.isEmpty ? "Untitled article" : title
        let punctuation = spokenTitle.last.map { ".!?".contains($0) } == true ? "" : "."
        return .init(opening: "\(spokenTitle)\(punctuation) Source: \(source).", closing: "End of article.")
    }
}

public enum NarrationPlanPurpose: Sendable { case preview, speechPreparation }

public enum NarrationPlanner {
    private static let previousVersion = "conservative-2/footnotes-1/sentence-chunks-1/decorative-quotes-1/article-boundaries-1"
    private static let separatorVersion = previousVersion + "/decorative-separators-1"
    private static let omissionVersion = separatorVersion + "/omission-runs-1"
    public static let version = "native-narration-1/unicode-chunks-1/image-captions-1"
    public static func version(pronunciations: PronunciationDictionary) -> String {
        pronunciations.fingerprint.isEmpty ? version : version + "/pronunciation-" + pronunciations.fingerprint
    }
    // These upgrades omit separators and duplicate placeholders. Identical text, index,
    // provenance and engine still produce identical audio, so keep those checkpoints.
    public static func chunkFingerprintVersion(_ version: String) -> String {
        [Self.version, Self.version.replacingOccurrences(of: "/image-captions-1", with: ""), omissionVersion, separatorVersion].contains(version) ? previousVersion : version
    }
    private static func isDecorativeQuotation(_ text: String) -> Bool {
        let marks = CharacterSet(charactersIn: "\"'\u{2018}\u{2019}\u{201C}\u{201D}\u{00AB}\u{00BB}\u{2039}\u{203A}\u{275D}\u{275E}")
            .union(.whitespacesAndNewlines)
        return !text.isEmpty && text.unicodeScalars.allSatisfy { marks.contains($0) }
    }
    private static func isDecorativeSeparator(_ text: String) -> Bool {
        let marks = CharacterSet(charactersIn: "-–—―•·‧⋅●◦▪▫|¦*⁂…._=~")
            .union(.whitespacesAndNewlines)
        return !text.isEmpty && text.unicodeScalars.allSatisfy { marks.contains($0) }
    }
    public static func prepare(_ article: SemanticDocument, limit: Int = 480, settings: SpeechSettings = .init(), profile: NarrationProfile = .document, pronunciations: PronunciationDictionary = .empty, purpose: NarrationPlanPurpose = .preview) throws -> NarrationPlan {
        guard limit > 0 else { throw NarrationError.invalidInput("Narration chunk limit must be positive.") }
        var chunks: [NarrationChunk] = []; var notices: [String] = []; var usedPronunciations = false; var mappedRules = 0
        var noteIndices: [String: [Int]] = [:]
        for (index, block) in article.blocks.enumerated() {
            if let id = block.footnoteID { noteIndices[id, default: []].append(index) }
        }
        let duplicateCaptions = CaptionDeduplication.suppressedIndices(in: article.blocks)
        var emitted: Set<String> = []
        var imageCredits: Set<String> = []
        var lastOmission: ContentBlock.Kind?
        func emit(_ text: String, indices: [Int], boundary: SpeechBoundary = .paragraph) throws {
            if !text.isEmpty { lastOmission = nil }
            let application = purpose == .speechPreparation ? try pronunciations.applyingWithMappings(to: text) : .init(text: try pronunciations.applying(to: text), applications: [])
            mappedRules += application.applications.count
            guard mappedRules <= 100_000 else { throw PronunciationError.tooManyApplications }
            let spoken = application.text
            usedPronunciations = usedPronunciations || spoken != text
            let parts = purpose == .speechPreparation ? [spoken] : try NarrationText.chunks(spoken, settings: settings, maximumScalars: min(limit, 480))
            for part in parts {
                let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { chunks.append(.init(index: chunks.count, text: value, blockIndices: indices,
                    boundaryAfter: purpose == .speechPreparation ? boundary : nil,
                    origin: purpose == .speechPreparation ? indices.first.map { article.blocks[$0].origin ?? .authored } : nil,
                    pronunciationApplications: purpose == .speechPreparation ? application.applications : nil)) }
            }
        }
        func content(_ index: Int) throws {
            let block = article.blocks[index]
            if duplicateCaptions.contains(index) { notices.append("Duplicate image caption omitted from narration."); return }
            var text = NarrationText.normalizeWhitespace(block.narrationText ?? block.text)
            if block.kind == .caption,
               let credit = text.range(of: #"(?i)(?:\b(?:image|photo(?:graph)?|picture|illustration)\s+credits?|\bcredits?|\bcourtesy of|\bcopyright|©)\s*:?.*$"#, options: .regularExpression) {
                let key = NarrationText.normalizeWhitespace(String(text[credit])).lowercased()
                    .replacingOccurrences(of: #"^(?:(?:image|photo(?:graph)?|picture|illustration)\s+)?credits?\s*:?\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                if !imageCredits.insert(key).inserted {
                    text = String(text[..<credit.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text == "Image description:" { text = "" }
                    notices.append("Repeated image credit omitted from narration.")
                }
            }
            if block.kind == .code || block.kind == .table {
                notices.append("Block \(index): \(block.kind.rawValue) retained in semantic artifact and omitted from narration.")
                text = block.kind == .code ? "Code block omitted from narration." : "Table omitted from narration."
            }
            if block.kind == .unsupported {
                notices.append("Block \(index): unsupported structure read as plain text; inspect before listening acceptance.")
            }
            if isDecorativeQuotation(text) {
                notices.append("Block \(index): decorative quotation retained in semantic artifact and omitted from narration.")
            } else if isDecorativeSeparator(text) {
                notices.append("Block \(index): decorative separator retained in semantic artifact and omitted from narration.")
            } else if (block.kind == .table || block.kind == .code), lastOmission == block.kind {
                notices.append("Block \(index): repeated omission announcement suppressed.")
            } else {
                try emit(text, indices: [index], boundary: block.kind == .heading ? .heading : block.kind == .footnote ? .footnote : .paragraph)
                if block.kind == .table || block.kind == .code { lastOmission = block.kind }
            }
            for id in block.footnoteReferences ?? [] { try footnote(id, referredBy: index) }
        }
        func footnote(_ id: String, referredBy index: Int?) throws {
            guard emitted.insert(id).inserted else { return }
            guard let notes = noteIndices[id], notes.contains(where: { !NarrationText.normalizeWhitespace(article.blocks[$0].narrationText ?? article.blocks[$0].text).isEmpty }) else {
                notices.append("A marked footnote/citation could not be resolved; its marker is omitted from speech.")
                return
            }
            let provenance = (index.map { [$0] } ?? []) + notes
            if index == nil { notices.append("Unreferenced footnote retained at the end of narration.") }
            try emit("Footnote:", indices: provenance, boundary: .continuation)
            for note in notes { try content(note) }
            try emit("End Footnote", indices: provenance, boundary: .footnote)
        }
        if let opening = profile.opening { try emit(opening, indices: []) }
        let headerChunks = chunks.count
        for (index, block) in article.blocks.enumerated() where block.footnoteID == nil {
            if block.kind == .footnote {
                notices.append("Block \(index): standalone footnote read with spoken boundary cues.")
                try emit("Footnote:", indices: [index], boundary: .continuation); try content(index); try emit("End Footnote", indices: [index], boundary: .footnote)
            } else { try content(index) }
        }
        for block in article.blocks {
            if let id = block.footnoteID, !emitted.contains(id) { try footnote(id, referredBy: nil) }
        }
        guard chunks.count > headerChunks else { throw NarrationError.invalidInput("No narration chunks were produced.") }
        if let closing = profile.closing { try emit(closing, indices: []) }
        if usedPronunciations { notices.append("User pronunciation overrides applied to narration; original source blocks are preserved.") }
        if purpose == .speechPreparation {
            var merged: [NarrationChunk] = []
            for chunk in chunks {
                if let previous = merged.last, previous.boundaryAfter == .continuation,
                   previous.text.unicodeScalars.count < 80,
                   !Set(previous.blockIndices).isDisjoint(with: chunk.blockIndices) {
                    merged.removeLast()
                    let offset = previous.text.utf16.count + 1
                    let applications = (previous.pronunciationApplications ?? []) + (chunk.pronunciationApplications ?? []).map { $0.shiftedSpoken(by: offset) }
                    merged.append(.init(index: merged.count, text: previous.text + " " + chunk.text,
                        blockIndices: Array(Set(previous.blockIndices + chunk.blockIndices)).sorted(),
                        boundaryAfter: chunk.boundaryAfter, origin: previous.origin == chunk.origin ? chunk.origin : nil,
                        pronunciationApplications: applications))
                } else {
                    merged.append(.init(index: merged.count, text: chunk.text, blockIndices: chunk.blockIndices,
                        boundaryAfter: chunk.boundaryAfter, origin: chunk.origin, pronunciationApplications: chunk.pronunciationApplications))
                }
            }
            chunks = merged
        }
        return NarrationPlan(version: version(pronunciations: pronunciations) + (purpose == .speechPreparation ? "/spoken-projection-1" : ""), chunks: chunks, notices: notices)
    }
}
