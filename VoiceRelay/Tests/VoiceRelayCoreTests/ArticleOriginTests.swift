import Foundation
import Testing
@testable import VoiceRelayCore

@Test(arguments: ["inventory", "snapshot", "corrupt", "mismatch", "missing"])
func episodeArticleOriginRecoveryIsReadOnly(_ arguments: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-origin-\(UUID())")
    try Files.directory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("library.sqlite"), profile = PrototypeProfile.fixture(at: root)
    let original = URL(string: "https://origin.example/article?private=value")!
    let key = "reviewed-url-v1-" + Files.hash(Data(original.absoluteString.utf8))
    let savedAt = Date(timeIntervalSinceReferenceDate: 100), publishedAt = Date(timeIntervalSinceReferenceDate: 200)
    let id: String, record: String
    do {
        let store = try NativeStore(url: database)
        var episode = try store.episode(sourceKey: key, settings: profile)
        episode.sourceHost = "archive.ph"; episode.sourceURL = URL(string: "https://canonical.example/article")
        episode.publicationDate = publishedAt; episode.stage = .published
        try store.save(episode); id = episode.id
        if arguments == "inventory" {
            var catalog = ReadingListCatalog()
            catalog.reconcile(ReadingListSnapshot(entries: [ReadingListEntry(id: "source", safariID: nil,
                url: original, title: "Synthetic article", addedAt: savedAt)], skippedEntries: 0))
            try store.saveCatalog(catalog)
        } else if arguments != "missing" {
            let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
            let page = FetchedPage(originalURL: arguments == "mismatch" ? URL(string: "https://other.example/article")! : original,
                finalURL: URL(string: "https://archive.ph/Abc12")!, bytes: Data(html.utf8), html: html,
                contentType: "text/html", encoding: "utf-8", fetchedAt: publishedAt)
            let review = try ReviewedSource.prepare(page, chunkLimit: 1800)
            try store.saveSnapshot(articleID: id, data: Files.json(StoredExtraction(review: review, chunkLimit: 1800)))
            if arguments == "corrupt" { try store.execute("UPDATE snapshots SET hash='invalid' WHERE article_id=?", [id]) }
        }
        record = try #require(store.query("SELECT record FROM episodes WHERE id=?", [id]).first?.first)
    }
    let reader = try NativeStore(url: database, readOnly: true)
    let listed = try reader.episodes().first, found = try reader.existingEpisode(sourceKey: key)
    for episode in [try #require(listed), try #require(found)] {
        #expect(episode.originalSourceHost == (["inventory", "snapshot"].contains(arguments) ? "origin.example" : nil))
        #expect(episode.readingListSavedAt == (arguments == "inventory" ? savedAt : nil))
        #expect(episode.sourceHost == "archive.ph" && episode.sourceURL?.host == "canonical.example")
        #expect(episode.publicationDate == publishedAt)
    }
    #expect(try reader.query("SELECT record FROM episodes WHERE id=?", [id]).first?.first == record)
}

@Test func episodeArticleOriginIsCapturedBeforeSpeechForRedirectedSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-origin-capture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let original = URL(string: "https://origin.example/article")!
    let page = FetchedPage(originalURL: original, finalURL: URL(string: "https://redirect.example/article")!,
        bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(ReviewedSource.prepare(page, chunkLimit: 1800),
        storage: storage, preferences: SpeechPreferences())
    let episode = try #require(await coordinator.library(storage: storage).first)
    #expect(episode.originalSourceHost == "origin.example" && item.sourceHost == "origin.example")
    #expect(episode.readingListSavedAt == nil && episode.publicationDate == nil)
    #expect(try JSONDecoder().decode(Episode.self, from: Files.json(episode)).originalSourceHost == "origin.example")
}
