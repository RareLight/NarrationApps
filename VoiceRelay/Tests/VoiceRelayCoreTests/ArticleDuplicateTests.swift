import Foundation
import Testing
@testable import VoiceRelayCore

private func duplicateStorage() -> (URL, ManagedSpeechStorage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-duplicates-\(UUID())")
    return (root, ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch")))
}
private func duplicateEntry(_ id: String, title: String = "Coastal habitats recover", host: String = "news.example", date: Double = 0) -> ReadingListEntry {
    ReadingListEntry(id: id, safariID: id, url: URL(string: "https://\(host)/\(id)")!, title: title,
        addedAt: Date(timeIntervalSinceReferenceDate: date))
}
private func duplicatePage(_ url: URL, paragraphs: Int = 8, blocked: Bool = false) -> FetchedPage {
    let text = blocked ? "Subscribe to continue reading" : (0..<paragraphs).map {
        "<p>Survey \($0) documents coastal habitats and the recovery of native species. Researchers compared the measurements over several years and found that restoring wetlands protected communities and wildlife from damaging storms.</p>"
    }.joined()
    let html = "<html><head><title>Coastal habitats recover</title></head><body><article><h1>Coastal habitats recover</h1>\(text)</article></body></html>"
    return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
        contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
}

@Test(arguments: [false, true]) func duplicateAdmissionPrefersFullTextOverNewerShortOrBlockedCopy(blocked: Bool) async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let full = duplicateEntry("full", date: 1), short = duplicateEntry("short", date: 2)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [short, full], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueueReadingList(short.id, storage: storage, preferences: .init(voice: .bella, speed: 1.2), fetch: {
        duplicatePage($0, paragraphs: $0 == full.url ? 8 : 2, blocked: $0 == short.url && blocked)
    }, describeImages: false)
    #expect(item.sourceEntryID == full.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [item.id])
    let catalog = try await coordinator.catalog(stateRoot: storage.stateRoot)
    #expect(catalog.inactiveDuplicateIDs == [short.id])
    #expect(catalog.hasHandled(short) && catalog.hasHandled(full))
    #expect(catalog.entries == [short, full]) // Safari records remain untouched.
    let episode = try #require(await coordinator.library(storage: storage).first)
    #expect(episode.settings.voice == "af_bella" && episode.settings.backendSettings["speed"]?.numericValue == 1.2)
    #expect(episode.readingListEntryID == full.id && episode.readingListSavedAt == full.addedAt)
}

