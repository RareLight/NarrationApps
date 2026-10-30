import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import AudioOutput
import ImageIO
#if canImport(Security)
import Security
import LocalAuthentication
#endif
@testable import VoiceRelayCore

private func deliveryTemporary() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("voicerelay-delivery-\(UUID().uuidString)")
    try Files.directory(url); return url
}

private func deliveryStorage(root: URL) throws -> ManagedSpeechStorage {
    try Files.directory(root.appendingPathComponent("audio"))
    return ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
                                stateRoot: root.appendingPathComponent("state"),
                                temporaryRoot: root.appendingPathComponent("scratch"))
}

private func deliveryReview(_ path: String = "one", host: String = "articles.example", title: String? = nil) throws -> ReviewedSource {
    let url = URL(string: "https://\(host)/\(path)")!
    var html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    if let title { html = html.replacingOccurrences(of: "A &amp; B: Reading &lt;Carefully&gt;", with: RSS.escaped(title)) }
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
                           contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    return try ReviewedSource.prepare(page, chunkLimit: 1800)
}

private func deliverySettings(enabled: Bool = true) -> DeliverySettings {
    var settings = DeliverySettings()
    settings.enabled = enabled
    settings.feedFolderURL = URL(string: "https://webdav.example/remote.php/dav/files/user/Podcast%20Feed/")
    settings.username = "user@example.com"
    settings.publicFolderURL = URL(string: "https://podcast.example/")
    return settings
}

private struct FakeCredentials: DeliveryCredentialStore {
    let password: String?
    func readPassword(username: String, host: String) throws -> String? { password }
    func writePassword(_ password: String, username: String, host: String) throws {}
    func deletePassword(username: String, host: String) throws {}
}

/// In-memory WebDAV double. Records every call, stores PUT byte counts, serves HEAD
/// from stored sizes, and can inject per-call status overrides or thrown failures.
private final class FakeWebDAVTransport: DeliveryTransport, @unchecked Sendable {
    struct Call { let method: String; let path: String; let authorized: Bool; let bytes: Int; let credentials: String?; let depth: String?; let directory: Bool; let url: URL; let encoding: String? }
    private let lock = NSLock()
    private var calls: [Call] = []
    private var objects: [String: Int] = [:]
    private var bodies: [String: Data] = [:]
    var statusFor: ((String, String) -> Int?)?
    var throwFor: ((String, String) -> (any Error)?)?
    var headLengths: [String: Int] = [:]
    var headHeaders: [String: [String: String]] = [:]
    var davLengths: [String: Int] = [:]
    var getResponseFor: ((String) -> DeliveryResponse?)?
    var propfindBodyFor: ((String) -> Data)?
    var recordedCalls: [Call] { lock.withLock { calls } }
    var methods: [String] { recordedCalls.map(\.method) }
    func upload(_ url: URL, file: URL, headers: [String: String], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DeliveryResponse {
        let bytes = Int64(try Data(contentsOf: file).count)
        progress(bytes / 2, bytes)
        let response = try await request("PUT", url: url, body: nil, file: file, headers: headers)
        progress(bytes, bytes)
        return response
    }
    func objectLength(_ path: String) -> Int? { lock.withLock { objects[path] } }
    func body(_ path: String) -> Data? { lock.withLock { bodies[path] } }
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        try Task.checkCancellation()
        let path = url.path
        let bytes = try body?.count ?? file.map { try Int(Data(contentsOf: $0).count) } ?? 0
        let (injected, failure) = lock.withLock { () -> (Int?, (any Error)?) in
            calls.append(Call(method: method, path: path,
                              authorized: headers["Authorization"]?.hasPrefix("Basic ") == true, bytes: bytes,
                              credentials: headers["Authorization"].flatMap { raw -> String? in
                                  guard raw.hasPrefix("Basic "), let data = Data(base64Encoded: String(raw.dropFirst(6))),
                                        let decoded = String(data: data, encoding: .utf8) else { return nil }
                                  return decoded
                              }, depth: headers["Depth"], directory: url.hasDirectoryPath, url: url, encoding: headers["Accept-Encoding"]))
            return (statusFor?(method, path), throwFor?(method, path))
        }
        if let failure { throw failure }
        if let injected { return DeliveryResponse(status: injected) }
        switch method {
        case "PROPFIND":
            let length = lock.withLock { objects[path].map { davLengths[path] ?? $0 } }
            let properties = length.map { "<d:getcontentlength>\($0)</d:getcontentlength><d:resourcetype/>" }
                ?? "<d:resourcetype><d:collection/></d:resourcetype>"
            let href = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
            let xml = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(properties)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
            return DeliveryResponse(status: 207, body: propfindBodyFor?(path) ?? Data(xml.utf8))
        case "GET":
            if let override = getResponseFor?(path) { return override }
            guard let data = lock.withLock({ bodies[path] }) else { return DeliveryResponse(status: 404) }
            return DeliveryResponse(status: 200, headers: ["Content-Length": String(data.count)], body: data)
        case "MKCOL": return DeliveryResponse(status: 201)
        case "PUT":
            lock.withLock {
                objects[path] = bytes
                bodies[path] = body ?? file.flatMap { try? Data(contentsOf: $0) }
            }
            return DeliveryResponse(status: 201)
        case "HEAD":
            if let headers = headHeaders[path] { return DeliveryResponse(status: 200, headers: headers) }
            let known = lock.withLock { objects[path].map { headLengths[path] ?? $0 } }
            guard let known else { return DeliveryResponse(status: 404) }
            return DeliveryResponse(status: 200, headers: ["Content-Length": String(known)])
        case "DELETE":
            let existed = lock.withLock { () -> Bool in
                bodies.removeValue(forKey: path)
                return objects.removeValue(forKey: path) != nil
            }
            return DeliveryResponse(status: existed ? 204 : 404)
        default: return DeliveryResponse(status: 405)
        }
    }
}

// Test-only audio, identical in spirit to the CoreTests synthesizer.
private struct DeliveryTestBackend: TTSBackend {
    let identity = BackendIdentity(id: "delivery-test-audio-v1", displayName: "Synthetic delivery test audio", isMock: false)
    func prepare() throws { try Task.checkCancellation() }
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try Task.checkCancellation()
        let rate = 24000; let count = rate / 4
        var pcm = Data()
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        pcm.append(Data("RIFF".utf8)); u32(UInt32(36 + count * 2)); pcm.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        pcm.append(Data("data".utf8)); u32(UInt32(count * 2))
        for sample in 0..<count {
            let ramp = min(1.0, Double(min(sample, count - 1 - sample)) / 240.0)
            u16(UInt16(bitPattern: Int16(sin(Double(sample) * 2 * .pi * 330 / Double(rate)) * 3000 * ramp)))
        }
        let file = directory.appendingPathComponent("segment.wav")
        try Files.write(pcm, to: file)
        return SynthesisResult(artifacts: [LosslessArtifact(url: file, sampleRate: rate, channels: 1, format: "wav")])
    }
}


@Test func feedItemsExposeOriginalSourceAsLinkAndDescription() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    var episode = result.episode
    let source = URL(string: "https://articles.example/report?one=1&two=two%20words#section")!
    episode.sourceURL = source
    episode.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(episode.id).m4a",
                                    uploadedByteLength: episode.info!.byteLength)
    let channel = try RemoteChannel(settings: settings)
    let expectedNote = "<p>Original source: <a href=\"https://articles.example/report?one=1&amp;two=two%20words#section\">https://articles.example/report?one=1&amp;two=two%20words#section</a></p>"
    for feed in [try RSS.render([episode], settings: episode.settings), try RSS.renderRemote([episode], channel: channel)] {
        let document = try XMLDocument(data: feed)
        let items = try document.nodes(forXPath: "//item")
        #expect(items.count == 1)
        let links = try items[0].nodes(forXPath: "link")
        #expect(links.count == 1 && links[0].stringValue == source.absoluteString)
        let descriptions = try items[0].nodes(forXPath: "description")
        #expect(descriptions.count == 1 && descriptions[0].stringValue == expectedNote)
    }
}

@Test func feedItemsOmitSourceMetadataForMissingOrUnsafeSources() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let channel = try RemoteChannel(settings: settings)
    for unsafe in ["file:///private/var/secret.pdf", "javascript:alert(1)", "data:text/html,hi",
                   "not-absolute", "https://user:password@articles.example/secret?token=abc"] {
        var episode = result.episode
        episode.sourceURL = URL(string: unsafe)
        episode.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(episode.id).m4a",
                                        uploadedByteLength: episode.info!.byteLength)
        let document = try XMLDocument(data: try RSS.renderRemote([episode], channel: channel))
        let items = try document.nodes(forXPath: "//item")
        #expect(items.count == 1)
        #expect(try items[0].nodes(forXPath: "link").isEmpty && items[0].nodes(forXPath: "description").isEmpty)
        let feed = String(decoding: try RSS.renderRemote([episode], channel: channel), as: UTF8.self)
        #expect(!feed.contains(unsafe) && !feed.contains("password"))
    }
    var missing = result.episode
    missing.sourceURL = nil
    missing.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(missing.id).m4a",
                                    uploadedByteLength: missing.info!.byteLength)
    let document = try XMLDocument(data: try RSS.renderRemote([missing], channel: channel))
    #expect(try document.nodes(forXPath: "//item/link").isEmpty && document.nodes(forXPath: "//item/description").isEmpty)
}

@Test func serverFeedParserKeepsIdentityWithSourceDescriptionPresent() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    var episode = result.episode
    episode.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(episode.id).m4a",
                                    uploadedByteLength: episode.info!.byteLength)
    let feed = try RSS.renderRemote([episode], channel: RemoteChannel(settings: settings))
    let parsed = try #require(ServerFeedParser.parse(feed).first)
    #expect(parsed.id == episode.id && parsed.source == episode.sourceURL)
}

private func publishReview(_ path: String = "one", storage: ManagedSpeechStorage,
                           delivery: DeliverySettings? = nil) async throws -> FixtureResult {
    try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: deliveryReview(path),
                                               backend: DeliveryTestBackend(), storage: storage, delivery: delivery)
}

@Test func readingListEpisodeDatesReachLocalAndRemoteFeedsInSavedOrder() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let oldest = ReadingListEntry(id: "oldest", safariID: "oldest", url: URL(string: "https://articles.example/oldest")!,
                                 title: "Oldest", addedAt: Date(timeIntervalSinceReferenceDate: 0))
    let newest = ReadingListEntry(id: "newest", safariID: "newest", url: URL(string: "https://articles.example/newest")!,
                                 title: "Newest", addedAt: Date(timeIntervalSinceReferenceDate: 86_400))
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [oldest, newest], skippedEntries: 0), stateRoot: storage.stateRoot)
    // Generate in the opposite order to the dates saved in Reading List.
    var results: [FixtureResult] = []
    for entry in [newest, oldest] {
        let review = try deliveryReview(entry.id, title: entry.title)
        let item = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(),
                                                            fetch: { _ in review.page })
        let queued = try #require(await coordinator.library(storage: storage).first { $0.id == item.id })
        #expect(queued.readingListSavedAt == entry.addedAt && queued.publicationDate == nil)
        let result = try await coordinator.resume(storage: storage, articleID: item.id, backend: DeliveryTestBackend(), delivery: settings)
        #expect(result.episode.readingListSavedAt == entry.addedAt)
        #expect(try #require(result.episode.publicationDate) > Date(timeIntervalSinceReferenceDate: 86_400))
        results.append(result)
    }
    let local = try String(contentsOf: storage.profile.feed, encoding: .utf8)
    #expect(local.contains("<pubDate>Tue, 02 Jan 2001 00:00:00 GMT</pubDate>"))
    #expect(local.contains("<pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate>"))
    #expect(try #require(local.range(of: results[0].episode.guid)).lowerBound < #require(local.range(of: results[1].episode.guid)).lowerBound)
    let transport = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    let remote = String(decoding: try #require(transport.body("/" + settings.remoteFeedPath)), as: UTF8.self)
    #expect(remote.contains("<pubDate>Tue, 02 Jan 2001 00:00:00 GMT</pubDate>"))
    #expect(remote.contains("<pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate>"))
    #expect(try #require(remote.range(of: results[0].episode.guid)).lowerBound < #require(remote.range(of: results[1].episode.guid)).lowerBound)
    // Undated/old JSON records keep the generation-date fallback.
    var undated = results[0].episode; undated.readingListSavedAt = nil
    let encoded = try #require(JSONSerialization.jsonObject(with: Files.json(undated)) as? [String: Any])
    #expect(encoded["readingListSavedAt"] == nil)
    let decoded = try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(decoded.readingListSavedAt == nil && decoded.podcastDate == decoded.publicationDate)
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    let fallbackDate = "<pubDate>\(formatter.string(from: try #require(decoded.publicationDate)))</pubDate>"
    #expect(String(decoding: try RSS.render([decoded], settings: decoded.settings), as: UTF8.self).contains(fallbackDate))
    // Use the confirmed record for the remote fallback.
    var confirmed = try #require(await coordinator.library(storage: storage).first { $0.id == decoded.id })
    confirmed.readingListSavedAt = nil
    #expect(String(decoding: try RSS.renderRemote([confirmed], channel: RemoteChannel(settings: settings)), as: UTF8.self).contains(fallbackDate))
}

@Test func readingListEpisodeDatesRecoverExistingPublishedMetadataWithoutAudioUpload() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview("legacy-date", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).remoteFeedPending == false)
    let original = result.article.originalURL
    #expect(result.episode.sourceURL != original) // Canonical link differs from Reading List identity.
    let entry = ReadingListEntry(id: "legacy-date", safariID: "legacy-date", url: original, title: "Legacy date",
                                 addedAt: Date(timeIntervalSinceReferenceDate: 0))
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let record: String
    do { record = try #require(NativeStore(url: storage.profile.database, readOnly: true).query("SELECT record FROM episodes WHERE id=?", [result.episode.id]).first?.first) }
    let saved = try #require(await coordinator.library(storage: storage).first)
    #expect(saved.readingListSavedAt == entry.addedAt && saved.publicationDate == result.episode.publicationDate)
    do { #expect(try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT record FROM episodes WHERE id=?", [saved.id]).first?.first == record) }
    #expect(String(decoding: try RSS.render([saved], settings: saved.settings), as: UTF8.self).contains("<pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate>"))
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).remoteFeedPending)
    let updated = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(updated.feedUploaded && updated.uploadedMedia == 0)
    #expect(try Files.hash(result.audioURL) == result.episode.audioHash)
    let remote = String(decoding: try #require(transport.body("/" + settings.remoteFeedPath)), as: UTF8.self)
    #expect(remote.contains("<pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate>"))
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).remoteFeedPending == false)
}

@Test func deliverySettingsValidationMatrix() throws {
    try deliverySettings().validate()
    var missing = deliverySettings(); missing.feedFolderURL = nil
    #expect(throws: RelayError.self) { try missing.validate() }
    missing = deliverySettings(); missing.publicFolderURL = nil
    #expect(throws: RelayError.self) { try missing.validate() }
    missing.enabled = false; try missing.validate()
    missing = deliverySettings(); missing.username = nil; try missing.validate()
    for username in [" ", "user:name", "user\nname"] {
        missing.username = username
        #expect(throws: RelayError.self) { try missing.validate() }
    }
    for input in ["ftp://example.com/podcast", "https://user:secret@example.com/podcast", "https://example.com/podcast?x=1", "https://example.com:0/podcast", "https://example.com/a%2fb", "https://example.com/a%0ab", "https://bad host/podcast", "https://", "https://example.com/a\\b", "https://example.com/a\nb"] {
        #expect(throws: RelayError.self) { try DeliveryURL.folder(input) }
    }
}

