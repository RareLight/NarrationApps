import Foundation
import AudioOutput
import Testing
@testable import VoiceRelayCore

private struct RecoveryCredentials: DeliveryCredentialStore {
    func readPassword(username: String, host: String) throws -> String? { "fixture-only" }
    func writePassword(_ password: String, username: String, host: String) throws {}
    func deletePassword(username: String, host: String) throws {}
}
private final class RecoveryTransport: DeliveryTransport, @unchecked Sendable {
    private let lock = NSLock()
    var objects: [String: Data]
    var durations: [String: Double] = [:]
    var invalidPaths: Set<String> = []
    var failingPaths: Set<String> = []
    var etags: [String: String] = [:]
    private var calls: [(String, URL)] = []
    init(_ objects: [String: Data]) { self.objects = objects }
    var methods: [String] { lock.withLock { calls.map(\.0) } }
    var urls: [URL] { lock.withLock { calls.map(\.1) } }
    func verifiedAudio(_ url: URL, headers: [String: String], maximumBytes: Int64, settings: PrototypeProfile) async throws -> VerifiedRemoteAudio {
        let response = try await read(url, headers: headers, maximumBytes: maximumBytes)
        let info = response.status == 200 && !invalidPaths.contains(url.path) ? AudioInfo(duration: durations[url.path] ?? 20, byteLength: Int64(response.body.count), sampleRate: 24_000, channels: 1, codec: "aac") : nil
        return VerifiedRemoteAudio(digest: RemoteAudioDigest(status: response.status, byteLength: Int64(response.body.count), sha256: Files.hash(response.body), etag: response.headers["ETag"]), info: info)
    }
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        try Task.checkCancellation()
        if failingPaths.contains(url.path) { throw DeliveryError.retryable("Synthetic unavailable copy") }
        return lock.withLock {
            calls.append((method, url))
            switch method {
            case "GET":
                guard let data = objects[url.path] else { return DeliveryResponse(status: 404) }
                var resultHeaders = ["Content-Length": String(data.count)]
                if let etag = etags[url.path] {
                    resultHeaders["ETag"] = etag
                    if headers["If-None-Match"] == etag { return DeliveryResponse(status: 304, headers: resultHeaders) }
                }
                return DeliveryResponse(status: 200, headers: resultHeaders, body: data)
            case "PROPFIND":
                let hrefs = headers["Depth"] == "1" ? objects.keys.filter { $0.hasPrefix(url.path) } : [url.path]
                let xml = hrefs.map { "<d:response><d:href>\(RSS.escaped($0))</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" }.joined()
                return DeliveryResponse(status: 207, body: Data("<d:multistatus xmlns:d=\"DAV:\">\(xml)</d:multistatus>".utf8))
            case "PUT": objects[url.path] = body ?? (file.flatMap { try? Data(contentsOf: $0) }) ?? Data(); return DeliveryResponse(status: 201)
            case "HEAD":
                guard let data = objects[url.path] else { return DeliveryResponse(status: 404) }
                var resultHeaders = ["Content-Length": String(data.count)]
                if let etag = etags[url.path] { resultHeaders["ETag"] = etag }
                return DeliveryResponse(status: 200, headers: resultHeaders)
            default: return DeliveryResponse(status: 405)
            }
        }
    }
}
private func recoveryStorage(_ name: String = "") throws -> (URL, ManagedSpeechStorage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-recovery-\(name)-\(UUID().uuidString)")
    try Files.directory(root)
    return (root, ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"), temporaryAudio: true))
}
private func recoverySettings() -> DeliverySettings {
    var settings = DeliverySettings(); settings.enabled = true
    settings.feedFolderURL = URL(string: "https://dav.example/podcast/")
    settings.publicFolderURL = URL(string: "https://public.example/podcast/"); settings.username = "fixture"
    return settings
}
private func recoverySeed(storage: ManagedSpeechStorage, path: String = "article", published: Bool = true) throws -> Episode {
    let database = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
    let store = try NativeStore(url: database)
    var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
    let url = URL(string: "https://news.example/\(path)")!
    var e = try store.episode(sourceKey: "reviewed-url-v1-" + Files.hash(Data(url.absoluteString.utf8)), settings: profile)
    e.stage = published ? .published : .extracted; e.title = "Synthetic article"
    e.sourceURL = url; e.originalSourceHost = url.host
    e.publicationDate = Date(timeIntervalSince1970: 1_700_000_000)
    e.readingListSavedAt = Date(timeIntervalSince1970: 1_600_000_000)
    if published {
        e.audioHash = Files.hash(Data("test-audio".utf8)); e.info = AudioInfo(duration: 20, byteLength: 10, sampleRate: 24_000, channels: 1, codec: "aac")
    }
    try store.save(e)
    return e
}
private func recoveryFeed(_ episode: Episode, settings: DeliverySettings, legacy: Bool = false) throws -> Data {
    var e = episode
    e.delivery = DeliveryState(status: .uploaded, remotePath: settings.remoteMediaPath(e.id), uploadedByteLength: e.info?.byteLength)
    e.delivery?.destinationURL = settings.feedFolderURL
    var feed = String(decoding: try RSS.renderRemote([e], channel: RemoteChannel(settings: settings)), as: UTF8.self)
    if legacy, let range = feed.range(of: "<vr:identity[^>]*/>", options: .regularExpression) { feed.removeSubrange(range) }
    return Data(feed.utf8)
}

@Test func serverRecoveryRestoresConfirmedCopiesWithoutRegenerationOrUpload() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    do { let store = try NativeStore(url: storage.profile.database)
        try store.saveQueueItem(SpeechQueueItem(id: episode.id, title: episode.title, sourceEntryID: nil, state: .queued)) }
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings),
        "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.verifiedCopies == 1 && report.publishedCopies == 1 && report.recoveredEpisodes == 0)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 1) // inspection is read-only
    #expect(transport.methods.allSatisfy { ["GET", "HEAD"].contains($0) })
    #expect(transport.urls.allSatisfy { $0.host == "dav.example" })
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.publicationStates[episode.id] == .published)
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func serverRecoveryReconstructsLostHistoryAndOriginalIdentityFromFeed() async throws {
    let (oldRoot, oldStorage) = try recoveryStorage(), (root, storage) = try recoveryStorage()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: oldRoot) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: oldStorage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.recoveredEpisodes == 1)
    #expect(!FileManager.default.fileExists(atPath: storage.stateRoot.path))
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    let recovered = try #require(await coordinator.library(storage: storage).first)
    #expect(recovered.id == episode.id && recovered.readingListSavedAt == episode.readingListSavedAt)
    #expect(recovered.publicationDate == episode.publicationDate)
    #expect(try await coordinator.hasRecordedArticle(url: URL(string: "https://news.example/article")!, stateRoot: storage.stateRoot))
    #expect(try await coordinator.savedAudio(storage: storage).count == 1)
}

