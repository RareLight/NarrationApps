import Foundation
import DocumentProcessing
import NarrationCore
import Pronunciation

/// Job-local preview values. Provisional prefixes are never used for generation.
public struct DocumentPreviewContent: Sendable {
    public let document: SemanticDocument
    public let chunks: [NarrationChunk]
    public let warnings: [String]
    public let completedPages: Int?
    public let totalPages: Int?
    public var isComplete: Bool { completedPages == nil }

    fileprivate init(_ document: SemanticDocument, settings: SpeechSettings,
                     pronunciations: PronunciationDictionary, options: NarrationOptions,
                     completedPages: Int? = nil, totalPages: Int? = nil) throws {
        let plan = try NarrationPlanner.prepare(document, settings: settings,
            pronunciations: pronunciations, options: options)
        self.document = document; chunks = plan.chunks
        warnings = Array(Set(document.warnings + plan.notices)).sorted()
        self.completedPages = completedPages; self.totalPages = totalPages
    }
}

public enum DocumentPreviewAnalysis {
    public static func run(_ input: InputDocument, describeImages: Bool,
                           settings: SpeechSettings, pronunciations: PronunciationDictionary,
                           options: NarrationOptions,
                           recognize: PDFDocumentExtractor.Recognition? = nil,
                           update: @escaping @Sendable (DocumentPreviewContent) async throws -> Void) async throws {
        let document = try await DocumentReader.readSemantic(input, describeImages: describeImages,
            recognize: recognize, pdfPreview: { prefix in
                try Task.checkCancellation()
                let content: DocumentPreviewContent
                do {
                    content = try .init(prefix.document, settings: settings,
                        pronunciations: pronunciations, options: options,
                        completedPages: prefix.completedPages, totalPages: prefix.totalPages)
                } catch NarrationError.invalidInput(let reason) where reason == "No narration chunks were produced." {
                    // A leading decorative/omitted-only prefix must not prevent
                    // later readable pages or the canonical final plan.
                    return
                }
                try await update(content)
                try Task.checkCancellation()
            })
        try Task.checkCancellation()
        let content = try DocumentPreviewContent(document, settings: settings,
            pronunciations: pronunciations, options: options)
        try await update(content)
        try Task.checkCancellation()
    }
}