@Test func duplicateIdenticalTextPrefersLatestSaveAndPersistsSuppressionAfterQueueReset() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let older = duplicateEntry("old", date: 1), newer = duplicateEntry("new", date: 2)
    let snapshot = ReadingListSnapshot(entries: [older, newer], skippedEntries: 0)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(snapshot, stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueueReadingList(older.id, storage: storage, preferences: .init(),
        fetch: { duplicatePage($0) }, describeImages: false)
    #expect(item.sourceEntryID == newer.id)
    try await coordinator.resetQueue(stateRoot: storage.stateRoot)
    let restarted = FixtureCoordinator()
    let catalog = try await restarted.reconcile(snapshot, stateRoot: storage.stateRoot)
    #expect(catalog.inactiveDuplicateIDs == [older.id])
    for entry in snapshot.entries { #expect(try await restarted.hasRecordedArticle(entry: entry, stateRoot: storage.stateRoot)) }
    #expect(try await restarted.queue(stateRoot: storage.stateRoot).isEmpty)
    // Even removing the selected source does not resurrect the consumed loser.
    _ = try await restarted.reconcile(.init(entries: [older], skippedEntries: 0), stateRoot: storage.stateRoot)
    #expect(try await restarted.hasRecordedArticle(entry: older, stateRoot: storage.stateRoot))
    // A genuinely new save is eligible, rather than being suppressed just by URL/title.
    let third = duplicateEntry("third", date: 3)
    _ = try await restarted.reconcile(.init(entries: [older, third], skippedEntries: 0), stateRoot: storage.stateRoot)
    #expect(try await !restarted.hasRecordedArticle(entry: third, stateRoot: storage.stateRoot))
}

@Test func duplicateMatchingRequiresOriginAndPreservesDatesAndQueryIdentity() {
    let first = duplicateEntry("first", title: "  COASTAL habitats recover ", host: "www.news.example")
    let second = duplicateEntry("second", date: 10)
    let unrelated = duplicateEntry("other", host: "other.example")
    #expect(ArticleDuplicates.groups([first, second, unrelated], evidence: [:]).map(\.count) == [2, 1])
    #expect(!ArticleDuplicates.matches(title: "Annual report 2025", host: "news.example", title: "Annual report 2026", host: "news.example"))
    #expect(!ArticleDuplicates.matches(title: "Untitled article", host: "news.example", title: "Untitled article", host: "news.example"))
    #expect(ArticleDuplicates.source(URL(string: "https://news.example/story?a=1#part")!) == "https://news.example/story?a=1")
    #expect(ArticleDuplicates.source(URL(string: "https://news.example/story?a=2")!) != ArticleDuplicates.source(URL(string: "https://news.example/story?a=1")!))
}

@Test func duplicateFetchFailureDoesNotDisplaceReadableCopyAndCancellationDoesNotConsumeSources() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let good = duplicateEntry("good"), failed = duplicateEntry("failed", date: 10)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [good, failed], skippedEntries: 0), stateRoot: storage.stateRoot)
    await #expect(throws: CancellationError.self) {
        try await coordinator.enqueueReadingList(good.id, storage: storage, preferences: .init(), fetch: { duplicatePage($0) },
            describeImages: false, shouldCommit: { false })
    }
    #expect(try await coordinator.catalog(stateRoot: storage.stateRoot).hasHandled(good) == false)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let item = try await coordinator.enqueueReadingList(failed.id, storage: storage, preferences: .init(), fetch: {
        if $0 == failed.url { throw SourceFetchError.network }
        return duplicatePage($0)
    }, describeImages: false)
    #expect(item.sourceEntryID == good.id)
    #expect(try await coordinator.catalog(stateRoot: storage.stateRoot).inactiveDuplicateIDs == [failed.id])
}

@Test func duplicateNewSaveOfPublishedURLCapturesNewSettingsWithoutChangingPredecessor() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let older = duplicateEntry("old", date: 1)
    let newer = ReadingListEntry(id: "new", safariID: "new", url: older.url, title: older.title, addedAt: Date(timeIntervalSinceReferenceDate: 2))
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [older], skippedEntries: 0), stateRoot: storage.stateRoot)
    let previous = try await coordinator.enqueueReadingList(older.id, storage: storage, preferences: .init(voice: .emma, speed: 1.25),
        fetch: { duplicatePage($0) }, describeImages: false)
    do {
        let store = try NativeStore(url: storage.profile.database)
        var episode = try #require(store.episodes().first)
        episode.stage = .published; episode.publicationDate = Date(timeIntervalSinceReferenceDate: 100)
        episode.settings.temporaryAudio = true
        try store.save(episode)
        // Legacy origin recovery used to be read-only. Freeze those resolved fields
        // before moving this record out of the original URL database slot.
        var legacy = try #require(JSONSerialization.jsonObject(with: Files.json(episode)) as? [String: Any])
        legacy.removeValue(forKey: "originalSourceIdentity"); legacy.removeValue(forKey: "originalSourceHost")
        try store.execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: JSONSerialization.data(withJSONObject: legacy), as: UTF8.self), episode.id])
        try store.execute("DELETE FROM speech_queue")
    }
    _ = try await coordinator.reconcile(.init(entries: [older, newer], skippedEntries: 0), stateRoot: storage.stateRoot)
    #expect(try await !coordinator.hasRecordedArticle(entry: newer, stateRoot: storage.stateRoot))
    let next = try await coordinator.enqueueReadingList(newer.id, storage: storage, preferences: .init(voice: .bella, speed: 0.9),
        fetch: { duplicatePage($0) }, describeImages: false)
    #expect(next.id != previous.id && next.sourceEntryID == newer.id)
    let episodes = try await coordinator.library(storage: storage)
    let old = try #require(episodes.first { $0.id == previous.id }), new = try #require(episodes.first { $0.id == next.id })
    #expect(old.stage == .published && old.settings.voice == "bf_emma")
    #expect(new.stage == .extracted && new.settings.voice == "af_bella" && new.settings.backendSettings["speed"]?.numericValue == 0.9)
    #expect(new.originalSourceIdentity == old.originalSourceIdentity)
    #expect(old.originalSourceIdentity != nil && old.originalSourceHost == older.url.host)
    #expect(try await coordinator.catalog(stateRoot: storage.stateRoot).inactiveDuplicateIDs == [older.id])
    for entry in [older, newer] { #expect(try await FixtureCoordinator().hasRecordedArticle(entry: entry, stateRoot: storage.stateRoot)) }
    // Missing temporary output must not regenerate the superseded older voice.
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [next.id])
}