@Test func serverRecoveryAdoptsLegacyFeedIDAndPreservesQueuedArticleSnapshot() async throws {
    let (oldRoot, oldStorage) = try recoveryStorage(), (root, storage) = try recoveryStorage()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: oldRoot) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: oldStorage)
    let queued = try recoverySeed(storage: storage, published: false)
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let url = URL(string: "https://news.example/article")!
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    let review = try ReviewedSource.prepare(page, chunkLimit: 1800)
    let snapshot = try Files.json(StoredExtraction(review: review, chunkLimit: 1800))
    do { let store = try NativeStore(url: storage.profile.database)
        try store.saveSnapshot(articleID: queued.id, data: snapshot)
        try store.saveQueueItem(SpeechQueueItem(id: queued.id, title: queued.title, sourceEntryID: nil, state: .queued)) }
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings, legacy: true), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let store = try NativeStore(url: storage.profile.database, readOnly: true)
    #expect(try store.snapshot(articleID: episode.id) == snapshot)
    #expect(try store.episodes().map(\.id) == [episode.id])
}

@Test func serverRecoveryReusesMediaFromInterruptedFeedPublication() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let transport = RecoveryTransport(["/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.verifiedCopies == 1 && report.publishedCopies == 0)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.publicationStates[episode.id] == .uploaded && summary.remoteFeedPending)
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(result.uploadedMedia == 0 && result.feedUploaded)
}

@Test func serverRecoveryRepairsSameSizeChangedBytesUsingVerifiedServerCopy() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), "/podcast/audio/\(episode.id).m4a": Data("bad--audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    #expect(try await coordinator.library(storage: storage).first?.audioHash == Files.hash(Data("bad--audio".utf8)))
    #expect(transport.methods.allSatisfy { ["GET", "HEAD"].contains($0) })
}

