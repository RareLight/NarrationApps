import Foundation
import Pronunciation
import SwiftSoup
import Testing
@testable import VoiceRelayCore

@Test func narrationCollapsesOmissionRunsWithoutChangingSourceBlocks() throws {
    let blocks: [ContentBlock] = [
        ContentBlock(kind: .paragraph, text: "Opening prose."),
        ContentBlock(kind: .table, text: "First table"),
        ContentBlock(kind: .table, text: "Second table"),
        ContentBlock(kind: .paragraph, text: "--"),
        ContentBlock(kind: .table, text: "Third table"),
        ContentBlock(kind: .paragraph, text: "A spoken boundary."),
        ContentBlock(kind: .table, text: "Fourth table"),
        ContentBlock(kind: .code, text: "first code"),
        ContentBlock(kind: .code, text: "second code"),
        ContentBlock(kind: .paragraph, text: "Closing prose.")
    ]
    let article = SemanticArticle(title: "Synthetic", originalURL: URL(string: "https://articles.example/one")!,
        finalURL: URL(string: "https://articles.example/one")!, canonicalURL: nil, author: nil,
        blocks: blocks, warnings: [], extractorVersion: ArticleExtractor.version)
    let plan = try Narration.prepare(article, limit: 120)
    let spoken = plan.chunks.map(\.text).joined(separator: "\n")
    #expect(spoken.components(separatedBy: "Table omitted from narration.").count - 1 == 2)
    #expect(spoken.components(separatedBy: "Code block omitted from narration.").count - 1 == 1)
    #expect(spoken.contains("A spoken boundary.") && spoken.hasSuffix("End of article."))
    #expect(!spoken.contains("First table") && !spoken.contains("first code"))
    #expect(article.blocks == blocks && plan.notices.filter { $0.contains("repeated omission") }.count == 3)
    #expect(plan.chunks.allSatisfy { $0.text.count <= 120 })
    let oldVersion = "conservative-2/footnotes-1/sentence-chunks-1/decorative-quotes-1/article-boundaries-1/decorative-separators-1"
    #expect(Narration.chunkFingerprintVersion(oldVersion) == Narration.chunkFingerprintVersion(plan.version))
    #expect(plan.version.contains("spoken-forms-2-en_US"))
}

@Test func narrationKeepsAuthoredPlaceholderTextAndFootnoteBoundaries() throws {
    let article = SemanticArticle(title: "Synthetic", originalURL: URL(string: "https://articles.example")!,
        finalURL: URL(string: "https://articles.example")!, canonicalURL: nil, author: nil,
        blocks: [ContentBlock(kind: .table, text: "One", footnoteReferences: ["note"]),
                 ContentBlock(kind: .table, text: "Two"),
                 ContentBlock(kind: .paragraph, text: "Table omitted from narration."),
                 ContentBlock(kind: .paragraph, text: "Table omitted from narration."),
                 ContentBlock(kind: .footnote, text: "Spoken note.", footnoteID: "note")],
        warnings: [], extractorVersion: ArticleExtractor.version)
    let spoken = try Narration.prepare(article, limit: 120).chunks.map(\.text).joined(separator: "\n")
    #expect(spoken.components(separatedBy: "Table omitted from narration.").count - 1 == 4)
    #expect(spoken.contains("Footnote:") && spoken.contains("End Footnote") && spoken.contains("Spoken note."))
}

private func reviewTemporary() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("voicerelay-review-test-\(UUID().uuidString)")
    try Files.directory(root); return root
}
private func listData(_ children: [[String: Any]], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["Children": [["Title": "Bookmarks", "Children": [
        ["Title": "com.apple.ReadingList", "Children": children]]]]], format: format, options: 0)
}
private func sourcePage(_ html: String, original: String = "https://articles.example/original", final: String = "https://articles.example/final/") -> FetchedPage {
    FetchedPage(originalURL: URL(string: original)!, finalURL: URL(string: final)!, bytes: Data(html.utf8), html: html,
                contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
}
private func fetchConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SourceReviewProtocol.self]
    return configuration
}
private final class CapturedRedirect: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var request: URLRequest? { lock.withLock { stored } }
    func accept(_ request: URLRequest?) { lock.withLock { stored = request } }
}

