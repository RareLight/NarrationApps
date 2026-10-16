import Pronunciation
import Foundation
import DocumentProcessing
import NarrationCore

// Transport authorization and article metadata remain app-specific; generated
// descriptions, budgets, digest deduplication and provenance are common.
enum ImageNarration {
    static func enrich(_ review: ReviewedSource, chunkLimit: Int, nativeEnabled: Bool,
                       fetch: ArticleSourceLoader.ImageFetch? = nil, caption: ArticleSourceLoader.ImageCaption? = nil,
                       debugLog: DeliveryDebugLog? = nil, settings: SpeechSettings = .init(), pronunciations: PronunciationDictionary = .empty, options: NarrationOptions = .init()) async throws -> ReviewedSource {
        guard let document = review.document else { return review }
        let input = document.article
        let transport: ImageDescriptions.Fetch?
        if let fetch { transport = fetch }
        else if nativeEnabled {
            transport = { @Sendable url in
                guard eligible(url) else { throw SourceFetchError.invalidURL }
                return try await PageFetcher(limits: FetchLimits(maximumBytes: 2_000_000, timeout: 10))
                    .fetch(url, configuration: .ephemeral, acceptedTypes: ["image/jpeg", "image/png", "image/webp", "image/heic"],
                           allowedHosts: [url.host!.lowercased()]).bytes
            }
        } else { transport = nil }
        let guarded: ImageDescriptions.Fetch? = transport.map { transport in
            { @Sendable url in guard eligible(url) else { throw SourceFetchError.invalidURL }; return try await transport(url) }
        }
        let enriched = try await DocumentImages.enrich(.init(title: input.title, author: input.author, blocks: input.blocks,
                                                             warnings: input.warnings, extractorVersion: input.extractorVersion, outline: input.outline),
                                                       pdfData: review.page.contentType == "application/pdf" ? review.page.bytes : nil,
                                                       enabled: nativeEnabled || caption != nil, fetch: guarded, caption: caption)
        var article = input
        article = SemanticArticle(title: input.title, originalURL: input.originalURL, finalURL: input.finalURL, canonicalURL: input.canonicalURL,
                                  author: input.author, blocks: enriched.blocks, warnings: enriched.warnings, extractorVersion: input.extractorVersion,
                                  sourceName: input.sourceName, previewImageURL: input.previewImageURL, archivedCopy: input.archivedCopy, outline: enriched.outline)
        return .init(page: review.page, document: .init(article: article, cleanedHTML: document.cleanedHTML),
                     narration: try Narration.prepare(article, limit: chunkLimit, pronunciations: pronunciations, settings: settings, options: options), issue: review.issue, archiveRecoveryFailed: review.archiveRecoveryFailed)
    }
    static func eligible(_ url: URL) -> Bool {
        guard url.scheme == "https", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        parts.query = nil; parts.fragment = nil
        return parts.url.flatMap(ArticleSourceLoader.lookupURL) != nil
    }
    static func cleanDescription(_ text: String) -> String? { ImageDescriptions.clean(text) }
}

typealias PDFImageMetadata = DocumentProcessing.PDFImageMetadata