@Test func serverRecoveryRejectsStalePlansAndChangedDestinations() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let transport = RecoveryTransport(["/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    var changed = settings; changed.feedFolderURL = URL(string: "https://other.example/podcast/")
    await #expect(throws: RelayError.self) { try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: changed) }
    do { let store = try NativeStore(url: storage.profile.database); var e = episode; e.title = "Changed"; try store.save(e) }
    let log = DeliveryDebugLog(); log.enabled = true
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings, debugLog: log)
    #expect(log.text.contains("itemFailed") && !log.text.contains("news.example"))
    #expect(try await coordinator.library(storage: storage).first?.title == "Changed")
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).blockedServerIDs?.contains(episode.id) == true)
}

@Test func serverRecoveryExistingFeedIsMergedAutomaticallyWithoutMediaUpload() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(result.uploadedMedia == 0)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[episode.id] == .published)
}

@Test func serverRecoveryParserRejectsMalformedDuplicateForeignAndEntityFeeds() throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), episode = try recoverySeed(storage: storage)
    let feed = String(decoding: try recoveryFeed(episode, settings: settings), as: UTF8.self)
    let item = try #require(feed.range(of: "<item>.*</item>", options: .regularExpression))
    #expect(throws: DeliveryError.self) { try ServerFeedParser.parse(Data(feed.replacingOccurrences(of: "</channel>", with: String(feed[item]) + "</channel>").utf8)) }
    #expect(throws: DeliveryError.self) { try ServerFeedParser.parse(Data(feed.replacingOccurrences(of: episode.id + ".m4a", with: "different.m4a").utf8)) }
    #expect(throws: DeliveryError.self) { try ServerFeedParser.parse(Data("<!DOCTYPE rss [<!ENTITY private SYSTEM 'file:///etc/passwd'>]><rss version='2.0'><channel><item><title>&private;</title></item></channel></rss>".utf8)) }
    #expect(throws: DeliveryError.self) { try ServerFeedParser.parse(Data(feed.dropLast(40).utf8)) }
}

@Test func serverRecoveryDowngradesMissingKnownCopiesWithoutDroppingQueueWork() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    var episode = try recoverySeed(storage: storage)
    episode.delivery = DeliveryState(status: .uploaded, remotePath: settings.remoteMediaPath(episode.id), uploadedByteLength: 10)
    episode.delivery?.destinationURL = settings.feedFolderURL
    do { let store = try NativeStore(url: storage.profile.database); try store.save(episode)
        try store.saveQueueItem(SpeechQueueItem(id: episode.id, title: episode.title, sourceEntryID: nil, state: .failed)) }
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.verifiedCopies == 0 && report.publishedCopies == 0 && report.missingCopies == 1)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .failed)
    #expect(try await coordinator.library(storage: storage).first?.delivery?.status == .pending)
}

@Test func serverRecoveryLegacyUnmatchedHistoryKeepsExactLinkWithoutClaimingOriginalIdentity() async throws {
    let (oldRoot, oldStorage) = try recoveryStorage(), (root, storage) = try recoveryStorage()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: oldRoot) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: oldStorage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings, legacy: true), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.unmatchedEpisodes == 1)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    let recovered = try #require(await coordinator.library(storage: storage).first)
    #expect(recovered.originalSourceIdentity == nil)
    #expect(try await !coordinator.hasRecordedArticle(url: URL(string: "https://news.example/unrelated")!, stateRoot: storage.stateRoot))
    #expect(try await coordinator.hasRecordedArticle(url: URL(string: "https://news.example/article")!, stateRoot: storage.stateRoot))
}

