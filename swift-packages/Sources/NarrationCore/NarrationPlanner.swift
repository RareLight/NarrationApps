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
    public static func version(settings: SpeechSettings, pronunciations: PronunciationDictionary = .empty, options: NarrationOptions = .init()) -> String {
        let base = version(pronunciations: pronunciations) + "/text-flow-1/pdf-layout-2/document-structure-1/scientific-text-2" + options.versionSuffix
        return settings.model == .kokoro ? base + "/" + SpokenFormNormalizer.version + "-" + SpokenFormNormalizer.locale(settings) : base
    }
    // These upgrades omit separators and duplicate placeholders. Identical text, index,
    // provenance and engine still produce identical audio, so keep those checkpoints.
    public static func chunkFingerprintVersion(_ version: String) -> String {
        var acousticVersion = NarrationOptions.acousticCompatibleVersion(version).replacingOccurrences(of: "/text-flow-1", with: "").replacingOccurrences(of: "/pdf-layout-2", with: "").replacingOccurrences(of: "/scientific-text-1", with: "").replacingOccurrences(of: "/scientific-text-2", with: "")
        for policy in ["spoken-forms-1", "spoken-forms-2"] {
            for locale in ["en_US", "en_GB"] {
                acousticVersion = acousticVersion.replacingOccurrences(of: "/" + policy + "-" + locale, with: "")
            }
        }
        return [Self.version, Self.version.replacingOccurrences(of: "/image-captions-1", with: ""), omissionVersion, separatorVersion].contains(acousticVersion) ? previousVersion : acousticVersion
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
    private enum OptionalLayoutBudget: Error { case exceeded }
    public static func prepare(_ article: SemanticDocument, limit: Int = 480, settings: SpeechSettings = .init(), profile: NarrationProfile = .document, pronunciations: PronunciationDictionary = .empty, purpose: NarrationPlanPurpose = .preview, options: NarrationOptions = .init()) throws -> NarrationPlan {
        do { return try prepare(article, limit: limit, settings: settings, profile: profile, pronunciations: pronunciations, purpose: purpose, options: options, layoutEnabled: true) }
        catch OptionalLayoutBudget.exceeded {
            // Optional layout work must not turn a readable book into a failure.
            // Replan once, before any G2P or inference, retaining all PDF prose.
            let plain = try prepare(article, limit: limit, settings: settings, profile: profile, pronunciations: pronunciations, purpose: purpose, options: options, layoutEnabled: false)
            return .init(version: plain.version, chunks: plain.chunks,
                         notices: plain.notices + ["PDF layout changes exceeded the source-mapping budget and were skipped; source text is retained."], omissions: plain.omissions)
        }
    }
    private static func prepare(_ article: SemanticDocument, limit: Int = 480, settings: SpeechSettings = .init(), profile: NarrationProfile = .document, pronunciations: PronunciationDictionary = .empty, purpose: NarrationPlanPurpose, options: NarrationOptions, layoutEnabled: Bool) throws -> NarrationPlan {
        try Task.checkCancellation()
        guard limit > 0 else { throw NarrationError.invalidInput("Narration chunk limit must be positive.") }
        var chunks: [NarrationChunk] = []; var notices: [String] = []; var usedPronunciations = false; var mappedRules = 0; var mappingCount = 0
        let structuralOmissions = NarrationStructure.omissions(article, options: options)
        let citations = try AcademicCitations.analyze(article, options: options)
        let excludedBlocks = Set(structuralOmissions.keys).union(citations.wholeBlocks)
        let equations = layoutEnabled ? try PDFEquationNarration.analyze(article, excluded: excludedBlocks, pronunciations: pronunciations) : PDFEquationNarration.Result()
        let layout = layoutEnabled ? try PDFLayoutAnalysis.analyze(article,
            experimentalWordJoining: options.experimentalPDFWordJoining,
            excludedBlocks: excludedBlocks) : PDFLayoutAnalysis.Result()
        let normalizer = SpokenFormNormalizer(settings: settings)
        let hasLayoutChanges = !layout.omissions.isEmpty || !layout.joins.isEmpty || !layout.wordCuts.isEmpty || !layout.letterCuts.isEmpty || !layout.readingOrder.isEmpty || !equations.edits.isEmpty
        var noteIndices: [String: [Int]] = [:]
        for (index, block) in article.blocks.enumerated() {
            if let id = block.footnoteID { noteIndices[id, default: []].append(index) }
        }
        let duplicateCaptions = CaptionDeduplication.suppressedIndices(in: article.blocks)
        var emitted: Set<String> = []
        var imageCredits: Set<String> = []
        var lastOmission: ContentBlock.Kind?
        var announcedComplexEquations = false
        func emit(_ text: String, indices: [Int], boundary: SpeechBoundary = .paragraph, mappingBlock: Int? = nil, projection: MappedProjection? = nil) throws {
            if !text.isEmpty { lastOmission = nil }
            let application = try pronunciations.applyingWithMappings(to: text)
            mappedRules += application.applications.count
            guard mappedRules <= 100_000 else { throw PronunciationError.tooManyApplications }
            let normalized = try normalizer.apply(text: text, application: application,
                block: mappingBlock.map { article.blocks[$0] }, index: mappingBlock, canonical: !pronunciations.entries.isEmpty, initialProjection: projection)
            let spoken = normalized.text
            let applications = normalized.applications
            mappingCount += normalized.mappings?.count ?? 0
            guard mappingCount <= 100_000 else {
                if hasLayoutChanges { throw OptionalLayoutBudget.exceeded }
                throw NarrationError.invalidInput("Spoken-form mapping budget exceeded. No text was truncated.") }
            usedPronunciations = usedPronunciations || application.text != text
            let parts = purpose == .speechPreparation ? [spoken] : try NarrationText.chunks(spoken, settings: settings, maximumScalars: min(limit, 480))
            var partOffset = 0
            for part in parts {
                let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawOffset = partOffset
                partOffset += part.utf16.count
                let trimmedOffset = (part as NSString).range(of: value).location
                let offset = rawOffset + (trimmedOffset == NSNotFound ? 0 : trimmedOffset)
                let mappings = ProjectionMapping.intersecting(normalized.mappings, location: offset, length: value.utf16.count)?.map { $0.shiftedSpoken(by: -offset) }
                if !value.isEmpty { chunks.append(.init(index: chunks.count, text: value, blockIndices: indices,
                    boundaryAfter: purpose == .speechPreparation ? boundary : nil,
                    origin: purpose == .speechPreparation ? indices.first.map { article.blocks[$0].origin ?? .authored } : nil,
                    pronunciationApplications: purpose == .speechPreparation ? applications : nil, sourceMappings: mappings)) }
            }
        }
        func projectedBlock(_ index: Int) throws -> MappedProjection {
            do {
                let block = article.blocks[index]
                func scientific(_ base: MappedProjection) throws -> MappedProjection {
                    let mapped = try base.replacingSourceRanges(equations.edits[index] ?? [])
                    // Mappings are now in actual narration order, including
                    // reconstructed columns and deferred footnotes.
                    var duplicates: [ProjectionEdit] = []
                    for run in mapped.mappings where run.rule == PDFEquationNarration.complexCueRule && run.spokenLength > 0 {
                        if announcedComplexEquations {
                            duplicates.append(.init(range: NSRange(location: run.spokenLocation, length: run.spokenLength), replacement: " ", rule: PDFEquationNarration.complexCueRule))
                        }
                        announcedComplexEquations = true
                    }
                    return duplicates.isEmpty ? mapped : try mapped.applying(duplicates)
                }
                if let order = layout.readingOrder[index] {
                    let ordered = try MappedProjection.orderedPDF(block.text, block: index, lines: order,
                        margins: layout.byBlock[index] ?? [], wordCuts: layout.wordCuts[index] ?? [], lineJoins: layout.lineJoins[index] ?? [:], letterCuts: layout.letterCuts[index] ?? [], citations: citations.ranges[index] ?? [], canonical: !pronunciations.entries.isEmpty)
                    let processed = try scientific(ordered)
                    return try citations.ranges[index] != nil ? processed.cleaningCitationWhitespace() : processed
                }
                let mapped = try MappedProjection.source(block.text, block: index, canonical: !pronunciations.entries.isEmpty)
                let margins = try layout.byBlock[index].map { try mapped.removingSourceRanges($0) } ?? mapped
                let joined = try layout.wordCuts[index].map { try margins.removingSourceRanges($0, rule: PDFWordJoining.rule) } ?? margins
                let letters = try layout.letterCuts[index].map { try joined.removingSourceRanges($0, rule: "pdf-letter-spacing-1") } ?? joined
                let cited = try citations.ranges[index].map { try letters.removingSourceRanges($0, rule: "academic-citation-1").cleaningCitationWhitespace() } ?? letters
                return try scientific(cited)
            } catch NarrationError.invalidInput(let reason) where reason.contains("budget") {
                throw OptionalLayoutBudget.exceeded
            }
        }
        func content(_ index: Int) throws {
            let block = article.blocks[index]
            if excludedBlocks.contains(index) { return }
            if duplicateCaptions.contains(index) { notices.append("Duplicate image caption omitted from narration."); return }
            var text = NarrationText.normalizeWhitespace(block.narrationText ?? block.text)
            var projection: MappedProjection?
            if layout.byBlock[index] != nil || layout.wordCuts[index] != nil || layout.letterCuts[index] != nil || layout.readingOrder[index] != nil || citations.ranges[index] != nil || equations.edits[index] != nil {
                let mapped = try projectedBlock(index)
                text = mapped.text; projection = mapped
            }
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
            if block.kind == .table {
                text = TableNarration.render(block)
                notices.append("Block \(index): prose table entries read in source order; numeric entries retain reliable labels, and unread content remains in the source.")
            }
            let tableUnavailable = block.kind == .table && (text == TableNarration.unavailable || text.hasPrefix("Table image. Its contents could not be read reliably."))
            if block.kind == .code {
                notices.append("Block \(index): \(block.kind.rawValue) retained in semantic artifact and omitted from narration.")
                text = "Code block omitted from narration."
            }
            if block.kind == .unsupported {
                notices.append("Block \(index): unsupported structure read as plain text; inspect before listening acceptance.")
            }
            if isDecorativeQuotation(text) {
                notices.append("Block \(index): decorative quotation retained in semantic artifact and omitted from narration.")
            } else if isDecorativeSeparator(text) {
                notices.append("Block \(index): decorative separator retained in semantic artifact and omitted from narration.")
            } else if block.kind == .code || tableUnavailable, lastOmission == block.kind {
                notices.append("Block \(index): repeated omission announcement suppressed.")
            } else {
                try emit(text, indices: [index], boundary: block.kind == .heading ? .heading : block.kind == .footnote ? .footnote : .paragraph,
                         mappingBlock: [.code, .table].contains(block.kind) ? nil : index, projection: projection)
                if block.kind == .code || tableUnavailable { lastOmission = block.kind }
            }
            if options.notes == .current { for id in block.footnoteReferences ?? [] { try footnote(id, referredBy: index) } }
        }
        func footnote(_ id: String, referredBy index: Int?) throws {
            guard options.notes != .omit, emitted.insert(id).inserted else { return }
            guard let notes = noteIndices[id], notes.contains(where: { !NarrationText.normalizeWhitespace(article.blocks[$0].narrationText ?? article.blocks[$0].text).isEmpty }) else {
                notices.append("A marked footnote/citation could not be resolved; its marker is omitted from speech.")
                return
            }
            guard notes.contains(where: { !excludedBlocks.contains($0) }) else { return }
            let provenance = (index.map { [$0] } ?? []) + notes
            if index == nil && options.notes == .current { notices.append("Unreferenced footnote retained at the end of narration.") }
            try emit("Footnote:", indices: provenance, boundary: .continuation)
            for note in notes { try content(note) }
            try emit("End Footnote", indices: provenance, boundary: .footnote)
        }
        if let opening = profile.opening { try emit(opening, indices: []) }
        let headerChunks = chunks.count
        var joined = Set<Int>()
        for (index, block) in article.blocks.enumerated() where block.footnoteID == nil {
            if joined.contains(index) || excludedBlocks.contains(index) { continue }
            if block.kind == .footnote && options.notes == .endOfDocument { continue }
            if layout.joins.contains(index) {
                var indices = [index], last = index, mapped = try projectedBlock(index)
                do {
                    while layout.joins.contains(last), indices.count < 16, !excludedBlocks.contains(last + 1) {
                        let direct = layout.directJoins.contains(last)
                        last += 1; indices.append(last); joined.insert(last)
                        mapped = try mapped.joining(projectedBlock(last), directly: direct)
                    }
                } catch NarrationError.invalidInput(let reason) where reason.contains("budget") {
                    throw OptionalLayoutBudget.exceeded
                }
                try emit(mapped.text, indices: indices, boundary: layout.joins.contains(last) ? .continuation : .paragraph, mappingBlock: index, projection: mapped)
            } else if block.kind == .footnote {
                notices.append("Block \(index): standalone footnote read with spoken boundary cues.")
                try emit("Footnote:", indices: [index], boundary: .continuation); try content(index); try emit("End Footnote", indices: [index], boundary: .footnote)
            } else { try content(index) }
        }
        if options.notes == .endOfDocument {
            for (index, block) in article.blocks.enumerated() where block.kind == .footnote && block.footnoteID == nil && !excludedBlocks.contains(index) {
                try emit("Footnote:", indices: [index], boundary: .continuation); try content(index); try emit("End Footnote", indices: [index], boundary: .footnote)
            }
        }
        for block in article.blocks {
            if let id = block.footnoteID, !emitted.contains(id) { try footnote(id, referredBy: nil) }
        }
        guard chunks.count > headerChunks else { throw NarrationError.invalidInput("No narration chunks were produced.") }
        if let closing = profile.closing { try emit(closing, indices: []) }
        if !layout.joins.isEmpty { notices.append("Joined \(layout.joins.count) PDF page continuations using compatible column, line and page-edge evidence; original blocks and source spans are retained.") }
        if !layout.readingOrder.isEmpty { notices.append("Reconstructed column reading order in \(layout.readingOrder.count) PDF blocks using separated gutters and full-width text boundaries; original extraction order is retained in source.") }
        if !layout.letterCuts.isEmpty { notices.append("Repaired dictionary-verified letter spacing in \(layout.letterCuts.count) PDF blocks; uncertain words and original source are retained.") }
        if !layout.omissions.isEmpty {
            let pages = Set(layout.omissions.compactMap { $0.pageIndex.map { $0 + 1 } }).sorted()
            let shown = pages.prefix(12).map(String.init).joined(separator: ", ") + (pages.count > 12 ? ", …" : "")
            notices.append("Recurring PDF headers/footers omitted on \(pages.count) pages (\(shown)); original text, source ranges and omission reasons are retained.")
        }
        if layout.budgetSkipped { notices.append("PDF layout review exceeded its evidence budget; affected text was left unchanged.") }
        if !layout.wordCuts.isEmpty {
            let count = layout.wordCuts.values.reduce(0) { $0 + $1.count }
            notices.append("Rejoined \(count) PDF printed word wraps using experimental geometry and English dictionary checks; recognized compound hyphens and uncertain words are preserved. Original source and mapped spans are retained.")
        }
        if equations.readable > 0 { notices.append("Read \(equations.readable) equations using verified linear notation; original source is retained.") }
        if equations.complex > 0 { notices.append("Flagged \(equations.complex) complex mathematical expressions. One spoken notice refers to the original text; every source range and page remains available for review, and explanatory prose is retained.") }
        for omission in structuralOmissions.values.sorted(by: { $0.source.blockIndex < $1.source.blockIndex }) {
            notices.append("Block \(omission.source.blockIndex + 1): " + omission.reason)
        }
        if options.notes == .endOfDocument { notices.append("Notes are narrated at the end of the document; original references and source blocks are retained.") }
        if !citations.omissions.isEmpty { notices.append("Skipped \(citations.omissions.count) academic citation spans using the selected settings; explanatory notes and original source are retained.") }
        if usedPronunciations { notices.append("User pronunciation overrides applied to narration; original source blocks are preserved.") }
        do {
            if normalizer.discretionaryCount > 0 { notices.append("Discretionary soft hyphens removed from \(normalizer.discretionaryCount) spoken spans; original source text is preserved.") }
            if normalizer.count > 0 { notices.append("Spoken forms expanded for \(normalizer.count) quantities, temperatures, explicit times or letter labels (\(normalizer.locale)); original source text is preserved.") }
            if normalizer.codeProtected { notices.append("Automatic spoken forms left paragraphs containing inline code unchanged.") }
            if normalizer.skipped { notices.append("Some automatic spoken-form changes were skipped because their original source spans could not be verified.") }
        }
        if purpose == .speechPreparation {
            var merged: [NarrationChunk] = []
            for chunk in chunks {
                if let previous = merged.last, previous.boundaryAfter == .continuation,
                   previous.text.unicodeScalars.count < 80,
                   !Set(previous.blockIndices).isDisjoint(with: chunk.blockIndices) {
                    merged.removeLast()
                    let offset = previous.text.utf16.count + 1
                    let applications = (previous.pronunciationApplications ?? []) + (chunk.pronunciationApplications ?? []).map { $0.shiftedSpoken(by: offset) }
                    let mappings: [ProjectionMapping]?
                    if previous.sourceMappings != nil || chunk.sourceMappings != nil {
                        let before = previous.sourceMappings ?? [.init(source: nil, spokenLocation: 0, spokenLength: previous.text.utf16.count, rule: "unaligned-cue-1")]
                        let after = chunk.sourceMappings ?? [.init(source: nil, spokenLocation: 0, spokenLength: chunk.text.utf16.count, rule: "unaligned-cue-1")]
                        mappings = before + [.init(source: nil, spokenLocation: offset - 1, spokenLength: 1, rule: "generated-cue-1")] + after.map { $0.shiftedSpoken(by: offset) }
                    } else { mappings = nil }
                    merged.append(.init(index: merged.count, text: previous.text + " " + chunk.text,
                        blockIndices: Array(Set(previous.blockIndices + chunk.blockIndices)).sorted(),
                        boundaryAfter: chunk.boundaryAfter, origin: previous.origin == chunk.origin ? chunk.origin : nil,
                        pronunciationApplications: applications, sourceMappings: mappings))
                } else {
                    merged.append(.init(index: merged.count, text: chunk.text, blockIndices: chunk.blockIndices,
                        boundaryAfter: chunk.boundaryAfter, origin: chunk.origin, pronunciationApplications: chunk.pronunciationApplications, sourceMappings: chunk.sourceMappings))
                }
            }
            chunks = merged
        }
        guard chunks.reduce(0, { $0 + ($1.sourceMappings?.count ?? 0) }) <= 100_000 else {
            if hasLayoutChanges { throw OptionalLayoutBudget.exceeded }
            throw NarrationError.invalidInput("Spoken-form mapping budget exceeded after cue composition. No text was truncated.") }
        let omissions = layout.omissions + structuralOmissions.values.sorted { $0.source.blockIndex < $1.source.blockIndex } + citations.omissions + equations.omissions
        return NarrationPlan(version: version(settings: settings, pronunciations: pronunciations, options: options) + (purpose == .speechPreparation ? "/spoken-projection-1" : ""), chunks: chunks, notices: notices, omissions: omissions.isEmpty ? nil : omissions)
    }
}
