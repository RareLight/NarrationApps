import Foundation
import Testing
@testable import VoiceRelayCore
@testable import VoiceRelayApp

private final class RuntimeCheckProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@Test @MainActor func safariSourceDefaultsWithoutOverridingChosenOrIsolatedSources() async throws {
    let suite = "voicerelay-source-default-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = RuntimeCheckProbe()
    let fresh = SourceReviewModel(defaults: defaults, snapshotReader: { _ in
        _ = probe.next(); throw RelayError.storage("No source read was expected.")
    })
    #expect(fresh.plist == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist"))
    let chosen = URL(fileURLWithPath: "/synthetic/Alternate.plist")
    defaults.set(chosen.path, forKey: "readingListSource")
    let saved = SourceReviewModel(defaults: defaults, snapshotReader: { _ in
        _ = probe.next(); throw RelayError.storage("No source read was expected.")
    })
    #expect(saved.plist == chosen)
    #expect(SourceReviewModel(preview: true, defaults: defaults).plist == nil)
    #expect(SourceReviewModel(stateRoot: URL(fileURLWithPath: "/synthetic/state"), defaults: defaults).plist == nil)
    #expect(SourceReviewModel.preferredPlist(savedPath: " ", home: URL(fileURLWithPath: "/synthetic/home")).path == "/synthetic/home/Library/Safari/Bookmarks.plist")
    #expect(probe.calls == 0)
    await fresh.stop(); await saved.stop()
}

@Test @MainActor func readingListPickerStartsAtSafariOrTheSelectedSourceWithoutOpeningAWindow() {
    let model = SourceReviewModel(preview: true)
    let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
    #expect(model.sourcePickerURL == expected)
    #expect(model.sourcePickerURL.deletingLastPathComponent().path.hasSuffix("/Library/Safari"))
    #expect(model.sourcePickerURL.lastPathComponent == "Bookmarks.plist")
    let selected = URL(fileURLWithPath: "/synthetic/ReadingLists/Alternate.plist")
    model.plist = selected
    #expect(model.sourcePickerURL == selected)
    model.selectPlist() // Inert models never present a panel or read the file.
    #expect(model.plist == selected && !model.busy)
}

@Test @MainActor func runtimeControlsIgnoreBackgroundPublishingAndMetadataButBlockOwnedSpeech() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-runtime-controls-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "voicerelay-runtime-controls-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = RuntimeCheckProbe()
    let model = AppModel(storage: betaAppStorage(root, "state"), defaults: defaults, runtimeSetup: { _, _ in _ = probe.next() })
    model.debugLoggingEnabled = true
    #expect(model.runtimeTestResult == .untested && model.canManageSpeechRuntime)
    model.deliveryBusy = true; model.deliveryTesting = true; model.deliveryCredentialBusy = true
    model.sourceReview.busy = true; model.sourceReview.persistenceBusy = true
    model.pendingAdds = ["one": "Preparing"]
    model.queueMutationBusy = true; model.audioMutationBusy = true
    #expect(!model.canManageLibrary && model.canManageSpeechRuntime)
    model.checkSpeechRuntime()
    #expect(model.runtimeBusy && !model.canManageSpeechRuntime)
    model.checkSpeechRuntime() // A duplicate request must not start a second check.
    await model.waitForRuntimeSetup()
    #expect(probe.calls == 1 && model.runtimeTestResult == .success && !model.runtimeBusy)
    #expect(model.canManageSpeechRuntime)
    #expect(model.deliveryDebugLog.text.contains("speech runtime check: verified"))
    #expect(!model.deliveryDebugLog.text.contains(root.path))
    model.running = true; model.processingSpeech = true
    #expect(!model.canManageSpeechRuntime && model.runtimeControlDisabledReason?.contains("Stop audio") == true)
    model.installSpeechRuntime(); model.checkSpeechRuntime()
    #expect(probe.calls == 1)
    model.running = false; model.processingSpeech = false; model.cancelling = true
    #expect(!model.canManageSpeechRuntime)
    model.cancelling = false; model.libraryMaintenanceBusy = true
    #expect(!model.canManageSpeechRuntime)
    model.libraryMaintenanceBusy = false
    model.deliveryBusy = false; model.deliveryTesting = false; model.deliveryCredentialBusy = false
    model.sourceReview.busy = false; model.sourceReview.persistenceBusy = false
    model.pendingAdds = [:]; model.queueMutationBusy = false; model.audioMutationBusy = false
    await model.shutdown()
    #expect(!model.canManageSpeechRuntime && !FileManager.default.fileExists(atPath: root.path))
}

@Test @MainActor func runtimeVerificationFailureRetriesAndCancellationPreservesAvailability() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-runtime-result-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "voicerelay-runtime-result-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = RuntimeCheckProbe()
    let model = AppModel(storage: betaAppStorage(root, "state"), defaults: defaults, runtimeSetup: { _, _ in
        if probe.next() == 1 { throw RelayError.setup("Synthetic verification failure") }
    })
    model.checkSpeechRuntime(); await model.waitForRuntimeSetup()
    #expect(model.runtimeTestResult == .failure("Synthetic verification failure"))
    #expect(!model.speechRuntimeAvailable && model.canManageSpeechRuntime)
    _ = SpeechRuntimeTestIndicator(model: model).body
    model.checkSpeechRuntime(); await model.waitForRuntimeSetup()
    #expect(model.runtimeTestResult == .success && model.speechRuntimeAvailable)
    let cancelled = AppModel(storage: betaAppStorage(root, "other"), defaults: defaults, runtimeSetup: { _, _ in throw CancellationError() })
    cancelled.checkSpeechRuntime(); await cancelled.waitForRuntimeSetup()
    #expect(cancelled.runtimeTestResult == .cancelled && cancelled.speechRuntimeAvailable && cancelled.canManageSpeechRuntime)
    _ = SpeechRuntimeTestIndicator(model: cancelled).body
    await model.shutdown(); await cancelled.shutdown()
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

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