/// In-process responses only: no socket, external endpoint, cookie, or credential access.
private final class SourceReviewProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "source-review.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/stall" { return }
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        var status = 200
        var body = Data("<html><title>Synthetic</title><body>Café 日本語</body></html>".utf8)
        switch url.path {
        case "/status": status = 403
        case "/pdf": headers["Content-Type"] = "application/pdf"
        case "/empty": body = Data()
        case "/oversize": body = Data(repeating: 65, count: 256)
        case "/declared-size": headers["Content-Length"] = "999999"
        case "/encoding": headers["Content-Type"] = "text/html; charset=not-a-charset"
        case "/error":
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "PRIVATE URL AND TOKEN"]))
            return
        case "/transport-policy":
            client?.urlProtocol(self, didFailWithError: URLError(.appTransportSecurityRequiresSecureConnection))
            return
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if url.path == "/body-stall" { return }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct SourceReviewTests {
    @Test func cleanedHTMLDeclaresUTF8RemovesMediaAndDeduplicatesCaptions() throws {
        let paragraph = String(repeating: "A synthetic article preserves punctuation, quotations and meaningful source wording. ", count: 8)
        let html = """
        <html><head><meta charset="utf-8"><title>Synthetic article</title></head><body><article>
        <header><h1>Synthetic article</h1><div><div class="caption"><div class="caption-content">One caption. Credit: Example</div></div></div>
        <picture><source srcset="/private.jpg"><img src="/private.jpg"></picture>
        <div class="caption">One caption. Credit: Example</div></header>
        <p>I’ll keep “Café 日本語” intact. \(paragraph)</p>
        <p>\(paragraph)</p><svg><text>Decorative image text</text></svg></article></body></html>
        """
        let result = try ArticleExtractor.extract(html: html, originalURL: sourcePage(html).originalURL, finalURL: sourcePage(html).finalURL)
        let dom = try SwiftSoup.parse(result.cleanedHTML)
        #expect(try dom.select("meta[charset]").first()?.attr("charset") == "utf-8")
        #expect(try dom.select("img, picture, source, svg").isEmpty())
        #expect(result.cleanedHTML.contains("I’ll") && !result.cleanedHTML.contains("â€™"))
        #expect(result.article.blocks.filter { $0.kind == .caption && $0.text == "One caption. Credit: Example" }.count == 1)
        #expect(try dom.select("figcaption:not([data-voicerelay-image])").count == 1)
        #expect(result.article.blocks.contains { $0.imageURL != nil && $0.narrationText == "" })
        #expect(result.article.blocks.filter { $0.text == paragraph.trimmingCharacters(in: .whitespaces) }.count <= 2)
        #expect(!result.article.blocks.map(\.text).joined().contains("Decorative image text"))
    }

    @Test(arguments: ["1", "*", "†", "[2]"])
    func linkedFootnotesResolveAfterTheReferringParagraph(_ marker: String) throws {
        let html = """
        <p>Keep 2026 and ordinary wording.<sup id="fnref:one"><a href="#fn:one" rel="footnote">\(marker)</a></sup></p>
        <p>Continue here.<a role="doc-noteref" href="#fn:one">\(marker)</a></p>
        <div class="footnotes"><ol><li id="fn:one"><p>First note paragraph with an apostrophe: isn’t.</p>
        <p>Second note paragraph.<a href="#fnref:one" rev="footnote">↩</a></p></li></ol></div>
        """
        let blocks = try ArticleExtractor.semanticBlocks(html: html, baseURL: sourcePage(html).finalURL)
        #expect(blocks[0].text.hasSuffix(marker) && blocks[0].narrationText == "Keep 2026 and ordinary wording.")
        #expect(blocks.filter { $0.footnoteID == "fn:one" }.count == 2)
        let article = SemanticArticle(title: "Synthetic", originalURL: sourcePage(html).originalURL, finalURL: sourcePage(html).finalURL,
            canonicalURL: nil, author: nil, blocks: blocks, warnings: [], extractorVersion: ArticleExtractor.version)
        let plan = try Narration.prepare(article, limit: 500)
        #expect(plan.chunks.filter { !$0.blockIndices.isEmpty }.map(\.text) == ["Keep 2026 and ordinary wording.", "Footnote:", "First note paragraph with an apostrophe: isn’t.",
            "Second note paragraph.", "End Footnote", "Continue here."])
        #expect(plan.chunks.filter { !$0.blockIndices.isEmpty }[1].blockIndices == [0, 2, 3] && plan.chunks.filter { !$0.blockIndices.isEmpty }[2].blockIndices == [2])
        #expect(!plan.chunks.map(\.text).joined().contains("↩"))
    }

    @Test func citationsMissingNotesAndOrdinaryNumbersRemainDistinct() throws {
        let html = """
        <p>Keep x<sup>2</sup>, year 2026, and <a href="#section2">chapter 2</a>.
        Missing note<sup><a role="doc-noteref" href="#missing">7</a></sup>.
        Linked citation<sup class="reference"><a href="#cite_note-2">[2]</a></sup>.</p>
        <ol><li id="cite_note-2">Synthetic citation text.</li></ol><p>*&nbsp; *&nbsp; *</p>
        """
        let blocks = try ArticleExtractor.semanticBlocks(html: html, baseURL: sourcePage(html).finalURL)
        let article = SemanticArticle(title: "Synthetic", originalURL: sourcePage(html).originalURL, finalURL: sourcePage(html).finalURL,
            canonicalURL: nil, author: nil, blocks: blocks, warnings: [], extractorVersion: ArticleExtractor.version)
        let plan = try Narration.prepare(article, limit: 500)
        let narration = plan.chunks.map(\.text).joined(separator: "\n")
        #expect(narration.contains("x2, year 2026, and chapter 2") && narration.contains("Missing note."))
        #expect(!narration.contains("[2]") && !narration.contains("*") && !narration.contains("note7"))
        #expect(narration.contains("Footnote:\nSynthetic citation text.\nEnd Footnote"))
        #expect(plan.notices.contains { $0.contains("could not be resolved") })
        let legacy = try JSONDecoder().decode(ContentBlock.self, from: Data(#"{"kind":"paragraph","text":"Legacy wording"}"#.utf8))
        #expect(legacy.narrationText == nil && legacy.footnoteReferences == nil && legacy.footnoteID == nil)
    }

    @Test func discardedAppendixRecoversOnlyReferencedFootnotes() throws {
        let paragraph = String(repeating: "A synthetic paragraph includes meaningful wording to exercise article extraction. ", count: 10)
        let html = """
        <html><title>Synthetic article</title><article><h1>Synthetic article</h1><p>\(paragraph)
        Note here<sup><a href="#fn:one" rel="footnote">3</a></sup>.</p><p>\(paragraph)</p></article>
        <footer><ol><li id="fn:one"><p>Recovered note’s first paragraph.</p><p>Its second paragraph.</p></li>
        <li id="fn:unrelated">Unrelated page note must not be added.</li></ol></footer></html>
        """
        let result = try ArticleExtractor.extract(html: html, originalURL: sourcePage(html).originalURL, finalURL: sourcePage(html).finalURL)
        #expect(result.article.blocks.filter { $0.footnoteID == "fn:one" }.count == 2)
        #expect(!result.article.blocks.contains { $0.footnoteID == "fn:unrelated" })
        #expect(try SwiftSoup.parse(result.cleanedHTML).getElementById("fn:one") != nil)
        let narration = try Narration.prepare(result.article, limit: 1800).chunks.map(\.text).joined(separator: "\n")
        #expect(narration.contains("Footnote:\nRecovered note’s first paragraph.\nIts second paragraph.\nEnd Footnote"))
        #expect(!narration.contains("Note here3") && !narration.contains("Unrelated page note"))
    }

    @Test func captionDeduplicationDoesNotRemoveRepeatedBodyParagraphs() throws {
        let html = "<p>Repeated body.</p><p>Repeated body.</p><figcaption>Same caption</figcaption><p>Intervening body.</p><figcaption>Same caption</figcaption>"
        let blocks = try ArticleExtractor.semanticBlocks(html: html, baseURL: sourcePage(html).finalURL)
        #expect(blocks.filter { $0.text == "Repeated body." }.count == 2)
        #expect(blocks.filter { $0.kind == .caption }.count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICERELAY_REVIEW_FIXTURES"] != nil))
    func explicitlySelectedPrivateSnapshotsReprocessWithoutFetching() throws {
        let value = try #require(ProcessInfo.processInfo.environment["VOICERELAY_REVIEW_FIXTURES"])
        let paths = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        for (index, path) in paths.enumerated() {
            let folder = URL(fileURLWithPath: path)
            let source = folder.appendingPathComponent("source.html")
            let bytes = try Data(contentsOf: source)
            let modification = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
            let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("response.json"))) as? [String: Any])
            #expect(metadata["sourceHash"] as? String == Files.hash(bytes))
            let originalString = try #require(metadata["originalURL"] as? String)
            let finalString = try #require(metadata["finalURL"] as? String)
            let original = try #require(URL(string: originalString))
            let final = try #require(URL(string: finalString))
            let decoded = try PageFetcher.decode(bytes, declared: metadata["encoding"] as? String)
            let page = FetchedPage(originalURL: original, finalURL: final, bytes: bytes, html: decoded.text,
                contentType: "text/html", encoding: decoded.encoding,
                fetchedAt: Date(timeIntervalSinceReferenceDate: metadata["fetchedAt"] as? Double ?? 0))
            let review = try ReviewedSource.prepare(page, chunkLimit: 1800)
            let document = try #require(review.document); let plan = try #require(review.narration)
            let dom = try SwiftSoup.parse(document.cleanedHTML)
            #expect(try dom.select("meta[charset]").first()?.attr("charset") == "utf-8")
            #expect(try dom.select("img, picture, svg, iframe").isEmpty())
            #expect(!document.cleanedHTML.contains("â€™") && !document.cleanedHTML.contains("â€œ"))
            let notes = Set(document.article.blocks.compactMap(\.footnoteID))
            #expect(plan.chunks.filter { $0.text == "Footnote:" }.count == notes.count)
            #expect(plan.chunks.filter { $0.text == "End Footnote" }.count == notes.count)
            for block in document.article.blocks where block.footnoteReferences != nil {
                #expect(block.narrationText != nil)
            }
            if let destination = ProcessInfo.processInfo.environment["VOICERELAY_REVIEW_OUTPUT"] {
                let output = try SourceReviewArchive.save(review, root: URL(fileURLWithPath: destination))
                print("Private fixture \(index + 1): refreshed export \(output.path)")
            }
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == modification)
            print("Private fixture \(index + 1): \(document.article.blocks.filter { $0.kind == .caption }.count) captions; \(notes.count) footnotes; \(plan.chunks.count) narration chunks")
        }
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func readingListFormatsAndStableIdentities(_ format: PropertyListSerialization.PropertyListFormat) throws {
        let same = "https://articles.example/article?private=value#section"
        let data = try listData([
            ["URLString": same, "WebBookmarkUUID": "A", "URIDictionary": ["title": "Café 日本語"], "ReadingList": ["DateAdded": Date(timeIntervalSinceReferenceDate: 100)]],
            ["URLString": same, "WebBookmarkUUID": "B", "ReadingList": ["DateAdded": 200]],
            ["URLString": same, "WebBookmarkUUID": "A"],
            ["URLString": "file:///private/article"],
            ["URLString": "https://user:password@articles.example/secret"]
        ], format: format)
        let snapshot = try ReadingList.parse(data)
        #expect(snapshot.entries.map(\.id) == ["safari:A", "safari:B"])
        #expect(snapshot.entries.first?.title == "Café 日本語")
        #expect(snapshot.entries.first?.url.absoluteString == same)
        #expect(snapshot.entries.map(\.addedAt) == [Date(timeIntervalSinceReferenceDate: 100), Date(timeIntervalSinceReferenceDate: 200)])
        #expect(snapshot.skippedEntries == 2)
    }

    @Test func readingListFallbackAndDates() throws {
        func identity(_ fragment: String, date: Int) throws -> String {
            try #require(ReadingList.parse(listData([["URLString": "https://articles.example/story#\(fragment)", "DateAdded": date]])).entries.first).id
        }
        #expect(try identity("a", date: 1) == identity("b", date: 1))
        #expect(try identity("a", date: 1) != identity("a", date: 2))
        #expect(ReadingList.date(true) == nil)
        #expect(ReadingList.date(Double.infinity) == nil)
        #expect(ReadingList.date("2001-01-01T00:00:01Z") == Date(timeIntervalSinceReferenceDate: 1))
        #expect(ReadingList.date("2001-01-01T00:00:01.500Z") == Date(timeIntervalSinceReferenceDate: 1.5))
    }

    @Test func readingListNewestFirstUpdatesAfterRefreshAndCatalogReload() throws {
        func entry(_ id: String, saved: TimeInterval) -> ReadingListEntry {
            ReadingListEntry(id: id, safariID: id, url: URL(string: "https://articles.example/\(id)")!,
                             title: id, addedAt: Date(timeIntervalSinceReferenceDate: saved))
        }
        let oldest = entry("oldest", saved: 1), middle = entry("middle", saved: 2), newest = entry("newest", saved: 3)
        var catalog = ReadingListCatalog()
        catalog.reconcile(ReadingListSnapshot(entries: [oldest, middle], skippedEntries: 0))
        #expect(catalog.newestFirstEntries.map(\.id) == ["middle", "oldest"])
        catalog.reconcile(ReadingListSnapshot(entries: [oldest, middle, newest], skippedEntries: 0))
        #expect(catalog.newestFirstEntries.map(\.id) == ["newest", "middle", "oldest"])
        #expect(catalog.entries.map(\.id) == ["oldest", "middle", "newest"])
        let reloaded = try JSONDecoder().decode(ReadingListCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(reloaded.newestFirstEntries == catalog.newestFirstEntries)
        // Reconciliation corrects saved dates and removes absent entries after a successful read.
        catalog.reconcile(ReadingListSnapshot(entries: [entry("oldest", saved: 4)], skippedEntries: 0))
        #expect(catalog.newestFirstEntries.map(\.id) == ["oldest"])
    }

    @Test func readingListNewestFirstKeepsEqualAndMissingDatesStable() {
        let entries = ["undated-one", "dated-one", "undated-two", "dated-two"].map { id in
            ReadingListEntry(id: id, safariID: id, url: URL(string: "https://articles.example/\(id)")!,
                             title: id, addedAt: id.hasPrefix("undated") ? nil : Date(timeIntervalSinceReferenceDate: 1))
        }
        var catalog = ReadingListCatalog()
        #expect(catalog.newestFirstEntries.isEmpty)
        catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
        #expect(catalog.newestFirstEntries.map(\.id) == ["dated-one", "dated-two", "undated-one", "undated-two"])
        #expect(catalog.entries == entries)
    }

    @Test func readingListReadDoesNotMutateAndFailuresRetainInventory() throws {
        let root = try reviewTemporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Bookmarks.plist")
        let bytes = try listData([["URLString": "https://articles.example/a", "WebBookmarkUUID": "A"]])
        try bytes.write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        var catalog = ReadingListCatalog(); catalog.reconcile(try ReadingList.read(file))
        catalog.excludedIDs.insert("safari:A")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
        let updated = ReadingListEntry(id: "safari:B", safariID: "B", url: URL(string: "https://articles.example/b")!, title: "New", addedAt: nil)
        catalog.reconcile(ReadingListSnapshot(entries: [updated, updated], skippedEntries: 0))
        #expect(catalog.entries.map(\.id) == ["safari:B"])
        #expect(catalog.currentIDs == ["safari:B"] && catalog.excludedIDs == ["safari:A"])
        try Data("incomplete".utf8).write(to: file)
        #expect(throws: RelayError.self) { try ReadingList.read(file) }
        #expect(catalog.entries.count == 1 && catalog.excludedIDs == ["safari:A"])
    }

    @Test func readingListRejectsIncompleteHierarchyAndOversizedInput() throws {
        #expect(throws: RelayError.self) { try ReadingList.parse(Data()) }
        #expect(throws: RelayError.self) { try ReadingList.parse(Data(repeating: 0, count: ReadingList.maximumBytes + 1)) }
        for object: [String: Any] in [["Children": []], ["Title": "com.apple.ReadingList", "Children": "incomplete"]] {
            let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            #expect(throws: RelayError.self) { try ReadingList.parse(bytes) }
        }
        var node: [String: Any] = ["Title": "com.apple.ReadingList", "Children": []]
        for _ in 0..<66 { node = ["Children": [node]] }
        let bytes = try PropertyListSerialization.data(fromPropertyList: node, format: .binary, options: 0)
        #expect(throws: RelayError.self) { try ReadingList.parse(bytes) }
    }

    @Test func articleURLsAndPerHopRedirectPolicy() throws {
        for address in ["file:///private/file", "ftp://articles.example/a", "https://user:secret@articles.example/a", "https://articles.example:0/a"] {
            #expect(throws: SourceFetchError.invalidURL) { try ArticleURL.validate(URL(string: address)!) }
        }
        #expect(try ArticleURL.validate(URL(string: "https://articles.example/a?q=private#section")!).query == "q=private")
        let redirects = FetchRedirects(maximum: 2)
        let http = URL(string: "http://articles.example/a")!, https = URL(string: "https://articles.example/a")!
        #expect(redirects.redirected(from: http, to: https) == nil)
        #expect(redirects.redirected(from: https, to: http) == .insecureRedirect)
        let bounded = FetchRedirects(maximum: 1)
        #expect(bounded.redirected(from: https, to: https) == nil)
        #expect(bounded.redirected(from: https, to: https) == .redirectLimit)
        #expect(FetchRedirects(maximum: 5).redirected(from: https, to: URL(string: "https://user:secret@articles.example/a")!) == .invalidURL)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: https)
        request.setValue("PRIVATE", forHTTPHeaderField: "Authorization")
        request.setValue("PRIVATE", forHTTPHeaderField: "Cookie")
        let capture = CapturedRedirect()
        FetchRedirects(maximum: 1).urlSession(session, task: session.dataTask(with: http),
            willPerformHTTPRedirection: HTTPURLResponse(url: http, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!,
            newRequest: request, completionHandler: { capture.accept($0) })
        #expect(capture.request?.url == https && capture.request?.value(forHTTPHeaderField: "Authorization") == nil
                && capture.request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(throws: SourceFetchError.invalidLimits) { try FetchLimits(maximumBytes: 0) }
        #expect(throws: SourceFetchError.invalidLimits) { try FetchLimits(timeout: .infinity) }
    }

    @Test func articleEncodingHonorsBOMHeaderAndMeta() throws {
        let unicode = "Café 日本語"
        #expect(try PageFetcher.decode(Data(unicode.utf8), declared: nil).text == unicode)
        #expect(try PageFetcher.decode(Data([0xEF, 0xBB, 0xBF]) + Data(unicode.utf8), declared: "windows-1252").text == unicode)
        #expect(try PageFetcher.decode(Data([0xFF, 0xFE]) + #require(unicode.data(using: .utf16LittleEndian)), declared: nil).text == unicode)
        let western = "<meta charset='windows-1252'><p>Café</p>"
        let bytes = try #require(western.data(using: .windowsCP1252))
        #expect(try PageFetcher.decode(bytes, declared: nil).text == western)
        #expect(try PageFetcher.decode(bytes, declared: "windows-1252").text == western)
        #expect(throws: SourceFetchError.unsupportedEncoding) { try PageFetcher.decode(Data([0xFF]), declared: "utf-8") }
        #expect(throws: SourceFetchError.unsupportedEncoding) { try PageFetcher.decode(Data([0xEF, 0xBB, 0xBF, 0xFF]), declared: "windows-1252") }
        #expect(throws: SourceFetchError.unsupportedEncoding) { try PageFetcher.decode(Data("hello".utf8), declared: "unknown") }
    }

    @Test func selectedFetchUsesBoundedPrivateSession() async throws {
        let url = URL(string: "https://source-review.invalid/article?token=PRIVATE")!
        let configuration = fetchConfiguration()
        let page = try await PageFetcher(limits: FetchLimits()).fetch(url, configuration: configuration)
        #expect(page.originalURL == url && page.finalURL == url && page.html.contains("Café 日本語"))
        #expect(page.bytes == Data(page.html.utf8) && page.contentType == "text/html" && page.encoding == "utf-8")
        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies && configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test(arguments: ["status", "pdf", "empty", "oversize", "declared-size", "encoding", "error", "transport-policy"])
    func selectedFetchClassifiesFailuresWithoutPrivateDetails(_ path: String) async throws {
        let expected: [String: SourceFetchError] = ["status": .status(403), "pdf": .invalidPDF, "empty": .empty,
            "oversize": .tooLarge, "declared-size": .tooLarge, "encoding": .unsupportedEncoding, "error": .network, "transport-policy": .transportPolicy]
        do {
            _ = try await PageFetcher(limits: FetchLimits(maximumBytes: 128)).fetch(
                URL(string: "https://source-review.invalid/\(path)?token=PRIVATE")!, configuration: fetchConfiguration())
            Issue.record("Invalid response accepted")
        } catch {
            #expect(error as? SourceFetchError == expected[path])
            #expect(!error.localizedDescription.contains("PRIVATE") && !error.localizedDescription.contains("source-review.invalid"))
        }
    }

    @Test(arguments: ["stall", "body-stall"])
    func selectedFetchDeadlineAndCancellation(_ path: String) async throws {
        let url = URL(string: "https://source-review.invalid/\(path)")!
        let clock = ContinuousClock(); let start = clock.now
        do {
            _ = try await PageFetcher(limits: FetchLimits(timeout: 0.08)).fetch(url, configuration: fetchConfiguration())
            Issue.record("Stalled response accepted")
        } catch { #expect(error as? SourceFetchError == .timeout) }
        #expect(start.duration(to: clock.now) < .seconds(3))
        let task = Task { try await PageFetcher(limits: FetchLimits(timeout: 10)).fetch(url, configuration: fetchConfiguration()) }
        try await Task.sleep(for: .milliseconds(40)); task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled response accepted") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: clock.now) < .seconds(3))
    }

    @Test func sourceReviewKeepsProvenanceAndNarration() throws {
        let html = try String(decoding: FixtureResource.html(), as: UTF8.self)
        let review = try ReviewedSource.prepare(sourcePage(html), chunkLimit: 140)
        let document = try #require(review.document); let narration = try #require(review.narration)
        #expect(review.issue == nil && document.article.originalURL == review.page.originalURL && document.article.finalURL == review.page.finalURL)
        #expect(document.article.canonicalURL?.path == "/private-canonical")
        #expect(document.article.blocks.contains { $0.kind == .quote })
        #expect(narration.chunks.allSatisfy { $0.text.count <= 140 } && !narration.chunks.isEmpty)
    }

    @Test(arguments: ["Sign in | Synthetic", "Cookie consent", "Access denied", "Empty"])
    func sourceReviewFlagsPagesForManualInspection(_ title: String) throws {
        let expected: [String: SourceReviewIssue] = ["Sign in | Synthetic": .login, "Cookie consent": .consent, "Access denied": .accessBlocked, "Empty": .extraction]
        let review = try ReviewedSource.prepare(sourcePage("<html><title>\(title)</title><body></body></html>"), chunkLimit: 140)
        #expect(review.issue == expected[title] && review.document == nil && review.narration == nil)
    }

    @Test func privateReviewArchivePreservesBytesAndPermissions() throws {
        let root = try reviewTemporary(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try ReviewedSource.prepare(sourcePage(String(decoding: FixtureResource.html(), as: UTF8.self)), chunkLimit: 140)
        let destination = root.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let folder = try SourceReviewArchive.save(review, root: destination)
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int == 0o700)
        #expect(UUID(uuidString: folder.lastPathComponent) != nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("source.html")) == review.page.bytes)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("response.json"))) as? [String: Any])
        #expect(manifest["sourceHash"] as? String == Files.hash(review.page.bytes))
        #expect(manifest["originalURL"] as? String == review.page.originalURL.absoluteString && manifest["finalURL"] as? String == review.page.finalURL.absoluteString)
        for file in ["source.html", "article.json", "cleaned.html", "narration.json", "response.json"] {
            #expect(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try SourceReviewArchive.save(review, root: folder.deletingLastPathComponent()) != folder)
    }

    @Test func privateReviewArchiveRejectsUnownedProtectedAndSymlinkedFolders() throws {
        let root = try reviewTemporary(); defer { try? FileManager.default.removeItem(at: root) }
        let review = ReviewedSource(page: sourcePage("<html></html>"), document: nil, narration: nil, issue: .extraction)
        try Data("untouched".utf8).write(to: root.appendingPathComponent("existing"))
        #expect(throws: RelayError.self) { try SourceReviewArchive.save(review, root: root) }
        #expect(try Data(contentsOf: root.appendingPathComponent("existing")) == Data("untouched".utf8))
        let owned = root.appendingPathComponent("owned"); try Files.directory(owned)
        let marker = root.appendingPathComponent("outside-marker"); try Data("VoiceRelay private source review v1\n".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent(".voicerelay-source-review"), withDestinationURL: marker)
        #expect(throws: RelayError.self) { try SourceReviewArchive.save(review, root: owned) }
        let profile = PrototypeProfile.fixture(at: root.appendingPathComponent("fixture"))
        #expect(throws: RelayError.self) { try SourceReviewArchive.save(review, root: profile.audio.appendingPathComponent("private"), imported: profile) }
        #expect(!FileManager.default.fileExists(atPath: profile.audio.path))
        #expect(throws: RelayError.self) {
            try SourceReviewArchive.save(review, root: profile.audio.appendingPathComponent("private"), excluding: [root.appendingPathComponent("fixture")])
        }
        let marked = root.appendingPathComponent("marked-fixture"); try Files.directory(marked)
        try Data("VoiceRelay isolated fixture workspace v1\n".utf8).write(to: marked.appendingPathComponent(".voicerelay-fixture"))
        #expect(throws: RelayError.self) { try SourceReviewArchive.save(review, root: marked.appendingPathComponent("media/new-private-folder")) }
        #expect(!FileManager.default.fileExists(atPath: marked.appendingPathComponent("media").path))
        let folder = try SourceReviewArchive.save(review, root: root.appendingPathComponent("failed-source"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("article.json").path))
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("response.json"))) as? [String: Any])
        #expect(manifest["issue"] as? String == "extraction")
    }
}

