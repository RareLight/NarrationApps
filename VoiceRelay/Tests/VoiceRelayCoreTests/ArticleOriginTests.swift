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

@Test(arguments: [false, true]) func capturedEpisodeOriginSurvivesStaleWritesAndSourceCacheRemoval(removed: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-origin-durable-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"), temporaryAudio: true)
    let original = URL(string: "https://origin.example/article")!
    let key = "reviewed-url-v1-" + Files.hash(Data(original.absoluteString.utf8))
    let savedAt = Date(timeIntervalSinceReferenceDate: 100)
    let entry = ReadingListEntry(id: "entry", safariID: nil, url: original, title: "Synthetic source", addedAt: savedAt)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let stale: Episode
    do {
        let store = try NativeStore(url: storage.profile.database)
        var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
        var episode = try store.episode(sourceKey: key, settings: profile)
        episode.stage = .published; episode.audioHash = "synthetic-audio-hash"
        episode.info = AudioInfo(duration: 100, byteLength: 1000, sampleRate: 24000, channels: 1, codec: "aac")
        episode.sourceHost = "redirect.example"; episode.publicationDate = Date(timeIntervalSinceReferenceDate: 1000)
        try store.save(episode)
        stale = episode // Legacy worker copy has no original host or saved date.
    }
    if removed {
        // Backfill before deleting the source inventory, then remove its cached text/work.
        _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
        try await coordinator.purgeRemovedReadingListCaches(storage: storage)
    } else {
        let captured = try #require(await coordinator.library(storage: storage).first)
        try NativeStore(url: storage.profile.database).save(captured)
    }
    var progress = stale; progress.title = "Updated episode"
    progress.originalSourceIdentity = nil
    try NativeStore(url: storage.profile.database).save(progress)
    // Reopen independently, without relying on presentation/inventory caches.
    let reader = try NativeStore(url: storage.profile.database, readOnly: true)
    let raw = try #require(reader.query("SELECT record FROM episodes WHERE id=?", [stale.id]).first?.first)
    let durable = try JSONDecoder().decode(Episode.self, from: Data(raw.utf8))
    #expect(durable.originalSourceHost == "origin.example" && durable.readingListSavedAt == savedAt)
    #expect(durable.originalSourceIdentity == key && durable.title == "Updated episode")
    #expect(durable.publicationDate == stale.publicationDate && durable.sourceHost == "redirect.example")
    if removed {
        #expect(durable.readingListRemoved == true && durable.articleCachePurged == true)
        #expect(try reader.catalog().entries.isEmpty && reader.snapshot(articleID: stale.id) == nil)
    }
    #expect(try await FixtureCoordinator().savedAudio(storage: storage).first?.readingListSavedAt == savedAt)
}
