import Pronunciation
import Foundation
import DocumentProcessing
import NarrationCore
import SwiftSoup
import PDFKit
import Vision

public enum SourceReviewIssue: String, Codable, Sendable {
    case login, consent, accessBlocked, subscription, unavailable, extraction
    public var message: String {
        switch self {
        case .login: "This looks like a login page. Review it in your browser; authenticated fetching is deferred."
        case .consent: "This looks like a consent page. Review it in your browser before trying again."
        case .accessBlocked: "This looks like an access or browser-check page. Automated bypass is not supported."
        case .extraction: "No readable article was extracted. Inspect the saved source before retrying."
        case .subscription: "This looks like a subscription prompt rather than a complete article."
        case .unavailable: "This looks like a missing or removed article page."
        }
    }
}

public struct ReviewedSource: Sendable {
    public let page: FetchedPage
    public let document: ExtractedDocument?
    public let narration: NarrationPlan?
    public let issue: SourceReviewIssue?
    public let archiveRecoveryFailed: Bool
    public var issueMessage: String? {
        issue.map { $0.message + (archiveRecoveryFailed ? " No readable archived copy was found." : "") }
    }
    public init(page: FetchedPage, document: ExtractedDocument?, narration: NarrationPlan?, issue: SourceReviewIssue?, archiveRecoveryFailed: Bool = false) {
        self.page = page; self.document = document; self.narration = narration; self.issue = issue
        self.archiveRecoveryFailed = archiveRecoveryFailed
    }
    public static func prepareAsync(_ page: FetchedPage, chunkLimit: Int, settings: SpeechSettings = .init(), pronunciations: PronunciationDictionary = .empty, options: NarrationOptions = .init(), sourceTitle: String? = nil, titleGenerator: DocumentTitles.Generate? = nil) async throws -> ReviewedSource {
        let review: ReviewedSource
        if page.contentType == "application/pdf" {
            let document = try await PDFArticleExtractor.extract(page)
            review = ReviewedSource(page: page, document: document, narration: nil, issue: nil)
        } else { review = try prepare(page, chunkLimit: chunkLimit, settings: settings, pronunciations: pronunciations, options: options) }
        guard let document = review.document, review.issue == nil else { return review }
        let resolved = try await DocumentTitles.resolve(title: document.article.title, sourceTitle: sourceTitle,
            blocks: document.article.blocks, urls: [page.originalURL, page.finalURL], isPDF: page.contentType == "application/pdf", generate: titleGenerator)
        var article = document.article
        article.title = resolved.text; article.titleOrigin = resolved.origin
        let changed = article.title != document.article.title
        let cleanedHTML: String
        if changed {
            let html = try SwiftSoup.parse(document.cleanedHTML)
            try html.title(article.title); cleanedHTML = try html.outerHtml()
        } else { cleanedHTML = document.cleanedHTML }
        let narration: NarrationPlan
        if !changed, let existing = review.narration { narration = existing }
        else { narration = try Narration.prepare(article, limit: chunkLimit, pronunciations: pronunciations, settings: settings, options: options) }
        return ReviewedSource(page: page, document: .init(article: article, cleanedHTML: cleanedHTML), narration: narration, issue: nil)
    }
    public static func prepare(_ page: FetchedPage, chunkLimit: Int, settings: SpeechSettings = .init(), pronunciations: PronunciationDictionary = .empty, options: NarrationOptions = .init()) throws -> ReviewedSource {
        guard page.contentType != "application/pdf" else { throw RelayError.setup("PDF preparation requires asynchronous intake.") }
        let dom = try SwiftSoup.parse(page.html, page.finalURL.absoluteString)
        let title = try dom.title().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasCaptcha = try dom.select("form[action*=captcha], #captcha, .g-recaptcha, .h-captcha").first() != nil
        let issue: SourceReviewIssue?
        if page.archivedCopy != nil && (["archive.today", "archive.ph", "webpage archive", "wayback machine"].contains(title) || hasCaptcha) { issue = .accessBlocked }
        else if ["sign in", "log in", "login"].contains(where: { title == $0 || title.hasPrefix($0 + " |") }) { issue = .login }
        else if ["consent required", "cookie consent", "privacy consent"].contains(where: { title.contains($0) }) { issue = .consent }
        else if ["access denied", "just a moment", "attention required", "enable javascript", "captcha", "verify you are human"].contains(where: { title.contains($0) }) { issue = .accessBlocked }
        else if ["page not found", "article not found", "404 not found", "content unavailable"].contains(where: { title.contains($0) }) { issue = .unavailable }
        else if title == "subscribe" || title.hasPrefix("subscribe |") { issue = .subscription }
        else { issue = nil }
        if let issue { return ReviewedSource(page: page, document: nil, narration: nil, issue: issue) }
        var document: ExtractedDocument
        do { document = try ArticleExtractor.extract(html: page.html, originalURL: page.originalURL, finalURL: page.finalURL) }
        catch { return ReviewedSource(page: page, document: nil, narration: nil, issue: .extraction) }
        let text = document.article.blocks.map(\.text).joined(separator: " ").lowercased()
        if text.count < 1200 && ["subscribe to continue reading", "subscribe to read the full", "this article is for subscribers", "subscription required"].contains(where: text.contains) {
            return ReviewedSource(page: page, document: nil, narration: nil, issue: .subscription)
        }
        if let copy = page.archivedCopy {
            var article = document.article
            article.archivedCopy = copy
            // Keep publisher attribution when archive HTML lacks social metadata.
            let name = article.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name == nil || ArticleArchive.allCases.contains(where: { $0.hosts.contains(name ?? "") || $0.label.lowercased() == name }) {
                article.sourceName = page.originalURL.host
            }
            if let image = article.previewImageURL, ArticleArchive.allCases.contains(where: { $0.hosts.contains(image.host?.lowercased() ?? "") }) {
                article.previewImageURL = nil
            }
            document = ExtractedDocument(article: article, cleanedHTML: document.cleanedHTML)
        }
        let narration = try Narration.prepare(document.article, limit: chunkLimit, pronunciations: pronunciations, settings: settings, options: options)
        return ReviewedSource(page: page, document: document, narration: narration, issue: nil)
    }
}

