import Foundation
import SwiftSoup
import Testing
@testable import VoiceRelayCore

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
        #expect(try dom.select("figcaption").count == 1)
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
        #expect(plan.chunks.map(\.text) == ["Keep 2026 and ordinary wording.", "Footnote:", "First note paragraph with an apostrophe: isn’t.",
            "Second note paragraph.", "End Footnote", "Continue here."])
        #expect(plan.chunks[1].blockIndices == [0, 2, 3] && plan.chunks[2].blockIndices == [2])
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
        #expect(catalog.entries.map(\.id) == ["safari:A", "safari:B"])
        #expect(catalog.currentIDs == ["safari:B"] && catalog.excludedIDs == ["safari:A"])
        try Data("incomplete".utf8).write(to: file)
        #expect(throws: RelayError.self) { try ReadingList.read(file) }
        #expect(catalog.entries.count == 2 && catalog.excludedIDs == ["safari:A"])
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
        let expected: [String: SourceFetchError] = ["status": .status(403), "pdf": .unsupportedType, "empty": .empty,
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