@Test func duplicateComparisonPrunesPendingLoserWhenRecoveredHeadlinesRevealMatch() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let first = duplicateEntry("first", title: "Short saved title", date: 1)
    let second = duplicateEntry("second", title: "Other saved title", date: 2)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [first, second], skippedEntries: 0), stateRoot: storage.stateRoot)
    let losing = try await coordinator.enqueueReadingList(first.id, storage: storage, preferences: .init(), fetch: {
        duplicatePage($0, paragraphs: 2)
    }, describeImages: false)
    let selected = try await coordinator.enqueueReadingList(second.id, storage: storage, preferences: .init(), fetch: {
        duplicatePage($0, paragraphs: 8)
    }, describeImages: false)
    #expect(selected.id != losing.id && selected.sourceEntryID == second.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [selected.id])
}

@Test func duplicateNewSaveReplacesUnstartedOlderVoiceSelectionOnce() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let older = duplicateEntry("older", date: 1), shorter = duplicateEntry("shorter", date: 2)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [older], skippedEntries: 0), stateRoot: storage.stateRoot)
    let previous = try await coordinator.enqueueReadingList(older.id, storage: storage, preferences: .init(voice: .emma), fetch: { duplicatePage($0) }, describeImages: false)
    _ = try await coordinator.reconcile(.init(entries: [older, shorter], skippedEntries: 0), stateRoot: storage.stateRoot)
    let selected = try await coordinator.enqueueReadingList(shorter.id, storage: storage, preferences: .init(voice: .bella), fetch: {
        duplicatePage($0, paragraphs: 2)
    }, describeImages: false)
    #expect(selected.sourceEntryID == older.id && selected.id != previous.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [selected.id])
    #expect(try await coordinator.library(storage: storage).first { $0.id == selected.id }?.settings.voice == "af_bella")
    let retry = try await coordinator.enqueueReadingList(older.id, storage: storage, preferences: .init(voice: .heart), fetch: {
        duplicatePage($0, paragraphs: 2)
    }, describeImages: false)
    #expect(retry.id == selected.id) // Refresh/retry of the handled group never rotates identity again.
}

@Test func duplicateRetirementRequiresConfirmedCurrentDestinationAndOriginalWebsite() throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
    var settings = DeliverySettings(); settings.enabled = true; settings.username = "fixture"
    settings.feedFolderURL = URL(string: "https://dav.example/feed/")
    settings.publicFolderURL = URL(string: "https://public.example/feed/")
    let old: Episode, unrelated: Episode, successor: Episode
    do {
        let store = try NativeStore(url: database)
        var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
        var first = try store.episode(sourceKey: "first", settings: profile)
        first.title = "Coastal habitats recover"; first.originalSourceHost = "news.example"
        first.stage = .published; first.audioHash = String(repeating: "a", count: 64)
        first.info = AudioInfo(duration: 1, byteLength: 1, sampleRate: 24000, channels: 1, codec: "aac")
        first.publicationDate = .distantFuture // Dates cannot displace generation ordering.
        try store.save(first); old = first
        var other = try store.episode(sourceKey: "other", settings: profile)
        other.title = first.title; other.originalSourceHost = "different.example"; other.stage = .published
        try store.save(other); unrelated = other
        var new = try store.episode(sourceKey: "successor", settings: profile)
        new.title = first.title; new.originalSourceHost = "www.news.example"; new.stage = .published
        new.replacesDuplicateAudio = true; new.audioHash = String(repeating: "b", count: 64)
        new.delivery = DeliveryState(status: .uploaded, remotePath: settings.remoteMediaPath(new.id))
        new.delivery?.destinationURL = settings.feedFolderURL; try store.save(new); successor = new
    }
    let pipeline = try PipelineStore(databaseURL: database)
    #expect(try !pipeline.retireConfirmedDuplicates(settings: settings, confirmed: [:], blocked: []))
    #expect(try !pipeline.retireConfirmedDuplicates(settings: settings, confirmed: [successor.id: successor.audioHash!], blocked: [successor.id]))
    var otherDestination = settings; otherDestination.feedFolderURL = URL(string: "https://elsewhere.example/feed/")
    #expect(try !pipeline.retireConfirmedDuplicates(settings: otherDestination, confirmed: [successor.id: successor.audioHash!], blocked: []))
    #expect(try pipeline.retireConfirmedDuplicates(settings: settings, confirmed: [successor.id: successor.audioHash!], blocked: []))
    #expect(try pipeline.episode(id: old.id)?.stage == .expired)
    #expect(try pipeline.episode(id: unrelated.id)?.stage == .published)
    #expect(try pipeline.episode(id: successor.id)?.stage == .published)
}