@Test func articlePreviewMetadataUsesStandardsWithoutFetchingImages() throws {
    let body = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let base = URL(string: "https://articles.example/path/article")!
    let cases: [(String, String?)] = [
        ("<meta property='og:image' content='/images/share.jpg?size=large&amp;v=2'>", "https://articles.example/images/share.jpg?size=large&v=2"),
        ("<meta property='og:image' content='http://images.example/insecure.jpg'><meta property='og:image:secure_url' content='https://images.example/secure.jpg'>", "https://images.example/secure.jpg"),
        ("<meta name='twitter:image' content='../card.png'>", "https://articles.example/card.png"),
        ("<meta property='og:image' content='https://user:password@images.example/private.jpg'><meta name='twitter:image:src' content='//images.example/public.jpg'>", "https://images.example/public.jpg"),
        ("<meta property='og:image' content='data:image/png;base64,abcd'><meta property='og:image' content='file:///private/image.png'>", nil),
        ("", nil)
    ]
    for (meta, expected) in cases {
        let html = body.replacingOccurrences(of: "</head>", with: "<meta property='og:site_name' content='Synthetic &amp; Source'>" + meta + "</head>")
        let document = try ArticleExtractor.extract(html: html, originalURL: base, finalURL: base)
        #expect(document.article.previewImageURL?.absoluteString == expected)
        #expect(document.article.sourceName == "Synthetic & Source")
        let decoded = try JSONDecoder().decode(SemanticArticle.self, from: Files.json(document.article))
        #expect(decoded == document.article)
    }
}