/// PDFKit reads embedded text locally; it never executes document actions or
/// follows links. Instances stay within the background review invocation.
enum PDFArticleExtractor {
    static let version = PDFDocumentExtractor.version
    static let maximumTextBytes = PDFExtractionLimits.article.maximumTextBytes
    static func extract(_ page: FetchedPage, ocr: (@Sendable (CGImage) throws -> String)? = nil) async throws -> ExtractedDocument {
        let recognition: PDFDocumentExtractor.Recognition?
        if let ocr { recognition = { @Sendable image in [.init(kind: .paragraph, text: try ocr(image), origin: .ocr)] } }
        else { recognition = nil }
        let document: SemanticDocument
        do { document = try await PDFDocumentExtractor.extract(data: page.bytes,
            title: page.finalURL.deletingPathExtension().lastPathComponent.removingPercentEncoding,
            limits: .article, recognize: recognition) }
        catch DocumentReadError.malformed { throw SourceFetchError.invalidPDF }
        catch DocumentReadError.encryptedPDF { throw SourceFetchError.lockedPDF }
        catch DocumentReadError.emptyPDF { throw SourceFetchError.pdfNoText }
        catch PDFExtractionError.pageLimit { throw SourceFetchError.pdfPageLimit }
        catch PDFExtractionError.ocrLimit { throw SourceFetchError.pdfOCRLimit }
        catch PDFExtractionError.restricted { throw SourceFetchError.pdfRestricted }
        catch PDFExtractionError.textLimit { throw SourceFetchError.tooLarge }
        guard document.blocks.reduce(0, { $0 + $1.text.count }) >= 80 else { throw RelayError.extraction("The PDF has too little readable text for narration.") }
        let title = document.title ?? "PDF document"
        let article = SemanticArticle(title: title, originalURL: page.originalURL, finalURL: page.finalURL,
            canonicalURL: nil, author: document.author, blocks: document.blocks, warnings: document.warnings,
            extractorVersion: document.extractorVersion, sourceName: page.originalURL.host, outline: document.outline)
        let html = try SwiftSoup.parseBodyFragment("")
        try html.title(title)
        for block in document.blocks { try html.body()?.appendElement("p").text(block.text) }
        return .init(article: article, cleanedHTML: "<!doctype html>\n" + (try html.outerHtml()))
    }
    static func render(_ page: PDFPage, maximumDimension: CGFloat = 2200) throws -> CGImage {
        try PDFDocumentExtractor.render(page, maximumDimension: maximumDimension)
    }
}