@Test func serverRecoverySkipsOrphanListingAndPreservesCorruptLedgerOnInspection() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let transport = RecoveryTransport(["/podcast/audio/\(UUID().uuidString.lowercased()).m4a": Data("orphan".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.verifiedCopies == 0 && !transport.methods.contains("PROPFIND"))
    _ = try recoverySeed(storage: storage)
    let ledger = DeliveryLedger.fileURL(stateRoot: storage.stateRoot)
    try Files.write(Data("not-json".utf8), to: ledger)
    await #expect(throws: RelayError.self) { try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport) }
    #expect(try Data(contentsOf: ledger) == Data("not-json".utf8))
}

@Test func serverRecoveryChangedPublicMappingRequiresFeedUpdateButReusesMedia() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    var changed = settings; changed.publicFolderURL = URL(string: "https://new-public.example/podcast/")
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: changed, credential: RecoveryCredentials(), transport: transport)
    #expect(report.verifiedCopies == 1 && report.publishedCopies == 0)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: changed)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: changed)
    #expect(summary.publicationStates[episode.id] == .uploaded && summary.remoteFeedPending)
}

@Test func serverRecoveryUnchangedRecordsRemainApplicableAcrossCatalogRefreshes() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    var entries = (0..<100).map { ReadingListEntry(id: "fixture-\($0)", safariID: "fixture-\($0)", url: URL(string: "https://news.example/item-\($0)")!, title: "Synthetic \($0)", addedAt: nil) }
    entries.append(ReadingListEntry(id: "article", safariID: "article", url: URL(string: "https://news.example/article")!, title: episode.title, addedAt: episode.readingListSavedAt))
    var catalog = ReadingListCatalog(); catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    do { let store = try NativeStore(url: storage.profile.database); try store.saveCatalog(catalog) }
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    for _ in 0..<3 {
        let again = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
        #expect(again.expectedRecords == report.expectedRecords)
    }
    catalog.reconcile(ReadingListSnapshot(entries: Array(entries.reversed()), skippedEntries: 0))
    do { let store = try NativeStore(url: storage.profile.database); try store.saveCatalog(catalog) }
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    #expect(try await coordinator.library(storage: storage).first?.delivery?.status == .uploaded)
}

@Test func serverRecoveryPrefersExistingFeedCopyOverNewUnuploadedDuplicate() async throws {
    let (oldRoot, oldStorage) = try recoveryStorage(), (root, storage) = try recoveryStorage()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: oldRoot) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), original = try recoverySeed(storage: oldStorage)
    var duplicate = try recoverySeed(storage: storage)
    let localBytes = Data("new-audio!".utf8)
    duplicate.audioHash = Files.hash(localBytes)
    duplicate.delivery = DeliveryState(status: .pending, remotePath: settings.remoteMediaPath(duplicate.id))
    duplicate.delivery?.destinationURL = settings.feedFolderURL
    do { let store = try NativeStore(url: storage.profile.database); try store.save(duplicate) }
    try Files.directory(storage.audioDirectory)
    let localFile = storage.audioDirectory.appendingPathComponent(duplicate.id + ".m4a")
    try Files.write(localBytes, to: localFile)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(original, settings: settings), "/podcast/audio/\(original.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.verifiedCopies == 1)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    let episode = try #require(await coordinator.library(storage: storage).first)
    #expect(episode.id == original.id && episode.audioHash == original.audioHash)
    #expect(try Data(contentsOf: localFile) == localBytes) // no unconfirmed local deletion
}

private func recoveryLocalFile(_ episode: Episode, duration: Double, storage: ManagedSpeechStorage, bytes: Data = Data("test-audio".utf8)) throws -> Episode {
    var local = episode
    try Files.directory(local.settings.audio)
    try Files.write(bytes, to: local.settings.audio.appendingPathComponent(local.id + ".m4a"))
    local.audioHash = Files.hash(bytes); local.encodedHash = local.audioHash
    local.info = AudioInfo(duration: duration, byteLength: Int64(bytes.count), sampleRate: 24_000, channels: 1, codec: "aac")
    local.audioFinalizationComplete = true // Fake fixture has already-finalized metadata; no speech acceptance claim.
    try NativeStore(url: storage.profile.database).save(local)
    return local
}

@Test func serverRecoveryLongerLocalCopyGetsNewIdentityWithoutOverwritingServer() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let original = try recoverySeed(storage: storage)
    _ = try recoveryLocalFile(original, duration: 40, storage: storage)
    let path = "/podcast/audio/\(original.id).m4a", oldBytes = Data("other-data".utf8)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(original, settings: settings), path: oldBytes])
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    let winner = try #require(await coordinator.library(storage: storage).first)
    #expect(winner.id != original.id && winner.info?.duration == 40)
    #expect(winner.audioHash == original.audioHash && result.uploadedMedia == 1 && result.feedUploaded)
    #expect(transport.objects[path] == oldBytes)
    #expect(transport.objects["/podcast/audio/\(winner.id).m4a"] == Data("test-audio".utf8))
    let feed = try #require(transport.objects["/podcast/feed.xml"])
    #expect(String(decoding: feed, as: UTF8.self).contains(winner.id))
    #expect(!String(decoding: feed, as: UTF8.self).contains(original.id))
}