@Test func narrationAddsTitleSourceAndSeparateEndParagraphWithBoundedProvenance() throws {
    let url = URL(string: "https://articles.example/story")!
    let article = SemanticArticle(title: "A title?", originalURL: url, finalURL: url, canonicalURL: nil,
        author: nil, blocks: [ContentBlock(kind: .paragraph, text: "Original first paragraph."), ContentBlock(kind: .paragraph, text: "Original final paragraph.")],
        warnings: [], extractorVersion: ArticleExtractor.version, sourceName: "Synthetic News")
    let plan = try Narration.prepare(article, limit: 1800)
    #expect(plan.chunks.map(\.text) == ["A title? Source: Synthetic News.", "Original first paragraph.", "Original final paragraph.", "End of article."])
    #expect(plan.chunks.map(\.blockIndices) == [[], [0], [1], []])
    #expect(plan.chunks.map(\.index) == [0, 1, 2, 3])
    var legacy = try #require(JSONSerialization.jsonObject(with: Files.json(article)) as? [String: Any])
    legacy.removeValue(forKey: "sourceName"); legacy.removeValue(forKey: "previewImageURL")
    let older = try JSONDecoder().decode(SemanticArticle.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(older.sourceName == nil && older.previewImageURL == nil)
    #expect(try Narration.prepare(older, limit: 1800).chunks.first?.text == "A title? Source: articles.example.")
    let bounded = try Narration.prepare(article, limit: 8)
    #expect(bounded.chunks.allSatisfy { $0.text.count <= 8 })
    #expect(article.blocks.map(\.text) == ["Original first paragraph.", "Original final paragraph."])
}

private actor ArchiveFixture {
    let original: URL
    let outcome: String
    var calls: [URL] = []
    init(_ original: URL, outcome: String = "archive") { self.original = original; self.outcome = outcome }
    func fetch(_ url: URL, limits: FetchLimits, types: Set<String>, hosts: Set<String>) throws -> FetchedPage {
        calls.append(url)
        #expect(limits.timeout <= 10 && limits.maximumRedirects == 3)
        #expect(hosts.contains(url.host!))
        var body: String, type: String
        if url.host == "archive.ph" && url.path.hasPrefix("/timemap/") {
            if outcome == "cancel" { throw CancellationError() }
            if outcome == "wayback" || outcome == "missing" { throw SourceFetchError.status(503) }
            body = """
            <\(original.absoluteString)>; rel="original",
            <https://archive.ph/Older>; rel="first memento"; datetime="Thu, 01 Jan 2026 00:00:00 GMT",
            <https://archive.ph/Newer>; datetime="Sun, 01 Feb 2026 00:00:00 GMT"; rel="last memento"
            """
            type = "application/link-format"
        } else if url.host == "archive.org" {
            type = "application/json"
            body = outcome == "missing" || outcome == "challenge" || outcome == "oversize" ? "{\"archived_snapshots\":{}}" : """
            {"archived_snapshots":{"closest":{"available":true,"status":"200","timestamp":"20260101000000","url":"http://web.archive.org/web/20260101000000/\(original.absoluteString)"}}}
            """
        } else {
            type = "text/html"
            body = String(decoding: try FixtureResource.html(), as: UTF8.self)
            if outcome == "challenge" { body = "<html><title>Article</title><body><form action='/captcha/'></form>\(body)</body></html>" }
            if outcome == "oversize" { body = String(repeating: "x", count: limits.maximumBytes + 1) }
        }
        #expect(types.contains(type))
        return FetchedPage(originalURL: url, finalURL: url, bytes: Data(body.utf8), html: body,
                           contentType: type, encoding: "utf-8", fetchedAt: .distantPast)
    }
}

@Test func archiveRecoveryKeepsOriginalIdentitySourceAndDurableProvenance() async throws {
    let url = URL(string: "https://articles.example/story")!, fixture = ArchiveFixture(URL(string: "https://articles.example/story")!)
    let saved = Date(timeIntervalSince1970: 1_767_225_600) // January 1, 2026 UTC
    let log = DeliveryDebugLog(); log.enabled = true
    let loader = ArticleSourceLoader(limits: try FetchLimits(), useArchives: true, fetch: { _ in throw SourceFetchError.status(404) },
        archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) }, debugLog: log)
    let review = try await loader.load(url, savedAt: saved, chunkLimit: 1800)
    let article = try #require(review.document?.article)
    #expect(review.issue == nil && review.page.originalURL == url && article.originalURL == url)
    #expect(review.page.finalURL.absoluteString == "https://archive.ph/Older")
    #expect(article.archivedCopy?.capturedAt == saved && article.archivedCopy?.provider == .archiveToday)
    #expect(review.narration?.chunks.first?.text.contains("Source: articles.example") == true)
    let restored = try StoredExtraction(review: review, chunkLimit: 1800).review()
    #expect(restored.document?.article == article && restored.page.archivedCopy == review.page.archivedCopy)
    #expect(await fixture.calls.count == 2)
    #expect(log.text.contains("archiveToday recovered"))
    #expect(!log.text.contains("articles.example") && !log.text.contains("Older"))
}

