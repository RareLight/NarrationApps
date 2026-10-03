import Foundation
import SwiftSoup

public enum SourceReviewIssue: String, Codable, Sendable {
    case login, consent, accessBlocked, extraction
    public var message: String {
        switch self {
        case .login: "This looks like a login page. Review it in your browser; authenticated fetching is deferred."
        case .consent: "This looks like a consent page. Review it in your browser before trying again."
        case .accessBlocked: "This looks like an access or browser-check page. Automated bypass is not supported."
        case .extraction: "No readable article was extracted. Inspect the saved source before retrying."
        }
    }
}

public struct ReviewedSource: Sendable {
    public let page: FetchedPage
    public let document: ExtractedDocument?
    public let narration: NarrationPlan?
    public let issue: SourceReviewIssue?
    public init(page: FetchedPage, document: ExtractedDocument?, narration: NarrationPlan?, issue: SourceReviewIssue?) {
        self.page = page; self.document = document; self.narration = narration; self.issue = issue
    }
    public static func prepare(_ page: FetchedPage, chunkLimit: Int) throws -> ReviewedSource {
        let dom = try SwiftSoup.parse(page.html, page.finalURL.absoluteString)
        let title = try dom.title().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let issue: SourceReviewIssue?
        if ["sign in", "log in", "login"].contains(where: { title == $0 || title.hasPrefix($0 + " |") }) { issue = .login }
        else if ["consent required", "cookie consent", "privacy consent"].contains(where: { title.contains($0) }) { issue = .consent }
        else if ["access denied", "just a moment", "attention required", "enable javascript"].contains(where: { title.contains($0) }) { issue = .accessBlocked }
        else { issue = nil }
        if let issue { return ReviewedSource(page: page, document: nil, narration: nil, issue: issue) }
        let document: ExtractedDocument
        do { document = try ArticleExtractor.extract(html: page.html, originalURL: page.originalURL, finalURL: page.finalURL) }
        catch { return ReviewedSource(page: page, document: nil, narration: nil, issue: .extraction) }
        let narration = try Narration.prepare(document.article, limit: chunkLimit)
        return ReviewedSource(page: page, document: document, narration: narration, issue: nil)
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
                throw RelayError.setup("Source-review export cannot be placed inside a tone or speech fixture workspace.")
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
        try Files.write(review.page.bytes, to: folder.appendingPathComponent("source.html"))
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
                                sourceHash: Files.hash(review.page.bytes), issue: review.issue)
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
    }
}