@Test func serverRecoveryCorruptServerUsesValidLocalWithoutDeletingDamagedBytes() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let original = try recoveryLocalFile(recoverySeed(storage: storage), duration: 20, storage: storage)
    let path = "/podcast/audio/\(original.id).m4a", damaged = Data("damaged".utf8)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(original, settings: settings), path: damaged])
    transport.invalidPaths.insert(path)
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(result.uploadedMedia == 1 && result.feedUploaded)
    #expect(try await coordinator.library(storage: storage).first?.id != original.id)
    #expect(transport.objects[path] == damaged)
}

@Test func serverRecoveryInvalidLocalDoesNotBlockVerifiedServer() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let original = try recoveryLocalFile(recoverySeed(storage: storage), duration: 40, storage: storage)
    try Files.write(Data("replaced-local".utf8), to: original.settings.audio.appendingPathComponent(original.id + ".m4a"))
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(original, settings: settings), "/podcast/audio/\(original.id).m4a": Data("other-data".utf8)])
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    let winner = try #require(await coordinator.library(storage: storage).first)
    #expect(winner.id == original.id && winner.audioHash == Files.hash(Data("other-data".utf8)))
    #expect(result.uploadedMedia == 0 && winner.localAudioReleased == true)
}

@Test func serverRecoveryItemFailurePreservesFeedAndPublishesHealthyLocalItem() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let broken = try recoverySeed(storage: storage, path: "broken")
    let healthy = try recoveryLocalFile(recoverySeed(storage: storage, path: "healthy"), duration: 20, storage: storage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(broken, settings: settings)])
    transport.failingPaths.insert("/podcast/audio/\(broken.id).m4a")
    let log = DeliveryDebugLog(); log.enabled = true
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, debugLog: log)
    #expect(result.uploadedMedia == 1 && result.feedUploaded && result.failed == 1)
    let feed = String(decoding: try #require(transport.objects["/podcast/feed.xml"]), as: UTF8.self)
    #expect(feed.contains(broken.id) && feed.contains(healthy.id))
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.reconciliationError != nil && ledger.blockedServerIDs?.contains(broken.id) == true)
    #expect(log.text.contains("itemFailed") && !log.text.contains("news.example"))
}

@Test func serverRecoveryCachedScanShortCircuitsUntilDueAndReusesVerifiedMedia() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), "/podcast/audio/\(episode.id).m4a": Data("test-audio".utf8)])
    let now = Date()
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: false, now: now, debugLog: nil)
    let count = transport.methods.count
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: false, now: now.addingTimeInterval(60), debugLog: nil)
    #expect(transport.methods.count == count)
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: false, now: now.addingTimeInterval(301), debugLog: nil)
    #expect(transport.methods.count == count + 1) // Only the feed; unchanged proof still fresh.
    let feed = try #require(transport.objects["/podcast/feed.xml"])
    transport.objects["/podcast/feed.xml"] = Data(String(decoding: feed, as: UTF8.self).replacingOccurrences(of: "<title>VoiceRelay</title>", with: "<title>Renamed channel</title>").utf8)
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: false, now: now.addingTimeInterval(602), debugLog: nil)
    #expect(transport.methods.count == count + 2) // Changed RSS does not invalidate identical per-item hash/size evidence.
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: true, now: now.addingTimeInterval(603), debugLog: nil)
    #expect(transport.methods.count == count + 5) // Force checks current media when no strong validator is available.
}

@Test func serverRecoveryRepresentationDigestRequiresExactlyOneSHA256() {
    let bytes = Data(repeating: 42, count: 32)
    let field = "sha-256=:\(bytes.base64EncodedString()):"
    #expect(FixtureCoordinator.representationHash(field) == bytes.map { String(format: "%02x", $0) }.joined())
    #expect(FixtureCoordinator.representationHash(field + "," + field) == nil)
    #expect(FixtureCoordinator.representationHash("sha-256=:YQ==:") == nil)
    #expect(!FixtureCoordinator.strongETag("W/\"version\""))
}