@Test func archiveRecoveryUsesWaybackRawReplayAfterArchiveTodayFailure() async throws {
    let url = URL(string: "https://articles.example/story")!, fixture = ArchiveFixture(URL(string: "https://articles.example/story")!, outcome: "wayback")
    let loader = ArticleSourceLoader(limits: try FetchLimits(), useArchives: true, fetch: { _ in throw SourceFetchError.authentication },
        archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) })
    let review = try await loader.load(url, savedAt: Date(timeIntervalSince1970: 1_767_225_600), chunkLimit: 1800)
    #expect(review.page.archivedCopy?.provider == .wayback)
    #expect(review.page.finalURL.absoluteString == "https://web.archive.org/web/20260101000000id_/https://articles.example/story")
    let calls = await fixture.calls
    #expect(calls.count == 3)
    #expect(URLComponents(url: calls[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "timestamp" })?.value == "20260101000000")
}

@Test(arguments: ["missing", "challenge", "oversize"])
func archiveRecoveryNeverQueuesUnavailableChallengeOrOversizedCopies(_ outcome: String) async throws {
    let url = URL(string: "https://articles.example/story")!, fixture = ArchiveFixture(URL(string: "https://articles.example/story")!, outcome: outcome)
    let loader = ArticleSourceLoader(limits: try FetchLimits(maximumBytes: 100_000), useArchives: true,
        fetch: { _ in throw SourceFetchError.status(403) }, archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) })
    do { _ = try await loader.load(url, chunkLimit: 1800); Issue.record("Unreadable cached copy accepted") }
    catch { #expect(error is ArticleRecoveryError); #expect(!error.localizedDescription.contains(url.absoluteString)) }
    #expect(await fixture.calls.count <= 3)
}

