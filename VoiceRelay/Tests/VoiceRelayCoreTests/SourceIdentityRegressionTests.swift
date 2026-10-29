import Foundation
import Testing
import AudioOutput
@testable import VoiceRelayCore

private func sourceIdentityReview(original: URL, final: URL? = nil, canonical: URL? = nil,
                                  archive: ArchivedArticleCopy? = nil) throws -> ReviewedSource {
    let prose = String(repeating: "The synthetic article explains how coastal habitats shelter nearby communities from storm damage. ", count: 8)
    let link = canonical.map { "<link rel='canonical' href='\($0.absoluteString)'>" } ?? ""
    let html = "<html><head><title>Coastal Habitats and Communities</title>\(link)</head><body><article><p>\(prose)</p><p>\(prose)</p></article></body></html>"
    return try ReviewedSource.prepare(.init(originalURL: original, finalURL: final ?? original,
        bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast,
        archivedCopy: archive), chunkLimit: 1800)
}

@Test(arguments: [false, true])
func readingListRetargetedEntryRetiresOnlyMissingSourceURLs(oldURLStillPresent: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-identity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let original = URL(string: "https://articles.example/original")!, replacement = URL(string: "https://articles.example/replacement")!
    let entry = ReadingListEntry(id: "safari:stable", safariID: "stable", url: original, title: "Original article", addedAt: .distantPast)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(.init(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let queued = try await coordinator.enqueue(sourceIdentityReview(original: original), storage: storage, preferences: .init(), sourceEntryID: entry.id)
    let stale = try #require(await coordinator.library(storage: storage).first { $0.id == queued.id })
    let updated = ReadingListEntry(id: entry.id, safariID: entry.safariID, url: replacement, title: "Replacement article", addedAt: entry.addedAt)
    let retained = ReadingListEntry(id: "safari:retained", safariID: "retained", url: original, title: entry.title, addedAt: entry.addedAt)
    _ = try await coordinator.reconcile(.init(entries: oldURLStillPresent ? [updated, retained] : [updated], skippedEntries: 0), stateRoot: storage.stateRoot)
    let episode = try #require(await coordinator.library(storage: storage).first { $0.id == queued.id })
    #expect((episode.readingListRemoved == true) == !oldURLStillPresent)
    #expect(try await !coordinator.hasRecordedArticle(entry: updated, stateRoot: storage.stateRoot))
    if oldURLStillPresent {
        #expect(episode.readingListEntryID == retained.id)
        try NativeStore(url: storage.profile.database).save(stale)
        #expect(try await coordinator.hasRecordedArticle(entry: retained, stateRoot: storage.stateRoot))
    }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).contains { $0.id == queued.id } == oldURLStillPresent)
    try await coordinator.purgeRemovedReadingListCaches(storage: storage)
    let snapshot = try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: queued.id)
    #expect((snapshot != nil) == oldURLStillPresent)
    let replacementItem = try await coordinator.enqueue(sourceIdentityReview(original: replacement), storage: storage, preferences: .init(), sourceEntryID: updated.id)
    #expect(replacementItem.id != queued.id)
}

private struct SourceIdentityAudio: TTSBackend {
    let identity = BackendIdentity(id: "source-identity-fixture-v1", displayName: "Synthetic source metadata audio", isMock: false)
    func prepare() throws { try Task.checkCancellation() }
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        let url = directory.appendingPathComponent("source-identity.wav"), writer = try AtomicAudioWriter(destination: url)
        let rate = 24_000
        let samples = (0..<(rate / 4)).map { Float(sin(Double($0) * 2 * .pi * 330 / Double(rate)) * 0.1) }
        try writer.append(samples: samples, sampleRate: rate); try writer.publish()
        return .init(artifacts: [.init(url: url, sampleRate: rate, channels: 1, format: "wav")])
    }
}

@Test(arguments: [false, true])
func archivedPublicationKeepsOriginalPublisherLinkAndPrivateReplayProvenance(rewrittenCanonical: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-publication-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    try FileManager.default.createDirectory(at: storage.audioDirectory, withIntermediateDirectories: true)
    let original = URL(string: "https://articles.example/original")!, replay = URL(string: "https://archive.ph/Abc12")!
    let copy = ArchivedArticleCopy(provider: .archiveToday, snapshotURL: replay, capturedAt: .distantPast)
    let review = try sourceIdentityReview(original: original, final: replay, canonical: rewrittenCanonical ? replay : nil, archive: copy)
    let coordinator = FixtureCoordinator()
    var settings = DeliverySettings()
    settings.enabled = true; settings.feedFolderURL = URL(string: "https://webdav.example/feed/")
    settings.publicFolderURL = URL(string: "https://podcast.example/feed/"); settings.username = "fixture"
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: review, backend: SourceIdentityAudio(), storage: storage, delivery: settings)
    #expect(result.episode.sourceURL == original && result.episode.sourceHost == original.host)
    #expect(result.article.archivedCopy == copy && result.article.finalURL == replay)
    var uploaded = result.episode
    uploaded.delivery?.status = .uploaded; uploaded.delivery?.destinationURL = settings.feedFolderURL
    uploaded.delivery?.uploadedByteLength = uploaded.info?.byteLength
    let feed = try RSS.renderRemote([uploaded], channel: .init(settings: settings))
    let xml = String(decoding: feed, as: UTF8.self)
    #expect(xml.contains("<link>\(original.absoluteString)</link>") && !xml.contains(replay.absoluteString))
    // Existing completed recordings retain their previously captured metadata.
    do {
        let store = try NativeStore(url: storage.profile.database)
        var legacy = result.episode; legacy.sourceURL = replay; legacy.sourceHost = replay.host
        try store.save(legacy)
    }
    let resumed = try await coordinator.runReviewed(root: storage.stateRoot, review: review, backend: SourceIdentityAudio(), storage: storage, delivery: settings)
    #expect(resumed.synthesizedChunks == 0 && resumed.episode.audioHash == result.episode.audioHash)
    #expect(resumed.episode.sourceURL == replay && resumed.episode.sourceHost == replay.host)
}

@Test func articleIntakeKeepsHeadlineThatMatchesDescriptiveHTMLSlug() async throws {
    let title = "How Wetlands Protect Coastal Communities"
    let url = URL(string: "https://articles.example/how-wetlands-protect-coastal-communities")!
    let prose = String(repeating: "Coastal habitats shelter nearby communities from storm damage and help people adapt to a changing climate. ", count: 8)
    let html = "<html><head><title>\(title)</title></head><body><article><h1>\(title)</h1><p>\(prose)</p><h2>Restoration Methods and Results</h2><p>\(prose)</p></article></body></html>"
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    let review = try await ReviewedSource.prepareAsync(page, chunkLimit: 1800, sourceTitle: title)
    #expect(review.document?.article.title == title && review.document?.article.titleOrigin == .metadata)
    #expect(review.narration?.chunks.first?.text.hasPrefix(title) == true)
}