@Test func serverRecoveryConditionalFeedAndStrongMediaValidatorsAvoidRepeatDownloads() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), episode = try recoverySeed(storage: storage)
    let media = "/podcast/audio/\(episode.id).m4a"
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(episode, settings: settings), media: Data("test-audio".utf8)])
    transport.etags = ["/podcast/feed.xml": "\"feed-1\"", media: "\"audio-1\""]
    let now = Date()
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: false, now: now, debugLog: nil)
    let count = transport.methods.count
    try await coordinator.reconcileServerAutomatically(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport, force: false, now: now.addingTimeInterval(86_401), debugLog: nil)
    #expect(Array(transport.methods.dropFirst(count)) == ["GET", "HEAD"])
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).serverAudioProofs?[episode.id]?.checkedAt == now.addingTimeInterval(86_401))
}

@Test func serverRecoveryWholeFeedFailureLeavesFeedUntouchedAndUploadsOtherMedia() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let local = try recoveryLocalFile(recoverySeed(storage: storage), duration: 20, storage: storage)
    let badFeed = Data("<rss>incomplete".utf8), transport = RecoveryTransport(["/podcast/feed.xml": badFeed])
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(result.uploadedMedia == 1 && !result.feedUploaded)
    #expect(transport.objects["/podcast/feed.xml"] == badFeed)
    #expect(transport.objects["/podcast/audio/\(local.id).m4a"] == Data("test-audio".utf8))
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).serverFeedUnsafe == true)
}

@Test func serverRecoveryDifferentNarrationSpeedsDoNotSelectLongerLocalVariant() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator(), server = try recoverySeed(storage: storage)
    var local = try recoveryLocalFile(server, duration: 40, storage: storage)
    local.settings.backendSettings["speed"] = .number(0.9)
    try NativeStore(url: storage.profile.database).save(local)
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(server, settings: settings), "/podcast/audio/\(server.id).m4a": Data("other-data".utf8)])
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    let winner = try #require(await coordinator.library(storage: storage).first)
    #expect(winner.id == server.id && winner.info?.duration == 20)
    #expect(winner.settings.backendSettings["speed"]?.numericValue == 1)
}

private struct RawRecoveryTransport: DeliveryTransport {
    let bytes: Data
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        DeliveryResponse(status: 200, headers: ["Content-Length": String(bytes.count)], body: bytes)
    }
}
@Test func serverRecoveryDefaultVerifierDecodesActualAACAndRejectsDamagedBytes() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("synthetic.m4a"), profile = storage.profile
    let wave = root.appendingPathComponent("synthetic.wav")
    let writer = try AtomicAudioWriter(destination: wave)
    try writer.append(samples: (0..<12_000).map { Float(sin(2 * Double.pi * 330 * Double($0) / 24_000) * 0.1) }, sampleRate: 24_000)
    try writer.publish()
    try NativeAudio.encode([wave], destination: file, profile: .init())
    let bytes = try Data(contentsOf: file), url = URL(string: "https://dav.example/audio.m4a")!
    let valid = try await RawRecoveryTransport(bytes: bytes).verifiedAudio(url, headers: [:], maximumBytes: 1_000_000, settings: profile)
    #expect(valid.digest.sha256 == Files.hash(bytes) && valid.info?.codec == "aac" && (valid.info?.duration ?? 0) > 0)
    await #expect(throws: InvalidServerAudio.self) {
        try await RawRecoveryTransport(bytes: Data("damaged-container".utf8)).verifiedAudio(url, headers: [:], maximumBytes: 1_000_000, settings: profile)
    }
}