@Test func deliveryFolderURLNormalizationAndFixedNames() throws {
    let cases: [(String, String)] = [
        ("  webdav.example/podcast  ", "https://webdav.example/podcast/"),
        ("https://WEBDAV.EXAMPLE:443//podcast/./", "https://webdav.example/podcast/"),
        ("http://example.com:80/old/../podcast/#anchor", "https://example.com/podcast/"),
        ("//example.com/../../podcast/feed.xml", "https://example.com/podcast/"),
        ("https://example.com/Podcast Feed/", "https://example.com/Podcast%20Feed/"),
        ("https://example.com/Podcast%20Feed", "https://example.com/Podcast%20Feed/"),
        ("https://example.com/a/%2e%2e/podcast", "https://example.com/podcast/"),
        ("https://example.com/Café/音声", "https://example.com/Caf%C3%A9/%E9%9F%B3%E5%A3%B0/"),
        ("https://example.com/100%25", "https://example.com/100%25/"),
        ("https://example.com", "https://example.com/")
    ]
    #expect(try DeliveryURL.folder("   ") == nil)
    for (input, expected) in cases {
        let folder = try #require(try DeliveryURL.folder(input))
        #expect(folder.absoluteString == expected)
        #expect(try DeliveryURL.folder(folder.absoluteString) == folder)
        var settings = deliverySettings()
        settings.feedFolderURL = folder; settings.publicFolderURL = folder
        try settings.validate()
        #expect(settings.publicFeedURL?.absoluteString == expected + "feed.xml")
        #expect(settings.publicAudioBaseURL?.absoluteString == expected + "audio/")
    }
}

@Test func deliveryErrorClassification() {
    for status in [401] {
        #expect(DeliveryError.classify(status) == .authFailed("Delivery credentials were rejected (HTTP \(status))."))
    }
    #expect(DeliveryError.classify(403) == .permissionDenied(DeliveryError.permissionNotice))
    for status in [500, 502, 503, 599] {
        guard case .retryable = DeliveryError.classify(status) else { Issue.record("5xx not retryable"); return }
    }
    for status in [301, 302, 400, 404, 409, 418] {
        guard case .fatal = DeliveryError.classify(status) else { Issue.record("status \(status) not fatal"); return }
    }
}

@Test func deliverySendsPasswordOnlyCredentialWhenUsernameUnset() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    var settings = deliverySettings()
    settings.username = nil
    try settings.validate()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "app-password"), transport: transport)
    #expect(drain.uploadedMedia == 1 && drain.feedUploaded)
    let calls = transport.recordedCalls
    #expect(calls.allSatisfy { $0.authorized && $0.credentials == ":app-password" })
    let episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .uploaded)
    var named = deliverySettings()
    named.username = "user@example.com"
    let namedTransport = FakeWebDAVTransport()
    try await WebDAVClient(transport: namedTransport, settings: named,
                           credential: FakeCredentials(password: "pw")).ensureCollections()
    #expect(namedTransport.recordedCalls.allSatisfy { $0.credentials == "user@example.com:pw" })
}

@Test func transportErrorClassificationDistinguishesTLSFromReachability() {
    let certificate = URLSessionDeliveryTransport.classifyTransport(
        URLError(.serverCertificateUntrusted))
    guard case .fatal(let message) = certificate else { Issue.record("TLS failure not fatal"); return }
    #expect(message.contains("certificate"))
    guard case .fatal = URLSessionDeliveryTransport.classifyTransport(URLError(.cannotFindHost)) else {
        Issue.record("DNS failure not fatal"); return
    }
    guard case .retryable = URLSessionDeliveryTransport.classifyTransport(URLError(.cannotConnectToHost)) else {
        Issue.record("connect failure not retryable"); return
    }
    guard case .retryable = URLSessionDeliveryTransport.classifyTransport(URLError(.timedOut)) else {
        Issue.record("timeout not retryable"); return
    }
    struct Other: Error {}
    guard case .retryable = URLSessionDeliveryTransport.classifyTransport(Other()) else {
        Issue.record("unknown error not retryable"); return
    }
}

@Test func episodeDeliveryFieldsDecodeFromOlderRecordsAndRoundTrip() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let result = try await publishReview(storage: storage, delivery: deliverySettings())
    var episode = result.episode
    #expect(episode.author == "Private Author")
    #expect(episode.sourceHost == "articles.example")
    #expect(episode.originalSourceHost == "articles.example")
    #expect(episode.sourceURL?.absoluteString == "https://articles.example/private-canonical")
    #expect(episode.delivery?.status == .pending)
    #expect(episode.delivery?.remotePath == "remote.php/dav/files/user/Podcast Feed/audio/\(episode.id).m4a")
    #expect(result.remoteDelivery == "pending")
    var legacy = try #require(JSONSerialization.jsonObject(with: Files.json(episode)) as? [String: Any])
    for key in ["author", "sourceHost", "originalSourceHost", "sourceURL", "delivery", "audioVolumeID", "manualAudioDeletionRequested"] {
        legacy.removeValue(forKey: key)
    }
    let restored = try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.id == episode.id && restored.author == nil && restored.sourceURL == nil && restored.delivery == nil && restored.originalSourceHost == nil)
    episode.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/x.m4a",
                                   attempts: 2, uploadedByteLength: 123, lastAttemptAt: Date(timeIntervalSince1970: 100))
    let decoded = try JSONDecoder().decode(Episode.self, from: Files.json(episode))
    #expect(decoded.delivery == episode.delivery && decoded.author == episode.author)
    let secondRoot = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: secondRoot) }
    let noDelivery = try await publishReview("two", storage: deliveryStorage(root: secondRoot))
    #expect(noDelivery.remoteDelivery == "disabled" && noDelivery.episode.delivery == nil)
}

@Test func deliveryDrainUploadsMediaThenFeedInOrder() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "app-password"), transport: transport)
    #expect(drain.uploadedMedia == 1 && drain.feedUploaded && !drain.skipped)
    let sequence = transport.recordedCalls.map { "\($0.method) \($0.path)" }
    let mediaPath = "/remote.php/dav/files/user/Podcast Feed/audio/\(result.episode.id).m4a"
    let feedPath = "/remote.php/dav/files/user/Podcast Feed/feed.xml"
    #expect(sequence == ["GET \(feedPath)", "HEAD \(mediaPath)", "PROPFIND /remote.php/dav/files/user/Podcast Feed",
                         "PROPFIND /remote.php/dav/files/user/Podcast Feed/audio",
                         "HEAD \(mediaPath)", "PUT \(mediaPath)", "HEAD \(mediaPath)", "GET \(mediaPath)",
                         "GET \(feedPath)", "PUT \(feedPath)", "HEAD \(feedPath)", "GET \(feedPath)"])
    #expect(transport.recordedCalls.map(\.authorized).allSatisfy { $0 })
    let episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .uploaded)
    #expect(episode?.delivery?.uploadedByteLength == episode?.info?.byteLength)
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(!ledger.remoteFeedPending && ledger.lastUploadedFeedHash != nil && ledger.pendingRemoteDeletes.isEmpty)
    // A steady-state drain performs no work.
    let quiet = FakeWebDAVTransport()
    let credentials = SessionCredentialFixture()
    credentials.failure = .credentialUnavailable("Idle delivery must not ask for credentials")
    for _ in 0..<3 {
        let again = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
            credential: credentials, transport: quiet)
        #expect(again.uploadedMedia == 0 && !again.feedUploaded && quiet.methods.isEmpty)
    }
    #expect(credentials.reads == 0)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot) == ledger)
}

@Test func deliveryIdleDrainRescindsStaleDeleteIntentWithoutNetworkAccess() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: FakeWebDAVTransport())
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    ledger.pendingRemoteDeletes = [settings.remoteMediaPath(result.episode.id)]
    try ledger.save(stateRoot: storage.stateRoot)
    let quiet = FakeWebDAVTransport(), credentials = SessionCredentialFixture()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: credentials, transport: quiet)
    #expect(quiet.methods.isEmpty && credentials.reads == 0)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
}

@Test func deliveryBackoffSkipsCredentialsAndResumesWhenDue() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport(), credentials = SessionCredentialFixture()
    let start = Date(timeIntervalSince1970: 1_000)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: credentials, transport: transport, now: start)
    let store = try PipelineStore(databaseURL: storage.profile.database)
    var episode = try #require(store.published().first { $0.id == result.episode.id })
    episode.delivery?.status = .pending
    episode.delivery?.attempts = 1
    episode.delivery?.nextAttemptAt = start + 60
    try store.save(episode)
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    ledger.remoteFeedPending = true; ledger.feedAttempts = 1; ledger.lastAttemptAt = start
    try ledger.save(stateRoot: storage.stateRoot)
    let count = transport.recordedCalls.count, reads = credentials.reads
    _ = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: credentials, transport: transport, now: start + 59)
    #expect(transport.recordedCalls.count == count && credentials.reads == reads)
    let resumed = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: credentials, transport: transport, now: start + 60)
    #expect(resumed.uploadedMedia == 1 && resumed.feedUploaded && credentials.reads > reads)
}

@Test func deliveryDrainBackfillsUndeliveredPublishedEpisodes() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let published = try await publishReview(storage: storage)
    #expect(published.episode.delivery == nil && published.remoteDelivery == "disabled")
    let transport = FakeWebDAVTransport()
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: deliverySettings(),
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.uploadedMedia == 1 && drain.feedUploaded)
    let episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == published.episode.id }
    #expect(episode?.delivery?.status == .uploaded)
    #expect(episode?.author == "Private Author" && episode?.sourceHost == "articles.example")
}

@Test func deliveryDrainSkipsWhenDisabled() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    _ = try await publishReview(storage: storage, delivery: deliverySettings())
    let transport = FakeWebDAVTransport()
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: deliverySettings(enabled: false),
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.skipped && transport.recordedCalls.isEmpty)
}

@Test func deliveryUnconfirmedSizeFailsEpisodeWithoutFeedReferenceAndExplicitRetryRecovers() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    let mediaPath = "/remote.php/dav/files/user/Podcast Feed/audio/\(result.episode.id).m4a"
    transport.headLengths[mediaPath] = 1
    transport.davLengths[mediaPath] = 1
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.failed == 1 && drain.feedUploaded)
    let episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .failed)
    #expect(episode?.delivery?.verificationFailed == true)
    // The feed still uploads; the unconfirmed item is simply absent from it.
    let feedPath = "/remote.php/dav/files/user/Podcast Feed/feed.xml"
    let feed = String(decoding: try #require(transport.body(feedPath)), as: UTF8.self)
    #expect(!feed.contains(result.episode.id))
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(!ledger.remoteFeedPending && ledger.lastUploadedFeedHash != nil)
    // Automatic drains preserve the failure. Explicit upload retries recover this specific
    // verification failure without retrying unrelated fatal failures.
    transport.headLengths.removeAll(); transport.davLengths.removeAll()
    let automatic = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(automatic.uploadedMedia == 0)
    let retry = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(retry.uploadedMedia == 0 && retry.feedUploaded) // Complete existing bytes are reconciled without another PUT.
    #expect(try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }?.delivery?.status == .uploaded)
}

@Test func savedAudioPublicationTracksConfirmedFeedMembershipAndCopyIdentity() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let first = try await publishReview("first", storage: storage, delivery: settings)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        .publicationStates[first.episode.id] == .awaitingUpload)
    let transport = FakeWebDAVTransport(), credentials = FakeCredentials(password: "x")
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        .publicationStates[first.episode.id] == .published)
    let second = try await publishReview("second", storage: storage, delivery: settings)
    transport.statusFor = { method, path in method == "PUT" && path.hasSuffix("/feed.xml") ? 503 : nil }
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    let pending = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(pending.remoteFeedPending && pending.publicationStates[first.episode.id] == .published)
    #expect(pending.publicationStates[second.episode.id] == .uploaded)
    transport.statusFor = nil
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport, force: true)
    let complete = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(complete.publicationStates.values.allSatisfy { $0 == .published })
    var changed = settings
    changed.enabled = false; changed.username = "another@example.com"
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: changed).publicationStates == complete.publicationStates)
    changed = settings; changed.publicFolderURL = URL(string: "https://podcast.example/new/")
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: changed)
        .publicationStates.values.allSatisfy { $0 == .uploaded })
    changed = settings; changed.feedFolderURL = URL(string: "https://another.example/podcast/")
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: changed)
        .publicationStates.values.allSatisfy { $0 == .notUploaded })
    // A regenerated copy with the same episode ID must wait for a new feed confirmation.
    do {
        let store = try NativeStore(url: storage.profile.database)
        var episode = try #require(try store.episodes().first { $0.id == first.episode.id })
        episode.audioHash = "a-new-audio-copy"
        try store.save(episode)
    }
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        .publicationStates[first.episode.id] == .uploaded)
}

@Test func savedAudioPublicationInfersLegacyConfirmationOnlyFromMatchingFeedBytes() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let first = try await publishReview(storage: storage, delivery: settings)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: FakeWebDAVTransport())
    let url = DeliveryLedger.fileURL(stateRoot: storage.stateRoot)
    var legacy = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    legacy.removeValue(forKey: "lastPublishedAudioHashes"); legacy.removeValue(forKey: "lastPublishedSettingsHash")
    try JSONSerialization.data(withJSONObject: legacy).write(to: url, options: .atomic)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).lastPublishedAudioHashes == nil)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        .publicationStates[first.episode.id] == .published)
    let second = try await publishReview("unlisted", storage: storage, delivery: settings)
    let pending = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(pending.publicationStates[first.episode.id] == .published && pending.publicationStates[second.episode.id] == .awaitingUpload)
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    ledger.lastUploadedFeedHash = "an-unrelated-feed"
    try ledger.save(stateRoot: storage.stateRoot)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        .publicationStates[first.episode.id] == .uploaded)
}

@Test func deliveryRetryableBackoffForceAndRecovery() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    var failPut = true
    transport.statusFor = { method, path in failPut && method == "PUT" && path.contains("/audio/") ? 503 : nil }
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.retrying == 1 && drain.uploadedMedia == 0)
    var episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .pending && episode?.delivery?.attempts == 1)
    let nextAttempt = try #require(episode?.delivery?.nextAttemptAt)
    #expect(nextAttempt > Date())
    // Not yet due: a second drain performs no media PUT.
    let callsBefore = transport.recordedCalls.count
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(transport.recordedCalls.dropFirst(callsBefore).allSatisfy { ["GET", "PROPFIND"].contains($0.method) })
    episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .pending)
    // A new app session checks the feed, without treating startup as a forced upload retry.
    let beforeLaunch = transport.recordedCalls.count
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport, reconcileNow: true)
    #expect(transport.recordedCalls.dropFirst(beforeLaunch).contains { $0.method == "GET" })
    #expect(!transport.recordedCalls.dropFirst(beforeLaunch).contains { $0.method == "PUT" })
    episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .pending && episode?.delivery?.nextAttemptAt == nextAttempt)
    failPut = false
    let forced = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(forced.uploadedMedia == 1 && forced.feedUploaded)
    episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .uploaded && episode?.delivery?.nextAttemptAt == nil)
}

@Test func deliveryAuthFailureMarksAndSettingsChangeResets() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    var settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    var reject = true
    transport.statusFor = { method, _ in reject && method == "PUT" ? 401 : nil }
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.failed == 1)
    var episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .failed && episode?.delivery?.lastError == DeliveryError.authNotice)
    // Same settings: the credential failure is not retried.
    let callsBefore = transport.recordedCalls.count
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(transport.recordedCalls.dropFirst(callsBefore).allSatisfy { ["GET", "PROPFIND"].contains($0.method) })
    // Any settings change makes auth failures eligible again.
    reject = false
    settings.publicFolderURL = URL(string: "https://podcast.example/new-show/")
    let retry = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(retry.uploadedMedia == 1 && retry.feedUploaded)
    episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .uploaded && episode?.delivery?.lastError == nil)
}

@Test func deliveryFatalFailureStaysFailed() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    transport.statusFor = { method, _ in method == "PUT" ? 400 : nil }
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.failed == 1)
    let episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.status == .failed && episode?.delivery?.nextAttemptAt == nil)
    transport.statusFor = nil
    let callsBefore = transport.recordedCalls.count
    // The failed item is never retried; it blocks nothing, so the feed uploads without it.
    let second = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(second.feedUploaded && second.uploadedMedia == 0)
    #expect(transport.recordedCalls.dropFirst(callsBefore).allSatisfy { ["PROPFIND", "HEAD"].contains($0.method) || $0.path.hasSuffix("feed.xml") })
    #expect(try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }?.delivery?.status == .failed)
}

