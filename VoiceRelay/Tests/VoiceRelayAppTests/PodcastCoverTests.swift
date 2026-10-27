import AudioOutput
import Foundation
import Testing
@testable import VoiceRelayApp
@testable import VoiceRelayCore

private func authoredPodcastCover() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("icon/VoiceRelay_Cover.jpg")
}

private func podcastCoverStorage(_ root: URL) -> ManagedSpeechStorage {
    .init(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"),
        temporaryRoot: root.appendingPathComponent("scratch"))
}

@Test @MainActor func defaultPodcastCoverAdoptsAuthoredImageAndPersistsWithoutChangingOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-default-art-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = authoredPodcastCover(), original = try Data(contentsOf: source)
    let store = CoverArtworkStore(root: root.appendingPathComponent("art")), storage = podcastCoverStorage(root)
    let model = AppModel(storage: storage, podcastCoverStore: store, defaultPodcastCoverURL: source)
    #expect(model.deliverySettings.podcastCoverDigest == nil && !model.coverImporting) // inert init never imports
    model.prepareDefaultPodcastCover()
    #expect(model.coverImporting)
    model.prepareDefaultPodcastCover() // coalesces concurrent preparation
    await model.waitForPodcastCoverImport()
    let digest = try #require(model.deliverySettings.podcastCoverDigest), art = try store.load(digest)
    #expect(art.width == 1700 && art.height == 1700)
    #expect(model.deliverySettings.podcastCoverConfigured == true && model.podcastCoverError == nil)
    #expect(model.podcastCoverURL == (try store.url(for: digest)))
    #expect(try Data(contentsOf: source) == original)
    let saved = try JSONDecoder().decode(DeliverySettings.self, from: #require(model.defaults.data(forKey: "deliverySettings")))
    #expect(saved.podcastCoverDigest == digest)
    await model.shutdown()
    let relaunched = AppModel(storage: storage, defaults: model.defaults, podcastCoverStore: store,
        defaultPodcastCoverURL: URL(fileURLWithPath: "/missing/default.png"))
    relaunched.prepareDefaultPodcastCover()
    #expect(!relaunched.coverImporting && relaunched.deliverySettings.podcastCoverDigest == digest)
    #expect(relaunched.podcastCoverError == nil)
    await relaunched.shutdown()
}

@Test @MainActor func defaultPodcastCoverPreservesCustomChoiceAndExplicitRemovalAcrossRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-default-choice-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CoverArtworkStore(root: root.appendingPathComponent("art")), storage = podcastCoverStorage(root)
    let model = AppModel(storage: storage, podcastCoverStore: store, defaultPodcastCoverURL: authoredPodcastCover())
    let custom = String(repeating: "a", count: 64)
    model.deliverySettings.podcastCoverDigest = custom // legacy/custom selection without a configured flag
    model.prepareDefaultPodcastCover()
    #expect(!model.coverImporting && model.deliverySettings.podcastCoverDigest == custom)
    model.removePodcastCover()
    model.prepareDefaultPodcastCover()
    #expect(!model.coverImporting && model.deliverySettings.podcastCoverDigest == nil)
    await model.shutdown()
    let relaunched = AppModel(storage: storage, defaults: model.defaults, podcastCoverStore: store,
        defaultPodcastCoverURL: authoredPodcastCover())
    relaunched.prepareDefaultPodcastCover()
    #expect(!relaunched.coverImporting && relaunched.deliverySettings.podcastCoverConfigured == true)
    #expect(relaunched.deliverySettings.podcastCoverDigest == nil)
    // A user may still choose a cover after removing the default.
    relaunched.choosePodcastCover(authoredPodcastCover())
    await relaunched.waitForPodcastCoverImport()
    #expect(relaunched.deliverySettings.podcastCoverDigest != nil && relaunched.podcastCoverError == nil)
    await relaunched.shutdown()
}

@Test @MainActor func defaultPodcastCoverDoesNotRestoreArtRemovedDuringPreparationOrQuit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-default-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CoverArtworkStore(root: root.appendingPathComponent("art")), storage = podcastCoverStorage(root)
    let removed = AppModel(storage: storage, podcastCoverStore: store, defaultPodcastCoverURL: authoredPodcastCover())
    removed.prepareDefaultPodcastCover(); removed.removePodcastCover()
    await removed.waitForPodcastCoverImport()
    #expect(removed.deliverySettings.podcastCoverDigest == nil && removed.deliverySettings.podcastCoverConfigured == true)
    await removed.shutdown()
    let quitting = AppModel(storage: storage, podcastCoverStore: store, defaultPodcastCoverURL: authoredPodcastCover())
    quitting.prepareDefaultPodcastCover()
    await quitting.shutdown()
    #expect(!quitting.coverImporting && quitting.deliverySettings.podcastCoverDigest == nil)
    let preview = AppModel(preview: true, podcastCoverStore: store, defaultPodcastCoverURL: authoredPodcastCover())
    preview.prepareDefaultPodcastCover()
    #expect(!preview.coverImporting && preview.deliverySettings.podcastCoverDigest == nil)
    await preview.shutdown()
}

@Test @MainActor func defaultPodcastCoverFailureKeepsChoiceUnsetForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-default-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CoverArtworkStore(root: root.appendingPathComponent("art"))
    let model = AppModel(storage: podcastCoverStorage(root), podcastCoverStore: store,
        defaultPodcastCoverURL: root.appendingPathComponent("missing.png"))
    model.prepareDefaultPodcastCover()
    await model.waitForPodcastCoverImport()
    #expect(model.podcastCoverError != nil && !model.coverImporting)
    #expect(model.deliverySettings.podcastCoverDigest == nil && model.deliverySettings.podcastCoverConfigured == nil)
    await model.shutdown()
}

@Test @MainActor func defaultPodcastCoverNeverOverwritesUnreadablePublishingPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-default-preferences-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "voicerelay-default-preferences-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let unreadable = Data("not valid settings JSON".utf8)
    defaults.set(unreadable, forKey: "deliverySettings")
    let model = AppModel(storage: podcastCoverStorage(root), defaults: defaults,
        podcastCoverStore: CoverArtworkStore(root: root.appendingPathComponent("art")), defaultPodcastCoverURL: authoredPodcastCover())
    model.prepareDefaultPodcastCover()
    #expect(model.error != nil && !model.coverImporting)
    #expect(defaults.data(forKey: "deliverySettings") == unreadable)
    await model.shutdown()
}