@Test func serverRecoveryUsesNativeInspectionDespiteLegacyToolSettings() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    var profile = storage.profile
    profile.ffprobe = root.appendingPathComponent("missing-ffprobe").path
    profile.ffmpeg = root.appendingPathComponent("missing-ffmpeg").path
    profile.toolTimeoutSeconds = 0
    let wave = root.appendingPathComponent("synthetic.wav"), file = root.appendingPathComponent("synthetic.m4a")
    let writer = try AtomicAudioWriter(destination: wave)
    try writer.append(samples: (0..<12_000).map { Float(sin(2 * Double.pi * 330 * Double($0) / 24_000) * 0.1) }, sampleRate: 24_000)
    try writer.publish()
    try NativeAudio.encode([wave], destination: file, profile: .init())
    let bytes = try Data(contentsOf: file), url = URL(string: "https://dav.example/audio.m4a")!
    let valid = try await RawRecoveryTransport(bytes: bytes).verifiedAudio(url, headers: [:], maximumBytes: 1_000_000, settings: profile)
    #expect(valid.digest.sha256 == Files.hash(bytes) && valid.info?.codec == "aac")
    await #expect(throws: InvalidServerAudio.self) {
        try await RawRecoveryTransport(bytes: Data("damaged-container".utf8)).verifiedAudio(url, headers: [:], maximumBytes: 1_000_000, settings: profile)
    }
}

@Test func serverRecoveryFailureIsVisibleBeforeAnEmptyLibraryHasADatabase() async throws {
    let (root, storage) = try recoveryStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let transport = RecoveryTransport(["/podcast/feed.xml": Data("<rss>incomplete".utf8)])
    let coordinator = FixtureCoordinator(), settings = recoverySettings()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.lastError?.contains("reconciliation could not finish") == true)
    #expect(!FileManager.default.fileExists(atPath: storage.profile.database.path))
}

@Test(arguments: [false, true])
func serverRecoveryPreservesIntentionalNewGenerationWhenOlderRemoteGUIDWasUnknown(legacy: Bool) async throws {
    let (oldRoot, oldStorage) = try recoveryStorage(), (root, storage) = try recoveryStorage()
    defer { try? FileManager.default.removeItem(at: oldRoot); try? FileManager.default.removeItem(at: root) }
    let settings = recoverySettings(), coordinator = FixtureCoordinator()
    let remote = try recoverySeed(storage: oldStorage, path: "same-article")
    let database = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
    let key = "reviewed-url-v1-" + Files.hash(Data(remote.sourceURL!.absoluteString.utf8))
    let new: Episode
    do {
        let store = try NativeStore(url: database)
        var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"; profile.voice = "af_bella"
        var episode = try store.episode(sourceKey: key, settings: profile)
        episode.title = remote.title; episode.originalSourceHost = remote.originalSourceHost
        episode.replacesDuplicateAudio = true; episode.stage = .extracted
        try store.save(episode)
        try store.saveQueueItem(.init(id: episode.id, title: episode.title))
        new = episode
    }
    let transport = RecoveryTransport(["/podcast/feed.xml": try recoveryFeed(remote, settings: settings, legacy: legacy),
        "/podcast/audio/\(remote.id).m4a": Data("test-audio".utf8)])
    let report = try await coordinator.inspectServerAudio(storage: storage, settings: settings, credential: RecoveryCredentials(), transport: transport)
    #expect(report.issues.isEmpty)
    try await coordinator.applyServerAudioRecovery(report, storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [new.id])
    var episodes = try await coordinator.library(storage: storage)
    #expect(episodes.count == 2)
    #expect(episodes.first { $0.id == new.id }?.settings.voice == "af_bella")
    #expect(episodes.first { $0.id == new.id }?.stage == .extracted)
    #expect(episodes.first { $0.id == remote.id }?.originalSourceIdentity == key)
    // Simulate confirmed replacement publication. Recovered old history was inserted
    // later, but must still retire once the deliberate new generation is confirmed.
    do {
        let store = try NativeStore(url: database)
        var successor = try #require(store.episodes().first { $0.id == new.id })
        successor.stage = .published; successor.audioHash = String(repeating: "b", count: 64)
        successor.delivery = DeliveryState(status: .uploaded, remotePath: settings.remoteMediaPath(new.id))
        successor.delivery?.destinationURL = settings.feedFolderURL
        try store.save(successor)
    }
    let pipeline = try PipelineStore(databaseURL: database)
    #expect(try pipeline.retireConfirmedDuplicates(settings: settings, confirmed: [new.id: String(repeating: "b", count: 64)], blocked: []))
    episodes = try await coordinator.library(storage: storage)
    #expect(episodes.first { $0.id == remote.id }?.stage == .expired)
    #expect(episodes.first { $0.id == new.id }?.stage == .published)
}