@Test func deliveryDrainOrdersFeedBeforeRemoteDeletes() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let keep = try await publishReview("keep", storage: storage, delivery: settings)
    let retired = try await publishReview("retire", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(transport.objectLength("/remote.php/dav/files/user/Podcast Feed/audio/\(retired.episode.id).m4a") != nil)
    _ = try await FixtureCoordinator().removeSavedAudio(ids: [retired.episode.id], storage: storage)
    let callsBefore = transport.recordedCalls.count
    // A fresh coordinator instance resumes from durable ledger state.
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.remoteDeletes == 1 && drain.feedUploaded && drain.uploadedMedia == 0)
    let sequence = transport.recordedCalls.dropFirst(callsBefore)
    let feedIndex = sequence.firstIndex { $0.method == "PUT" && $0.path.hasSuffix("Podcast Feed/feed.xml") }
    let deleteIndex = sequence.firstIndex { $0.method == "DELETE" }
    #expect(feedIndex != nil && deleteIndex != nil && feedIndex! < deleteIndex!)
    #expect(transport.objectLength("/remote.php/dav/files/user/Podcast Feed/audio/\(retired.episode.id).m4a") == nil)
    #expect(transport.objectLength("/remote.php/dav/files/user/Podcast Feed/audio/\(keep.episode.id).m4a") != nil)
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.pendingRemoteDeletes.isEmpty && !ledger.remoteFeedPending)
}

@Test(arguments: [false, true]) func deliveryFailedFeedUploadNeverStrandsRemoteDeletes(sizeFailure: Bool) async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let retired = try await publishReview("gone", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    _ = try await FixtureCoordinator().removeSavedAudio(ids: [retired.episode.id], storage: storage)
    if sizeFailure {
        let feedPath = "/remote.php/dav/files/user/Podcast Feed/feed.xml"
        transport.headLengths[feedPath] = 1; transport.davLengths[feedPath] = 1
    } else {
        transport.statusFor = { method, path in method == "PUT" && path.hasSuffix("feed.xml") ? 503 : nil }
    }
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(!drain.feedUploaded && drain.remoteDeletes == 0)
    #expect(transport.objectLength("/remote.php/dav/files/user/Podcast Feed/audio/\(retired.episode.id).m4a") != nil)
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.remoteFeedPending && ledger.pendingRemoteDeletes == ["remote.php/dav/files/user/Podcast Feed/audio/\(retired.episode.id).m4a"])
    let callsBeforeBackoff = transport.recordedCalls.count
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: nil), transport: transport,
        now: try #require(ledger.lastAttemptAt) + 1)
    #expect(transport.recordedCalls.count == callsBeforeBackoff)
    transport.statusFor = nil
    transport.headLengths.removeAll(); transport.davLengths.removeAll()
    let recovered = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect((recovered.feedUploaded || sizeFailure) && recovered.remoteDeletes == 1)
    // When only the receipt failed, GET confirms the already-updated feed without another PUT.
}

@Test func removeSavedAudioQueuesRemoteDeleteWithoutNetwork() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    let calls = transport.recordedCalls.count
    _ = try await FixtureCoordinator().removeSavedAudio(ids: [result.episode.id], storage: storage)
    #expect(transport.recordedCalls.count == calls)
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.pendingRemoteDeletes == ["remote.php/dav/files/user/Podcast Feed/audio/\(result.episode.id).m4a"])
    #expect(ledger.remoteFeedPending)
}

@Test func deliveryLedgerCorruptPreservesOriginal() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    _ = try await publishReview(storage: storage, delivery: deliverySettings())
    let file = DeliveryLedger.fileURL(stateRoot: storage.stateRoot)
    try Files.write(Data("not a ledger".utf8), to: file)
    #expect(try await FixtureCoordinator().savedAudio(storage: storage).count == 1)
    #expect(try Data(contentsOf: file) == Data("not a ledger".utf8))
    #expect(throws: RelayError.self) { try DeliveryLedger.load(stateRoot: storage.stateRoot) }
    let siblings = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
    let preserved = siblings.filter { $0.hasPrefix("delivery.json.corrupt-") }
    #expect(preserved.count == 1)
    // The corrupt bytes are preserved under the timestamped name, never silently reset.
    #expect(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(preserved[0])) == Data("not a ledger".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot) == DeliveryLedger())
}

@Test func deliveryCancellationMidDrainLeavesResumableState() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let retired = try await publishReview("gone", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    _ = try await FixtureCoordinator().removeSavedAudio(ids: [retired.episode.id], storage: storage)
    transport.throwFor = { method, _ in method == "DELETE" ? CancellationError() : nil }
    do {
        _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
            credential: FakeCredentials(password: "x"), transport: transport)
        Issue.record("Cancellation did not propagate")
    } catch { #expect(error is CancellationError) }
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.pendingRemoteDeletes == ["remote.php/dav/files/user/Podcast Feed/audio/\(retired.episode.id).m4a"] && !ledger.remoteFeedPending)
    transport.throwFor = nil
    let resumed = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(resumed.remoteDeletes == 1)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
    _ = result
}

@Test func renderRemoteIncludesConfirmedItemsOnlyWithOriginMetadata() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let channel = try RemoteChannel(settings: settings)
    var uploaded = result.episode
    uploaded.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(uploaded.id).m4a",
                                    uploadedByteLength: uploaded.info!.byteLength)
    let feed = String(decoding: try RSS.renderRemote([uploaded], channel: channel), as: UTF8.self)
    #expect(feed.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\""))
    #expect(feed.contains("<link>https://articles.example/private-canonical</link>"))
    #expect(feed.contains("&lt;a href=&quot;https://articles.example/private-canonical&quot;&gt;https://articles.example/private-canonical&lt;/a&gt;"))
    #expect(feed.contains("<dc:creator>Private Author</dc:creator>"))
    #expect(feed.contains("<enclosure url=\"https://podcast.example/audio/\(uploaded.id).m4a\""))
    #expect(feed.contains("<itunes:block>yes</itunes:block>") && XMLParser(data: Data(feed.utf8)).parse())
    // Public paths start at the website's selected Publish folder, independently
    // of the account/files ancestors used by WebDAV uploads.
    var website = settings
    website.feedFolderURL = URL(string: "https://webdav.example/account.domain.com/files/Podcast%20Feed/")
    website.publicFolderURL = URL(string: "https://public.example/podcast/")
    let hosted = String(decoding: try RSS.renderRemote([uploaded], channel: RemoteChannel(settings: website)), as: UTF8.self)
    #expect(hosted.contains("https://public.example/podcast/feed.xml"))
    #expect(hosted.contains("https://public.example/podcast/audio/\(uploaded.id).m4a"))
    #expect(!hosted.contains("account.domain.com/files"))
    // Host fallback when the article carries no author.
    var fallback = uploaded
    fallback.author = nil
    let rendered = String(decoding: try RSS.renderRemote([fallback], channel: channel), as: UTF8.self)
    #expect(rendered.contains("<dc:creator>articles.example</dc:creator>"))
    var noLink = uploaded; noLink.sourceURL = nil; noLink.author = nil; noLink.sourceHost = nil
    let minimal = String(decoding: try RSS.renderRemote([noLink], channel: channel), as: UTF8.self)
    #expect(!minimal.contains("<dc:creator>") && !minimal.contains("<link>https://articles.example"))
    // Published-but-unconfirmed media is absent until its upload completes.
    let pending = result.episode
    #expect(String(decoding: try RSS.renderRemote([pending], channel: channel), as: UTF8.self).contains("<item>") == false)
    var failed = result.episode
    failed.delivery = DeliveryState(status: .failed, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(failed.id).m4a",
                                    lastError: "The delivery endpoint refused the request.")
    #expect(String(decoding: try RSS.renderRemote([failed], channel: channel), as: UTF8.self).contains("<item>") == false)
    // An inconsistent confirmed record indicates corruption and still fails the render.
    var corrupt = result.episode
    corrupt.delivery = DeliveryState(status: .uploaded, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/\(corrupt.id).m4a",
                                    uploadedByteLength: corrupt.info!.byteLength + 1)
    #expect(throws: RelayError.self) { try RSS.renderRemote([corrupt], channel: channel) }
    var expired = uploaded; expired.stage = .expired
    #expect(String(decoding: try RSS.renderRemote([expired], channel: channel), as: UTF8.self).contains("<item>") == false)
    // Escaping matches the local feed contract.
    var escaped = uploaded; escaped.title = "A & B <Private>"
    #expect(String(decoding: try RSS.renderRemote([escaped], channel: channel), as: UTF8.self).contains("A &amp; B &lt;Private&gt;"))
}

@Test func remoteFeedUploadedBytesContainConfirmedEnclosure() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    let feedCall = try #require(transport.recordedCalls.first { $0.method == "PUT" && $0.path.hasSuffix("feed.xml") })
    #expect(feedCall.bytes > 0)
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.lastUploadedFeedHash != nil)
    _ = result
}

@Test func deliveryUnconfirmedItemDoesNotBlockFeedUpdate() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let good = try await publishReview("good", storage: storage, delivery: settings)
    let stuck = try await publishReview("stuck", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    transport.statusFor = { method, path in
        method == "PUT" && path.contains("\(stuck.episode.id).m4a") ? 503 : nil
    }
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.uploadedMedia == 1 && drain.retrying == 1 && drain.failed == 0 && drain.feedUploaded)
    // The feed still updates, listing only the byte-confirmed item.
    let feed = String(decoding: try #require(transport.body("/remote.php/dav/files/user/Podcast Feed/feed.xml")), as: UTF8.self)
    #expect(feed.contains(good.episode.id) && !feed.contains(stuck.episode.id))
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(!ledger.remoteFeedPending)
}

@Test func deliveryDrainReconcilesLostRemoteDeleteIntent() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let settings = deliverySettings()
    let retired = try await publishReview("lost", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    let mediaPath = "/remote.php/dav/files/user/Podcast Feed/audio/\(retired.episode.id).m4a"
    _ = try await FixtureCoordinator().removeSavedAudio(ids: [retired.episode.id], storage: storage)
    // Simulate the retire-crash window: the episode is durably expired but the
    // ledger write was lost before the remote delete could be recorded.
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    ledger.pendingRemoteDeletes = []
    ledger.remoteFeedPending = false
    try ledger.save(stateRoot: storage.stateRoot)
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.remoteDeletes == 1 && drain.feedUploaded)
    #expect(transport.objectLength(mediaPath) == nil)
    let calls = transport.recordedCalls
    let feedIndex = try #require(calls.lastIndex { $0.method == "PUT" && $0.path.hasSuffix("feed.xml") })
    let deleteIndex = try #require(calls.lastIndex { $0.method == "DELETE" })
    #expect(feedIndex < deleteIndex)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
}

@Test func deliveryDrainFollowsDestinationChangesForPendingAndUploadedCopies() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    var settings = deliverySettings()
    let result = try await publishReview(storage: storage, delivery: settings)
    let oldPath = "remote.php/dav/files/user/Podcast Feed/audio/\(result.episode.id).m4a"
    #expect(result.episode.delivery?.remotePath == oldPath)
    // A pending record follows the configured folders; its path is aspirational.
    settings.feedFolderURL = URL(string: "https://webdav.example/remote.php/dav/files/user/Moved%20Feed/")
    let transport = FakeWebDAVTransport()
    let drain = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: transport)
    #expect(drain.uploadedMedia == 1 && drain.feedUploaded)
    var episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    let movedPath = "remote.php/dav/files/user/Moved Feed/audio/\(result.episode.id).m4a"
    #expect(episode?.delivery?.remotePath == movedPath && episode?.delivery?.status == .uploaded)
    #expect(transport.objectLength("/remote.php/dav/files/user/Moved Feed/audio/\(result.episode.id).m4a") != nil)
    // An uploaded record must be confirmed at the newly configured host too.
    settings.feedFolderURL = URL(string: "https://other.example/remote.php/dav/files/user/Moved%20Feed/")
    let quiet = FakeWebDAVTransport()
    let again = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "x"), transport: quiet)
    #expect(again.uploadedMedia == 1 && again.feedUploaded)
    #expect(quiet.recordedCalls.allSatisfy { $0.url.host == "other.example" })
    episode = try await FixtureCoordinator().library(storage: storage).first { $0.id == result.episode.id }
    #expect(episode?.delivery?.remotePath == movedPath)
}

@Test func deliveryReadOnlyProbeRequiresExactReadableDAVCollection() async throws {
    let transport = FakeWebDAVTransport()
    let settings = deliverySettings()
    let client = try WebDAVClient(transport: transport, settings: settings, credential: FakeCredentials(password: "pw"))
    try await client.testConnection()
    #expect(transport.methods == ["PROPFIND", "PROPFIND"])
    #expect(transport.recordedCalls.first?.depth == "0")
    #expect(transport.recordedCalls.first?.path == settings.feedFolderURL?.path)
    #expect(transport.recordedCalls.first?.url == settings.feedFolderURL)
    #expect(transport.recordedCalls.first?.authorized == true)
    var noSlash = settings
    noSlash.feedFolderURL = URL(string: "https://webdav.example/account/files")
    try await WebDAVClient(transport: transport, settings: noSlash, credential: FakeCredentials(password: "pw")).testConnection()
    #expect(transport.recordedCalls.last?.path == "/account/files/audio" && transport.recordedCalls.last?.directory == true)
    #expect(transport.recordedCalls.last?.url.absoluteString == "https://webdav.example/account/files/audio/")
    let path = settings.feedFolderURL!.path
    func xml(href: String, status: String, property: String, namespace: String = "DAV:") -> Data {
        Data("<d:multistatus xmlns:d=\"\(namespace)\"><d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(property)</d:resourcetype></d:prop><d:status>\(status)</d:status></d:propstat></d:response></d:multistatus>".utf8)
    }
    for invalid in [Data("not xml".utf8), Data(),
        xml(href: path, status: "HTTP/1.1 403 Forbidden", property: "<d:collection/>"),
        xml(href: path, status: "HTTP/1.1 200 OK", property: ""),
        xml(href: path, status: "invalid 200 status", property: "<d:collection/>"),
        Data(("<!DOCTYPE d:multistatus [<!ENTITY extra 'private'>]>" + String(decoding: xml(href: path, status: "HTTP/1.1 200 OK", property: "<d:collection/>"), as: UTF8.self)).utf8),
        xml(href: "/different-folder", status: "HTTP/1.1 200 OK", property: "<d:collection/>"),
        xml(href: "https://other.example\(path)", status: "HTTP/1.1 200 OK", property: "<d:collection/>"),
        xml(href: path, status: "HTTP/1.1 200 OK", property: "<d:collection/>", namespace: "not-DAV")] {
        transport.propfindBodyFor = { _ in invalid }
        await #expect(throws: DeliveryError.self) { try await client.testConnection() }
    }
    transport.propfindBodyFor = nil
    transport.statusFor = { _, _ in 405 }
    await #expect(throws: DeliveryError.self) { try await client.testConnection() }
    #expect(transport.methods.allSatisfy { $0 == "PROPFIND" })
}

@Test func deliveryExistingCollectionRequiresVerificationAfter405() async throws {
    let transport = FakeWebDAVTransport()
    let root = "/remote.php/dav/files/user"
    var existing: Set<String> = [root]
    transport.statusFor = { method, path in
        if method == "PROPFIND", !existing.contains(path) { return 404 }
        if method == "MKCOL" { existing.insert(path); return 405 }
        return nil
    }
    let client = try WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
    try await client.ensureCollections()
    #expect(transport.methods == ["PROPFIND", "PROPFIND", "MKCOL", "PROPFIND", "PROPFIND", "PROPFIND", "MKCOL", "PROPFIND"])
    transport.propfindBodyFor = { _ in Data("<not-a-collection/>".utf8) }
    await #expect(throws: DeliveryError.self) { try await client.ensureCollections() }
}