@Test func archiveRecoveryOptOutGoodOriginalAndCancellationMakeNoAdditionalRequests() async throws {
    let url = URL(string: "https://articles.example/story")!, fixture = ArchiveFixture(URL(string: "https://articles.example/story")!, outcome: "cancel")
    let fetch: ArticleSourceLoader.ArchiveFetch = { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) }
    let original: ArticleSourceLoader.Fetch = { url in
        let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
        return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    }
    let good = try await ArticleSourceLoader(limits: FetchLimits(), useArchives: true, fetch: original, archiveFetch: fetch).load(url, chunkLimit: 1800)
    #expect(good.page.archivedCopy == nil && good.issue == nil)
    #expect(await fixture.calls.isEmpty)
    do { _ = try await ArticleSourceLoader(limits: FetchLimits(), fetch: { _ in throw SourceFetchError.status(404) }, archiveFetch: fetch).load(url, chunkLimit: 1800); Issue.record("Disabled recovery fetched") }
    catch { #expect(error as? SourceFetchError == .status(404)) }
    #expect(await fixture.calls.isEmpty)
    do { _ = try await ArticleSourceLoader(limits: FetchLimits(), useArchives: true, fetch: { _ in throw SourceFetchError.status(404) }, archiveFetch: fetch).load(url, chunkLimit: 1800); Issue.record("Cancelled recovery succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(await fixture.calls.count == 1)
}

@Test func archiveRecoveryRejectsPrivateURLsWrongArticleAndForeignSnapshotHosts() throws {
    for raw in ["https://localhost/story", "https://localhost./story", "https://device.local/story", "https://host.lan/story", "https://device.ts.net/story", "https://127.0.0.1/story", "https://[::1]/story", "https://user:secret@articles.example/story", "https://articles.example/story?token=PRIVATE", "https://articles.example:8443/story"] {
        #expect(ArticleSourceLoader.lookupURL(URL(string: raw)!) == nil)
    }
    let original = URL(string: "https://articles.example/story")!
    #expect(ArticleSourceLoader.lookupURL(URL(string: "https://articles.example/story#section")!) == original)
    for raw in ["https://evil.example/Abc12", "https://archive.ph/submit/", "https://archive.ph/wip/Abc12", "https://archive.ph/Abc12?secret=x", "https://archive.ph:8443/Abc12"] {
        #expect(ArticleSourceLoader.snapshotURL(URL(string: raw)!, provider: .archiveToday, original: original) == nil)
    }
    #expect(ArticleSourceLoader.snapshotURL(URL(string: "https://web.archive.org/web/20260101000000/https://elsewhere.example/story")!, provider: .wayback, original: original) == nil)
    let map = "<https://elsewhere.example/story>; rel=\"original\", <https://archive.ph/Abc12>; rel=\"memento\"; datetime=\"Thu, 01 Jan 2026 00:00:00 GMT\""
    #expect(try ArticleSourceLoader.capture(map, provider: .archiveToday, original: original, savedAt: nil) == nil)
    let redirects = FetchRedirects(maximum: 3, allowedHosts: ArticleArchive.archiveToday.hosts)
    let from = URL(string: "https://archive.ph/Abc12")!
    #expect(redirects.redirected(from: from, to: URL(string: "https://archive.is/Abc12")!) == nil)
    #expect(redirects.redirected(from: from, to: original) == .invalidURL)
    #expect(FetchRedirects(maximum: 3, allowedHosts: ArticleArchive.archiveToday.hosts).redirected(from: from, to: URL(string: "https://archive.ph:8443/Abc12")!) == .invalidURL)
}

@Test func archiveRecoveryAlsoHandlesValidatedLoginAndSubscriptionPages() async throws {
    let url = URL(string: "https://articles.example/story")!, fixture = ArchiveFixture(URL(string: "https://articles.example/story")!)
    let loader = ArticleSourceLoader(limits: try FetchLimits(), useArchives: true, fetch: { url in
        let html = "<html><title>Sign in | Publisher</title><body>Please log in.</body></html>"
        return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    }, archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) })
    #expect(try await loader.load(url, chunkLimit: 1800).page.archivedCopy != nil)
    let html = "<html><title>Publisher article</title><body><article><h1>Publisher article</h1><p>\(String(repeating: "Some introductory article text. ", count: 6)) Subscribe to continue reading.</p></article></body></html>"
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    #expect(try ReviewedSource.prepare(page, chunkLimit: 1800).issue == .subscription)
}

