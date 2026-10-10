import Foundation
import Testing
@testable import VoiceRelayApp
@testable import VoiceRelayCore

private struct ServerAppCredentials: DeliveryCredentialStore {
    func readPassword(username: String, host: String) throws -> String? { "fixture" }
    func writePassword(_ password: String, username: String, host: String) throws {}
    func deletePassword(username: String, host: String) throws {}
}
private final class ServerAppTransport: DeliveryTransport, @unchecked Sendable {
    private let lock = NSLock()
    let id: String
    private var objects: [String: Data]
    private var methods: [String] = []
    init(id: String, sourceKey: String) {
        self.id = id
        let audio = Data("test-audio".utf8), hash = Files.hash(audio)
        let feed = Data("""
        <rss version="2.0" xmlns:vr="urn:voicerelay:recovery:1"><channel><item><title>Synthetic article</title><guid>\(id)</guid><link>https://news.example/article</link><pubDate>Tue, 14 Nov 2023 22:13:20 GMT</pubDate><enclosure url="https://public.example/audio/\(id).m4a" type="audio/mp4" length="10"/><vr:identity source="\(sourceKey)" sha256="\(hash)"/></item></channel></rss>
        """.utf8)
        objects = ["/podcast/feed.xml": feed, "/podcast/audio/\(id).m4a": audio]
    }
    var calls: [String] { lock.withLock { methods } }
    func verifiedAudio(_ url: URL, headers: [String: String], maximumBytes: Int64, settings: PrototypeProfile) async throws -> VerifiedRemoteAudio {
        let response = try await read(url, headers: headers, maximumBytes: maximumBytes)
        return VerifiedRemoteAudio(digest: RemoteAudioDigest(status: response.status, byteLength: Int64(response.body.count), sha256: Files.hash(response.body)),
            info: response.status == 200 ? AudioInfo(duration: 20, byteLength: Int64(response.body.count), sampleRate: 24_000, channels: 1, codec: "aac") : nil)
    }
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        lock.withLock {
            methods.append(method)
            if method == "PUT" { objects[url.path] = body ?? Data(); return DeliveryResponse(status: 201) }
            if ["GET", "HEAD"].contains(method) {
                guard let data = objects[url.path] else { return DeliveryResponse(status: 404) }
                return DeliveryResponse(status: 200, headers: ["Content-Length": String(data.count)], body: method == "GET" ? data : Data())
            }
            if method == "PROPFIND" { return DeliveryResponse(status: 207, body: Data("<d:multistatus xmlns:d='DAV:'><d:response><d:href>\(url.path)</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>".utf8)) }
            return DeliveryResponse(status: 503)
        }
    }
}
private func serverAppSettings() -> DeliverySettings {
    var settings = DeliverySettings(); settings.enabled = true; settings.username = "fixture"
    settings.feedFolderURL = URL(string: "https://dav.example/podcast/")
    settings.publicFolderURL = URL(string: "https://public.example/")
    return settings
}

@Test @MainActor func serverRecoveryAutomaticallyRemovesMatchedQueueBeforeGeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-app-sync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"), temporaryAudio: true)
    let key = "reviewed-url-v1-" + Files.hash(Data("https://news.example/article".utf8))
    let database = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
    let localID: String
    do {
        let store = try NativeStore(url: database); var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
        let e = try store.episode(sourceKey: key, settings: profile); localID = e.id
        try store.saveQueueItem(SpeechQueueItem(id: e.id, title: "Synthetic article", sourceEntryID: nil, state: .queued))
    }
    let remoteID = UUID().uuidString.lowercased(), transport = ServerAppTransport(id: remoteID, sourceKey: key)
    let suite = "voicerelay-app-sync-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: ServerAppCredentials())
    model.deliverySettings = serverAppSettings()
    model.queueItems = [SpeechQueueItem(id: localID, title: "Synthetic article", sourceEntryID: nil, state: .queued)]
    model.triggerDelivery()
    #expect(model.deliveryPreflightBusy && !model.canGenerateAudio)
    await model.waitForDelivery(); await model.waitForLibraryRefresh()
    #expect(!model.deliveryPreflightBusy && model.deliveryError == nil)
    #expect(model.queueItems.isEmpty && model.savedEpisodes.map(\.id) == [remoteID])
    #expect(transport.calls.contains("GET"))
    await model.shutdown()
}

@Test @MainActor func serverRecoveryInertAndRestoreReviewNeverStartAutomaticSync() async throws {
    let transport = ServerAppTransport(id: UUID().uuidString.lowercased(), sourceKey: "reviewed-url-v1-" + String(repeating: "a", count: 64))
    let model = AppModel(preview: true, deliveryTransport: { transport }, credentialStore: ServerAppCredentials())
    model.deliverySettings = serverAppSettings(); model.triggerDelivery()
    #expect(transport.calls.isEmpty)
    model.preview = false; model.libraryReviewRequired = true; model.triggerDelivery()
    #expect(transport.calls.isEmpty && !model.canGenerateAudio)
    await model.shutdown()
}