@Test func deliveryFeedFolderCreatesFixedAudioAndEncodesNamesOnce() async throws {
    var settings = deliverySettings()
    settings.feedFolderURL = try DeliveryURL.folder("https://webdav.example//podcast feed/./")
    settings.publicFolderURL = try DeliveryURL.folder("https://public.example/podcast")
    #expect(settings.remoteFeedPath == "podcast feed/feed.xml")
    #expect(settings.remoteMediaPath("opaque") == "podcast feed/audio/opaque.m4a")
    let transport = FakeWebDAVTransport()
    transport.statusFor = { method, _ in method == "MKCOL" ? 403 : nil }
    let log = DeliveryDebugLog(); log.enabled = true
    let client = try WebDAVClient(transport: LoggingDeliveryTransport(base: transport, log: log), settings: settings,
        credential: FakeCredentials(password: "pw"), debugLog: log)
    #expect(try await client.testConnection())
    #expect(transport.recordedCalls.map(\.path) == ["/podcast feed", "/podcast feed/audio"])
    try await client.ensureCollections()
    try await client.uploadData(Data("feed".utf8), remotePath: settings.remoteFeedPath)
    try await client.uploadData(Data("audio".utf8), remotePath: settings.remoteMediaPath("opaque"))
    #expect(!transport.methods.contains("MKCOL"))
    let puts = transport.recordedCalls.filter { $0.method == "PUT" }
    #expect(puts.map { $0.url.absoluteString } == ["https://webdav.example/podcast%20feed/feed.xml", "https://webdav.example/podcast%20feed/audio/opaque.m4a"])
    #expect(transport.recordedCalls.allSatisfy { $0.authorized && $0.url.host == "webdav.example" })
    #expect(settings.publicFeedURL?.absoluteString == "https://public.example/podcast/feed.xml")
    #expect(settings.publicAudioBaseURL?.absoluteString == "https://public.example/podcast/audio/")
    #expect(log.text.contains("folder check: feed") && log.text.contains("folder check: audio"))
    for sensitive in ["podcast feed", "pw", "webdav.example"] { #expect(!log.text.contains(sensitive)) }
}

@Test func deliveryCreatesOnlyMissingAncestorsInOrderAndStopsOnDeniedAccess() async throws {
    var settings = deliverySettings()
    settings.feedFolderURL = URL(string: "https://webdav.example/account.domain.com/files/Podcast%20Feed/Nested/")
    var existing: Set<String> = ["/", "/account.domain.com", "/account.domain.com/files"]
    let transport = FakeWebDAVTransport()
    transport.statusFor = { method, path in
        if method == "PROPFIND", !existing.contains(path) { return 404 }
        if method == "MKCOL" {
            let parent = String(path[..<path.lastIndex(of: "/")!])
            guard existing.contains(parent.isEmpty ? "/" : parent) else { return 409 }
            existing.insert(path)
        }
        return nil
    }
    let client = try WebDAVClient(transport: transport, settings: settings, credential: FakeCredentials(password: "pw"))
    // A read-only test reports a missing configured destination without creating it.
    #expect(try await client.testConnection() == false)
    #expect(transport.methods.allSatisfy { $0 == "PROPFIND" })
    try await client.ensureCollections()
    let creates = transport.recordedCalls.filter { $0.method == "MKCOL" }
    #expect(creates.map(\.path) == ["/account.domain.com/files/Podcast Feed", "/account.domain.com/files/Podcast Feed/Nested", "/account.domain.com/files/Podcast Feed/Nested/audio"])
    #expect(creates.allSatisfy { $0.directory })
    let before = transport.recordedCalls.count
    try await client.ensureCollections()
    #expect(transport.recordedCalls.dropFirst(before).allSatisfy { $0.method == "PROPFIND" })
    transport.statusFor = { method, _ in method == "PROPFIND" ? 403 : nil }
    await #expect(throws: DeliveryError.self) { try await client.ensureCollections() }
    #expect(transport.recordedCalls.last?.method == "PROPFIND")
}

@Test func deliveryOlderSettingsKeepFeedDestinationAndAdoptFixedLayout() throws {
    let old = Data(#"{"enabled":true,"webdavURL":"https://webdav.example/base/","remoteFolder":"Saved Feed","mediaFolder":"Separate Audio","publicFeedURL":"https://public.example/show/old.xml","publicAudioBaseURL":"https://public.example/audio/","username":"user"}"#.utf8)
    let restored = try JSONDecoder().decode(DeliverySettings.self, from: old)
    #expect(restored.feedFolderURL?.absoluteString == "https://webdav.example/base/Saved%20Feed/")
    #expect(restored.remoteFeedPath == "base/Saved Feed/feed.xml")
    #expect(restored.remoteMediaPath("id") == "base/Saved Feed/audio/id.m4a")
    #expect(restored.publicFeedURL?.absoluteString == "https://public.example/show/feed.xml")
    #expect(restored.publicAudioBaseURL?.absoluteString == "https://public.example/show/audio/")
    let data = try JSONEncoder().encode(restored)
    #expect(try JSONDecoder().decode(DeliverySettings.self, from: data) == restored)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for retired in ["webdavURL", "remoteFolder", "mediaFolder", "publicFeedURL", "publicAudioBaseURL"] { #expect(object[retired] == nil) }
}

@Test func deliveryUploadNowRecoversCredentialsAndPermissionsWithoutSettingsChange() async throws {
    for failure in [401, 403] {
        let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = try deliveryStorage(root: root)
        let settings = deliverySettings()
        let published = try await publishReview(storage: storage, delivery: settings)
        let transport = FakeWebDAVTransport()
        transport.statusFor = { method, _ in method == "PUT" ? failure : nil }
        let coordinator = FixtureCoordinator()
        let first = try await coordinator.deliverPending(storage: storage, settings: settings,
            credential: FakeCredentials(password: "old"), transport: transport)
        #expect(first.failed == 1)
        transport.statusFor = nil
        let automatic = try await coordinator.deliverPending(storage: storage, settings: settings,
            credential: FakeCredentials(password: "corrected"), transport: transport)
        #expect(automatic.uploadedMedia == 0)
        let manual = try await coordinator.deliverPending(storage: storage, settings: settings,
            credential: FakeCredentials(password: "corrected"), transport: transport, force: true)
        #expect(manual.uploadedMedia == 1 && manual.feedUploaded)
        let episode = try await coordinator.library(storage: storage).first { $0.id == published.episode.id }
        #expect(episode?.delivery?.status == .uploaded)
    }
}

@Test func deliveryDebugLoggingIsOptInBoundedAndSanitized() async throws {
    let log = DeliveryDebugLog()
    log.record(.credentialRead)
    #expect(log.text.isEmpty)
    log.enabled = true
    let transport = FakeWebDAVTransport()
    transport.statusFor = { _, _ in 403 }
    let client = try WebDAVClient(transport: LoggingDeliveryTransport(base: transport, log: log),
        settings: deliverySettings(), credential: FakeCredentials(password: "secret-password"), debugLog: log)
    do { try await client.testConnection() } catch { log.recordFailure(error) }
    #expect(log.text.contains("credential read: succeeded") && log.text.contains("PROPFIND HTTP 403"))
    #expect(log.text.contains("failure: permissions"))
    for privateValue in ["secret-password", "user@example.com", "webdav.example", "Authorization", "Basic ", "remote.php"] {
        #expect(!log.text.contains(privateValue))
    }
    transport.throwFor = { _, _ in NSError(domain: "secret-password", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-password"]) }
    transport.statusFor = nil
    do { try await client.testConnection() } catch { log.recordFailure(error) }
    #expect(!log.text.contains("secret-password"))
    for _ in 0..<220 { log.record(.deliveryStarted) }
    #expect(log.text.split(separator: "\n").count == 200)
    let retained = log.text
    log.enabled = false; log.record(.credentialRemoved)
    #expect(log.text == retained)
    log.clear(); #expect(log.text.isEmpty)
}

@Test func deliverySizeHeadersRequireNonnegativeDecimalBytes() {
    for (text, expected) in [("42", Int64(42)), (" 42\r\n", 42), ("0", 0), ("+42", nil), ("-1", nil), ("", nil), ("42,42", nil), ("1.0", nil), ("9223372036854775808", nil)] {
        #expect(DeliveryResponse(status: 200, headers: ["cOnTeNt-LeNgTh": text]).contentLength == expected)
    }
}

@Test func deliveryVerifiesDAVFileSizeWhenHEADCannotConfirm() async throws {
    let path = "/remote.php/dav/files/user/Podcast Feed/feed.xml"
    for headers in [[:], ["Content-Length": "wrong"], ["Content-Length": "1"], ["Content-Length": "-1"]] {
        let transport = FakeWebDAVTransport(); transport.headHeaders[path] = headers
        let log = DeliveryDebugLog(); log.enabled = true
        let client = try WebDAVClient(transport: LoggingDeliveryTransport(base: transport, log: log),
            settings: deliverySettings(), credential: FakeCredentials(password: "private-secret"), debugLog: log)
        try await client.uploadData(Data("fixture-feed".utf8), remotePath: deliverySettings().remoteFeedPath)
        #expect(transport.methods == ["PUT", "HEAD", "PROPFIND"])
        #expect(transport.recordedCalls.last?.depth == "0" && transport.recordedCalls.last?.directory == false)
        #expect(transport.recordedCalls.filter { $0.method != "PUT" }.allSatisfy { $0.encoding == "identity" })
        #expect(log.text.contains("upload size check: PROPFIND matched"))
        for secret in ["private-secret", "Podcast Feed", "user@example.com", "webdav.example"] { #expect(!log.text.contains(secret)) }
    }
    for unsupported in [405, 501] {
        let transport = FakeWebDAVTransport(); transport.statusFor = { method, _ in method == "HEAD" ? unsupported : nil }
        try await WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
            .uploadData(Data("fixture".utf8), remotePath: deliverySettings().remoteFeedPath)
        #expect(transport.methods == ["PUT", "HEAD", "PROPFIND"])
    }
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.m4a"); try Files.write(Data(repeating: 1, count: 1234), to: file)
    let transport = FakeWebDAVTransport()
    transport.headHeaders["/remote.php/dav/files/user/Podcast Feed/audio/opaque.m4a"] = [:]
    try await WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
        .uploadFile(file, remotePath: "remote.php/dav/files/user/Podcast Feed/audio/opaque.m4a")
    #expect(transport.methods == ["PUT", "HEAD", "PROPFIND"] && transport.recordedCalls.first?.bytes == 1234)
}

@Test func deliveryRejectsUntrustedDAVFileSizesWithoutAcceptingXMLBodyLength() async throws {
    let path = "/remote.php/dav/files/user/Podcast Feed/feed.xml"
    let encoded = "/remote.php/dav/files/user/Podcast%20Feed/feed.xml"
    func response(href: String = "/remote.php/dav/files/user/Podcast%20Feed/feed.xml", length: String = "8",
                  status: String = "HTTP/1.1 200 OK", type: String = "") -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:getcontentlength>\(length)</d:getcontentlength><d:resourcetype>\(type)</d:resourcetype></d:prop><d:status>\(status)</d:status></d:propstat></d:response>"
    }
    func document(_ responses: String, namespace: String = "DAV:") -> Data {
        Data("<d:multistatus xmlns:d=\"\(namespace)\">\(responses)</d:multistatus>".utf8)
    }
    let good = document(response())
    let invalid = [Data(), Data("not XML".utf8), document(response(length: "7")),
        document(response(length: "-1")), document(response(length: "9223372036854775808")), document(response(length: "8x")),
        document(response(status: "HTTP/1.1 404 Not Found")), document(response(status: "invalid 200 status")),
        document(response(href: "/different/feed.xml")), document(response(href: "https://other.example\(encoded)")),
        document(response(href: encoded + "?query=1")), document(response(type: "<d:collection/>")),
        document(response(href: encoded + "/")), document(response(length: "")),
        document(response(), namespace: "not-DAV"), document(response() + response()),
        document(response(length: "8</d:getcontentlength><d:getcontentlength>8")),
        Data(("<!DOCTYPE d:multistatus [<!ENTITY secret '8'>]>" + String(decoding: good, as: UTF8.self)).utf8)]
    for body in invalid {
        let transport = FakeWebDAVTransport(); transport.headHeaders[path] = [:]
        transport.propfindBodyFor = { _ in body }
        let client = try WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
        await #expect(throws: DeliveryError.fatal(DeliveryError.verificationNotice)) {
            try await client.uploadData(Data("12345678".utf8), remotePath: deliverySettings().remoteFeedPath)
        }
    }
    for body in [good, document(response(length: " 8\n")), document(response(href: "feed.xml")),
        document("<d:response><d:href>\(encoded)</d:href><d:propstat><d:prop><d:getcontentlength>8</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")] {
        let transport = FakeWebDAVTransport(); transport.headHeaders[path] = [:]
        transport.propfindBodyFor = { _ in body }
        try await WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
            .uploadData(Data("12345678".utf8), remotePath: deliverySettings().remoteFeedPath)
        #expect(transport.recordedCalls.last?.authorized == true)
    }
    for status in [401, 403, 404, 500, 302] {
        let transport = FakeWebDAVTransport(); transport.statusFor = { method, _ in method == "HEAD" ? status : nil }
        await #expect(throws: DeliveryError.self) {
            try await WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
                .uploadData(Data("12345678".utf8), remotePath: deliverySettings().remoteFeedPath)
        }
        #expect(transport.methods == ["PUT", "HEAD"])
    }
    let transport = FakeWebDAVTransport(); transport.throwFor = { method, _ in method == "HEAD" ? CancellationError() : nil }
    await #expect(throws: CancellationError.self) {
        try await WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "pw"))
            .uploadData(Data("12345678".utf8), remotePath: deliverySettings().remoteFeedPath)
    }
    #expect(transport.methods == ["PUT", "HEAD"])
}

private final class SessionCredentialFixture: DeliveryCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    var failure: DeliveryError?
    private(set) var reads = 0, writes = 0, deletes = 0, presenceChecks = 0
    private var password: String? = "session-secret"
    func readPassword(username: String, host: String) throws -> String? {
        try lock.withLock {
            reads += 1
            if let failure { throw failure }
            return password
        }
    }
    func writePassword(_ password: String, username: String, host: String) throws {
        lock.withLock { writes += 1; self.password = password }
    }
    func deletePassword(username: String, host: String) throws { lock.withLock { deletes += 1; password = nil } }
    func hasPassword(username: String, host: String) throws -> Bool {
        lock.withLock { presenceChecks += 1; return password != nil }
    }
}

@Test func deliveryCredentialSessionCoalescesConcurrentReadsAndNeverQueriesStatus() async throws {
    let base = SessionCredentialFixture()
    let log = DeliveryDebugLog(); log.enabled = true
    let session = SessionDeliveryCredentialStore(base: base, debugLog: log)
    #expect(session.presence(username: "user", host: "host") == .unchecked)
    #expect(try !session.hasPassword(username: "user", host: "host"))
    try await withThrowingTaskGroup(of: String?.self) { group in
        for _ in 0..<24 { group.addTask { try session.readPassword(username: " user\n", host: "HOST") } }
        for try await password in group { #expect(password == "session-secret") }
    }
    #expect(base.reads == 1 && base.presenceChecks == 0)
    #expect(session.presence(username: "user", host: "host") == .stored)
    session.retryFailedAccess(username: "user", host: "host")
    #expect(try session.readPassword(username: "user", host: "host") == "session-secret")
    #expect(base.reads == 1)
    #expect(log.text.contains("no Keychain query") && !log.text.contains("session-secret"))
    // Save replaces the session value and never re-reads the keychain.
    try session.writePassword("new-secret", username: "user", host: "host")
    try session.writePassword("new-secret", username: "user", host: "host")
    #expect(try session.readPassword(username: "user", host: "host") == "new-secret")
    #expect(base.writes == 2 && base.reads == 1) // every explicit Save applies the current access policy
    try session.deletePassword(username: "user", host: "host")
    #expect(session.presence(username: "user", host: "host") == .missing)
    #expect(try session.readPassword(username: "user", host: "host") == nil)
    #expect(base.deletes == 1 && base.reads == 1)
    session.clearSession()
    #expect(session.presence(username: "user", host: "host") == .unchecked)
}

@Test func deliveryCredentialDenialDoesNotRepromptUntilExplicitRetry() throws {
    let base = SessionCredentialFixture()
    base.failure = .credentialUnavailable("Access cancelled")
    let session = SessionDeliveryCredentialStore(base: base)
    for _ in 0..<5 {
        #expect(throws: DeliveryError.self) { try session.readPassword(username: "user", host: "host") }
    }
    #expect(base.reads == 1 && session.presence(username: "user", host: "host") == .unavailable)
    base.failure = nil
    session.retryFailedAccess(username: "user", host: "host")
    #expect(try session.readPassword(username: "user", host: "host") == "session-secret")
    #expect(base.reads == 2)
    _ = try session.readPassword(username: "other", host: "host")
    #expect(base.reads == 3) // different credentials never inherit a cached secret
}

#if canImport(Security)
@Test func deliveryProtectedKeychainPolicyUsesLocalDataProtectionWithoutLegacyFallback() throws {
    let query = KeychainCredentialStore().base(" user\n", "HOST")
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecAttrAccount as String] as? String == "host:user")
    #expect(KeychainCredentialStore.accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    #expect(KeychainCredentialStore.accessFlags.isEmpty)
    // In-memory policy construction only: no item, prompt, biometric or Keychain access.
    _ = try KeychainCredentialStore.accessControl()
}

