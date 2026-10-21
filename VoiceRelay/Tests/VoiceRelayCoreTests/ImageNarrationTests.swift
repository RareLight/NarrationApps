import Foundation
import Testing
@testable import VoiceRelayCore

private final class ImageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0, captions = 0
    func fetched() { lock.withLock { fetches += 1 } }
    func captioned() { lock.withLock { captions += 1 } }
    var counts: (Int, Int) { lock.withLock { (fetches, captions) } }
}
private func imageReview() throws -> ReviewedSource {
    let url = URL(string: "https://articles.example/story")!
    let prose = String(repeating: "An authored paragraph describes this synthetic article and stays in its original reading order. ", count: 8)
    let html = """
    <html><head><title>Synthetic article</title></head><body><article><p>\(prose)</p>
    <figure><img src="https://images.example/one.jpg" alt="A red boat beside the pier."><figcaption>Image Credit: Example Agency</figcaption></figure>
    <p>\(prose)</p><p><picture><source srcset="/unused.webp"><img src="https://images.example/two.jpg"></picture></p>
    <figure><img src="https://images.example/three.jpg"></figure>
    <figure><img src="https://images.example/three.jpg"></figure>
    <figure><img src="https://private.local/no.jpg"></figure></article></body></html>
    """
    return try ReviewedSource.prepare(FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 180)
}

@Test func authoredImageAltBecomesNarrationWhileExplicitDecorationsStaySilent() throws {
    let blocks = try ArticleExtractor.semanticBlocks(html: """
        <p>Before.<img alt="A red boat."><span>After.</span></p>
        <figure><picture><img alt="A green forest."></picture></figure>
        <img alt="" src="https://images.example/decorative.jpg">
        <div aria-hidden="true"><img alt="Hidden icon."></div>
        <img width="1" height="1" alt="Tracking pixel.">
        """, baseURL: URL(string: "https://articles.example")!)
    let spoken = blocks.map { $0.narrationText ?? $0.text }.joined(separator: " ")
    #expect(spoken.contains("Image description: A red boat.") && spoken.contains("Image description: A green forest."))
    #expect(spoken.contains("Before.") && spoken.contains("After."))
    #expect(!spoken.contains("Hidden icon") && !spoken.contains("Tracking pixel"))
}

@Test func repeatedImageCreditsAreSuppressedWithoutErasingDistinctCaptionsOrAuthoredProse() throws {
    let blocks = [ContentBlock(kind: .caption, text: "A harbor. Image Credit: Example Agency."),
        ContentBlock(kind: .paragraph, text: "An authored sentence."),
        ContentBlock(kind: .caption, text: "A forest. Photo credit: EXAMPLE AGENCY"),
        ContentBlock(kind: .caption, text: "Image Credit: Other Agency"),
        ContentBlock(kind: .paragraph, text: "Image Credit: Example Agency is an authored statement.")]
    let article = SemanticArticle(title: "Synthetic", originalURL: URL(string: "https://articles.example")!, finalURL: URL(string: "https://articles.example")!, canonicalURL: nil, author: nil, blocks: blocks, warnings: [], extractorVersion: ArticleExtractor.version)
    let plan = try Narration.prepare(article, limit: 180)
    let text = plan.chunks.map(\.text).joined(separator: " ")
    #expect(text.contains("A harbor.") && text.contains("A forest.") && !text.contains("EXAMPLE AGENCY"))
    #expect(text.contains("Other Agency") && text.contains("is an authored statement."))
    #expect(article.blocks == blocks && plan.notices.contains("Repeated image credit omitted from narration."))
    #expect(Narration.chunkFingerprintVersion(Narration.version) == Narration.chunkFingerprintVersion(Narration.version.replacingOccurrences(of: "/image-captions-1", with: "")))
}

@Test func imageEnrichmentPrefersAltDeduplicatesAndContinuesAfterPerImageFailure() async throws {
    let review = try imageReview(), probe = ImageProbe(), log = DeliveryDebugLog(); log.enabled = true
    let result = try await ImageNarration.enrich(review, chunkLimit: 180, nativeEnabled: false, fetch: { url in
        probe.fetched()
        if url.lastPathComponent == "two.jpg" { throw RelayError.setup("PRIVATE failure with URL") }
        return Data("synthetic-image".utf8)
    }, caption: { _ in probe.captioned(); return "A snowy mountain above a lake." }, debugLog: log)
    let spoken = try #require(result.narration).chunks.map(\.text).joined(separator: " ")
    #expect(spoken.contains("A red boat beside the pier.") && spoken.contains("A snowy mountain above a lake."))
    #expect(spoken.components(separatedBy: "A snowy mountain").count == 2)
    #expect(probe.counts.0 == 2 && probe.counts.1 == 1)
    #expect(result.page.bytes == review.page.bytes && result.document!.article.blocks.filter { $0.imageDescriptionGenerated == true }.count == 1)
    #expect(!log.text.contains("PRIVATE") && !log.text.contains("images.example"))
    let snapshot = try StoredExtraction(review: result, chunkLimit: 180).review()
    #expect(snapshot.narration == result.narration && snapshot.document?.article == result.document?.article)
}

@Test func injectedLoadersNeverFetchImagesOrInvokeNativeModelsWithoutExplicitProviders() async throws {
    let review = try imageReview()
    let loaded = try await ArticleSourceLoader(limits: FetchLimits(), fetch: { _ in review.page }).load(review.page.originalURL, chunkLimit: 180)
    #expect(!loaded.document!.article.blocks.contains { $0.imageDescriptionGenerated == true })
    #expect(loaded.narration!.chunks.map(\.text).joined().contains("A red boat"))
    for value in ["http://images.example/a.jpg", "https://127.0.0.1/a.jpg", "https://private.local/a.jpg", "https://user:pw@images.example/a.jpg"] {
        #expect(!ImageNarration.eligible(URL(string: value)!))
    }
    #expect(ImageNarration.eligible(URL(string: "https://images.example/a.jpg?width=800")!))
    #expect(ImageNarration.cleanDescription("NONE") == nil)
    #expect(ImageNarration.cleanDescription(String(repeating: "word ", count: 100))!.split(separator: " ").count == 35)
}

@Test func disablingGeneratedImageDescriptionsStillNarratesAuthoredAlt() async throws {
    let review = try imageReview(), probe = ImageProbe()
    let loader = ArticleSourceLoader(limits: try FetchLimits(), fetch: { _ in review.page },
        imageFetch: { _ in probe.fetched(); return Data() }, imageCaption: { _ in probe.captioned(); return "Unused" }, describeImages: false)
    let result = try await loader.load(review.page.originalURL, chunkLimit: 180)
    #expect(probe.counts.0 == 0 && probe.counts.1 == 0)
    #expect(result.narration!.chunks.map(\.text).joined().contains("A red boat"))
}

@Test func imageEnrichmentCancellationJoinsTheOwnedCaptionTask() async throws {
    let review = try imageReview(), probe = ImageProbe()
    let work = Task {
        try await ImageNarration.enrich(review, chunkLimit: 180, nativeEnabled: false, fetch: { _ in Data("synthetic".utf8) },
            caption: { _ in probe.captioned(); try await Task.sleep(for: .seconds(10)); return "Never completed" })
    }
    let deadline = Date().addingTimeInterval(5)
    while probe.counts.1 == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.counts.1 == 1)
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
}
