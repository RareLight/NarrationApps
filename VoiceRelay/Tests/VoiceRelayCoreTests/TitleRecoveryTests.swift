import Foundation
import Testing
import DocumentProcessing
@testable import VoiceRelayCore

private func titlePage(_ url: URL) -> FetchedPage {
    let html = "<html><head><title>Untitled article</title></head><body><article><p>Coastal wetlands protect surrounding communities from storm damage. This synthetic article examines restoration projects and explains how vegetation reduces wave energy. Researchers compared restored habitats over several years and found that healthy ecosystems can help communities adapt to a changing climate.</p></article></body></html>"
    return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
}
private func titleSnapshot(_ id: String, storage: ManagedSpeechStorage) throws -> ReviewedSource {
    let store = try NativeStore(url: storage.profile.database, readOnly: true)
    let bytes = try #require(try store.snapshot(articleID: id))
    return try JSONDecoder().decode(StoredExtraction.self, from: bytes).review()
}

@Test func titleRecoveryHonorsOptInAndInjectedTransportIsolation() async throws {
    let url = URL(string: "https://articles.example/report.pdf")!
    let fake: DocumentTitles.Generate = { _ in "Wetland Restoration Protects Coastal Communities" }
    let off = try await ArticleSourceLoader(limits: .init(), fetch: { titlePage($0) }, describeImages: false,
        titleGenerator: { _ in Issue.record("Disabled generation must stay inert"); return nil }).load(url, chunkLimit: 180)
    #expect(off.document?.article.titleOrigin != .generated)
    let inert = try await ArticleSourceLoader(limits: .init(), fetch: { titlePage($0) }, describeImages: false,
        generateMissingTitles: true).load(url, chunkLimit: 180)
    #expect(inert.document?.article.titleOrigin != .generated)
    let generated = try await ArticleSourceLoader(limits: .init(), fetch: { titlePage($0) }, describeImages: false,
        generateMissingTitles: true, titleGenerator: fake).load(url, chunkLimit: 180)
    #expect(generated.document?.article.titleOrigin == .generated)
    #expect(generated.narration?.chunks.first?.text.hasPrefix("Wetland Restoration Protects Coastal Communities") == true)
    let source = try await ArticleSourceLoader(limits: .init(), fetch: { titlePage($0) }, describeImages: false,
        sourceTitle: "How Coastal Habitats Reduce Storm Damage", generateMissingTitles: true,
        titleGenerator: { _ in Issue.record("A useful source title must win"); return nil }).load(url, chunkLimit: 180)
    #expect(source.document?.article.titleOrigin == .readingList)
}

@Test func titleRecoveryKeepsUsefulTitlesNarrationAndCleanedMarkup() async throws {
    let original = titlePage(URL(string: "https://articles.example/report")!)
    let html = original.html.replacingOccurrences(of: "Untitled article", with: "How Wetlands Protect Coastal Communities")
    let page = FetchedPage(originalURL: original.originalURL, finalURL: original.finalURL, bytes: Data(html.utf8), html: html,
        contentType: original.contentType, encoding: original.encoding, fetchedAt: original.fetchedAt)
    let before = try ReviewedSource.prepare(page, chunkLimit: 180)
    let after = try await ReviewedSource.prepareAsync(page, chunkLimit: 180, titleGenerator: { _ in Issue.record("Useful titles must not invoke generation"); return nil })
    #expect(after.document?.article.title == before.document?.article.title && after.document?.article.titleOrigin == .metadata)
    #expect(after.document?.cleanedHTML == before.document?.cleanedHTML && after.narration == before.narration)
}