@Test func deliveryKeychainBackgroundReadsNeverPromptAndExplicitSaveMigratesExistingItem() throws {
    var oldPolicy = true, password = "fixture-secret", writes = 0
    var readQueries: [[String: Any]] = [], additions: [[String: Any]] = [], updates: [[String: Any]] = []
    let store = KeychainCredentialStore(operations: .init(read: { query in
        readQueries.append(query)
        return oldPolicy ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, Data(password.utf8) as CFData)
    }, add: { attributes in
        additions.append(attributes); return errSecDuplicateItem
    }, update: { query, attributes in
        #expect(query[kSecAttrAccount as String] as? String == "host:user")
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false)
        updates.append(attributes)
        guard attributes[kSecAttrAccessControl as String] != nil,
              let bytes = attributes[kSecValueData as String] as? Data else { return errSecParam }
        password = String(decoding: bytes, as: UTF8.self); oldPolicy = false; writes += 1
        return errSecSuccess
    }, delete: { _ in Issue.record("Migration must never delete the existing credential"); return errSecParam }))
    let session = SessionDeliveryCredentialStore(base: store)
    for _ in 0..<3 {
        do { _ = try session.readPassword(username: "user", host: "host"); Issue.record("Expected protected-item failure") }
        catch { #expect(error.localizedDescription.contains("Save Password")) }
    }
    #expect(readQueries.count == 1)
    #expect((readQueries.first?[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    try session.writePassword(password, username: " user ", host: "HOST")
    #expect(writes == 1 && additions.count == 1 && updates.count == 1)
    #expect(try session.readPassword(username: "user", host: "host") == "fixture-secret")
    // A fresh app session reads the durable item without authorization, even with no cached grant.
    let restarted = SessionDeliveryCredentialStore(base: store)
    #expect(try restarted.readPassword(username: "user", host: "host") == "fixture-secret")
    #expect(readQueries.count == 2)
    #expect(readQueries.allSatisfy { ($0[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true })
    try session.writePassword(password, username: "user", host: "host")
    #expect(writes == 2) // unchanged password still refreshes access control
}

@Test func deliveryKeychainFailedMigrationPreservesExistingItemAndSession() throws {
    var updates = 0
    let store = KeychainCredentialStore(operations: .init(read: { _ in (errSecSuccess, Data("old-secret".utf8) as CFData) },
        add: { _ in errSecDuplicateItem }, update: { _, _ in updates += 1; return errSecUserCanceled },
        delete: { _ in Issue.record("Failed Save must never delete a credential"); return errSecParam }))
    let session = SessionDeliveryCredentialStore(base: store)
    #expect(try session.readPassword(username: "user", host: "host") == "old-secret")
    #expect(throws: DeliveryError.self) { try session.writePassword("new-secret", username: "user", host: "host") }
    #expect(updates == 1)
    #expect(try session.readPassword(username: "user", host: "host") == "old-secret")
}
#endif

@Test func deliveryDestinationChangesPreserveOldCopiesAndDoNotForwardDeletes() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    var settings = deliverySettings()
    let coordinator = FixtureCoordinator()
    let retiring = try await publishReview("retiring-copy", storage: storage, delivery: settings)
    let retained = try await publishReview("retained-copy", storage: storage, delivery: settings)
    let old = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "pw"), transport: old)
    _ = try await coordinator.removeSavedAudio(ids: [retiring.episode.id], storage: storage)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.count == 1)
    settings.feedFolderURL = URL(string: "https://new.example/podcast/")
    let fresh = FakeWebDAVTransport()
    let drain = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "pw"), transport: fresh)
    #expect(drain.uploadedMedia == 1 && drain.feedUploaded && drain.remoteDeletes == 0)
    #expect(!fresh.methods.contains("DELETE"))
    #expect(old.objectLength("/" + deliverySettings().remoteMediaPath(retiring.episode.id)) != nil)
    #expect(old.objectLength("/" + deliverySettings().remoteMediaPath(retained.episode.id)) != nil)
    let feed = String(decoding: try #require(fresh.body("/podcast/feed.xml")), as: UTF8.self)
    #expect(feed.contains("/audio/\(retained.episode.id).m4a") && !feed.contains(retiring.episode.id))
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
    // A public-folder-only change refreshes feed links without uploading unchanged audio.
    settings.publicFolderURL = URL(string: "https://public.example/new-show/")
    let mapping = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "pw"), transport: fresh)
    #expect(mapping.uploadedMedia == 0 && mapping.feedUploaded)
    let remapped = String(decoding: try #require(fresh.body("/podcast/feed.xml")), as: UTF8.self)
    #expect(remapped.contains("https://public.example/new-show/feed.xml"))
    #expect(remapped.contains("https://public.example/new-show/audio/\(retained.episode.id).m4a"))
}

@Test func episodeArtworkSurvivesPublicationAndAppearsInLocalAndRemoteRSS() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    let url = URL(string: "https://articles.example/artwork-story")!
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self).replacingOccurrences(of: "</head>",
        with: "<meta property='og:image' content='https://images.example/preview.jpg?a=1&amp;b=2'><meta property='og:site_name' content='Synthetic News'></head>")
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
        contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    let review = try ReviewedSource.prepare(page, chunkLimit: 1800)
    let settings = deliverySettings()
    let result = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: review,
        backend: DeliveryTestBackend(), storage: storage, delivery: settings)
    #expect(result.episode.artworkURL?.absoluteString == "https://images.example/preview.jpg?a=1&b=2")
    #expect(result.narration.chunks.first?.text.contains("Source: Synthetic News.") == true)
    #expect(result.narration.chunks.last?.text == "End of article.")
    let image = "<itunes:image href=\"https://images.example/preview.jpg?a=1&amp;b=2\"/>"
    #expect(try String(contentsOf: result.feedURL, encoding: .utf8).contains(image))
    let transport = FakeWebDAVTransport()
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "pw"), transport: transport)
    let feed = try #require(transport.body("/" + settings.remoteFeedPath))
    #expect(String(decoding: feed, as: UTF8.self).contains(image))
    #expect(XMLParser(data: feed).parse())
    var episode = try #require(await FixtureCoordinator().library(storage: storage).first)
    episode.artworkURL = URL(string: "https://user:secret@images.example/private.jpg")
    let noArt = try RSS.renderRemote([episode], channel: RemoteChannel(settings: settings))
    #expect(!String(decoding: noArt, as: UTF8.self).contains("itunes:image"))
    var old = try #require(JSONSerialization.jsonObject(with: Files.json(episode)) as? [String: Any])
    old.removeValue(forKey: "artworkURL")
    #expect(try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: old)).artworkURL == nil)
}

private func temporaryDeliveryStorage(_ root: URL) -> ManagedSpeechStorage {
    ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("temporary-audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"),
        temporaryAudio: true)
}

@Test func temporaryAudioPublicationReleasesBytesKeepsHistoryAndSupportsServerDeletion() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let first = try await publishReview(storage: storage, delivery: settings), transport = FakeWebDAVTransport()
    #expect(first.episode.settings.temporaryAudio == true && first.episode.audioFinalizationComplete == true)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(!FileManager.default.fileExists(atPath: first.audioURL.path))
    let history = try #require(try await coordinator.savedAudio(storage: storage).first)
    #expect(history.id == first.episode.id && history.localAudioReleased == true && history.stage == .published)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[history.id] == .published)
    #expect(try await coordinator.reconcileMissingAudio(storage: storage).isEmpty)
    // A second publication must preserve the released first enclosure in BOTH feeds.
    let second = try await publishReview("second", storage: storage, delivery: settings)
    #expect(String(decoding: try Data(contentsOf: second.feedURL), as: UTF8.self).contains(history.id))
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    let feedPath = "/" + settings.remoteFeedPath
    #expect(String(decoding: try #require(transport.body(feedPath)), as: UTF8.self).contains(history.id))
    try FileManager.default.removeItem(at: storage.audioDirectory) // macOS may evict the entire directory.
    _ = try await coordinator.removeSavedAudio(ids: [history.id], storage: storage)
    let count = transport.recordedCalls.count
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    let calls = Array(transport.recordedCalls.dropFirst(count))
    #expect(calls.firstIndex { $0.method == "PUT" && $0.path == feedPath }! < calls.firstIndex { $0.method == "DELETE" }!)
    #expect(!String(decoding: try #require(transport.body(feedPath)), as: UTF8.self).contains(history.id))
    #expect(transport.objectLength("/" + settings.remoteMediaPath(history.id)) == nil)
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [second.episode.id])
}

@Test(arguments: [false, true]) func temporaryAudioRetainedUntilMediaAndFeedBothVerified(failFeed: Bool) async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings), transport = FakeWebDAVTransport()
    transport.statusFor = { method, path in
        method == "PUT" && (failFeed ? path.hasSuffix("feed.xml") : path.hasSuffix(".m4a")) ? 503 : nil
    }
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    #expect(try await coordinator.library(storage: storage).first?.localAudioReleased != true)
    transport.statusFor = nil
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path))
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[result.episode.id] == .published)
}

@Test func temporaryAudioCleanupWaitsForFinalizationAndRejectsSubstitutedBytes() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings), transport = FakeWebDAVTransport()
    var episode = result.episode; episode.audioFinalizationComplete = nil
    try NativeStore(url: storage.profile.database).save(episode)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    episode = try #require(try await coordinator.library(storage: storage).first)
    episode.audioFinalizationComplete = true; try NativeStore(url: storage.profile.database).save(episode)
    let original = try Data(contentsOf: result.audioURL)
    try Files.write(Data("substituted".utf8), to: result.audioURL)
    await #expect(throws: RelayError.self) {
        try await coordinator.releaseConfirmedTemporaryAudio(storage: storage, settings: settings)
    }
    #expect(try Data(contentsOf: result.audioURL) == Data("substituted".utf8))
    try Files.write(original, to: result.audioURL)
    // Intent survives a crash before unlink; an idle drain repairs it without credentials/HTTP.
    episode.localAudioReleased = true; try NativeStore(url: storage.profile.database).save(episode)
    let idle = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: nil), transport: idle)
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path) && idle.methods.isEmpty)
}

@Test func temporaryAudioLossRegeneratesFromSnapshotAndDestinationChangePreservesGUID() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), coordinator = FixtureCoordinator()
    var settings = deliverySettings()
    let initial = try await publishReview(storage: storage, delivery: settings)
    try FileManager.default.removeItem(at: storage.audioDirectory)
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [initial.episode.id])
    let recovered = try await coordinator.runQueued(initial.episode.id, storage: storage, backend: { _ in DeliveryTestBackend() }, delivery: settings)
    #expect(recovered.synthesizedChunks > 0 && recovered.episode.id == initial.episode.id)
    let old = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: old)
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    settings.feedFolderURL = URL(string: "https://new.example/new-podcast/")
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
    let fresh = try await coordinator.runQueued(initial.episode.id, storage: storage, backend: { _ in DeliveryTestBackend() }, delivery: settings)
    #expect(fresh.episode.id == initial.episode.id && fresh.episode.publicationDate == initial.episode.publicationDate)
    #expect(fresh.episode.settings.voice == initial.episode.settings.voice)
    let target = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: target)
    #expect(old.objectLength("/" + deliverySettings().remoteMediaPath(initial.episode.id)) != nil)
    #expect(!target.methods.contains("DELETE") && target.methods.contains("PUT"))
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[initial.episode.id] == .published)
}

@Test func temporaryAudioFailedServerRemovalStaysInHistoryUntilConfirmed() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings), transport = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
    transport.statusFor = { method, path in method == "PUT" && path.hasSuffix("feed.xml") ? 503 : nil }
    let failed = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(failed.remoteDeletes == 0)
    #expect(try await coordinator.savedAudio(storage: storage).first?.stage == .expired)
    #expect(transport.objectLength("/" + settings.remoteMediaPath(result.episode.id)) != nil)
    transport.statusFor = nil
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
}

@Test func temporaryAudioRecoveryPreservesManualRetryForFailedRows() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings)
    try FileManager.default.removeItem(at: result.audioURL)
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
    var item = try #require(try await coordinator.queue(stateRoot: storage.stateRoot).first)
    item.state = .failed; item.lastError = "Fixture failure"
    try NativeStore(url: storage.profile.database).saveQueueItem(item)
    try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first == item)
}

@Test func existingNativeAudioAdoptsConfirmedCleanupWithoutDeletingUnrelatedFiles() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let original = try await publishReview("legacy", storage: legacy, delivery: settings)
    let unrelated = legacy.audioDirectory.appendingPathComponent("unrelated.m4a")
    try Files.write(Data("unrelated".utf8), to: unrelated)
    let app = temporaryDeliveryStorage(root), transport = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: app, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(!FileManager.default.fileExists(atPath: original.audioURL.path))
    #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
    let history = try #require(try await coordinator.savedAudio(storage: app).first)
    #expect(history.id == original.episode.id && history.localAudioReleased == true)
    let next = try await publishReview("fresh", storage: app, delivery: settings)
    #expect(next.episode.settings.temporaryAudio == true)
    #expect(String(decoding: try Data(contentsOf: next.feedURL), as: UTF8.self).contains(history.id))
    _ = try await coordinator.deliverPending(storage: app, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    var changed = settings; changed.feedFolderURL = URL(string: "https://new.example/show/")
    try await coordinator.recoverTemporaryAudio(storage: app, settings: changed)
    let regenerated = try await coordinator.runQueued(history.id, storage: app, backend: { _ in DeliveryTestBackend() }, delivery: changed)
    #expect(regenerated.episode.id == original.episode.id && regenerated.episode.settings.temporaryAudio == true)
    #expect(Files.samePath(regenerated.audioURL.deletingLastPathComponent(), app.audioDirectory))
    #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
}

@Test func serverAudioRepeatedRemovalIsIdempotentBeforeAndAfterConfirmation() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let result = try await publishReview(storage: storage, delivery: settings), transport = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    let ids = [result.episode.id]
    _ = try await coordinator.removeSavedAudio(ids: ids, storage: storage)
    let pending = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(try await coordinator.removeSavedAudio(ids: ids, storage: storage) == ids)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot) == pending)
    #expect(try await coordinator.library(storage: storage).first?.manualAudioDeletionRequested == false)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    let confirmed = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    let record = try Files.json(try #require(try await coordinator.library(storage: storage).first))
    #expect(try await coordinator.removeSavedAudio(ids: ids, storage: storage) == ids)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot) == confirmed)
    #expect(try Files.json(try #require(try await coordinator.library(storage: storage).first)) == record)
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
    let quiet = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: nil), transport: quiet)
    #expect(quiet.methods.isEmpty && confirmed.pendingRemoteDeletes.isEmpty)
}

#if canImport(Security)
@Test func deliveryCredentialCancellationReplacesContextWithoutKeychainAccess() {
    let store = KeychainCredentialStore(), original = store.context()
    store.cancelAuthentication()
    let renewed = store.context()
    #expect(renewed !== original)
    #expect(store.context() === renewed)
    store.cancelAuthentication()
    #expect(store.context() !== renewed)
}
#endif

