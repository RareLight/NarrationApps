import Foundation
import Testing
@testable import VoiceRelayCore
@testable import VoiceRelayApp

private func betaAppStorage(_ root: URL, _ tag: String) -> ManagedSpeechStorage {
    ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("\(tag)-audio"),
        stateRoot: root.appendingPathComponent(tag), temporaryRoot: root.appendingPathComponent("\(tag)-scratch"), temporaryAudio: true)
}

@Test @MainActor func libraryBackupUIRoundTripDisablesAutomationAndPreservesPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-beta-app-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "voicerelay-beta-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = betaAppStorage(root, "source"), target = betaAppStorage(root, "target")
    let coordinator = FixtureCoordinator()
    let url = URL(string: "https://articles.example/one")!
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [ReadingListEntry(id: "one", safariID: nil,
        url: url, title: "Synthetic", addedAt: nil)], skippedEntries: 0), stateRoot: source.stateRoot)
    let item = try await coordinator.enqueueReadingList("one", storage: source, preferences: SpeechPreferences(), fetch: { _ in
        FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: Date())
    })
    let model = AppModel(storage: source, defaults: defaults)
    let backup = root.appendingPathComponent("library.voicerelaybackup")
    model.backUpLibrary(to: backup)
    #expect(model.libraryMaintenanceBusy && !model.canGenerateAudio && !model.canManageLibrary)
    await model.waitForLibraryMaintenance()
    #expect(model.libraryBackupError == nil && model.libraryBackupStatus?.contains("1 articles") == true)
    let restored = AppModel(storage: target, defaults: defaults)
    restored.preferences = SpeechPreferences(voice: .bella)
    restored.autoAdmitEnabled = true; restored.autoProcessEnabled = true
    defaults.set(true, forKey: "autoAdmitArticles"); defaults.set(true, forKey: "autoProcessArticles")
    restored.restoreLibrary(from: backup)
    await restored.waitForLibraryMaintenance(); await restored.waitForLibraryRefresh()
    #expect(restored.libraryBackupError == nil)
    #expect(restored.libraryReviewRequired && !restored.canGenerateAudio)
    #expect(!restored.autoAdmitEnabled && !restored.autoProcessEnabled && restored.autoHalted && !restored.deliverySettings.enabled)
    #expect(defaults.bool(forKey: "autoAdmitArticles") == false && defaults.bool(forKey: "autoProcessArticles") == false)
    #expect(restored.preferences.voice == .bella && restored.queueItems.map(\.id) == [item.id])
    await model.shutdown(); await restored.shutdown()
}

@Test @MainActor func restoredLibraryReviewSurvivesRelaunchAndBlocksOwnedLocalCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-beta-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "voicerelay-beta-review-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = betaAppStorage(root, "state")
    let database = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
    try Files.directory(storage.audioDirectory)
    var episode: Episode
    do {
        let store = try NativeStore(url: database)
        var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
        episode = try store.episode(sourceKey: "synthetic-cleanup", settings: profile)
        episode.stage = .expired; episode.manualAudioDeletionRequested = true
        episode.info = AudioInfo(duration: 1, byteLength: 4, sampleRate: 24_000, channels: 1, codec: "aac")
        episode.audioHash = Files.hash(Data("keep".utf8))
        try store.save(episode)
    }
    // Owned byte fixture for cleanup behavior; this is not speech or codec evidence.
    let audio = storage.audioDirectory.appendingPathComponent(episode.id + ".m4a")
    try Files.write(Data("keep".utf8), to: audio)
    let first = AppModel(storage: storage, defaults: defaults)
    first.libraryReviewRequired = true
    await first.shutdown()
    let relaunched = AppModel(storage: storage, defaults: defaults)
    #expect(relaunched.libraryReviewRequired)
    relaunched.refreshLibrary(); await relaunched.waitForLibraryRefresh()
    #expect(FileManager.default.fileExists(atPath: audio.path) && relaunched.audioCleanupError == nil)
    #expect(!relaunched.canDeleteSavedAudio && !relaunched.canGenerateAudio)
    relaunched.finishLibraryReview(); await relaunched.waitForLibraryRefresh()
    #expect(!relaunched.libraryReviewRequired && !defaults.bool(forKey: "libraryReviewRequired"))
    #expect(!relaunched.autoProcessEnabled && !relaunched.deliverySettings.enabled)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    await relaunched.shutdown()
}

@Test @MainActor func backupAndRuntimeControlsAreInertInPreviewsAndInjectedRuntimeModels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-beta-inert-\(UUID().uuidString)")
    let model = AppModel(preview: true, storage: betaAppStorage(root, "state"))
    model.backUpLibrary(to: root.appendingPathComponent("backup")); model.restoreLibrary(from: root.appendingPathComponent("backup"))
    model.installSpeechRuntime(); model.checkSpeechRuntime()
    #expect(!model.libraryMaintenanceBusy && !model.runtimeBusy && !FileManager.default.fileExists(atPath: root.path))
    let injected = AppModel(storage: betaAppStorage(root, "state"))
    injected.installSpeechRuntime(); injected.checkSpeechRuntime()
    #expect(!injected.runtimeBusy && !FileManager.default.fileExists(atPath: root.path))
    await injected.shutdown()
}

@Test @MainActor func libraryMaintenanceBlocksMutationControlsAndInvalidRestoreKeepsState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-beta-blocked-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "voicerelay-beta-blocked-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: betaAppStorage(root, "state"), defaults: defaults)
    model.queueItems = [SpeechQueueItem(id: UUID().uuidString, title: "Synthetic")]
    model.queueSelection = [.episode(model.queueItems[0].id)]
    model.libraryMaintenanceBusy = true
    #expect(!model.canGenerateAudio && !model.canResetQueue && !model.canRemoveQueueSelection && !model.canDeleteSavedAudio)
    model.removeSelectedQueueItems()
    #expect(model.queueItems.count == 1 && !model.queueMutationBusy)
    model.libraryMaintenanceBusy = false
    model.restoreLibrary(from: root.appendingPathComponent("missing"))
    await model.waitForLibraryMaintenance()
    #expect(model.libraryBackupError != nil && !FileManager.default.fileExists(atPath: root.path))
    await model.shutdown()
}
