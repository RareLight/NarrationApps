import Foundation
import Pronunciation
import NarrationCore
import DocumentProcessing

public struct ExtractedDocument: Sendable {
    public let article: SemanticArticle
    public let cleanedHTML: String
}

/// Product metadata stays here; parsing and narration policies live in the
/// independent common libraries used by both applications.
public enum ArticleExtractor {
    public static let version = HTMLDocumentExtractor.version
    public static func extract(html: String, originalURL: URL, finalURL: URL) throws -> ExtractedDocument {
        do {
            let result = try HTMLDocumentExtractor.extract(html: html, originalURL: originalURL, finalURL: finalURL)
            let article = result.article
            return .init(article: SemanticArticle(title: article.title, originalURL: article.originalURL, finalURL: article.finalURL,
                         canonicalURL: article.canonicalURL, author: article.author, blocks: article.blocks, warnings: article.warnings,
                         extractorVersion: article.extractorVersion, sourceName: article.sourceName, previewImageURL: article.previewImageURL),
                         cleanedHTML: result.cleanedHTML)
        } catch { throw RelayError.extraction(error.localizedDescription) }
    }
    public static func semanticBlocks(html: String, baseURL: URL) throws -> [ContentBlock] {
        try HTMLDocumentExtractor.semanticBlocks(html: html, baseURL: baseURL)
    }
    public static func normalize(_ text: String) -> String { NarrationText.normalizeWhitespace(text) }
}

public enum Narration {
    public static let version = NarrationPlanner.version
    public static func version(pronunciations: PronunciationDictionary) -> String { NarrationPlanner.version(pronunciations: pronunciations) }
    static func chunkFingerprintVersion(_ version: String) -> String { NarrationPlanner.chunkFingerprintVersion(version) }
    public static func prepare(_ article: SemanticArticle, limit: Int, pronunciations: PronunciationDictionary = .empty, settings: SpeechSettings? = nil, purpose: NarrationPlanPurpose = .preview) throws -> NarrationPlan {
        let host = article.finalURL.host ?? article.originalURL.host ?? "Unknown source"
        let source = ArticleExtractor.normalize(article.sourceName ?? host)
        do { return try NarrationPlanner.prepare(.init(title: article.title, blocks: article.blocks, warnings: article.warnings,
                                                   extractorVersion: article.extractorVersion), limit: limit, settings: settings ?? .init(),
                                            profile: .article(title: article.title, source: source.isEmpty ? host : source), pronunciations: pronunciations, purpose: purpose)
        } catch let error as NarrationError { throw RelayError.extraction(error.localizedDescription) }
    }
}