private final class UploadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UploadProgress] = []
    func record(_ event: UploadProgress) { lock.withLock { events.append(event) } }
    var snapshot: [UploadProgress] { lock.withLock { events } }
}

@Test func uploadsCleanupConflictDoesNotFailPublishingOrBlockOtherLocalCleanup() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let first = try await publishReview("conflict", storage: storage, delivery: settings)
    let second = try await publishReview("healthy", storage: storage, delivery: settings)
    do {
        let store = try NativeStore(url: storage.profile.database)
        for var episode in try store.episodes() { episode.audioFinalizationComplete = false; try store.save(episode) }
    }
    let remote = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote)
    do {
        let store = try NativeStore(url: storage.profile.database)
        for var episode in try store.episodes() { episode.audioFinalizationComplete = true; try store.save(episode) }
    }
    let original = try Data(contentsOf: first.audioURL)
    try Files.write(Data("unowned replacement".utf8), to: first.audioURL)
    let idle = FakeWebDAVTransport(), log = DeliveryDebugLog(); log.enabled = true
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: nil), transport: idle, debugLog: log)
    let episodes = try await coordinator.savedAudio(storage: storage)
    let conflict = try #require(episodes.first { $0.id == first.episode.id })
    let healthy = try #require(episodes.first { $0.id == second.episode.id })
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.lastError == nil && summary.pendingMedia == 0 && !summary.needsDrain)
    #expect(conflict.localCleanupNotice != nil && healthy.localCleanupNotice == nil)
    #expect(try Data(contentsOf: first.audioURL) == Data("unowned replacement".utf8))
    #expect(!FileManager.default.fileExists(atPath: second.audioURL.path) && idle.methods.isEmpty)
    #expect(UploadItem(episode: conflict, publication: .published).isInOutbox)
    #expect(!UploadItem(episode: healthy, publication: .published).isInOutbox)
    #expect(log.text.contains("local audio cleanup: verification failed") && !log.text.contains(root.path))
    // Repairing the tracked bytes clears the durable issue on a quiet local retry.
    try Files.write(original, to: first.audioURL)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: nil), transport: idle)
    let repaired = try #require(try await coordinator.savedAudio(storage: storage).first { $0.id == first.episode.id })
    #expect(repaired.localCleanupNotice == nil && !FileManager.default.fileExists(atPath: first.audioURL.path))
    #expect(!UploadItem(episode: repaired, publication: .published).isInOutbox)
}

@Test func uploadsProgressAndFeedConfirmationRemainSeparate() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: storage, delivery: settings), remote = FakeWebDAVTransport()
    remote.statusFor = { method, path in method == "PUT" && path.hasSuffix("feed.xml") ? 503 : nil }
    let recorder = UploadEventRecorder()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: LoggingDeliveryTransport(base: remote, log: DeliveryDebugLog()), progress: recorder.record)
    let phases = recorder.snapshot.map(\.phase)
    #expect(phases.contains(.verifyingLocal) && phases.contains(.transferring) && phases.contains(.verifyingServer))
    #expect(phases.last == .publishing)
    #expect(recorder.snapshot.compactMap(\.fraction).last == 1)
    #expect(recorder.snapshot.compactMap(\.fraction).first.map { $0 > 0 && $0 < 1 } == true)
    let episode = try #require(try await coordinator.savedAudio(storage: storage).first)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.publicationStates[episode.id] == .uploaded)
    #expect(UploadItem(episode: episode, publication: .uploaded, feedError: summary.feedError).isInOutbox)
    remote.statusFor = nil
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote, force: true)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[episode.id] == .published)
    #expect(remote.recordedCalls.filter { $0.method == "PUT" && $0.path.hasSuffix(generated.episode.id + ".m4a") }.count == 1)
}

@Test func uploadsByteProgressRequiresKnownTotalsAndDoesNotCertifyPublication() {
    let episode = Episode(id: "synthetic", title: "Synthetic", stage: .published, settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
    let progress = UploadProgress(episode: episode, phase: .transferring, sentBytes: 100, totalBytes: 100)
    #expect(progress.fraction == 1)
    #expect(UploadItem(episode: episode, publication: .awaitingUpload, progress: progress).isInOutbox)
    #expect(UploadProgress(episode: episode, phase: .transferring, sentBytes: 5, totalBytes: -1).fraction == nil)
    #expect(UploadProgress(episode: episode, phase: .verifyingServer, sentBytes: 100, totalBytes: 100).fraction == nil)
    #expect(!UploadItem(episode: episode, publication: .published).isInOutbox)
    var removing = episode; removing.manualAudioDeletionRequested = true
    removing.delivery = DeliveryState(status: .failed, remotePath: "audio/synthetic.m4a", lastError: "Removal needs retry.")
    #expect(!UploadItem(episode: removing, publication: .failed).isInOutbox)
}

@Test func uploadsServerRemovalFailuresRemainVisibleInHistoryWithPerItemDetails() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: storage, delivery: settings), remote = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote)
    _ = try await coordinator.removeSavedAudio(ids: [generated.episode.id], storage: storage)
    remote.statusFor = { method, _ in method == "DELETE" ? 503 : nil }
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote, force: true)
    let pending = try #require(try await coordinator.savedAudio(storage: storage).first)
    let item = UploadItem(episode: pending, publication: .notUploaded)
    #expect(item.phase == .removalFailed && item.detail != nil && item.phase.needsAttention)
    #expect(!item.isInOutbox)
    remote.statusFor = nil
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote, force: true)
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
}

@Test func uploadsExplicitRetryRevalidatesRepairedLocalBytesBeforeTransferring() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: storage, delivery: settings), remote = FakeWebDAVTransport()
    let original = try Data(contentsOf: generated.audioURL)
    try Files.write(Data("substituted".utf8), to: generated.audioURL)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote)
    let failed = try #require(try await coordinator.savedAudio(storage: storage).first)
    #expect(failed.delivery?.verificationFailed == true && failed.delivery?.status == .failed)
    #expect(!remote.recordedCalls.contains { $0.method == "PUT" && $0.path.hasSuffix(".m4a") })
    try Files.write(original, to: generated.audioURL)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote, force: true)
    let recovered = try #require(try await coordinator.savedAudio(storage: storage).first)
    #expect(recovered.delivery?.verificationFailed != true)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[recovered.id] == .published)
    #expect(remote.recordedCalls.filter { $0.method == "PUT" && $0.path.hasSuffix(".m4a") }.count == 1)
    #expect(UploadItem(episode: failed, publication: .notUploaded).phase == .waiting)
}

@Test func localUploadDiscardRemovesChangedBytesButPreservesConfirmedServerAndText() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: storage, delivery: settings), remote = FakeWebDAVTransport()
    do {
        let store = try NativeStore(url: storage.profile.database)
        var episode = generated.episode; episode.audioFinalizationComplete = false; try store.save(episode)
    }
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote)
    let before = try #require(try await coordinator.savedAudio(storage: storage).first)
    let serverBytes = remote.body("/" + settings.remoteMediaPath(before.id))
    let feed = remote.body("/" + settings.remoteFeedPath), count = remote.recordedCalls.count
    try Files.write(Data("partial or conflicting local bytes".utf8), to: generated.audioURL)
    try await coordinator.discardLocalUpload(id: before.id, storage: storage)
    let after = try #require(try await coordinator.savedAudio(storage: storage).first)
    #expect(!FileManager.default.fileExists(atPath: generated.audioURL.path))
    #expect(after.stage == .published && after.localAudioDiscarded == true && after.localCleanupNotice == nil)
    #expect(after.audioHash == before.audioHash && after.info == before.info && after.delivery == before.delivery)
    #expect(!UploadItem(episode: after, publication: .published).isInOutbox)
    #expect(remote.recordedCalls.count == count && remote.body("/" + settings.remoteMediaPath(after.id)) == serverBytes)
    #expect(remote.body("/" + settings.remoteFeedPath) == feed)
    try await FixtureCoordinator().recoverTemporaryAudio(storage: storage, settings: settings)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let store = try NativeStore(url: storage.profile.database, readOnly: true)
    #expect(try store.snapshot(articleID: after.id) != nil)
}

@Test func localUploadDiscardSuppressesAutomaticRecoveryAndTransferAfterRelaunch() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: storage, delivery: settings)
    let ready = try await coordinator.enqueue(deliveryReview(), storage: storage, preferences: SpeechPreferences())
    #expect(ready.id == generated.episode.id)
    try await coordinator.discardLocalUpload(id: generated.episode.id, storage: storage)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let restarted = FixtureCoordinator()
    try await restarted.recoverTemporaryAudio(storage: storage, settings: settings)
    #expect(try await restarted.queue(stateRoot: storage.stateRoot).isEmpty)
    let episode = try #require(try await restarted.savedAudio(storage: storage).first)
    let item = UploadItem(episode: episode, publication: .awaitingUpload)
    #expect(item.phase == .discarded && !item.isInOutbox)
    let remote = FakeWebDAVTransport()
    _ = try await restarted.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: remote)
    #expect(!remote.recordedCalls.contains { $0.method == "PUT" && $0.path.hasSuffix(".m4a") })
    #expect(try await restarted.deliverySummary(stateRoot: storage.stateRoot, settings: settings).pendingMedia == 0)
}

@Test func localUploadDiscardRetainsReplacedOrLinkedFilesAndDurableRetryNotice() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: storage)
    await coordinator.setBeforeOwnedAudioUnlink { file in try? Files.write(Data("replacement during unlink".utf8), to: file) }
    await #expect(throws: RelayError.self) { try await coordinator.discardLocalUpload(id: generated.episode.id, storage: storage) }
    await coordinator.setBeforeOwnedAudioUnlink(nil)
    #expect(try Data(contentsOf: generated.audioURL) == Data("replacement during unlink".utf8))
    let failed = try #require(try await coordinator.savedAudio(storage: storage).first)
    #expect(failed.localAudioDiscarded == true && failed.localCleanupNotice != nil)
    #expect(UploadItem(episode: failed, publication: .notUploaded).isInOutbox)
    let unrelated = root.appendingPathComponent("unrelated.m4a")
    try Files.write(Data("unrelated".utf8), to: unrelated)
    try FileManager.default.removeItem(at: generated.audioURL)
    try FileManager.default.createSymbolicLink(at: generated.audioURL, withDestinationURL: unrelated)
    await #expect(throws: RelayError.self) { try await coordinator.discardLocalUpload(id: generated.episode.id, storage: storage) }
    #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
    try FileManager.default.removeItem(at: generated.audioURL)
    try await coordinator.discardLocalUpload(id: generated.episode.id, storage: storage)
    #expect(try await coordinator.savedAudio(storage: storage).first?.localCleanupNotice == nil)
}

@Test func localUploadDiscardPreservesLegacyChangedFilesAndAllowsDeliberateRegeneration() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try deliveryStorage(root: root), coordinator = FixtureCoordinator()
    let generated = try await publishReview(storage: legacy)
    try Files.write(Data("changed legacy file".utf8), to: generated.audioURL)
    await #expect(throws: RelayError.self) { try await coordinator.discardLocalUpload(id: generated.episode.id, storage: legacy) }
    #expect(try Data(contentsOf: generated.audioURL) == Data("changed legacy file".utf8))
    let nextRoot = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: nextRoot) }
    let temporary = temporaryDeliveryStorage(nextRoot)
    let initial = try await publishReview(storage: temporary)
    try await coordinator.discardLocalUpload(id: initial.episode.id, storage: temporary)
    let regenerated = try await publishReview(storage: temporary)
    #expect(regenerated.episode.id == initial.episode.id && regenerated.episode.localAudioDiscarded == nil)
    #expect(regenerated.episode.localCleanupNotice == nil && FileManager.default.fileExists(atPath: regenerated.audioURL.path))
}

@Test(arguments: [false, true]) func sourceRemovalRetainsServerEpisodesAndUnconfirmedAudio(confirmed: Bool) async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = temporaryDeliveryStorage(root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let entry = ReadingListEntry(id: "source", safariID: nil, url: URL(string: "https://articles.example/one")!,
        title: "Synthetic source", addedAt: .distantPast)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let result = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    if confirmed {
        _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    }
    let feedPath = "/" + settings.remoteFeedPath
    let remoteFeed = transport.body(feedPath), ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    let old = try #require(try await coordinator.library(storage: storage).first)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
    // A stale pipeline result cannot restore deleted source caches/removal intent.
    try NativeStore(url: storage.profile.database).save(old)
    try await coordinator.purgeRemovedReadingListCaches(storage: storage)
    let saved = try #require(try await coordinator.library(storage: storage).first)
    #expect(saved.readingListRemoved == true && saved.articleCachePurged == true && saved.stage == .published)
    #expect(saved.originalSourceHost == "articles.example" && saved.readingListSavedAt == entry.addedAt)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: saved.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: saved.settings.work.appendingPathComponent(saved.id).path))
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path) == !confirmed)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot) == ledger)
    #expect(transport.body(feedPath) == remoteFeed && !transport.methods.contains("DELETE"))
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [saved.id])
    if !confirmed {
        // Missing local output is not regenerated from a deleted article, nor remotely retired.
        try FileManager.default.removeItem(at: result.audioURL)
        try await coordinator.recoverTemporaryAudio(storage: storage, settings: settings)
        _ = try await coordinator.reconcileMissingAudio(storage: storage)
        #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
        #expect(try await coordinator.library(storage: storage).first?.stage == .published)
    }
}

@Test func feedReadbackRejectsStaleEqualLengthAndIncompleteRepresentations() async throws {
    let settings = deliverySettings(), transport = FakeWebDAVTransport()
    let client = try WebDAVClient(transport: transport, settings: settings, credential: FakeCredentials(password: "fixture"))
    let expected = Data("new-feed".utf8)
    try await client.uploadData(expected, remotePath: settings.remoteFeedPath)
    for response in [
        DeliveryResponse(status: 200, headers: ["Content-Length": "8"], body: Data("old-feed".utf8)),
        DeliveryResponse(status: 200, headers: ["Content-Length": "8"], body: Data("new".utf8)),
        DeliveryResponse(status: 404),
        DeliveryResponse(status: 200, body: Data(repeating: 0, count: 4 * 1024 * 1024 + 1))
    ] {
        transport.getResponseFor = { _ in response }
        await #expect(throws: (any Error).self) { try await client.confirmPublishedFeed(expected) }
    }
    transport.getResponseFor = nil
    try await client.confirmPublishedFeed(expected)
    #expect(transport.recordedCalls.filter { $0.method == "GET" }.allSatisfy { $0.authorized && $0.encoding == "identity" })
    let cancelled = Task { try Task.checkCancellation(); try await client.confirmPublishedFeed(expected) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func unconfirmedFeedRetainsLocalAudioAndBlocksRemoteDeletes() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let episode = try await publishReview(storage: storage, delivery: settings).episode
    let transport = FakeWebDAVTransport()
    // Missing feed before PUT is normal. After PUT, return stale bytes of exactly the new length.
    transport.getResponseFor = { path in
        guard path.hasSuffix("feed.xml"), let data = transport.body(path) else { return nil }
        return DeliveryResponse(status: 200, headers: ["Content-Length": String(data.count)], body: Data(repeating: 32, count: data.count))
    }
    let result = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "fixture"), transport: transport, force: true)
    #expect(!result.feedUploaded)
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.remoteFeedPending)
    #expect(ledger.lastUploadedFeedHash == nil)
    #expect(ledger.lastPublishedAudioHashes?.isEmpty != false)
    #expect(FileManager.default.fileExists(atPath: storage.audioDirectory.appendingPathComponent(episode.id + ".m4a").path))
    #expect(!transport.methods.contains("DELETE"))
    transport.getResponseFor = nil
    let retried = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "fixture"), transport: transport, force: true, reconcileNow: true)
    // Reconciliation may confirm the already-correct stored feed without another PUT.
    #expect(retried.failed == 0)
    let confirmed = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(!confirmed.remoteFeedPending && confirmed.lastPublishedAudioHashes?[episode.id] == episode.audioHash)
}