@Test func archiveRecoveryRemovesTrackingButPreservesQueueIdentitySavedDateAndOfflineReuse() async throws {
    let url = URL(string: "https://articles.example/story?utm_source=PRIVATE&mc_eid=PRIVATE#section")!
    let lookup = URL(string: "https://articles.example/story")!
    #expect(ArticleSourceLoader.lookupURL(url) == lookup)
    let fixture = ArchiveFixture(lookup)
    let root = try reviewTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let entry = ReadingListEntry(id: "archive-entry", safariID: nil, url: url, title: "Original entry", addedAt: Date(timeIntervalSince1970: 1_767_225_600))
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(),
        fetch: { _ in throw SourceFetchError.status(410) }, useArchives: true,
        archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) })
    #expect(item.sourceHost == "articles.example" && item.state == .queued)
    let episode = try #require(try await coordinator.library(storage: storage).first)
    #expect(episode.readingListSavedAt == entry.addedAt)
    let store = try NativeStore(url: storage.profile.database, readOnly: true)
    #expect(try store.existingEpisode(sourceKey: "reviewed-url-v1-" + Files.hash(Data(url.absoluteString.utf8)))?.id == episode.id)
    let readded = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { _ in
        Issue.record("Saved archived text refetched"); throw SourceFetchError.network
    }, useArchives: true, archiveFetch: { _, _, _, _ in
        Issue.record("Saved archived text queried an archive"); throw SourceFetchError.network
    })
    #expect(readded.id == item.id && readded.sourceHost == "articles.example")
    let calls = await fixture.calls
    #expect(calls.count == 2 && calls.allSatisfy { !$0.absoluteString.contains("PRIVATE") })
}

@Test func archiveRecoveryUnavailableReviewAndUnsafeFetchFailurePreserveOriginalOutcome() async throws {
    let url = URL(string: "https://articles.example/story")!, fixture = ArchiveFixture(URL(string: "https://articles.example/story")!, outcome: "missing")
    let html = "<html><title>Sign in</title><body>Login required.</body></html>"
    let original = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    let review = try await ArticleSourceLoader(limits: FetchLimits(), useArchives: true, fetch: { _ in original },
        archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) }).load(url, chunkLimit: 1800)
    #expect(review.issue == .login && review.page.finalURL == url && review.page.archivedCopy == nil)
    #expect(review.issueMessage?.contains("No readable archived copy was found") == true)
    let previousCalls = await fixture.calls.count
    for failure in [SourceFetchError.tooLarge, .unsupportedType, .invalidURL] {
        do { _ = try await ArticleSourceLoader(limits: FetchLimits(), useArchives: true, fetch: { _ in throw failure },
            archiveFetch: { try await fixture.fetch($0, limits: $1, types: $2, hosts: $3) }).load(url, chunkLimit: 1800)
            Issue.record("Unsafe original fetch was recovered")
        } catch { #expect(error as? SourceFetchError == failure) }
    }
    #expect(await fixture.calls.count == previousCalls)
}