@Test func existingDuplicateInventoryReceivesOneComparisonThenStaysHandled() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let first = duplicateEntry("first", date: 1), second = duplicateEntry("second", date: 2)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [first, second], skippedEntries: 0), stateRoot: storage.stateRoot)
    // Existing pre-feature snapshots still need one duplicate assessment.
    for entry in [first, second] {
        let review = try ReviewedSource.prepare(duplicatePage(entry.url), chunkLimit: 1800)
        _ = try await coordinator.enqueue(review, storage: storage, preferences: .init(), sourceEntryID: entry.id)
    }
    #expect(try await !coordinator.hasRecordedArticle(entry: first, stateRoot: storage.stateRoot))
    #expect(try await !coordinator.hasRecordedArticle(entry: second, stateRoot: storage.stateRoot))
    let item = try await coordinator.enqueueReadingList(first.id, storage: storage, preferences: .init(voice: .bella),
        fetch: { _ in Issue.record("Existing snapshots should stay offline"); throw CancellationError() }, describeImages: false)
    #expect(item.sourceEntryID == second.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [item.id])
    for entry in [first, second] { #expect(try await coordinator.hasRecordedArticle(entry: entry, stateRoot: storage.stateRoot)) }
}

@Test func duplicateNewSaveDateCannotBeMaskedByLegacyDisplayDateRecovery() async throws {
    let (root, storage) = duplicateStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let url = URL(string: "https://news.example/same-url")!
    let undated = ReadingListEntry(id: "same-id", safariID: "same-id", url: url, title: "Coastal habitats recover", addedAt: nil)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [undated], skippedEntries: 0), stateRoot: storage.stateRoot)
    let previous = try await coordinator.enqueueReadingList(undated.id, storage: storage, preferences: .init(), fetch: { duplicatePage($0) }, describeImages: false)
    do {
        let store = try NativeStore(url: storage.profile.database)
        var episode = try #require(store.episodes().first)
        episode.stage = .published; episode.publicationDate = Date(timeIntervalSinceReferenceDate: 100)
        try store.save(episode); try store.execute("DELETE FROM speech_queue")
    }
    let resaved = ReadingListEntry(id: undated.id, safariID: undated.safariID, url: url, title: undated.title,
        addedAt: Date(timeIntervalSinceReferenceDate: 200))
    _ = try await coordinator.reconcile(.init(entries: [resaved], skippedEntries: 0), stateRoot: storage.stateRoot)
    #expect(try await !coordinator.hasRecordedArticle(entry: resaved, stateRoot: storage.stateRoot))
    let next = try await coordinator.enqueueReadingList(resaved.id, storage: storage, preferences: .init(voice: .bella), fetch: {
        duplicatePage($0, paragraphs: 10)
    }, describeImages: false)
    #expect(next.id != previous.id)
    let review = try await coordinator.savedArticlePreview(articleID: next.id, stateRoot: storage.stateRoot)
    #expect(review.page.bytes == duplicatePage(url, paragraphs: 10).bytes)
}