@Test func feedReadbackFailurePreservesPendingRemoteRemoval() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let retired = try await publishReview("retire-readback", storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport()
    _ = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "fixture"), transport: transport)
    let oldFeed = try #require(transport.body("/" + settings.remoteFeedPath))
    _ = try await coordinator.removeSavedAudio(ids: [retired.episode.id], storage: storage)
    let start = transport.recordedCalls.count
    transport.getResponseFor = { path in
        guard path.hasSuffix("feed.xml"), transport.body(path) != oldFeed else { return nil }
        let count = transport.body(path)!.count
        return DeliveryResponse(status: 200, headers: ["Content-Length": String(count)], body: Data(repeating: 32, count: count))
    }
    let failed = try await coordinator.deliverPending(storage: storage, settings: settings,
        credential: FakeCredentials(password: "fixture"), transport: transport, force: true)
    #expect(!failed.feedUploaded && failed.remoteDeletes == 0)
    #expect(!transport.recordedCalls.dropFirst(start).contains { $0.method == "DELETE" })
    let ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.remoteFeedPending && ledger.pendingRemoteDeletes == [settings.remoteMediaPath(retired.episode.id)])
    #expect(transport.objectLength("/" + settings.remoteMediaPath(retired.episode.id)) != nil)
}

@Test func oversizedFeedIsRejectedBeforePUT() async throws {
    let transport = FakeWebDAVTransport()
    let client = try WebDAVClient(transport: transport, settings: deliverySettings(), credential: FakeCredentials(password: "fixture"))
    await #expect(throws: (any Error).self) { try await client.publishFeed(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)) }
    #expect(transport.methods.isEmpty)
}

@Test func deliveryPreflightUsesDestinationAndCadenceWithoutMutatingCorruptLedger() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator(), settings = deliverySettings()
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    #expect(await coordinator.deliveryPreflightRequired(stateRoot: root, settings: settings, now: now))
    var ledger = DeliveryLedger()
    ledger.destinationURL = settings.feedFolderURL; ledger.reconciliationAttemptAt = now
    try ledger.save(stateRoot: root)
    #expect(await coordinator.deliveryPreflightRequired(stateRoot: root, settings: settings, now: now.addingTimeInterval(299)) == false)
    #expect(await coordinator.deliveryPreflightRequired(stateRoot: root, settings: settings, now: now.addingTimeInterval(300)))
    var changed = settings; changed.feedFolderURL = URL(string: "https://other.example/podcast/")
    #expect(await coordinator.deliveryPreflightRequired(stateRoot: root, settings: changed, now: now))
    let file = DeliveryLedger.fileURL(stateRoot: root), corrupt = Data("invalid-json".utf8)
    try Files.write(corrupt, to: file)
    #expect(await coordinator.deliveryPreflightRequired(stateRoot: root, settings: settings, now: now))
    #expect(try Data(contentsOf: file) == corrupt)
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["delivery.json"])
}

@Test func podcastCoverPublishesBeforeFeedWithoutChangingEpisodeMedia() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), coordinator = FixtureCoordinator()
    var settings = deliverySettings()
    let published = try await publishReview(storage: storage, delivery: settings)
    let context = try #require(CGContext(data: nil, width: 1400, height: 1400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let imageData = NSMutableData(), imageDestination = try #require(CGImageDestinationCreateWithData(imageData, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(imageDestination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(imageDestination))
    let art = try CoverArtwork(data: imageData as Data, profile: .podcast)
    let artStore = CoverArtworkStore(root: root.appendingPathComponent("art"))
    settings.podcastCoverDigest = try artStore.save(art); settings.podcastCoverConfigured = true
    let transport = FakeWebDAVTransport(), credentials = FakeCredentials(password: "synthetic")
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials,
        transport: transport, force: true, artworkStore: artStore)
    #expect(result.feedUploaded)
    let feedPath = settings.remoteFolder.isEmpty ? "/feed.xml" : "/" + settings.remoteFeedPath
    let feed = try #require(transport.body(feedPath))
    let snapshot = try ServerFeedSnapshot(feed)
    #expect(snapshot.channelArtworkURL?.lastPathComponent == "artwork-" + art.digest + ".jpg")
    #expect(snapshot.items.first?.id == published.episode.id)
    let putCalls = transport.recordedCalls.filter { $0.method == "PUT" }
    #expect(try #require(putCalls.firstIndex { $0.path.hasSuffix(".jpg") }) < #require(putCalls.firstIndex { $0.path.hasSuffix("feed.xml") }))
    let mediaPuts = putCalls.filter { $0.path.hasSuffix(".m4a") }.count
    let firstHash = try #require(await coordinator.savedAudio(storage: storage).first).audioHash
    settings.podcastCoverDigest = nil; settings.podcastCoverConfigured = true
    let removed = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials,
        transport: transport, force: true, artworkStore: artStore)
    #expect(removed.feedUploaded)
    #expect(try ServerFeedSnapshot(#require(transport.body(feedPath))).channelArtworkURL == nil)
    #expect(transport.recordedCalls.filter { $0.method == "PUT" && $0.path.hasSuffix(".m4a") }.count == mediaPuts)
    #expect(try #require(await coordinator.savedAudio(storage: storage).first).audioHash == firstHash)
    let oldFeed = try #require(transport.body(feedPath))
    settings.podcastCoverDigest = art.digest
    settings.feedFolderURL = URL(string: "https://other-webdav.example/new-podcast/")
    settings.publicFolderURL = URL(string: "https://other-podcast.example/")
    let moved = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials,
        transport: transport, force: true, artworkStore: artStore)
    #expect(moved.feedUploaded)
    #expect(transport.body(feedPath) == oldFeed)
    let newFeedPath = "/" + settings.remoteFeedPath
    #expect(try ServerFeedSnapshot(#require(transport.body(newFeedPath))).channelArtworkURL?.host == "other-podcast.example")
    try FileManager.default.removeItem(at: artStore.url(for: art.digest))
    settings.channelDescription = "Metadata-only update with a remotely retained cover"
    let remoteOnly = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials,
        transport: transport, force: true, artworkStore: artStore)
    #expect(remoteOnly.feedUploaded)
    #expect(try ServerFeedSnapshot(#require(transport.body(newFeedPath))).channelArtworkURL?.lastPathComponent == "artwork-" + art.digest + ".jpg")
}

@Test func podcastCoverReadbackFailurePreservesPreviousFeed() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), coordinator = FixtureCoordinator()
    var settings = deliverySettings()
    _ = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport(), credentials = FakeCredentials(password: "synthetic")
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport, force: true)
    let path = "/" + settings.remoteFeedPath, prior = try #require(transport.body(path))
    settings.podcastCoverConfigured = true; settings.podcastCoverDigest = String(repeating: "a", count: 64)
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials,
        transport: transport, force: true, artworkStore: .init(root: root.appendingPathComponent("missing")))
    #expect(!result.feedUploaded)
    #expect(transport.body(path) == prior)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).remoteFeedPending)
}

@Test func podcastCoverRecoveryDoesNotEraseRemoteOnlyShowArtOrEpisodeArt() throws {
    let remote = Data("<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><itunes:image href=\"https://podcast.example/old.jpg\"/></channel></rss>".utf8)
    var settings = deliverySettings()
    let preserved = try RSS.renderRemote([], channel: RemoteChannel(settings: settings, previousFeed: remote))
    #expect(try ServerFeedSnapshot(preserved).channelArtworkURL?.absoluteString == "https://podcast.example/old.jpg")
    settings.podcastCoverConfigured = true
    let removed = try RSS.renderRemote([], channel: RemoteChannel(settings: settings, previousFeed: remote))
    #expect(try ServerFeedSnapshot(removed).channelArtworkURL == nil)
    let old = try JSONDecoder().decode(DeliverySettings.self, from: Data("{}".utf8))
    #expect(old.podcastCoverConfigured == nil && old.podcastCoverDigest == nil)
}

@Test func podcastCoverCorruptReadbackNeverPublishesItsReference() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), coordinator = FixtureCoordinator()
    var settings = deliverySettings()
    _ = try await publishReview(storage: storage, delivery: settings)
    let transport = FakeWebDAVTransport(), credentials = FakeCredentials(password: "synthetic")
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport, force: true)
    let prior = try #require(transport.body("/" + settings.remoteFeedPath))
    let context = try #require(CGContext(data: nil, width: 1400, height: 1400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let bytes = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil); #expect(CGImageDestinationFinalize(destination))
    let art = try CoverArtwork(data: bytes as Data, profile: .podcast), store = CoverArtworkStore(root: root.appendingPathComponent("art"))
    settings.podcastCoverDigest = try store.save(art); settings.podcastCoverConfigured = true
    transport.getResponseFor = { path in path.hasSuffix(".jpg") && transport.body(path) != nil ? DeliveryResponse(status: 200, body: Data("corrupt".utf8)) : nil }
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials,
        transport: transport, force: true, artworkStore: store)
    #expect(!result.feedUploaded)
    #expect(transport.body("/" + settings.remoteFeedPath) == prior)
}

@Test func queuedNarrationOptionsAreCapturedAndLegacyPreferencesKeepDefaults() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), coordinator = FixtureCoordinator()
    let review = try deliveryReview()
    var preferences = SpeechPreferences()
    preferences.effectiveNarrationOptions = .init(notes: .omit, includeAuxiliary: false)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: preferences)
    preferences.effectiveNarrationOptions = .init()
    let episode = try #require(await coordinator.library(storage: storage).first { $0.id == item.id })
    #expect(episode.settings.narrationOptions == .init(notes: .omit, includeAuxiliary: false))
    #expect(try await coordinator.articlePreviewProfile(articleID: item.id, stateRoot: storage.stateRoot).narrationOptions == .init(notes: .omit, includeAuxiliary: false))
    let old = try JSONDecoder().decode(SpeechPreferences.self, from: Data("{\"voice\":\"af_heart\",\"speed\":1}".utf8))
    #expect(old.effectiveNarrationOptions == .init())
}

private func transcriptReview(_ path: String, storage: ManagedSpeechStorage, enabled: Bool = true,
                              interruptAfter: FixtureBoundary? = nil) async throws -> FixtureResult {
    let coordinator = FixtureCoordinator(), review = try deliveryReview(path)
    var preferences = SpeechPreferences(); preferences.timedTranscriptsEnabled = enabled
    _ = try await coordinator.enqueue(review, storage: storage, preferences: preferences)
    return try await coordinator.runReviewed(root: storage.stateRoot, review: review, backend: DeliveryTestBackend(),
        interruptAfter: interruptAfter, storage: storage, delivery: deliverySettings())
}

@Test func timedTranscriptCapturesPreferenceSurvivesEncodingResumeAndBackup() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root)
    do {
        _ = try await transcriptReview("resume-transcript", storage: storage, interruptAfter: .encoded)
        Issue.record("Expected the encoded recovery boundary")
    } catch let error as RelayError { #expect(error == .interrupted) }
    let before = try #require(NativeStore(url: storage.profile.database, readOnly: true).episodes().first)
    let transcript = try #require(before.transcript)
    let resumed = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: deliveryReview("resume-transcript"),
        backend: DeliveryTestBackend(), storage: storage, delivery: deliverySettings())
    #expect(resumed.synthesizedChunks == 0 && resumed.episode.encodedHash == before.encodedHash)
    #expect(resumed.episode.transcript == transcript)
    #expect(transcript.vtt.components(separatedBy: " --> ").count - 1 == resumed.narration.chunks.count)
    #expect(transcript.audioHash == resumed.episode.audioHash)
    #expect(!FileManager.default.fileExists(atPath: resumed.episode.settings.work.appendingPathComponent(resumed.episode.id).path))
    _ = try await transcriptReview("disabled-transcript", storage: storage, enabled: false)
    let episodes = try NativeStore(url: storage.profile.database, readOnly: true).episodes()
    #expect(episodes.contains { $0.settings.publishTranscripts == false && $0.transcript == nil })
    let backup = root.appendingPathComponent("backup")
    _ = try await FixtureCoordinator().backupLibrary(storage: storage, destination: backup)
    let saved = try NativeStore(url: backup.appendingPathComponent("native.sqlite3"), readOnly: true).episodes()
    #expect(saved.first { $0.id == resumed.episode.id }?.transcript == transcript)
}

@Test func timedTranscriptPublishesVerifiedSidecarBeforeRSSAndRetiresAfterFeed() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let generated = try await transcriptReview("transcript-publish", storage: storage)
    let transcript = try #require(generated.episode.transcript)
    let path = "/" + transcript.remotePath(id: generated.episode.id, settings: settings)
    let transport = FakeWebDAVTransport()
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(result.uploadedTranscripts == 1 && result.feedUploaded)
    #expect(transport.body(path) == Data(transcript.vtt.utf8))
    let calls = transport.recordedCalls
    let put = try #require(calls.firstIndex { $0.method == "PUT" && $0.path == path })
    let readback = try #require(calls.indices.first { $0 > put && calls[$0].method == "GET" && calls[$0].path == path })
    let feedPut = try #require(calls.firstIndex { $0.method == "PUT" && $0.path.hasSuffix("/feed.xml") })
    #expect(put < readback && readback < feedPut && calls[put].authorized)
    let feed = try #require(transport.body("/" + settings.remoteFeedPath))
    let items = try ServerFeedParser.parse(feed), reference = try transcript.reference(id: generated.episode.id, settings: settings)
    #expect(items.first?.transcripts == [reference])
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.pendingTranscripts == 0 && summary.failedTranscripts == 0 && !summary.needsDrain)
    // Source-free recovery retains the standard RSS reference without fetching it.
    let recoveredStorage = try deliveryStorage(root: root.appendingPathComponent("recovered"))
    let recovery = FixtureCoordinator()
    _ = try await recovery.deliverPending(storage: recoveredStorage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    let recovered = try NativeStore(url: recoveredStorage.profile.database, readOnly: true).episodes()
    #expect(recovered.first?.transcriptReferences == [reference] && recovered.first?.transcript == nil)
    // Retire only the owning destination's sidecar, after the feed omits the episode.
    _ = try await coordinator.removeSavedAudio(ids: [generated.episode.id], storage: storage)
    let start = transport.recordedCalls.count
    let retired = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(retired.remoteDeletes == 2)
    let after = Array(transport.recordedCalls.dropFirst(start))
    let firstDelete = try #require(after.firstIndex { $0.method == "DELETE" })
    let removeFeed = try #require(after.firstIndex { $0.method == "PUT" && $0.path.hasSuffix("/feed.xml") })
    #expect(removeFeed < firstDelete && transport.body(path) == nil)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
    let again = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(again.remoteDeletes == 0)
}

@Test func timedTranscriptFailureIsolatedAndResumesWithoutAudioOrResynthesis() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings()
    let first = try await transcriptReview("transcript-failure", storage: storage)
    let second = try await transcriptReview("transcript-healthy", storage: storage)
    let failed = try #require(first.episode.transcript)
    let failedPath = "/" + failed.remotePath(id: first.episode.id, settings: settings)
    let transport = FakeWebDAVTransport()
    // Corrupt only this sidecar's readback, while preserving its stored bytes.
    transport.getResponseFor = { path in
        guard path == failedPath, transport.objectLength(path) != nil else { return nil }
        return DeliveryResponse(status: 200, body: Data("wrong transcript".utf8))
    }
    let coordinator = FixtureCoordinator()
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    #expect(result.uploadedMedia == 2 && result.uploadedTranscripts == 1 && result.retrying == 1 && result.feedUploaded)
    let feed = try #require(transport.body("/" + settings.remoteFeedPath)), parsed = try ServerFeedParser.parse(feed)
    #expect(parsed.first { $0.id == first.episode.id }?.transcripts.isEmpty == true)
    #expect(parsed.first { $0.id == second.episode.id }?.transcripts.count == 1)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.pendingTranscripts == 1 && summary.needsDrain && summary.lastError != nil)
    let episode = try #require(NativeStore(url: storage.profile.database, readOnly: true).episodes().first { $0.id == first.episode.id })
    #expect(UploadItem(episode: episode, publication: .published).phase == .transcriptFailed)
    // Temporary audio may already be released; text remains durably retryable.
    try? FileManager.default.removeItem(at: first.audioURL)
    transport.getResponseFor = nil
    let count = transport.recordedCalls.count
    let retry = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(retry.uploadedMedia == 0 && retry.uploadedTranscripts >= 1 && retry.feedUploaded)
    #expect(!transport.recordedCalls.dropFirst(count).contains { $0.method == "PUT" && $0.path.hasSuffix(".m4a") })
    let final = try ServerFeedParser.parse(#require(transport.body("/" + settings.remoteFeedPath)))
    #expect(final.first { $0.id == first.episode.id }?.transcripts.count == 1)
}