public enum SourceReviewArchive {
    /// Explicit private export. Separate ownership prevents mixing reviews with fixture media/state.
    public static func save(_ review: ReviewedSource, root: URL, imported: PrototypeProfile? = nil, excluding: [URL] = []) throws -> URL {
        try Task.checkCancellation()
        guard root.isFileURL else { throw RelayError.setup("Choose a dedicated local source-review folder.") }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        for protected in excluding {
            guard !Files.contains(root, protected), !Files.contains(protected, root) else {
                throw RelayError.setup("Source-review export must be separate from the selected fixture workspace.")
            }
        }
        var ancestor = root
        while true {
            guard !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".voicerelay-fixture").path) else {
                throw RelayError.setup("Source-review export cannot be placed inside a processing workspace.")
            }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        if let p = imported {
            for protected in [p.safariPlist, p.database, p.work, p.audio, p.feed, p.configurationURL].compactMap({ $0 }) {
                guard !Files.contains(root, protected), !Files.contains(protected, root) else {
                    throw RelayError.setup("Source-review export must be separate from configured source, state, media and feed paths.")
                }
            }
        }
        let marker = root.appendingPathComponent(".voicerelay-source-review")
        let ownership = Data("VoiceRelay private source review v1\n".utf8)
        if FileManager.default.fileExists(atPath: root.path) {
            if FileManager.default.fileExists(atPath: marker.path) {
                guard !Files.hasSymlink(marker, below: root), (try? Data(contentsOf: marker)) == ownership else {
                    throw RelayError.setup("Source-review folder ownership is invalid.")
                }
            } else {
                guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
                    throw RelayError.setup("Select an empty folder or an existing VoiceRelay source-review folder.")
                }
            }
        }
        try Files.directory(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if !FileManager.default.fileExists(atPath: marker.path) { try Files.write(ownership, to: marker) }
        let folder = root.appendingPathComponent(UUID().uuidString.lowercased())
        guard Files.contains(root, folder), !Files.hasSymlink(folder, below: root) else { throw RelayError.setup("Invalid source-review destination.") }
        try Files.directory(folder)
        let sourceFilename = review.page.contentType == "application/pdf" ? "source.pdf" : "source.html"
        try Files.write(review.page.bytes, to: folder.appendingPathComponent(sourceFilename))
        try Task.checkCancellation()
        if let document = review.document {
            try Files.write(try Files.json(document.article), to: folder.appendingPathComponent("article.json"))
            try Files.write(Data(document.cleanedHTML.utf8), to: folder.appendingPathComponent("cleaned.html"))
        }
        if let narration = review.narration { try Files.write(try Files.json(narration), to: folder.appendingPathComponent("narration.json")) }
        try Task.checkCancellation()
        // Commit last: a folder without this manifest is an incomplete export.
        let manifest = Manifest(schemaVersion: 1, originalURL: review.page.originalURL, finalURL: review.page.finalURL,
                                fetchedAt: review.page.fetchedAt, contentType: review.page.contentType, encoding: review.page.encoding,
                                sourceHash: Files.hash(review.page.bytes), issue: review.issue, sourceFilename: sourceFilename)
        try Files.write(try Files.json(manifest), to: folder.appendingPathComponent("response.json"))
        return folder
    }
    private struct Manifest: Codable {
        let schemaVersion: Int
        let originalURL: URL
        let finalURL: URL
        let fetchedAt: Date
        let contentType: String
        let encoding: String
        let sourceHash: String
        let issue: SourceReviewIssue?
        let sourceFilename: String
    }
}