@Test func archiveRecoveryParsesTimestampReplayLinksAndNormalizesRootURLs() throws {
    // Shape verified against the service's public example.com TimeMap.
    let original = URL(string: "https://example.com")!
    let map = """
    <https://example.com/>; rel="original",
    <http://archive.md/timegate/https://example.com/>; rel="timegate",
    <http://archive.md/20260101000000/http://example.com/>; rel="first memento"; datetime="Thu, 01 Jan 2026 00:00:00 GMT"
    """
    let capture = try #require(try ArticleSourceLoader.capture(map, provider: .archiveToday, original: original, savedAt: nil))
    #expect(capture.snapshotURL.absoluteString == "https://archive.md/20260101000000/http://example.com/")
    #expect(ArticleSourceLoader.snapshotURL(URL(string: "https://archive.md/20260101000000/https://elsewhere.example/")!, provider: .archiveToday, original: original) == nil)
    let ambiguous = map + ", <https://elsewhere.example/>; rel=\"original\""
    #expect(try ArticleSourceLoader.capture(ambiguous, provider: .archiveToday, original: original, savedAt: nil) == nil)
    let wrongDate = """
    {"archived_snapshots":{"closest":{"available":true,"status":"200","timestamp":"20260101000000","url":"https://web.archive.org/web/20260201000000/https://example.com/"}}}
    """
    #expect(try ArticleSourceLoader.capture(wrongDate, provider: .wayback, original: original, savedAt: nil) == nil)
}

@Test func archiveRecoveryRetainsPublisherAttributionAndOmitsArchiveArtwork() throws {
    let original = URL(string: "https://articles.example/story")!, snapshot = URL(string: "https://archive.ph/Abc12")!
    let copy = ArchivedArticleCopy(provider: .archiveToday, snapshotURL: snapshot, capturedAt: .distantPast)
    for (name, image, expectedSource, expectedImage) in [
        ("archive.ph", "https://archive.ph/Abc12/image.jpg", "articles.example", nil as String?),
        ("Original Publisher", "https://images.example/art.jpg", "Original Publisher", "https://images.example/art.jpg")
    ] {
        let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
            .replacingOccurrences(of: "</head>", with: "<meta property='og:site_name' content='\(name)'><meta property='og:image' content='\(image)'></head>")
        let page = FetchedPage(originalURL: original, finalURL: snapshot, bytes: Data(html.utf8), html: html,
            contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast, archivedCopy: copy)
        let review = try ReviewedSource.prepare(page, chunkLimit: 1800)
        #expect(review.document?.article.sourceName == expectedSource)
        #expect(review.document?.article.previewImageURL?.absoluteString == expectedImage)
    }
}

@Test func removedReadingListCachesPurgeWaitingWorkAndAllowFreshReaddition() async throws {
    let root = try reviewTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let url = URL(string: "https://articles.example/removed")!
    let entry = ReadingListEntry(id: "removed", safariID: nil, url: url, title: "Removed", addedAt: .distantPast)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let review = try ReviewedSource.prepare(FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
        contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id)
    let work = storage.profile.work.appendingPathComponent(item.id)
    try Files.directory(work); try Files.write(Data("private cached article".utf8), to: work.appendingPathComponent("cached.txt"))
    let unchanged = storage.profile.work.appendingPathComponent("unrelated.txt")
    try Files.write(Data("unrelated".utf8), to: unchanged)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
    #expect(try await coordinator.catalog(stateRoot: storage.stateRoot).entries.isEmpty)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let lease = try PipelineLease(database: storage.profile.database)
    await #expect(throws: RelayError.self) { try await coordinator.purgeRemovedReadingListCaches(storage: storage) }
    #expect(FileManager.default.fileExists(atPath: work.path))
    lease.release()
    try await coordinator.purgeRemovedReadingListCaches(storage: storage)
    #expect(!FileManager.default.fileExists(atPath: work.path))
    #expect(try Data(contentsOf: unchanged) == Data("unrelated".utf8))
    #expect(try await coordinator.library(storage: storage).isEmpty)
    let reader = try NativeStore(url: storage.profile.database, readOnly: true)
    #expect(try reader.snapshot(articleID: item.id) == nil)
    #expect(try reader.queue().isEmpty)
    try await coordinator.purgeRemovedReadingListCaches(storage: storage) // restart/idempotence
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let readded = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id)
    #expect(readded.id != item.id && readded.state == .queued)
}

@Test func removedReadingListCacheFailureContinuesOtherItemsAndRetriesSafely() async throws {
    let root = try reviewTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator(), html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let entries = ["one", "two"].map { ReadingListEntry(id: $0, safariID: nil,
        url: URL(string: "https://articles.example/" + $0)!, title: $0, addedAt: nil) }
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0), stateRoot: storage.stateRoot)
    var items: [SpeechQueueItem] = []
    for entry in entries {
        let review = try ReviewedSource.prepare(FetchedPage(originalURL: entry.url, finalURL: entry.url, bytes: Data(html.utf8), html: html,
            contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
        items.append(try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id))
    }
    let outside = root.appendingPathComponent("unowned")
    try Files.directory(outside); try Files.write(Data("keep".utf8), to: outside.appendingPathComponent("private.txt"))
    let link = storage.profile.work.appendingPathComponent(items[0].id)
    try Files.directory(storage.profile.work)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
    await #expect(throws: RelayError.self) { try await coordinator.purgeRemovedReadingListCaches(storage: storage) }
    #expect(try Data(contentsOf: outside.appendingPathComponent("private.txt")) == Data("keep".utf8))
    #expect(try await coordinator.library(storage: storage).map(\.id) == [items[0].id])
    try FileManager.default.removeItem(at: link)
    try await coordinator.purgeRemovedReadingListCaches(storage: storage)
    #expect(try await coordinator.library(storage: storage).isEmpty)
}


@Test func reviewedArticleUsesCapturedVoiceDictionaryAndSpokenFormNotices() async throws {
    let url = URL(string: "https://articles.example/normalization")!
    let prose = String(repeating: "Package A carries 2 kg beside SQLite at 18°C before 9:05 pm. A car carries a book. ", count: 10)
    let html = "<html><title>Synthetic</title><body><article><p>" + prose + "</p></article></body></html>"
    let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
    let loader = ArticleSourceLoader(limits: try FetchLimits(), fetch: { _ in
        FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: Date(timeIntervalSince1970: 0))
    }, describeImages: false, speechSettings: .init(voice: "bf_emma"), pronunciations: dictionary)
    let result = try await loader.load(url, chunkLimit: 480)
    let narration = try #require(result.narration)
    let spoken = narration.chunks.map(\.text).joined(separator: " ")
    #expect(spoken.contains("Package ay carries 2 kilograms beside sequel lite at 18 degrees Celsius before 9 oh 5 p.m."))
    #expect(narration.notices.contains { $0.contains("Spoken forms expanded") && $0.contains("en_GB") })
    #expect(result.document?.article.blocks.map(\.text).joined().contains("SQLite at 18°C") == true)
    #expect(spoken.contains("A car carries a book."))
    #expect(result.document?.article.blocks.map(\.text).joined().contains("Package A carries") == true)
    #expect(narration.version.contains(dictionary.fingerprint))
}