@Test func timedTranscriptCancellationAfterPUTAndDestinationChangeAreRecoverable() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings()
    let generated = try await transcriptReview("transcript-cancel", storage: storage)
    let transcript = try #require(generated.episode.transcript)
    let oldPath = "/" + transcript.remotePath(id: generated.episode.id, settings: settings)
    let transport = FakeWebDAVTransport()
    transport.throwFor = { method, path in method == "HEAD" && path == oldPath ? CancellationError() : nil }
    do {
        _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
        Issue.record("Expected cancellation")
    } catch is CancellationError {}
    let pending = try #require(NativeStore(url: storage.profile.database, readOnly: true).episodes().first)
    #expect(pending.transcript?.delivery?.destinationURL == settings.feedFolderURL)
    #expect(pending.transcriptReferences == nil && transport.body(oldPath) != nil)
    transport.throwFor = nil
    let start = transport.recordedCalls.count
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(!transport.recordedCalls.dropFirst(start).contains { $0.method == "PUT" && $0.path == oldPath })
    var next = settings
    next.feedFolderURL = URL(string: "https://webdav.example/new-feed/")
    next.publicFolderURL = URL(string: "https://podcast.example/new-feed/")
    let result = try await FixtureCoordinator().deliverPending(storage: storage, settings: next, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(result.uploadedTranscripts == 1 && result.remoteDeletes == 0)
    #expect(transport.body(oldPath) != nil)
    let parsed = try ServerFeedParser.parse(#require(transport.body("/" + next.remoteFeedPath)))
    #expect(parsed.first?.transcripts.contains(try transcript.reference(id: generated.episode.id, settings: next)) == true)
}

@Test func timedTranscriptFeedFailureRemainsInOutboxUntilReferenceIsConfirmed() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), transport = FakeWebDAVTransport()
    let generated = try await transcriptReview("transcript-feed-failure", storage: storage)
    transport.statusFor = { method, path in method == "PUT" && path.hasSuffix(".vtt") ? 503 : nil }
    _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport)
    transport.statusFor = { method, path in method == "PUT" && path.hasSuffix("/feed.xml") ? 503 : nil }
    let result = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(result.uploadedTranscripts == 1 && !result.feedUploaded)
    let coordinator = FixtureCoordinator()
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.publicationStates[generated.episode.id] == .uploaded)
    do {
        let store = try NativeStore(url: storage.profile.database)
        var episode = try #require(store.episodes().first)
        #expect(episode.transcript?.delivery?.status == .uploaded)
        #expect(UploadItem(episode: episode, publication: .uploaded, feedError: summary.feedError).isInOutbox)
        // A stale metadata save must not erase the confirmed transcript copy/link.
        episode.transcript?.delivery = nil; episode.transcriptReferences = nil
        try store.save(episode)
        let preserved = try #require(store.episodes().first)
        #expect(preserved.transcript?.delivery?.status == .uploaded && preserved.transcriptReferences?.count == 1)
    } // Release the fixture writer before asking a new drain to own the database.
    transport.statusFor = nil
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: FakeCredentials(password: "x"), transport: transport, force: true)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings).publicationStates[generated.episode.id] == .published)
}

@Test(arguments: [false, true], [false, true])
func retirementRejectsOldDestinationAndLegacyPendingPaths(sameHost: Bool, staleIntent: Bool) async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), old = deliverySettings(), transport = FakeWebDAVTransport()
    let credentials = FakeCredentials(password: "synthetic"), coordinator = FixtureCoordinator()
    let generated = try await publishReview("old-destination", storage: storage, delivery: old)
    _ = try await coordinator.deliverPending(storage: storage, settings: old, credential: credentials, transport: transport)
    let oldPath = "/" + old.remoteMediaPath(generated.episode.id)
    let oldBytes = try #require(transport.body(oldPath))
    try await coordinator.discardLocalUpload(id: generated.episode.id, storage: storage)
    var next = old
    next.feedFolderURL = URL(string: sameHost ? "https://webdav.example/new-podcast/" : "https://new-webdav.example/new-podcast/")
    next.publicFolderURL = URL(string: "https://new-public.example/podcast/")
    _ = try await coordinator.deliverPending(storage: storage, settings: next, credential: credentials, transport: transport)
    _ = try await coordinator.removeSavedAudio(ids: [generated.episode.id], storage: storage)
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.destinationURL == next.feedFolderURL && ledger.pendingRemoteDeletes.isEmpty)
    if staleIntent {
        // Older versions could record foreign paths in an already migrated ledger.
        ledger.pendingRemoteDeletes = [old.remoteMediaPath(generated.episode.id), "unowned/audio.m4a"]
        try ledger.save(stateRoot: storage.stateRoot)
    }
    let start = transport.recordedCalls.count
    let retired = try await coordinator.deliverPending(storage: storage, settings: next, credential: credentials, transport: transport)
    #expect(retired.remoteDeletes == 0)
    #expect(!transport.recordedCalls.dropFirst(start).contains { $0.method == "DELETE" })
    #expect(transport.body(oldPath) == oldBytes)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
}

@Test func retirementUpdatesOnlyOwnersOfDeletedMediaAndTranscripts() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), transport = FakeWebDAVTransport()
    let credentials = FakeCredentials(password: "synthetic"), coordinator = FixtureCoordinator()
    let untouched = try await transcriptReview("already-retired", storage: storage)
    let first = try await transcriptReview("retire-first", storage: storage)
    let second = try await transcriptReview("retire-second", storage: storage)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    _ = try await coordinator.removeSavedAudio(ids: [untouched.episode.id], storage: storage)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    _ = try await coordinator.removeSavedAudio(ids: [first.episode.id, second.episode.id], storage: storage)
    do {
        let store = try NativeStore(url: storage.profile.database)
        try store.execute("CREATE TABLE deletion_updates (article_id TEXT)")
        try store.execute("CREATE TRIGGER track_deletion_updates AFTER UPDATE ON episodes BEGIN INSERT INTO deletion_updates VALUES (NEW.id); END")
    }
    let result = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    #expect(result.remoteDeletes == 4)
    let store = try NativeStore(url: storage.profile.database, readOnly: true)
    #expect(try store.query("SELECT COUNT(*) FROM deletion_updates WHERE article_id=?", [untouched.episode.id]).first?.first == "0")
    for id in [first.episode.id, second.episode.id] {
        #expect(try store.query("SELECT COUNT(*) FROM deletion_updates WHERE article_id=?", [id]).first?.first == "2")
        let episode = try #require(store.episodes().first { $0.id == id })
        #expect(episode.delivery?.remotePath == "" && episode.transcript?.delivery?.remotePath == "")
        #expect(episode.transcriptReferences?.isEmpty == true)
    }
}

@Test func timedTranscriptPublicMappingChangeRefreshesRSSWithoutAudioUpload() async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), transport = FakeWebDAVTransport()
    let credentials = FakeCredentials(password: "synthetic"), coordinator = FixtureCoordinator()
    let generated = try await transcriptReview("transcript-public-map", storage: storage)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    let original = try #require(generated.episode.transcript)
    let external = PodcastTranscriptReference(url: URL(string: "https://external.example/edited.vtt")!, type: "text/vtt", language: "en", rel: "captions")
    do {
        let store = try NativeStore(url: storage.profile.database)
        var episode = try #require(store.episodes().first)
        episode.transcriptReferences?.append(external)
        try store.save(episode)
    }
    var next = settings; next.publicFolderURL = URL(string: "https://new-public.example/podcast/")
    let pending = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: next)
    #expect(pending.pendingTranscripts == 1 && pending.needsDrain)
    let start = transport.recordedCalls.count
    let updated = try await coordinator.deliverPending(storage: storage, settings: next, credential: credentials, transport: transport)
    #expect(updated.feedUploaded && updated.uploadedMedia == 0)
    let calls = transport.recordedCalls.dropFirst(start)
    #expect(!calls.contains { $0.method == "PUT" && ($0.path.hasSuffix(".m4a") || $0.path.hasSuffix(".vtt")) })
    #expect(calls.contains { $0.method == "GET" && $0.path.hasSuffix(".vtt") })
    let feed = try #require(transport.body("/" + settings.remoteFeedPath))
    let references = try #require(ServerFeedParser.parse(feed).first).transcripts
    #expect(references.contains(try original.reference(id: generated.episode.id, settings: next)))
    #expect(!references.contains(try original.reference(id: generated.episode.id, settings: settings)))
    #expect(references.contains(external))
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: next)
    #expect(summary.publicationStates[generated.episode.id] == .published && !summary.needsDrain)
}

@Test(arguments: [false, true])
func retirementKeepsTranscriptOnlyFailureVisibleUntilRetryCompletes(transcriptFirst: Bool) async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), transport = FakeWebDAVTransport()
    let credentials = FakeCredentials(password: "synthetic"), coordinator = FixtureCoordinator()
    let generated = try await transcriptReview("transcript-removal-retry", storage: storage)
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    _ = try await coordinator.removeSavedAudio(ids: [generated.episode.id], storage: storage)
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    let mediaPath = settings.remoteMediaPath(generated.episode.id)
    let transcriptPath = try #require(generated.episode.transcript).remotePath(id: generated.episode.id, settings: settings)
    ledger.pendingRemoteDeletes = transcriptFirst ? [transcriptPath, mediaPath] : [mediaPath, transcriptPath]
    try ledger.save(stateRoot: storage.stateRoot)
    transport.statusFor = { method, path in method == "DELETE" && path.hasSuffix(".vtt") ? 503 : nil }
    let partial = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    #expect(partial.remoteDeletes == 1)
    let pending = try #require(await coordinator.savedAudio(storage: storage).first { $0.id == generated.episode.id })
    #expect(pending.delivery?.remotePath == "" && pending.delivery?.lastError != nil)
    #expect(pending.transcript?.delivery?.remotePath.isEmpty == false)
    #expect(UploadItem(episode: pending, publication: .notUploaded).phase == .removalFailed)
    transport.statusFor = nil
    let retry = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credentials, transport: transport)
    #expect(retry.remoteDeletes == 1)
    #expect(try await !coordinator.savedAudio(storage: storage).contains { $0.id == generated.episode.id })
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).pendingRemoteDeletes.isEmpty)
}

@Test(arguments: ["none", "media", "firstFeed", "replacementFeed", "delete"], [false, true])
func duplicateReplacementKeepsOldServerAudioUntilNewFeedIsConfirmed(failure: String, sameURL: Bool) async throws {
    let root = try deliveryTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try deliveryStorage(root: root), settings = deliverySettings(), coordinator = FixtureCoordinator()
    let review = try deliveryReview("duplicate")
    let oldEntry = ReadingListEntry(id: "old-save", safariID: "old-save", url: review.page.originalURL,
        title: review.document!.article.title, addedAt: Date(timeIntervalSinceReferenceDate: 1))
    _ = try await coordinator.reconcile(.init(entries: [oldEntry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let oldItem = try await coordinator.enqueueReadingList(oldEntry.id, storage: storage, preferences: .init(voice: .emma),
        fetch: { _ in review.page }, describeImages: false)
    let old = try await coordinator.runQueued(oldItem.id, storage: storage, backend: { _ in DeliveryTestBackend() }, delivery: settings)
    let transport = FakeWebDAVTransport(), credential = FakeCredentials(password: "synthetic-only")
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credential, transport: transport)
    let feedPath = settings.feedFolderURL!.appendingPathComponent("feed.xml").path
    let oldPath = "/" + settings.remoteMediaPath(oldItem.id)
    #expect(transport.objectLength(oldPath) == Int(old.episode.info!.byteLength))
    let oldTranscript = try #require(old.episode.transcript)
    let oldTranscriptPath = "/" + oldTranscript.remotePath(id: oldItem.id, settings: settings)
    #expect(transport.objectLength(oldTranscriptPath) != nil)
    let newReview = sameURL ? review : try deliveryReview("duplicate-new", title: oldEntry.title)
    let newEntry = ReadingListEntry(id: "new-save", safariID: "new-save", url: newReview.page.originalURL,
        title: oldEntry.title, addedAt: Date(timeIntervalSinceReferenceDate: 2))
    _ = try await coordinator.reconcile(.init(entries: [oldEntry, newEntry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let newItem = try await coordinator.enqueueReadingList(newEntry.id, storage: storage, preferences: .init(voice: .bella, speed: 1.2),
        fetch: { _ in newReview.page }, describeImages: false)
    let replacement = try await coordinator.runQueued(newItem.id, storage: storage, backend: { _ in DeliveryTestBackend() }, delivery: settings)
    #expect(replacement.episode.id == newItem.id && newItem.id != oldItem.id)
    #expect(replacement.episode.settings.voice == "af_bella")
    let newPath = "/" + settings.remoteMediaPath(newItem.id)
    var feedPuts = 0
    transport.statusFor = { method, path in
        if method == "PUT" && path == feedPath {
            feedPuts += 1
            if (failure == "firstFeed" && feedPuts == 1) || (failure == "replacementFeed" && feedPuts == 2) { return 503 }
        }
        if failure == "media" && method == "PUT" && path == newPath { return 503 }
        if failure == "delete" && method == "DELETE" && path == oldPath { return 503 }
        return nil
    }
    let start = transport.recordedCalls.count
    _ = try await coordinator.deliverPending(storage: storage, settings: settings, credential: credential, transport: transport, force: true)
    let calls = Array(transport.recordedCalls.dropFirst(start))
    let finalFeed = String(decoding: transport.body(feedPath)!, as: UTF8.self)
    if failure == "none" {
        #expect(transport.objectLength(oldPath) == nil)
        #expect(transport.objectLength(oldTranscriptPath) == nil)
        #expect(finalFeed.contains(newItem.id) && !finalFeed.contains(oldItem.id))
        let deleted = try #require(calls.firstIndex { $0.method == "DELETE" && $0.path == oldPath })
        #expect(calls[..<deleted].filter { $0.method == "PUT" && $0.path == feedPath }.count == 2)
    } else {
        #expect(transport.objectLength(oldPath) != nil)
        if failure == "media" || failure == "firstFeed" {
            #expect(finalFeed.contains(oldItem.id))
            #expect(transport.objectLength(oldTranscriptPath) != nil)
            #expect(!calls.contains { $0.method == "DELETE" && $0.path == oldPath })
            #expect(try await coordinator.library(storage: storage).first { $0.id == oldItem.id }?.stage == .published)
        }
        if failure == "replacementFeed" { #expect(finalFeed.contains(oldItem.id) && finalFeed.contains(newItem.id)) }
        transport.statusFor = nil
        // Relaunch and force reconciliation: superseded URL slots cannot steal the
        // successor's identity/settings, and expired copies cannot be resurrected.
        _ = try await FixtureCoordinator().deliverPending(storage: storage, settings: settings, credential: credential,
            transport: transport, force: true, reconcileNow: true)
        #expect(transport.objectLength(oldPath) == nil)
        #expect(transport.objectLength(oldTranscriptPath) == nil)
        let retried = String(decoding: transport.body(feedPath)!, as: UTF8.self)
        #expect(retried.contains(newItem.id) && !retried.contains(oldItem.id))
    }
    for entry in [oldEntry, newEntry] {
        #expect(try await FixtureCoordinator().hasRecordedArticle(entry: entry, stateRoot: storage.stateRoot))
    }
    #expect(try await coordinator.catalog(stateRoot: storage.stateRoot).inactiveDuplicateIDs == [oldEntry.id])
}