@Test func titleRecoveryPersistsAcrossRefreshReuseAndExplicitCorrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let url = URL(string: "https://articles.example/report.pdf")!
    let entry = ReadingListEntry(id: "source", safariID: "source", url: url, title: "report.pdf", addedAt: .distantPast)
    let snapshot = ReadingListSnapshot(entries: [entry], skippedEntries: 0)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(snapshot, stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: .init(), fetch: { titlePage($0) }, describeImages: false,
        generateMissingTitles: true, titleGenerator: { _ in "Wetland Restoration Protects Coastal Communities" })
    #expect(item.title == "Wetland Restoration Protects Coastal Communities")
    let catalog = try await coordinator.reconcile(snapshot, stateRoot: storage.stateRoot)
    #expect(catalog.entries.first?.title == "report.pdf" && catalog.displayTitle(for: entry) == item.title)
    let decoded = try JSONDecoder().decode(ReadingListCatalog.self, from: Files.json(catalog))
    #expect(decoded.displayTitle(for: entry) == item.title)
    let reused = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: .init(), fetch: { _ in Issue.record("Must reuse saved text without fetching"); throw CancellationError() }, describeImages: false,
        generateMissingTitles: true, titleGenerator: { _ in Issue.record("Must not regenerate saved titles"); return nil })
    #expect(reused.title == item.title && reused.id == item.id)
    let renamed = try await coordinator.renameQueuedArticle(item.id, title: "A Custom Coastal Restoration Title", stateRoot: storage.stateRoot)
    #expect(renamed.id == item.id && renamed.title == "A Custom Coastal Restoration Title")
    let reviewed = try titleSnapshot(item.id, storage: storage)
    #expect(reviewed.document?.article.titleOrigin == .user)
    #expect(reviewed.page.bytes == titlePage(url).bytes)
    #expect(reviewed.narration?.chunks.first?.text.hasPrefix(renamed.title) == true)
    // A speech attempt or published episode may never be renamed by this operation.
    let store = try NativeStore(url: storage.profile.database)
    var started = renamed; started.attempts = 1; try store.saveQueueItem(started)
    await #expect(throws: RelayError.self) { try await coordinator.renameQueuedArticle(item.id, title: "Too late to change", stateRoot: storage.stateRoot) }
    #expect(try titleSnapshot(item.id, storage: storage).document?.article.title == renamed.title)
    var published = try #require(try store.episodes().first)
    published.stage = .published; published.publicationDate = Date(timeIntervalSinceReferenceDate: 123)
    started.attempts = 0; try store.saveQueueItem(started); try store.save(published)
    await #expect(throws: RelayError.self) { try await coordinator.renameQueuedArticle(item.id, title: "Do not rename published audio", stateRoot: storage.stateRoot) }
    #expect(try #require(try store.episodes().first).title == renamed.title)
    let savedPreview = try await coordinator.savedArticlePreview(articleID: item.id, stateRoot: storage.stateRoot)
    #expect(savedPreview.document?.article.title == renamed.title && savedPreview.page.bytes == reviewed.page.bytes)
}

@Test func titleRecoveryLegacyMetadataDecodesWithoutNewFields() throws {
    let page = titlePage(URL(string: "https://articles.example/report")!)
    let article = try #require(ReviewedSource.prepare(page, chunkLimit: 180).document?.article)
    var object = try #require(JSONSerialization.jsonObject(with: Files.json(article)) as? [String: Any])
    object.removeValue(forKey: "titleOrigin")
    #expect(try JSONDecoder().decode(SemanticArticle.self, from: JSONSerialization.data(withJSONObject: object)).titleOrigin == nil)
    let catalog = try JSONDecoder().decode(ReadingListCatalog.self, from: Data("{\"entries\":[],\"currentIDs\":[],\"excludedIDs\":[]}".utf8))
    #expect(catalog.entries.isEmpty)
}

@Test func titleRecoveryCatalogDoesNotTransferTitlesToChangedSourceURLs() {
    let original = ReadingListEntry(id: "same-safari-id", safariID: "same-safari-id", url: URL(string: "https://articles.example/one")!, title: "Original source", addedAt: nil)
    let replaced = ReadingListEntry(id: original.id, safariID: original.safariID, url: URL(string: "https://articles.example/two")!, title: "Different source", addedAt: nil)
    var catalog = ReadingListCatalog()
    catalog.reconcile(.init(entries: [original], skippedEntries: 0))
    catalog.setResolvedTitle("A recovered title for the original source", for: original.id)
    catalog.reconcile(.init(entries: [replaced], skippedEntries: 0))
    #expect(catalog.displayTitle(for: replaced) == replaced.title)
}
