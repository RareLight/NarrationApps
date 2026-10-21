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
    static func chunkFingerprintVersion(_ version: String) -> String {
        // Text, indices and provenance remain part of each request fingerprint;
        // table policy changes do not invalidate otherwise identical audio.
        version.replacingOccurrences(of: "semantic-5-images", with: "semantic-4-images").replacingOccurrences(of: "/anchors-1", with: "")
            .replacingOccurrences(of: "/table-prose-2", with: "").replacingOccurrences(of: "/table-flow-2", with: "")
    }
    public static func semanticBlocks(html: String, baseURL: URL) throws -> [ContentBlock] {
        try HTMLDocumentExtractor.semanticBlocks(html: html, baseURL: baseURL)
    }
    public static func normalize(_ text: String) -> String { NarrationText.normalizeWhitespace(text) }
}

public enum Narration {
    public static let version = NarrationPlanner.version(settings: .init())
    public static func version(pronunciations: PronunciationDictionary) -> String { NarrationPlanner.version(settings: .init(), pronunciations: pronunciations) }
    public static func version(settings: SpeechSettings, pronunciations: PronunciationDictionary, options: NarrationOptions = .init()) -> String { NarrationPlanner.version(settings: settings, pronunciations: pronunciations, options: options) }
    static func chunkFingerprintVersion(_ version: String) -> String { NarrationPlanner.chunkFingerprintVersion(version) }
    public static func prepare(_ article: SemanticArticle, limit: Int, pronunciations: PronunciationDictionary = .empty, settings: SpeechSettings? = nil, purpose: NarrationPlanPurpose = .preview, options: NarrationOptions = .init()) throws -> NarrationPlan {
        let host = article.finalURL.host ?? article.originalURL.host ?? "Unknown source"
        let source = ArticleExtractor.normalize(article.sourceName ?? host)
        do { return try NarrationPlanner.prepare(.init(title: article.title, blocks: article.blocks, warnings: article.warnings,
                                                   extractorVersion: article.extractorVersion, outline: article.outline), limit: limit, settings: settings ?? .init(),
                                            profile: .article(title: article.title, source: source.isEmpty ? host : source), pronunciations: pronunciations, purpose: purpose, options: options)
        } catch let error as NarrationError { throw RelayError.extraction(error.localizedDescription) }
    }
}
