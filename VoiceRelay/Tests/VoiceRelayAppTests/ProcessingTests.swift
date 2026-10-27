import AppPresentation
import AppKit
import SwiftUI
import Foundation
import AudioOutput
import Testing
@testable import VoiceRelayCore
@testable import VoiceRelayApp

private func isolatedStorage() throws -> (URL, ManagedSpeechStorage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-lifecycle-\(UUID())")
    let audio = root.appendingPathComponent("audio")
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    return (root, ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"),
                                       temporaryRoot: root.appendingPathComponent("scratch")))
}
private func article(_ path: String = "article") throws -> ReviewedSource {
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self), url = URL(string: "https://synthetic.example/\(path)")!
    return try ReviewedSource.prepare(FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
        contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
}

private struct SyntheticProvider: TTSBackend {
    let identity = BackendIdentity(id: "app-lifecycle-test", displayName: "Synthetic lifecycle audio", isMock: false)
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        let wav = directory.appendingPathComponent("synthetic.wav")
        let writer = try AtomicAudioWriter(destination: wav)
        try writer.append(samples: (0..<6000).map { Float(sin(2 * Double.pi * 300 * Double($0) / 24_000) * 0.1) }, sampleRate: 24_000)
        try writer.publish()
        return SynthesisResult(artifacts: [LosslessArtifact(url: wav, sampleRate: 24000, channels: 1, format: "wav")])
    }
}

@Test @MainActor func completedArticleLeavesVisibleQueueAndSurvivesLaterFailure() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { episode in
        if episode.id == second.id { throw RelayError.artifact("Synthetic second-article failure") }
        return SyntheticProvider()
    })
    model.queueItems = [first, second]
    #expect(model.canGenerateAudio && !model.libraryReviewRequired)
    model.runQueue(); await model.waitForProcessing()
    #expect(model.result?.episode.id == first.id && model.result?.localFeedCurrent == true)
    #expect(!model.running && model.batchProgress == nil && model.error != nil)
    let deadline = Date().addingTimeInterval(3)
    while model.queueItems.contains(where: { $0.id == first.id }) && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.queueItems.map(\.id) == [second.id])
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.state) == [.failed])
    #expect(try await coordinator.library(storage: storage).contains(where: { $0.id == first.id && $0.stage == .published }))
}
private final class CancellableProvider: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "cancel-test", displayName: "Inert lifecycle test", isMock: false)
    private let lock = NSLock()
    private var prepared = false
    private var completed = false
    private var cleanupAllowed: Bool
    init(holdCleanup: Bool = false) { cleanupAllowed = !holdCleanup }
    var started: Bool { lock.withLock { prepared } }
    var finished: Bool { lock.withLock { completed } }
    func allowCleanup() { lock.withLock { cleanupAllowed = true } }
    func prepare() throws {
        defer { lock.withLock { completed = true } }
        lock.withLock { prepared = true }
        let deadline = Date().addingTimeInterval(5)
        while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        // Keep cleanup observable: a replacement operation must not start before this returns.
        Thread.sleep(forTimeInterval: 0.1)
        let cleanupDeadline = Date().addingTimeInterval(5)
        while !lock.withLock({ cleanupAllowed }) && Date() < cleanupDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try Task.checkCancellation()
        throw RelayError.artifact("Synthetic timeout")
    }
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult { throw RelayError.artifact("Unexpected inference") }
    func cancel() {}
}

@Test @MainActor func cancelClearsStaleProgressEvenWhenNoWorkerExists() throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: storage)
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 25, completedArticles: 0, totalArticles: 2)
    model.error = "Cannot read artifact"; model.running = true
    model.cancel()
    #expect(model.batchProgress == nil && model.progress == nil && model.error == nil)
    #expect(!model.running && !model.cancelling)
}

@Test @MainActor func cancellingWaitsForOwnedWorkerAndRetainsQueueWithoutLateProgress() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator(), provider = CancellableProvider()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in provider })
    model.refreshLibrary() // Race an in-flight library refresh with generation/cancellation.
    model.queueItems = [item]; model.runQueue()
    let deadline = Date().addingTimeInterval(5)
    while !provider.started && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(provider.started)
    model.cancel()
    #expect(model.running && model.cancelling && model.batchProgress == nil)
    model.runQueue() // A new run must not take ownership while cleanup is pending.
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    // Allow callbacks queued before cancellation to arrive.
    try await Task.sleep(for: .milliseconds(30))
    #expect(!model.running && !model.cancelling && model.progress == nil && model.batchProgress == nil)
    #expect(model.error == nil && model.status.contains("Cancelled"))
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.count == 1 && queue.first?.state == .paused && queue.first?.attempts == 1)
    #expect(model.queueItems.map(\.state) == [.paused])
}

@Test @MainActor func failedGenerationClearsProgressAndAllowsExplicitRetry() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in throw RelayError.artifact("Synthetic read failure") })
    model.queueItems = [item]; model.runQueue(); await model.waitForProcessing()
    #expect(!model.running && model.batchProgress == nil && model.progress == nil && model.error != nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .failed)
    model.cancel()
    #expect(model.error == nil && !model.running)
    model.changeQueue(item.id, remove: false); await model.waitForProcessing()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .queued)
    model.runQueue(); await model.waitForProcessing()
    #expect(!model.running && model.batchProgress == nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.attempts == 2)
}

@Test @MainActor func libraryRefreshNeverAppliesLegacyScheduledRetention() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("oneDay", forKey: "audioRetention")
    let coordinator = FixtureCoordinator()
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: article(), backend: SyntheticProvider(), storage: storage)
    let model = AppModel(storage: storage, defaults: defaults)
    model.result = result
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: result.audioURL.path)
    model.refreshLibrary(); await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.map(\.id) == [result.episode.id])
    #expect(model.result != nil && model.audioCleanupError == nil)
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    await model.shutdown()
}

@Test @MainActor func queueResetIsExplicitAndPreservesSourceAndAudio() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let preview = AppModel(preview: true)
    preview.queueItems = [SpeechQueueItem(id: UUID().uuidString.lowercased(), title: "Synthetic")]
    #expect(!preview.canResetQueue)
    let idle = AppModel(storage: storage)
    #expect(!idle.canResetQueue)
    let entry = ReadingListEntry(id: "one", safariID: nil, url: try article().page.originalURL, title: "One", addedAt: nil)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let published = try await coordinator.runReviewed(root: storage.stateRoot, review: article("published"), backend: SyntheticProvider(), storage: storage)
    let plist = root.appendingPathComponent("reading-list.plist")
    try Files.write(try PropertyListSerialization.data(fromPropertyList: ["reading-list": ["entry"]], format: .binary, options: 0), to: plist)
    let plistBytes = try Data(contentsOf: plist)
    let catalogBytes = String(decoding: try Files.json(try await coordinator.catalog(stateRoot: storage.stateRoot)), as: UTF8.self)
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    model.queueItems = [item]
    #expect(model.canResetQueue)
    model.running = true
    #expect(!model.canResetQueue)
    model.resetQueue()
    #expect(model.queueItems == [item])
    model.running = false
    model.cancelling = true
    #expect(!model.canResetQueue)
    model.cancelling = false
    model.resetQueue()
    await model.waitForProcessing()
    #expect(!model.running && model.error == nil && model.status.contains("Queue cleared"))
    #expect(model.queueItems.isEmpty)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(String(decoding: try Files.json(try await coordinator.catalog(stateRoot: storage.stateRoot)), as: UTF8.self) == catalogBytes)
    #expect(try Data(contentsOf: plist) == plistBytes)
    #expect(FileManager.default.fileExists(atPath: published.audioURL.path))
    #expect(model.result == nil && model.progress == nil && model.batchProgress == nil)
    await model.shutdown()
    #expect(model.stopping && !model.canResetQueue)
}

@Test @MainActor func audioCleanupWarningPreservesSpecificReconcileFailure() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.runReviewed(root: storage.stateRoot, review: article(), backend: SyntheticProvider(), storage: storage)
    let second = try await coordinator.runReviewed(root: storage.stateRoot, review: article("second"), backend: SyntheticProvider(), storage: storage)
    try FileManager.default.removeItem(at: first.audioURL)
    var unavailable = second.episode
    unavailable.audioVolumeID = "00000000-0000-0000-0000-000000000000"
    try { () throws in
        let store = try NativeStore(url: storage.profile.database)
        try store.save(unavailable)
    }()
    try FileManager.default.removeItem(at: first.feedURL)
    try Files.directory(first.feedURL)
    defer { try? FileManager.default.removeItem(at: first.feedURL) }
    let model = AppModel(storage: storage)
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.isEmpty)
    #expect(model.audioCleanupError != nil)
    #expect(model.audioCleanupError != "Some saved audio is unavailable. Reconnect its original storage or restore access.")
}

@Test @MainActor func appShutdownWaitsForOwnedWorkAndPreservesQueue() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator(), provider = CancellableProvider(holdCleanup: true)
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in provider })
    model.queueItems = [item]; model.runQueue()
    let deadline = Date().addingTimeInterval(5)
    while !provider.started && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(provider.started && model.running)
    let stopping = Task { await model.shutdown() }
    defer { provider.allowCleanup() }
    for _ in 0..<200 {
        if model.stopping { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.stopping && model.running && !provider.finished)
    model.runQueue()
    model.changeQueue(item.id, remove: false)
    model.sourceReview.preview = false
    model.sourceReview.requestSourceSync()
    #expect(!model.sourceReview.busy)
    provider.allowCleanup()
    await stopping.value
    #expect(provider.finished && !model.running && !model.cancelling)
    #expect(model.progress == nil && model.batchProgress == nil)
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.count == 1 && queue.first?.state == .paused && queue.first?.attempts == 1)
    let relaunched = AppModel(storage: storage)
    #expect(!relaunched.running && !relaunched.stopping)
    relaunched.changeQueue(item.id, remove: false)
    await relaunched.waitForProcessing()
    #expect(!relaunched.running)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .queued)
    await relaunched.shutdown()
}

@Test @MainActor func appShutdownRefusesNewWorkAndIsIdempotent() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator(), provider = CancellableProvider()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in provider })
    model.queueItems = [item]
    await model.shutdown()
    await model.shutdown()
    #expect(model.stopping)
    model.runQueue()
    model.changeQueue(item.id, remove: false)
    model.refreshLibrary()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(!provider.started && !model.running)
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.count == 1 && queue.first?.state == .queued && queue.first?.attempts == 0)
    let review = SourceReviewModel(preview: true)
    await review.stop()
    await review.stop()
    #expect(!review.busy && !review.maintenanceSuspended)
    let idle = AppModel(storage: storage)
    await idle.shutdown()
    #expect(idle.stopping && !idle.running)
}

@Test @MainActor func settingsSectionsAreDistinctAndInertViewsConstruct() throws {
    #expect(SettingsSection.allCases == [.general, .pronunciation, .delivery, .troubleshooting])
    #expect(Set(SettingsSection.allCases.map(\.rawValue)) == ["General", "Pronunciation", "Publishing", "Troubleshooting"])
    let model = AppModel(preview: true)
    let general = SettingsView(model: model)
    let troubleshooting = SettingsView(model: model, initialSection: .troubleshooting)
    _ = general; _ = troubleshooting
    #expect(model.pronunciationIsInert && model.pronunciationConfiguration == nil)
    _ = SettingsView(model: model, initialSection: .pronunciation)
    #expect(!model.running && !model.stopping)
}

@Test @MainActor func regionalVoiceSettingsPersistAndConstructWithoutStartingWork() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, defaults: defaults)
    #expect(model.preferences.languageRegion == .usEnglish)
    #expect(model.preferences.timedTranscriptsEnabled)
    model.preferences.timedTranscriptsEnabled = false
    model.preferences.languageRegion = .ukEnglish
    #expect(model.preferences.voice == .emma)
    model.preferences.voice = .fable
    let data = try #require(defaults.data(forKey: "speechPreferences"))
    let saved = try JSONDecoder().decode(SpeechPreferences.self, from: data)
    #expect(saved.voice == .fable && saved.languageRegion == .ukEnglish)
    #expect(!saved.timedTranscriptsEnabled)
    _ = ConfigurationView(model: model).body
    #expect(!model.running && model.result == nil && !model.deliveryBusy)
    let previewDefaults = try #require(UserDefaults(suiteName: suite + "-preview"))
    defer { previewDefaults.removePersistentDomain(forName: suite + "-preview") }
    let preview = AppModel(preview: true, defaults: previewDefaults)
    preview.preferences = SpeechPreferences(voice: .george)
    _ = ConfigurationView(model: preview).body
    #expect(previewDefaults.data(forKey: "speechPreferences") == nil)
    await model.shutdown()
}

@Test @MainActor func settingsPanesShareFixedGlassControlLayout() async throws {
    #expect(SettingsView.windowWidth == 440 && SettingsView.windowHeight == 680)
    #expect(SettingsNavigation<SettingsSection>.idealWidth == 392)
    #expect(SettingsSection.allCases.map(\.systemImage) == ["gearshape", "text.word.spacing", "antenna.radiowaves.left.and.right", "stethoscope"])
    let model = AppModel(preview: true)
    _ = SettingsView(model: model)
    _ = SettingsView(model: model, initialSection: .troubleshooting)
    for section in SettingsSection.allCases {
        _ = SettingsNavigation(selection: .constant(section)).body
    }
    await model.waitForProcessing()
    #expect(!model.running && !model.stopping && model.progress == nil && model.batchProgress == nil)
}

@Test @MainActor func troubleshootingKeepsBackupAndDiagnosticsWithoutReadingListControls() throws {
    let model = AppModel(preview: true)
    let entries = ["one", "two"].map {
        ReadingListEntry(id: $0, safariID: $0, url: URL(string: "https://articles.example/\($0)")!,
                         title: "Synthetic \($0)", addedAt: nil)
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.sourceReview.error = "Synthetic file-access failure; previous entries retained."
    _ = TroubleshootingView(model: model).body
    _ = ConfigurationView(model: model).body
    #expect(model.sourceReview.catalog.entries.count == 2 && !model.sourceReview.busy && !model.sourceReview.maintenanceSuspended)
    #expect(!model.libraryMaintenanceBusy && !model.runtimeBusy)
}

@Test @MainActor func articlesSelectionFollowsNewestFirstDisplayOrder() {
    let model = AppModel(preview: true)
    let entries = ["oldest", "middle", "newest"].enumerated().map { index, id in
        ReadingListEntry(id: id, safariID: id, url: URL(string: "https://articles.example/\(id)")!,
                         title: id, addedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.articleSelection = Set(entries.map(\.id))
    #expect(model.selectedArticles.map(\.id) == ["newest", "middle", "oldest"])
    model.articleSelection = ["oldest", "newest"]
    #expect(model.selectedArticles.map(\.id) == ["newest", "oldest"])
    _ = ArticlesView(model: model).body
    #expect(model.sourceReview.catalog.entries == entries && !model.running)
}

@Test @MainActor func workspaceSectionsAndNativeViewsConstructInertly() async throws {
    #expect(WorkspaceSection.allCases == [.articles, .uploads, .savedAudio])
    #expect(Set(WorkspaceSection.allCases.map(\.rawValue)) == ["Articles", "Uploads", "Server Audio"])
    let model = AppModel(preview: true)
    for section in WorkspaceSection.allCases {
        model.workspaceSection = section
        _ = WorkspaceView(model: model)
        _ = RelayMenu(model: model).body
    }
    model.libraryReviewRequired = true // Construct the clickable failure/status branch inertly.
    _ = RelayMenu(model: model).body
    model.syncBusy = true; model.syncPhase = .reconciling
    _ = RelayMenu(model: model).body
    _ = SyncMenuProgress(model: model).body
    let reference = MenuPopoverWindowReference()
    reference.dismiss() // An unattached/inert menu must not touch other app windows.
    #expect(reference.window == nil)
    await model.waitForProcessing()
    #expect(!model.running && !model.stopping)
}

@Test @MainActor func statusItemButtonAcceptsBothMouseReleasesThroughOneActionWithoutInstallingUI() throws {
    var contentRequests = 0
    let host = StatusItemPopoverHost { contentRequests += 1; return AnyView(EmptyView()) }
    let button = NSStatusBarButton(frame: .zero)
    host.configure(button)
    let configuredEvents = NSEvent.EventTypeMask(rawValue: UInt64(button.sendAction(on: [])))
    #expect(configuredEvents.contains(.leftMouseUp) && configuredEvents.contains(.rightMouseUp))
    #expect(!configuredEvents.contains(.leftMouseDown) && !configuredEvents.contains(.rightMouseDown))
    #expect(button.target === host && button.action != nil)
    #expect(button.image?.isTemplate == true && button.toolTip == "VoiceRelay")
    let originalImage = try #require(NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil))
    let enlargedImage = try #require(button.image)
    let originalRaster = try #require(originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let enlargedRaster = try #require(enlargedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(enlargedImage.size.height >= originalImage.size.height * 1.9)
    #expect(Double(enlargedRaster.width) >= Double(originalRaster.width) * 1.9)
    #expect(button.symbolConfiguration != nil && button.imageScaling == .scaleProportionallyDown)
    button.sendAction(on: configuredEvents)
    button.performClick(nil) // No status item was installed; must not create or show a popover.
    host.stop(); host.stop()
    #expect(contentRequests == 0)
}

@Test @MainActor func statusItemHostIsNotInstalledForInertAppModels() async {
    let delegate = VoiceRelayApplicationDelegate()
    let model = AppModel(preview: true)
    delegate.model = model
    var contentRequests = 0
    delegate.installMenu { contentRequests += 1; return AnyView(EmptyView()) }
    await Task.yield()
    delegate.dismissMenu()
    #expect(contentRequests == 0)
    await model.shutdown()
}

@Test @MainActor func statusItemClosingLastWindowKeepsBackgroundAppAlive() {
    let delegate = VoiceRelayApplicationDelegate()
    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}

@Test(arguments: [80, 100, 200]) @MainActor
func statusItemMenuFitsCommandsAndKeepsWidthDuringSync(percent: Int) async {
    let model = AppModel(preview: true)
    let textSize = AppTextSize(percent: percent)
    func measure() -> CGSize {
        let controller = NSHostingController(rootView: RelayMenu(model: model)
            .appTextSizing(textSize).environment(\.dynamicTypeSize, .large))
        // Measure unattached content only: no status item, window, or services.
        return controller.sizeThatFits(in: CGSize(width: 1000, height: 2000))
    }
    let idle = measure()
    let initialHealth = model.appHealth.title
    let fontSize = AppTypography.pointSize(base: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                           size: textSize, dynamic: .large)
    let titleWidth = ("Copy Podcast URL" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
    #expect(idle.width >= titleWidth)
    #expect(idle.width < 280 * max(1, CGFloat(percent) / 100) * 0.8)
    #expect(idle.height > 0)
    model.syncBusy = true
    for phase in [SyncPhase.preparing, .reconciling, .generating, .publishing] {
        model.syncPhase = phase
        let busy = measure()
        #expect(abs(busy.width - idle.width) < 1)
        #expect(busy.height > 0 && busy.height < 2000)
    }
    model.processingSpeech = true
    model.progress = PipelineProgress(stage: .published, completedChunks: 1, totalChunks: 3)
    model.syncPhase = .generating
    #expect(model.syncProgressFraction != nil)
    #expect(abs(measure().width - idle.width) < 1)
    model.libraryReviewRequired = true // Changing status must not widen the menu.
    #expect(model.appHealth.title != initialHealth)
    #expect(abs(measure().width - idle.width) < 1)
    await model.shutdown()
}

@Test(arguments: [100.0, 200.0]) @MainActor
func statusItemMenuAddsTwentyFivePercentToContentWidth(width: Double) {
    let controller = NSHostingController(rootView: PopoverMenuLayout {
        Color.clear.frame(width: width, height: 20)
            .layoutValue(key: PopoverMenuLayout.WidthSource.self, value: true)
    }.padding(PopoverMenuLayout.outerPadding))
    let size = controller.sizeThatFits(in: CGSize(width: 1000, height: 1000))
    #expect(abs(size.width - (width == 100 ? 140 : 265)) < 1)
}

@Test @MainActor func statusItemCopyPodcastURLUsesConfiguredPublicFeedWithoutChangingSettings() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: storage)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Keep clipboard unchanged", forType: .string)
    #expect(model.deliverySubscriptionURL == nil)
    model.copyDeliverySubscriptionURL(to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "Keep clipboard unchanged")
    model.deliverySettings.publicFolderURL = URL(string: "https://synthetic.example/My%20Podcast/")!
    let settings = model.deliverySettings
    model.copyDeliverySubscriptionURL(to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "https://synthetic.example/My%20Podcast/feed.xml")
    #expect(model.deliverySettings == settings && !model.syncBusy && !model.deliveryBusy)
    await model.shutdown()
    let preview = AppModel(preview: true)
    preview.deliverySettings.publicFolderURL = settings.publicFolderURL
    pasteboard.clearContents(); pasteboard.setString("Preview is inert", forType: .string)
    preview.copyDeliverySubscriptionURL(to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "Preview is inert")
    await preview.shutdown()
}

@Test @MainActor func generationActionsReflectReadyRunningCancellingAndStopping() async throws {
    let preview = AppModel(preview: true)
    preview.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "Synthetic", state: .queued)]
    #expect(preview.readyQueueCount == 1 && !preview.canGenerateAudio && !preview.canStopProcessing)
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    model.queueItems = [item]
    #expect(model.readyQueueCount == 1 && model.canGenerateAudio && !model.canStopProcessing)
    model.running = true
    #expect(!model.canGenerateAudio && !model.canStopProcessing)
    model.processingSpeech = true
    #expect(model.canStopProcessing)
    model.cancelling = true
    #expect(!model.canStopProcessing)
    model.cancelling = false; model.running = false; model.processingSpeech = false
    await model.shutdown()
    #expect(!model.canGenerateAudio && !model.canStopProcessing && model.stopping)
}

@Test @MainActor func workspaceErrorDoesNotRepeatQueueRowButKeepsDistinctGlobalFailures() throws {
    let model = AppModel(preview: true)
    model.workspaceSection = .articles; model.articleScope = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "Synthetic", state: .failed, lastError: "Synthetic feed failure")]
    model.error = "Synthetic feed failure"
    #expect(model.workspaceError == nil)
    model.error = "A different failure needs attention."
    #expect(model.workspaceError == "A different failure needs attention.")
    model.workspaceSection = .savedAudio
    model.error = "Synthetic feed failure"
    #expect(model.workspaceError == "Synthetic feed failure")
    model.error = nil
    #expect(model.workspaceError == nil)
}

@Test @MainActor func appQueueUsesCapturedSettingsAndPreservesQueueRecovery() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences(voice: .bella, speed: 0.9))
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    model.queueItems = [item]
    model.preferences = SpeechPreferences(voice: .heart, speed: 1.0)
    model.runQueue()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(model.result?.episode.id == item.id && model.result?.episode.stage == .published)
    #expect(model.result?.episode.settings.voice == SpeechVoice.bella.rawValue)
    #expect(model.result?.episode.settings.backendSettings["speed"]?.numericValue == 0.9)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(!model.running && model.progress == nil && model.batchProgress == nil)
}

@Test @MainActor func successfulQueueRunClearsTransientProgressButPreservesSavedAudio() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    model.queueItems = [first, second]
    model.runQueue()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(!model.running && !model.cancelling)
    #expect(model.progress == nil && model.batchProgress == nil)
    #expect(model.error == nil && model.status == "Finished 2 articles")
    #expect(model.result?.episode.id == second.id && model.result?.episode.stage == .published)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty && model.queueItems.isEmpty)
    #expect(model.savedEpisodes.map(\.id).sorted() == [first.id, second.id].sorted())
    for episode in model.savedEpisodes {
        #expect(FileManager.default.fileExists(atPath: episode.settings.audio.appendingPathComponent(episode.id + ".m4a").path))
    }
    let finishedID = model.result?.episode.id
    for section in WorkspaceSection.allCases {
        model.workspaceSection = section
        _ = WorkspaceView(model: model)
        #expect(model.progress == nil && model.batchProgress == nil)
    }
    #expect(!model.showsProcessingProgress)
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.progress == nil && model.batchProgress == nil)
    #expect(model.result?.episode.id == finishedID)
}

@Test @MainActor func processingSummaryOnlyAppearsDuringOwnedWork() throws {
    let model = AppModel(preview: true)
    model.progress = PipelineProgress(stage: .published, completedChunks: 3, totalChunks: 3)
    #expect(!model.showsProcessingProgress && model.processingFraction == nil)
    _ = ProcessingSummary(model: model).body
    model.running = true
    #expect(!model.showsProcessingProgress)
    model.processingSpeech = true
    #expect(model.showsProcessingProgress && model.processingFraction == 1)
    _ = ProcessingSummary(model: model).body
    model.cancelling = true
    #expect(model.showsProcessingProgress)
    model.running = false; model.processingSpeech = false
    #expect(model.showsProcessingProgress)
    model.cancelling = false
    #expect(!model.showsProcessingProgress)
}

@Test @MainActor func processingPresentationKeepsFinishingBelowCompleteAndReportsWaitingWork() {
    let model = AppModel(preview: true)
    model.running = true; model.processingSpeech = true
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 1000, totalChunks: 1000,
                                             completedArticles: 0, totalArticles: 1, currentArticleIndex: 1)
    #expect(model.processingFraction != nil && model.processingFraction! < 1)
    #expect(model.processingStatusLine.contains("99%") && !model.processingStatusLine.contains("100%"))
    model.batchProgress = QueueBatchProgress(stage: .published, completedChunks: 1000, totalChunks: 1000,
                                             completedArticles: 1, totalArticles: 1, currentArticleIndex: 1)
    #expect(model.processingFraction == 1 && model.processingStatusLine.contains("100%"))
    model.batchProgress = nil
    model.progress = PipelineProgress(stage: .encoding, completedChunks: 3, totalChunks: 3)
    #expect(model.processingFraction == 0.75)
    #expect(model.processingStatusLine.contains("75%") && model.processingStatusLine.contains("Finishing audio"))
    model.progress = PipelineProgress(stage: .published, completedChunks: 0, totalChunks: 3)
    #expect(model.processingFraction == 0)
    #expect(model.processingStatusLine.contains("Checking saved audio") && !model.processingStatusLine.contains("100%"))
    model.progress = PipelineProgress(stage: .published, completedChunks: 3, totalChunks: 3)
    #expect(model.processingFraction == 1 && model.processingStatusLine.contains("100%"))
    model.progress = nil
    model.status = "Preparing selected articles…"
    #expect(model.processingFraction == nil && model.processingStatusLine.contains("Preparing selected articles"))
    model.cancelling = true
    #expect(model.processingStatusLine == "Stopping…")
}

@Test @MainActor func backgroundAddToQueueReturnsImmediatelyAndConvertsPendingRows() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try article("one")
    let one = ReadingListEntry(id: "one", safariID: nil, url: review.page.originalURL, title: "One", addedAt: nil)
    let two = ReadingListEntry(id: "two", safariID: nil, url: URL(string: "https://synthetic.example/two")!, title: "Two", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [one, two], skippedEntries: 0), stateRoot: storage.stateRoot)
    // Saved text for the first entry lets the add resolve offline without a fetch.
    let queued = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: one.id)
    try await coordinator.removeFromQueue(queued.id, stateRoot: storage.stateRoot)
    final class FetchCounter: @unchecked Sendable { var count = 0 }
    let counter = FetchCounter()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { _ in
        counter.count += 1; throw SourceFetchError.network
    })
    model.sourceReview.catalog = catalog
    model.articleSelection = [one.id, two.id]
    model.addSelectedToQueue()
    #expect(model.articleSelection.isEmpty && model.pendingAdds.count == 2 && !model.running)
    await model.waitForEnqueue()
    // Both entries were attempted: one committed, one became a collected issue.
    #expect(model.pendingAdds.isEmpty && counter.count == 1)
    #expect(model.queueItems.map(\.id) == [queued.id])
    #expect(model.enqueueIssues.count == 1 && model.enqueueIssues.first?.contains("Two") == true)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [queued.id])
    model.articleSelection = [one.id]
    // Unified Articles omits sources already in Queue. A disabled/no-op Add must
    // not clear an unrelated entry's collected issue or create duplicate work.
    #expect(!model.canAddSelectedArticles && model.eligibleSelectedArticles.isEmpty)
    model.addSelectedToQueue()
    #expect(model.enqueueIssues.count == 1)
    await model.waitForEnqueue()
    #expect(model.enqueueIssues.count == 1 && counter.count == 1 && model.queueItems.count == 1 && !model.running)
    await model.shutdown()
    #expect(model.pendingAdds.isEmpty)
}

@Test @MainActor func articlePreviewWindowAndQueuePendingRowsConstructInertly() async throws {
    let model = AppModel(preview: true)
    model.pendingAdds = ["one": "Synthetic article one"]
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "Synthetic queued article")]
    _ = ArticlesView(model: model)
    let url = URL(string: "https://articles.example/synthetic")!
    _ = ArticlePreviewView(url: url, inert: true)
    _ = RelayMenu(model: model)
    await model.waitForEnqueue()
    #expect(model.pendingAdds.count == 1 && !model.running)
}

private final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var enteredCount = 0
    var entered: Bool { lock.withLock { enteredCount > 0 } }
    var fetchCount: Int { lock.withLock { enteredCount } }
    func openGate() { lock.withLock { open = true } }
    func wait(for url: URL) async throws -> FetchedPage {
        lock.withLock { enteredCount += 1 }
        let deadline = Date().addingTimeInterval(10)
        while !lock.withLock({ open }) && !Task.isCancelled && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
        return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
                           contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    }
}

private final class GateProvider: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "app-gate-test", displayName: "Gated synthetic audio", isMock: false)
    private let lock = NSLock()
    private var gateOpen = false
    private var entered = false
    private var completed = false
    var synthesizeEntered: Bool { lock.withLock { entered } }
    var finished: Bool { lock.withLock { completed } }
    func openGate() { lock.withLock { gateOpen = true } }
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        lock.withLock { entered = true }
        let deadline = Date().addingTimeInterval(10)
        while !lock.withLock({ gateOpen }) && !Task.isCancelled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try Task.checkCancellation()
        defer { lock.withLock { completed = true } }
        return try SyntheticProvider().synthesize(request, directory: directory)
    }
}

private func awaitMainActor(_ deadline: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if await MainActor.run(body: condition) { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await MainActor.run(body: condition)
}

@Test @MainActor func drainCommitsPendingAddsWhileSpeechIsBlocked() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let one = try article("one"), two = try article("two")
    let entries = [one, two].enumerated().map { index, review in
        ReadingListEntry(id: "entry-\(index)", safariID: nil, url: review.page.originalURL, title: "Entry \(index)", addedAt: nil)
    }
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(one, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entries[0].id)
    let fetchGate = FetchGate()
    let provider = GateProvider()
    let model = AppModel(storage: storage, backend: { episode -> any TTSBackend in
        episode.id == item.id ? provider : SyntheticProvider()
    }, enqueueFetch: { url in try await fetchGate.wait(for: url) })
    model.sourceReview.catalog = catalog
    model.queueItems = [item]
    model.runQueue()
    #expect(try await awaitMainActor { provider.synthesizeEntered })
    model.articleSelection = [entries[1].id]
    model.addSelectedToQueue()
    #expect(model.pendingAdds.count == 1)
    fetchGate.openGate()
    await model.waitForEnqueue()
    #expect(!provider.finished)
    let midQueue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(midQueue.count == 2 && midQueue.last?.state == .queued)
    provider.openGate()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(model.savedEpisodes.count == 2 && !model.running && !model.processingSpeech)
}

@Test @MainActor func stopAbandonsActiveWorkRestoresReadyAndReturnsGenerate() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("two"), storage: storage, preferences: SpeechPreferences())
    let provider = GateProvider()
    let model = AppModel(storage: storage, backend: { episode -> any TTSBackend in
        episode.id == second.id ? provider : SyntheticProvider()
    })
    model.queueItems = [first, second]
    model.runQueue()
    #expect(try await awaitMainActor { provider.synthesizeEntered })
    model.stopQueue()
    #expect(!model.canStopProcessing && model.cancelling)
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(!model.running && !model.processingSpeech && !model.cancelling)
    #expect(model.progress == nil && model.batchProgress == nil)
    #expect(model.status.contains("Stopped"))
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == [second.id] && queue.first?.state == .queued && queue.first?.lastError == nil)
    #expect(try await coordinator.library(storage: storage).first(where: { $0.id == first.id })?.stage == .published)
    #expect(FileManager.default.fileExists(atPath: storage.audioDirectory.appendingPathComponent(first.id + ".m4a").path))
    #expect(!FileManager.default.fileExists(atPath: storage.profile.work.appendingPathComponent(second.id).path))
    #expect(model.canGenerateAudio)
    provider.openGate()
    model.runQueue()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(model.result?.episode.id == second.id && model.savedEpisodes.count == 2)
}

@Test @MainActor func selectionRemovalCoversReadyFailedAndPreparingRowsWithoutDialogs() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try article("one")
    let entry = ReadingListEntry(id: "entry-one", safariID: nil, url: review.page.originalURL, title: "Entry", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let ready = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    let failed = try await coordinator.enqueue(article("two"), storage: storage, preferences: SpeechPreferences())
    var failedRow = failed; failedRow.state = .failed; failedRow.lastError = "Synthetic failure"
    do { try NativeStore(url: storage.profile.database).saveQueueItem(failedRow) }
    let gate = FetchGate()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() },
                         enqueueFetch: { url in try await gate.wait(for: url) })
    model.sourceReview.catalog = catalog
    model.queueItems = [ready, failedRow]
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    #expect(model.pendingAdds.count == 1)
    model.queueSelection = [.episode(ready.id), .episode(failed.id), .preparation(entry.id)]
    #expect(model.canRemoveQueueSelection)
    model.removeSelectedQueueItems()
    await model.waitForProcessing()
    #expect(model.queueItems.isEmpty && model.pendingAdds.isEmpty && model.queueSelection.isEmpty)
    gate.openGate()
    await model.waitForEnqueue()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try await coordinator.library(storage: storage).count == 2)
    #expect(try await coordinator.catalog(stateRoot: storage.stateRoot).entries.count == 1)
    model.queueItems = [SpeechQueueItem(id: secondRunningID, title: "Synthetic running", state: .running)]
    model.processingSpeech = true
    model.queueSelection = [.episode(secondRunningID)]
    #expect(!model.canRemoveQueueSelection)
    model.processingSpeech = false
    #expect(model.canRemoveQueueSelection)
}

private let secondRunningID = "00000000-0000-0000-0000-0000000000aa"

@Test @MainActor func repeatedAddsWhilePendingKeepEveryEntryInOrder() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let one = try article("one"), two = try article("two")
    let entries = [one, two].enumerated().map { index, review in
        ReadingListEntry(id: "entry-\(index)", safariID: nil, url: review.page.originalURL, title: "Entry \(index)", addedAt: nil)
    }
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0), stateRoot: storage.stateRoot)
    let gate = FetchGate()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() },
                         enqueueFetch: { url in try await gate.wait(for: url) })
    model.sourceReview.catalog = catalog
    model.articleSelection = [entries[0].id]
    model.addSelectedToQueue()
    #expect(try await awaitMainActor { gate.entered })
    model.articleSelection = [entries[1].id]
    model.addSelectedToQueue()
    #expect(model.pendingAdds.count == 2)
    model.articleSelection = [entries[0].id]
    model.addSelectedToQueue()
    #expect(model.pendingAdds.count == 2)
    gate.openGate()
    await model.waitForEnqueue()
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.count == 2 && queue.map(\.sourceEntryID) == [entries[0].id, entries[1].id])
    #expect(model.queueItems.map(\.sourceEntryID) == [entries[0].id, entries[1].id])
    await model.shutdown()
}

@Test @MainActor func removingPendingAddBeforeCommitAndReaddingUsesFreshToken() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try article("one")
    let entry = ReadingListEntry(id: "entry-one", safariID: nil, url: review.page.originalURL, title: "Entry", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let gate = FetchGate()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() },
                         enqueueFetch: { url in try await gate.wait(for: url) })
    model.sourceReview.catalog = catalog
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    #expect(try await awaitMainActor { gate.entered })
    model.removePreparation(entry.id)
    #expect(model.pendingAdds.isEmpty)
    gate.openGate()
    await model.waitForEnqueue()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(model.queueItems.isEmpty)
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    await model.waitForEnqueue()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 1)
    #expect(gate.fetchCount == 2)
    await model.shutdown()
}

@Test @MainActor func pendingOnlyResetCancelsFetchAndAllowsFreshAdd() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try article("one")
    let entry = ReadingListEntry(id: "entry-one", safariID: nil, url: review.page.originalURL, title: "Entry", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let gate = FetchGate()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in try await gate.wait(for: url) })
    model.sourceReview.catalog = catalog
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    #expect(try await awaitMainActor { gate.entered })
    #expect(model.canResetQueue && model.queueItems.isEmpty && model.pendingAdds.count == 1)
    model.resetQueue()
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    #expect(model.pendingAdds.isEmpty)
    gate.openGate()
    await model.waitForProcessing()
    await model.waitForEnqueue()
    #expect(!model.queueMutationBusy)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty && model.pendingAdds.isEmpty)
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    await model.waitForEnqueue()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 1)
    #expect(model.queueItems.count == 1 && model.queueItems.first?.state == .queued)
    await model.shutdown()
}

@Test @MainActor func queueSelectionTransfersOnCommitAndPrunesOnRefresh() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try article("one")
    let entry = ReadingListEntry(id: "entry-one", safariID: nil, url: review.page.originalURL, title: "Entry", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in
        let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
        return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
                           contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    })
    model.sourceReview.catalog = catalog
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    model.queueSelection = [.preparation(entry.id)]
    await model.waitForEnqueue()
    let item = try #require(await coordinator.queue(stateRoot: storage.stateRoot).first)
    #expect(model.queueSelection == [.episode(item.id)])
    model.runQueue()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(model.queueSelection.isEmpty)
    model.pendingAdds = ["ghost-entry": "Ghost"]
    model.queueSelection = [.preparation("ghost-entry"), .episode("missing-episode")]
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.queueSelection == [.preparation("ghost-entry")])
    model.pendingAdds = [:]
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.queueSelection.isEmpty && model.canRemoveQueueSelection == false)
    await model.shutdown()
}

@Test @MainActor func removingApprovedAdmissionRollsBackCommit() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try article("one")
    let entry = ReadingListEntry(id: "entry-one", safariID: nil, url: review.page.originalURL, title: "Entry", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in
        let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
        return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
                           contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    })
    model.sourceReview.catalog = catalog
    let probe = CommitProbe()
    await model.coordinator.setBeforeEnqueueCommit({
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            model.removePreparation(entry.id)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        probe.record()
    })
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    await model.waitForEnqueue()
    await model.waitForProcessing()
    #expect(probe.fired)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(model.queueItems.isEmpty && model.pendingAdds.isEmpty)
    await model.shutdown()
}

private final class CommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
}

@Test @MainActor func queueRowRemovalLeavesSpeechStateAndProgressUntouched() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage)
    model.queueItems = [item]
    model.progress = PipelineProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 4)
    model.batchProgress = QueueBatchProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 4,
                                             completedArticles: 0, totalArticles: 1, currentArticleIndex: 1)
    model.queueSelection = [.episode(item.id)]
    do {
        let holder = try NativeStore(url: storage.profile.database)
        model.changeQueue(item.id, remove: true)
        #expect(model.queueMutationBusy && model.mutatingQueueEntries.contains(.episode(item.id)))
        #expect(!model.running && !model.processingSpeech)
        #expect(model.progress?.completedChunks == 2 && model.batchProgress?.totalArticles == 1)
        #expect(model.error == nil && model.queueItems == [item])
        _ = holder
    }
    await model.waitForProcessing()
    #expect(!model.queueMutationBusy && model.mutatingQueueEntries.isEmpty)
    #expect(model.queueItems.isEmpty && model.queueSelection.isEmpty)
    #expect(model.progress?.completedChunks == 2 && model.batchProgress?.totalArticles == 1)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test @MainActor func rapidQueueRemovalsBothComplete() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage)
    model.queueItems = [first, second]
    model.changeQueue(first.id, remove: true)
    model.changeQueue(second.id, remove: true)
    await model.waitForProcessing()
    #expect(model.queueItems.isEmpty && model.error == nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test @MainActor func queueRowsResolveOriginalSiteForSavedAndLegacyItems() throws {
    let model = AppModel(preview: true)
    let entry = ReadingListEntry(id: "source", safariID: "source", url: URL(string: "https://origin.example/article?private=value")!, title: "Synthetic source", addedAt: nil)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    let saved = SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "Saved", state: .failed,
                               lastError: "Synthetic error", sourceHost: "saved.example")
    let legacy = SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "Legacy", sourceEntryID: entry.id)
    let unknown = SpeechQueueItem(id: "00000000-0000-0000-0000-000000000003", title: "Unknown")
    #expect(model.queueOriginHost(saved) == "saved.example" && model.queueOriginHost(legacy) == "origin.example")
    #expect(model.queueOriginHost(unknown) == nil)
    model.queueItems = [saved, legacy, unknown]; model.pendingAdds[entry.id] = entry.title
    _ = ArticlesView(model: model).body
    #expect(!model.running && !model.processingSpeech)
}

@Test @MainActor func selectionManagementControlSwitchesToBulkAboveOneSelection() throws {
    func control(_ count: Int) -> SelectionManagementControl {
        SelectionManagementControl(selectionCount: count, resetTitle: "Reset…", canReset: true, canRemove: true,
                                   resetHelp: "reset", removeHelp: "remove", onReset: {}, onRemove: {})
    }
    #expect(!control(0).usesBulkRemoval && !control(1).usesBulkRemoval)
    #expect(control(2).usesBulkRemoval && control(9).usesBulkRemoval)
    let model = AppModel(preview: true)
    _ = ArticlesView(model: model)
    _ = LibraryView(model: model)
}

@Test @MainActor func savedAudioRemovalDeletesFileAndPrunesListing() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let published = try await coordinator.runReviewed(root: storage.stateRoot, review: article(),
                                                      backend: SyntheticProvider(), storage: storage)
    let model = AppModel(storage: storage)
    model.savedEpisodes = [published.episode]
    model.savedAudioSelection = [published.episode.id]
    #expect(model.canDeleteSavedAudio)
    model.removeSavedAudio(ids: [published.episode.id])
    #expect(model.audioMutationBusy && model.mutatingSavedAudioIDs.contains(published.episode.id))
    #expect(!model.running && !model.processingSpeech)
    await model.waitForAudioMutation()
    await model.waitForLibraryRefresh()
    #expect(!FileManager.default.fileExists(atPath: published.audioURL.path))
    #expect(model.savedEpisodes.isEmpty && model.savedAudioSelection.isEmpty && model.error == nil)
    let episode = try #require(try await coordinator.library(storage: storage).first)
    #expect(episode.stage == .expired)
}

@Test @MainActor func savedAudioRemovalBlockedDuringSpeech() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let published = try await coordinator.runReviewed(root: storage.stateRoot, review: article(),
                                                      backend: SyntheticProvider(), storage: storage)
    let model = AppModel(storage: storage)
    model.savedEpisodes = [published.episode]
    model.processingSpeech = true
    #expect(!model.canDeleteSavedAudio)
    model.removeSavedAudio(ids: [published.episode.id])
    #expect(!model.audioMutationBusy)
    #expect(FileManager.default.fileExists(atPath: published.audioURL.path))
    model.processingSpeech = false
    #expect(model.canDeleteSavedAudio)
}

@Test @MainActor func queuePreviewResolvesSavedSnapshotURL() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let published = try await coordinator.runReviewed(root: storage.stateRoot, review: article("preview"),
                                                      backend: SyntheticProvider(), storage: storage)
    let url = try await coordinator.articlePreviewURL(articleID: published.episode.id, stateRoot: storage.stateRoot)
    #expect(url == URL(string: "https://synthetic.example/preview"))
    #expect(ArticlePreviewNavigation.validated(url) == url)
    #expect(ArticlePreviewNavigation.validated(URL(fileURLWithPath: "/tmp/x")) == nil)
}

@Test @MainActor func savedAudioResetCapturesDisplayedIDsNotLiveList() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    for tag in ["one", "two", "three"] {
        _ = try await coordinator.runReviewed(root: storage.stateRoot, review: article(tag),
                                              backend: SyntheticProvider(), storage: storage)
    }
    let model = AppModel(storage: storage)
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.count == 3)
    let captured = model.savedAudioResetCandidates
    let fourth = try await coordinator.runReviewed(root: storage.stateRoot, review: article("four"),
                                                   backend: SyntheticProvider(), storage: storage)
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.count == 4)
    #expect(captured.count == 3 && !captured.contains(fourth.episode.id))
    model.removeSavedAudio(ids: captured)
    await model.waitForAudioMutation()
    #expect(model.error == nil)
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.map(\.id) == [fourth.episode.id])
    #expect(FileManager.default.fileExists(atPath: fourth.audioURL.path))
    let feed = try String(contentsOf: fourth.feedURL, encoding: .utf8)
    #expect(feed.contains(fourth.episode.id))
    for id in captured { #expect(!feed.contains(id)) }
}

private final class RecordingProvider: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "recording-test", displayName: "Recording", isMock: false)
    private let lock = NSLock()
    private var ids: [String] = []
    var synthesized: [String] { lock.withLock { ids } }
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        lock.withLock { ids.append(request.articleID) }
        return try SyntheticProvider().synthesize(request, directory: directory)
    }
}

private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor private func waitForCatalog(_ model: SourceReviewModel) async throws {
    model.loadCatalog()
    let deadline = Date().addingTimeInterval(5)
    while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.busy)
}

@MainActor private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition(), Comment(rawValue: description))
}

private func sourceFixture(_ name: String = "chosen") throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-src-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let plist = root.appendingPathComponent("\(name).plist")
    try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: plist)
    return (root, plist)
}

@Test @MainActor func queueControlsStayEnabledDuringRowMutation() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage)
    model.queueItems = [first, second]
    #expect(model.canGenerateAudio && model.canResetQueue)
    do {
        let holder = try NativeStore(url: storage.profile.database)
        model.changeQueue(first.id, remove: true)
        #expect(model.queueMutationBusy && model.mutatingQueueEntries.contains(.episode(first.id)))
        #expect(model.canGenerateAudio && model.canResetQueue && model.queueItems.count == 2)
        _ = holder
    }
    await model.waitForProcessing()
    #expect(!model.queueMutationBusy && model.queueItems.map(\.id) == [second.id])
    #expect(model.canGenerateAudio && model.canResetQueue)
}

@Test @MainActor func generateAwaitsPendingRemovalAndSynthesizesOnlyRemaining() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let recorder = RecordingProvider()
    let model = AppModel(storage: storage, backend: { _ in recorder })
    model.queueItems = [first, second]
    do {
        // Holding the writer lock across runQueue() keeps the removal in flight without a
        // wall-clock window: the drain cannot claim work before the mutation commits.
        let holder = try NativeStore(url: storage.profile.database)
        model.changeQueue(first.id, remove: true)
        #expect(model.queueMutationBusy)
        model.runQueue()
        #expect(model.running && recorder.synthesized.isEmpty)
        _ = holder
    }
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(!recorder.synthesized.isEmpty && recorder.synthesized.allSatisfy { $0 == second.id })
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(!model.running && model.queueItems.isEmpty)
}

@Test @MainActor func confirmedResetBehindPendingRemovalClearsAllRows() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage)
    model.queueItems = [first, second]
    do {
        let holder = try NativeStore(url: storage.profile.database)
        model.changeQueue(first.id, remove: true)
        #expect(model.queueMutationBusy && model.canResetQueue)
        model.resetQueue()
        #expect(model.isQueueResetPending && !model.canResetQueue)
        _ = holder
    }
    await model.waitForProcessing()
    #expect(model.queueItems.isEmpty && !model.isQueueResetPending)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test @MainActor func stopDuringMutationAwaitSynthesizesNothingButFinishesMetadata() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let recorder = RecordingProvider()
    let model = AppModel(storage: storage, backend: { _ in recorder })
    model.queueItems = [first, second]
    do {
        let holder = try NativeStore(url: storage.profile.database)
        model.changeQueue(first.id, remove: true)
        model.runQueue()
        #expect(model.running && recorder.synthesized.isEmpty)
        model.stopQueue()
        _ = holder
    }
    await model.waitForProcessing()
    #expect(recorder.synthesized.isEmpty && !model.running)
    #expect(!model.queueMutationBusy && model.queueItems.map(\.id) == [second.id])
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [second.id])
}

@Test @MainActor func noticeDismissalIsKeyedStableAndPresentationOnly() {
    let notices = NoticeDismissalState()
    let item = SpeechQueueItem(id: "q1", title: "One", state: .failed, attempts: 1, lastError: "Chunk failed")
    let key = "queue:\(item.id):\(item.attempts):\(item.state)"
    #expect(notices.isVisible(message: item.lastError ?? "", key: key))
    notices.dismiss(message: item.lastError ?? "", key: key)
    #expect(!notices.isVisible(message: item.lastError ?? "", key: key))
    #expect(item.lastError == "Chunk failed" && item.attempts == 1 && item.state == .failed)
    let retried = SpeechQueueItem(id: item.id, title: item.title, state: .failed,
                                  attempts: 2, lastError: item.lastError)
    #expect(notices.isVisible(message: retried.lastError ?? "", key: "queue:\(retried.id):\(retried.attempts):\(retried.state)"))
    notices.dismiss(message: "Audio cleanup could not finish.", key: "audio")
    #expect(!notices.isVisible(message: "Audio cleanup could not finish.", key: "audio"))
    #expect(notices.isVisible(message: "A different warning.", key: "audio"))
    notices.reset(key: "audio")
    #expect(notices.isVisible(message: "Audio cleanup could not finish.", key: "audio"))
}

@Test @MainActor func previewErrorClearKeepsReviewContentAndStoreUntouched() throws {
    let review = try ReviewedSource.prepare(FetchedPage(originalURL: URL(string: "https://synthetic.example/inert")!,
        finalURL: URL(string: "https://synthetic.example/inert")!, bytes: Data("<html><body>Hi</body></html>".utf8),
        html: "<html><body>Hi</body></html>", contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
    let model = ArticlePreviewModel(inert: true, review: review)
    model.error = "Article preview failed; inspect the source and retry."
    model.error = nil
    #expect(model.error == nil && model.review?.page.originalURL == review.page.originalURL)
    _ = InlineNotice(message: "inert")
    _ = InlineNotice(message: "inert") {}
    _ = SectionHelpHeader(title: "Storage", explanation: "inert")
}

@Test @MainActor func typographyAndSelectorConstantsMeetPresentationFloor() {
    #expect(AppTypography.minimumPointSize >= 12)
    #expect(SettingsNavigation<SettingsSection>.idealWidth == 392)
    #expect(SettingsView.windowWidth == 440 && SettingsView.windowHeight == 680)
}

@Test @MainActor func autoSyncWithoutChosenSourceNeverReadsPlist() async throws {
    let (root, _) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let calls = SyncCounter()
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), snapshotReader: { url in
        calls.increment()
        return try ReadingList.read(url)
    })
    model.startAutomaticSynchronization()
    try await waitForCatalog(model)
    #expect(await model.synchronizeOnce() && calls.value == 0)
    try await waitUntil("unset source guides source choice") {
        model.status.contains("Choose a Reading List source")
    }
    await model.stop()
    #expect(await model.synchronizeOnce() == false && calls.value == 0)
}

@Test @MainActor func chosenSourceSyncsAndRemovesAbsentInventory() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try Data(contentsOf: plist)
    let calls = SyncCounter()
    let one = ReadingListEntry(id: "safari:one", safariID: "one", url: URL(string: "https://articles.example/one")!, title: "One", addedAt: nil)
    let two = ReadingListEntry(id: "safari:two", safariID: "two", url: URL(string: "https://articles.example/two")!, title: "Two", addedAt: nil)
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist, snapshotReader: { url in
        #expect(url == plist)
        let index = calls.value; calls.increment()
        return ReadingListSnapshot(entries: index == 0 ? [one, two] : [two], skippedEntries: 0)
    })
    try await waitForCatalog(model)
    #expect(await model.synchronizeOnce() && calls.value == 1)
    #expect(model.catalog.currentIDs == [one.id, two.id] && model.error == nil)
    #expect(await model.synchronizeOnce() && calls.value == 2)
    #expect(model.catalog.currentIDs == [two.id])
    #expect(model.catalog.entries.map(\.id) == [two.id])
    #expect(try Data(contentsOf: plist) == bytes)
    await model.stop()
}

@Test @MainActor func failedSourceReadPreservesInventoryAndSuccessClearsError() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let mode = SyncCounter()
    let entry = ReadingListEntry(id: "safari:one", safariID: "one", url: URL(string: "https://articles.example/one")!, title: "One", addedAt: nil)
    struct Failed: Error {}
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist, snapshotReader: { _ in
        if mode.value == 1 { throw Failed() }
        return ReadingListSnapshot(entries: [entry], skippedEntries: 0)
    })
    try await waitForCatalog(model)
    #expect(await model.synchronizeOnce() && model.catalog.currentIDs == [entry.id] && model.error == nil)
    mode.increment()
    #expect(await model.synchronizeOnce())
    #expect(model.error != nil && model.catalog.currentIDs == [entry.id])
    mode.increment()
    #expect(await model.synchronizeOnce())
    #expect(model.error == nil && model.status.contains("current entries"))
    await model.stop()
}

@Test @MainActor func stopCancelsAndAwaitsOwnedSourceRead() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let started = SyncCounter()
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist, snapshotReader: { _ in
        started.increment()
        try await Task.sleep(for: .seconds(30))
        return ReadingListSnapshot(entries: [], skippedEntries: 0)
    })
    try await waitForCatalog(model)
    model.requestSourceSync()
    try await waitUntil("owned reader started") { started.value == 1 }
    await model.stop()
    let count = started.value
    #expect(await model.synchronizeOnce() == false)
    model.requestSourceSync()
    try await Task.sleep(for: .milliseconds(100))
    #expect(started.value == count && count == 1)
}

@Test @MainActor func sourceSwitchDuringReadCommitsOnlyNewSource() async throws {
    let (root, oldPlist) = try sourceFixture("old")
    let newPlist = root.appendingPathComponent("new.plist")
    try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: newPlist)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldReads = SyncCounter(), newReads = SyncCounter(), release = SyncCounter()
    let old = ReadingListEntry(id: "safari:old", safariID: "old", url: URL(string: "https://articles.example/old")!, title: "Old", addedAt: nil)
    let new = ReadingListEntry(id: "safari:new", safariID: "new", url: URL(string: "https://articles.example/new")!, title: "New", addedAt: nil)
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: oldPlist, snapshotReader: { url in
        if url == oldPlist {
            oldReads.increment()
            let deadline = Date().addingTimeInterval(5)
            while release.value == 0 && !Task.isCancelled && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            return ReadingListSnapshot(entries: [old], skippedEntries: 0)
        }
        newReads.increment()
        return ReadingListSnapshot(entries: [new], skippedEntries: 0)
    })
    try await waitForCatalog(model)
    model.requestSourceSync()
    try await waitUntil("old source read started") { oldReads.value == 1 }
    model.setSource(newPlist)
    release.increment()
    try await waitUntil("new source committed") { model.catalog.currentIDs == [new.id] }
    #expect(newReads.value >= 1 && oldReads.value == 1)
    #expect(model.catalog.entries.map(\.id) == [new.id] && model.error == nil)
    #expect(model.status.contains("1 current entries"))
    await model.stop()
}

@Test @MainActor func requestDuringActiveReadCoalescesExtraPass() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let calls = SyncCounter(), release = SyncCounter()
    let entry = ReadingListEntry(id: "safari:one", safariID: "one", url: URL(string: "https://articles.example/one")!, title: "One", addedAt: nil)
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist, snapshotReader: { _ in
        calls.increment()
        let deadline = Date().addingTimeInterval(5)
        while release.value == 0 && !Task.isCancelled && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return ReadingListSnapshot(entries: [entry], skippedEntries: 0)
    })
    try await waitForCatalog(model)
    model.requestSourceSync()
    try await waitUntil("first read started") { calls.value == 1 }
    model.requestSourceSync()
    release.increment()
    try await waitUntil("coalesced extra pass ran") { calls.value == 2 }
    try await waitUntil("extra pass committed") { model.catalog.currentIDs == [entry.id] }
    #expect(model.error == nil)
    await model.stop()
}

@Test @MainActor func explicitOperationsResetDismissedNotices() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, enqueueFetch: { _ in throw RelayError.setup("inert test fetch") })
    let notices = model.notices
    model.audioCleanupError = "Audio cleanup could not finish."
    notices.dismiss(message: "Audio cleanup could not finish.", key: "audio")
    model.audioCleanupError = "Audio cleanup could not finish."
    #expect(!notices.isVisible(message: "Audio cleanup could not finish.", key: "audio"))
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    #expect(model.audioCleanupError == nil)
    model.audioCleanupError = "Audio cleanup could not finish."
    #expect(notices.isVisible(message: "Audio cleanup could not finish.", key: "audio"))
    notices.dismiss(message: "any failure", key: "global")
    model.changeQueue("missing-id", remove: true)
    #expect(notices.isVisible(message: "any failure", key: "global"))
    await model.waitForProcessing()
    notices.dismiss(message: "Audio cleanup could not finish.", key: "audio")
    notices.dismiss(message: "any failure", key: "global")
    model.savedEpisodes = try await coordinator.library(storage: storage)
    if let first = model.savedEpisodes.first { model.removeSavedAudio(ids: [first.id]) }
    #expect(notices.isVisible(message: "Audio cleanup could not finish.", key: "audio"))
    #expect(notices.isVisible(message: "any failure", key: "global"))
    await model.waitForAudioMutation()
    await model.waitForLibraryRefresh()
    notices.dismiss(message: "A — failed", key: "enqueue")
    let entry = ReadingListEntry(id: "safari:a", safariID: "a", url: URL(string: "https://articles.example/a")!, title: "A", addedAt: nil)
    var catalog = ReadingListCatalog()
    catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    model.sourceReview.catalog = catalog
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    #expect(notices.isVisible(message: "A — failed", key: "enqueue"))
    await model.waitForEnqueue()
}

// MARK: - Stage 2: delivery settings, drains, connection test, automation

private func isolatedDefaults() throws -> (UserDefaults, String) {
    let name = "voicerelay-app-test-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}

private func appDeliverySettings(enabled: Bool = true) -> DeliverySettings {
    var settings = DeliverySettings()
    settings.enabled = enabled
    settings.feedFolderURL = URL(string: "https://webdav.example/remote.php/dav/files/user/Podcast%20Feed/")
    settings.username = "user@example.com"
    settings.publicFolderURL = URL(string: "https://podcast.example/")
    return settings
}

/// Records credential writes/deletes; serves a fixed password on read.
private final class RecordingCredentials: DeliveryCredentialStore, @unchecked Sendable {
    var password: String?
    var writes: [(password: String, username: String, host: String)] = []
    var deletes: [(username: String, host: String)] = []
    var reads: [(username: String, host: String)] = []
    var readError: (any Error)?
    init(password: String? = nil) { self.password = password }
    func hasPassword(username: String, host: String) throws -> Bool { password != nil }
    func readPassword(username: String, host: String) throws -> String? {
        reads.append((username, host))
        if let readError { throw readError }
        return password
    }
    func writePassword(_ password: String, username: String, host: String) throws {
        writes.append((password, username, host)); self.password = password
    }
    func deletePassword(username: String, host: String) throws {
        deletes.append((username, host)); password = nil
    }
}

/// Minimal transport double: records calls, injects status/throw overrides, answers MKCOL.
private final class StubDeliveryTransport: DeliveryTransport, @unchecked Sendable {
    struct Call { let method: String; let path: String }
    var calls: [Call] = []
    var statusFor: ((String) -> Int?)?
    var throwFor: ((String) -> (any Error)?)?
    var statusForPath: ((String, String) -> Int?)?
    var headLengths: [String: Int] = [:]
    var stored: [String: Int] = [:]
    var bodies: [String: Data] = [:]
    var entered: (method: String, path: String)? { calls.first.map { ($0.method, $0.path) } }
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        try Task.checkCancellation()
        let path = url.path
        calls.append(Call(method: method, path: path))
        if let failure = throwFor?(method) { throw failure }
        if let injected = statusForPath?(method, path) ?? statusFor?(method) { return DeliveryResponse(status: injected) }
        switch method {
        case "PROPFIND":
            let xml = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>\(path)</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
            return DeliveryResponse(status: 207, body: Data(xml.utf8))
        case "GET":
            guard let data = bodies[path] else { return DeliveryResponse(status: 404) }
            return DeliveryResponse(status: 200, headers: ["Content-Length": String(data.count)], body: data)
        case "MKCOL": return DeliveryResponse(status: 201)
        case "PUT":
            let bytes = try body?.count ?? file.map { try Data(contentsOf: $0).count } ?? 0
            stored[path] = bytes
            bodies[path] = try body ?? file.map { try Data(contentsOf: $0) }
            return DeliveryResponse(status: 201)
        case "HEAD":
            guard let size = stored[path].map({ headLengths[path] ?? $0 }) else { return DeliveryResponse(status: 404) }
            return DeliveryResponse(status: 200, headers: ["Content-Length": String(size)])
        case "DELETE": return DeliveryResponse(status: 204)
        default: return DeliveryResponse(status: 405)
        }
    }
}

private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var on: Bool { lock.withLock { value } }
    func set(_ new: Bool) { lock.withLock { value = new } }
}

@Test @MainActor func defaultPodcastCoverHoldsInitialDeliveryUntilArtworkIsReady() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("icon/VoiceRelay_Cover.jpg")
    let credentials = RecordingCredentials(password: "fixture"), transport = StubDeliveryTransport()
    let store = CoverArtworkStore(root: root.appendingPathComponent("art"))
    let model = AppModel(storage: storage, deliveryTransport: { transport }, credentialStore: credentials,
        podcastCoverStore: store, defaultPodcastCoverURL: source)
    model.deliverySettings = appDeliverySettings()
    model.prepareDefaultPodcastCover()
    model.triggerDelivery(force: true)
    model.triggerDelivery(force: true)
    #expect(!model.deliveryBusy && credentials.reads.isEmpty && transport.calls.isEmpty)
    await model.waitForPodcastCoverImport()
    await model.waitForDelivery()
    let digest = try #require(model.deliverySettings.podcastCoverDigest)
    let feedPath = try #require(model.deliverySettings.feedFolderURL).appendingPathComponent("feed.xml").path
    let feed = try #require(transport.bodies[feedPath])
    #expect(try ServerFeedSnapshot(feed).channelArtworkURL?.lastPathComponent == "artwork-" + digest + ".jpg")
    let puts = transport.calls.filter { $0.method == "PUT" }
    #expect(try #require(puts.firstIndex { $0.path.hasSuffix(".jpg") }) < #require(puts.firstIndex { $0.path.hasSuffix("feed.xml") }))
    #expect(credentials.reads.count == 1 && model.deliveryError == nil)
    await model.shutdown()
}

@Test @MainActor func deliverySettingsPersistWithoutPasswordAndReload() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    var settings = appDeliverySettings()
    settings.channelTitle = "My Private Feed"
    let credentials = RecordingCredentials(password: nil)
    let model = AppModel(storage: storage, defaults: defaults, credentialStore: credentials)
    model.deliverySettings = settings
    model.deliveryPassword = "app-secret-password"
    model.saveDeliveryPassword(); await model.waitForCredentialMutation()
    // The password reached only the credential store; no UserDefaults value contains it.
    let write = try #require(credentials.writes.first)
    #expect(credentials.writes.count == 1 && write.password == "app-secret-password"
            && write.username == "user@example.com" && write.host == "webdav.example")
    #expect(model.deliveryPassword.isEmpty && model.deliveryPasswordStored)
    let encoded = try #require(defaults.data(forKey: "deliverySettings"))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("app-secret-password"))
    for key in defaults.dictionaryRepresentation().keys {
        let value = String(describing: defaults.object(forKey: key) ?? "")
        #expect(!value.contains("app-secret-password"))
    }
    let reloaded = AppModel(storage: storage, defaults: defaults, credentialStore: credentials)
    #expect(reloaded.deliverySettings == settings)
    await model.shutdown(); await reloaded.shutdown()
}

@Test @MainActor func deliveryTestConnectionClassifiesOutcomes() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubDeliveryTransport()
    let credentials = RecordingCredentials(password: "pw")
    let model = AppModel(storage: storage, defaults: defaults,
                         deliveryTransport: { transport }, credentialStore: credentials)
    model.deliverySettings = appDeliverySettings()
    #expect(model.deliveryTestResult == .untested)
    model.testDeliveryConnection()
    await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .success && !model.deliveryTesting)
    #expect(transport.calls.map(\.method) == ["PROPFIND", "PROPFIND"])
    #expect(credentials.reads.count == 1)
    // Missing credentials → credentials needed.
    model.clearDeliveryPassword(); await model.waitForCredentialMutation()
    model.deliveryTestResult = .untested
    model.testDeliveryConnection()
    await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .failure("No saved password for this host and username."))
    model.deliveryPassword = "pw"
    model.saveDeliveryPassword(); await model.waitForCredentialMutation()
    // HTTP 401 → authentication failed.
    transport.statusFor = { _ in 401 }
    model.testDeliveryConnection()
    await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .failure("Delivery credentials were rejected (HTTP 401)."))
    transport.statusFor = nil
    // Transport throw → server unreachable.
    struct SyntheticDown: Error {}
    transport.throwFor = { _ in SyntheticDown() }
    model.testDeliveryConnection()
    await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .failure("Server unreachable"))
    transport.throwFor = nil
    // Editing a field resets the result.
    model.deliveryTestResult = .success
    model.deliverySettings.channelTitle = "Renamed"
    #expect(model.deliveryTestResult == .untested)
    // Invalid configuration fails fast without a transport call.
    let calls = transport.calls.count
    model.deliverySettings.feedFolderURL = URL(string: "https://example.com/folder?bad=1")
    model.testDeliveryConnection()
    await model.waitForDeliveryTest()
    if case .failure(let message) = model.deliveryTestResult {
        #expect(message.contains("without a query"))
    } else { Issue.record("Invalid folder path was accepted") }
    #expect(transport.calls.count == calls)
    await model.shutdown()
}

@Test @MainActor func publishMarksDeliveryPendingAndDrainUploadsMediaBeforeFeed() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, defaults: defaults,
                         deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings()
    model.queueItems = [item]
    model.runQueue()
    await model.waitForProcessing()
    await model.waitForDelivery()
    await model.waitForLibraryRefresh()
    #expect(model.error == nil && model.result?.remoteDelivery == "pending")
    let methods = transport.calls.map(\.method)
    let mediaIndex = try #require(methods.indices.first { transport.calls[$0].path.hasSuffix("/audio/\(item.id).m4a") && transport.calls[$0].method == "PUT" })
    let feedIndex = try #require(methods.indices.first { transport.calls[$0].path.hasSuffix("/feed.xml") && transport.calls[$0].method == "PUT" })
    #expect(mediaIndex < feedIndex)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot)
    #expect(!summary.needsDrain && summary.uploadedMedia == 1 && model.deliveryPendingCount == 0)
    #expect(model.deliveryStatus != nil && model.deliveryError == nil)
    await model.shutdown()
}

@Test @MainActor func deliveryStartsAfterPublicationWhileLaterSpeechIsRunning() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator(), provider = GateProvider()
    defer { provider.openGate() }
    let first = try await coordinator.enqueue(article("first"), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, backend: { episode in
        episode.id == first.id ? SyntheticProvider() as any TTSBackend : provider
    }, defaults: defaults, deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings(); model.queueItems = [first, second]
    model.runQueue()
    try await waitUntil("first article uploads while later speech is blocked") {
        provider.synthesizeEntered && transport.calls.contains { $0.method == "PUT" && $0.path.hasSuffix("/audio/\(first.id).m4a") }
    }
    #expect(model.running && !provider.finished)
    provider.openGate()
    await model.waitForProcessing(); await model.waitForDelivery(); await model.waitForLibraryRefresh()
    #expect(model.error == nil && model.deliveryError == nil)
    #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot).uploadedMedia == 2)
    await model.shutdown()
}

/// Hold the first feed-size response after the drain has enumerated its media.
/// Publishing during this hold requires another drain, not just another feed PUT.
private actor FeedConfirmationGate: DeliveryTransport {
    private let base = StubDeliveryTransport()
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        if !held && method == "HEAD" && url.lastPathComponent == "feed.xml" {
            held = true
            let timeout = Task { try? await Task.sleep(for: .seconds(10)); self.release() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { await self.release() } }
            timeout.cancel()
            try Task.checkCancellation()
        }
        return try await base.request(method, url: url, body: body, file: file, headers: headers)
    }
    func waitUntilHeld() async throws {
        let end = Date().addingTimeInterval(5)
        while continuation == nil && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        guard continuation != nil else { throw RelayError.tool("Synthetic feed confirmation did not start.") }
    }
    func release() { continuation?.resume(); continuation = nil }
    func probeCount() -> Int { base.calls.filter { $0.method == "PROPFIND" }.count }
}

@Test(arguments: ["automatic", "backoff", "force", "check"])
@MainActor func deliveryCoalescesFollowUpsWithoutLosingForceOrBypassingBackoff(_ mode: String) async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator(), settings = appDeliverySettings(), transport = FeedConfirmationGate()
    _ = try await coordinator.runReviewed(root: storage.stateRoot, review: article("first"),
        backend: SyntheticProvider(), storage: storage, delivery: settings)
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
        credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings
    model.triggerDelivery()
    try await transport.waitUntilHeld()
    let second = try await coordinator.runReviewed(root: storage.stateRoot, review: article("second"),
        backend: SyntheticProvider(), storage: storage, delivery: settings)
    let store = try PipelineStore(databaseURL: storage.profile.database)
    var episode = try #require(store.published().first { $0.id == second.episode.id })
    let deadline = Date().addingTimeInterval(600)
    if mode == "backoff" {
        episode.delivery?.nextAttemptAt = deadline
        episode.delivery?.attempts = 1
    } else if mode == "force" {
        episode.delivery?.status = .failed
        episode.delivery?.lastError = DeliveryError.authNotice
    }
    try store.save(episode)
    for _ in 0..<3 { model.triggerDelivery() }
    if mode == "force" { model.triggerDelivery(force: true); model.triggerDelivery() }
    if mode == "check" { model.triggerDelivery(reconcileNow: true); model.triggerDelivery() }
    await transport.release()
    await model.waitForDelivery()
    let current = try #require(store.published().first { $0.id == second.episode.id })
    let probes = await transport.probeCount()
    if mode == "backoff" {
        #expect(current.delivery?.status == .pending && current.delivery?.nextAttemptAt == deadline)
        #expect(current.delivery?.attempts == 1 && probes == 2)
    } else {
        #expect(current.delivery?.status == .uploaded)
        #expect(try await coordinator.deliverySummary(stateRoot: storage.stateRoot).uploadedMedia == 2)
        #expect(probes == 4)
        #expect(!model.deliveryBusy && model.deliveryError == nil)
        if mode == "check" { #expect(model.deliveryConnectionVerified) }
    }
    await model.shutdown()
}

@Test @MainActor func deliveryShutdownCancelsHeldDrainWithoutStartingFollowUp() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: article(),
        backend: SyntheticProvider(), storage: storage, delivery: appDeliverySettings())
    let transport = FeedConfirmationGate()
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
        credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings()
    model.triggerDelivery()
    try await transport.waitUntilHeld()
    model.triggerDelivery(force: true); model.triggerDelivery()
    await model.shutdown()
    #expect(!model.deliveryBusy && model.stopping)
    #expect(await transport.probeCount() == 2)
}

@Test @MainActor func savedAudioUploadControlHidesOnlyAfterFeedPublicationAndRetriesFailures() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator(), settings = appDeliverySettings()
    let first = try await coordinator.runReviewed(root: storage.stateRoot, review: article("first"),
        backend: SyntheticProvider(), storage: storage, delivery: settings)
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
                         credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings
    model.savedEpisodes = try await coordinator.savedAudio(storage: storage)
    #expect(model.savedAudioDeliveryStatus(first.episode) == .awaitingUpload)
    #expect(model.uploadItems.map(\.id) == [first.episode.id])
    #expect(model.showsUploadNewItems && model.canUploadNewItems)
    model.uploadNewItems()
    #expect(model.deliveryBusy && model.showsUploadNewItems && !model.canUploadNewItems)
    await model.waitForDelivery()
    // The status updates at drain completion, without a library refresh or pane reopen.
    #expect(model.savedAudioDeliveryStatus(first.episode) == .published)
    #expect(!model.showsUploadNewItems && !model.canUploadNewItems)
    #expect(model.uploadItems.isEmpty && model.uploadProgress.isEmpty)
    var replacement = first.episode
    replacement.audioHash = "replacement-audio"
    #expect(model.savedAudioDeliveryStatus(replacement) == .awaitingUpload)
    replacement.delivery?.status = .failed
    #expect(model.savedAudioDeliveryStatus(replacement) == .failed)
    let count = transport.calls.count
    model.uploadNewItems(); #expect(transport.calls.count == count)
    let second = try await coordinator.runReviewed(root: storage.stateRoot, review: article("second"),
        backend: SyntheticProvider(), storage: storage, delivery: settings)
    model.savedEpisodes = try await coordinator.savedAudio(storage: storage)
    transport.statusForPath = { method, path in method == "PUT" && path.hasSuffix("/feed.xml") ? 503 : nil }
    model.uploadNewItems(); await model.waitForDelivery()
    #expect(model.savedAudioDeliveryStatus(first.episode) == .published)
    #expect(model.savedAudioDeliveryStatus(second.episode) == .uploaded)
    #expect(model.showsUploadNewItems && model.canUploadNewItems && model.deliveryError != nil)
    #expect(model.uploadItems.map(\.id) == [second.episode.id] && model.uploadsNeedAttention)
    transport.statusForPath = nil
    model.uploadNewItems(); await model.waitForDelivery()
    #expect(model.savedAudioDeliveryStatus(second.episode) == .published && !model.showsUploadNewItems)
    #expect(model.deliveryError == nil && model.uploadItems.isEmpty && model.uploadProgress.isEmpty)
    model.deliverySettings.feedFolderURL = URL(string: "https://another.example/podcast/")
    #expect(model.savedAudioDeliveryStatus(first.episode) == .notUploaded && model.showsUploadNewItems)
    #expect(model.uploadItems.count == 2)
    model.deliverySettings.enabled = false
    #expect(!model.showsUploadNewItems && !model.canUploadNewItems)
    let stopped = transport.calls.count
    model.uploadNewItems(); #expect(transport.calls.count == stopped)
    await model.shutdown()
}

@Test @MainActor func savedAudioUploadControlSkipsRemovalsAndIsInertInPreviews() throws {
    let model = AppModel(preview: true), settings = appDeliverySettings()
    model.deliverySettings = settings
    let episode = Episode(id: UUID().uuidString, title: "Synthetic saved audio", stage: .published,
        settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
    model.savedEpisodes = [episode]
    #expect(model.savedAudioDeliveryStatus(episode) == .notUploaded)
    #expect(model.showsUploadNewItems && !model.canUploadNewItems)
    model.uploadNewItems(); #expect(!model.deliveryBusy)
    var removing = episode; removing.manualAudioDeletionRequested = true
    model.savedEpisodes = [removing]
    #expect(!model.hasNewItemsToUpload && !model.showsUploadNewItems)
    model.savedEpisodes = []
    #expect(!model.showsUploadNewItems)
}

@Test @MainActor func disabledDeliveryIsInertAndShutdownRefusesNewDrains() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: article(),
                                                   backend: SyntheticProvider(), storage: storage,
                                                   delivery: appDeliverySettings())
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults,
                         deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    // Disabled settings: trigger is a no-op.
    model.deliverySettings = appDeliverySettings(enabled: false)
    model.triggerDelivery()
    await model.waitForDelivery()
    #expect(transport.calls.isEmpty && !model.deliveryBusy)
    // Invalid settings are also a no-op.
    var broken = appDeliverySettings(); broken.feedFolderURL = URL(string: "https://example.com/folder?bad=1")
    model.deliverySettings = broken
    model.triggerDelivery()
    #expect(transport.calls.isEmpty)
    // Shutdown cancels and refuses new drains.
    model.deliverySettings = appDeliverySettings()
    await model.shutdown()
    model.triggerDelivery()
    model.testDeliveryConnection()
    await model.waitForDelivery()
    await model.waitForDeliveryTest()
    #expect(transport.calls.isEmpty && !model.deliveryTesting)
}

/// Suspend before committing the first media PUT so turning publishing off can
/// be observed without transferring any bytes or contacting a real server.
private actor PublishingOffGate: DeliveryTransport {
    private let base = StubDeliveryTransport()
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var observedCancellation = false

    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        if !held && method == "PUT" && url.pathExtension == "m4a" {
            held = true
            let timeout = Task { try? await Task.sleep(for: .seconds(10)); self.release() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { await self.release() } }
            timeout.cancel()
            do { try Task.checkCancellation() }
            catch { observedCancellation = true; throw error }
        }
        return try await base.request(method, url: url, body: body, file: file, headers: headers)
    }
    func waitUntilHeld() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard continuation != nil else { throw RelayError.tool("Synthetic media upload did not start.") }
    }
    func release() { continuation?.resume(); continuation = nil }
    func writeCount() -> Int { base.calls.filter { ["PUT", "MKCOL", "DELETE"].contains($0.method) }.count }
}

@Test @MainActor func disablingPublishingCancelsActiveDrainAndKeepsMediaForReenable() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator(), settings = appDeliverySettings(), transport = PublishingOffGate()
    defer { Task { await transport.release() } }
    var expectedHashes: [String: String] = [:]
    for path in ["first", "second"] {
        let result = try await coordinator.runReviewed(root: storage.stateRoot, review: article(path),
            backend: SyntheticProvider(), storage: storage, delivery: settings)
        expectedHashes[result.episode.id] = try #require(result.episode.audioHash)
    }
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
        credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings; model.triggerDelivery()
    try await transport.waitUntilHeld()
    let writesBeforeOff = await transport.writeCount()
    model.triggerDelivery(force: true) // A queued follow-up must not survive Off.
    model.deliverySettings.enabled = false
    await model.waitForDelivery(); await model.waitForLibraryRefresh(); await model.waitForSettingsBookkeeping()
    #expect(await transport.observedCancellation)
    #expect(await transport.writeCount() == writesBeforeOff)
    #expect(!model.deliveryBusy && model.deliveryError == nil)
    let pending = try await coordinator.savedAudio(storage: storage)
    #expect(pending.count == 2)
    for episode in pending {
        #expect(episode.delivery?.status == .pending && episode.audioHash == expectedHashes[episode.id])
        #expect(FileManager.default.fileExists(atPath: episode.settings.audio.appendingPathComponent(episode.id + ".m4a").path))
    }
    model.triggerDelivery(force: true); await model.waitForDelivery()
    #expect(await transport.writeCount() == writesBeforeOff)

    // The next ordinary delivery tick after the user re-enables Publishing resumes
    // the same retained recordings, without another synthesis pass.
    model.deliverySettings.enabled = true; model.triggerDelivery()
    await model.waitForDelivery(); await model.waitForLibraryRefresh()
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings)
    #expect(summary.uploadedMedia == 2 && summary.pendingMedia == 0)
    #expect(model.deliveryError == nil && model.savedEpisodes.count == 2)
    for episode in model.savedEpisodes {
        #expect(episode.audioHash == expectedHashes[episode.id] && model.savedAudioDeliveryStatus(episode) == .published)
    }
    await model.shutdown()
}

@Test @MainActor func deliverySettingsChangeMarksRemoteFeedPending() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = appDeliverySettings()
    _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: article(),
                                                   backend: SyntheticProvider(), storage: storage, delivery: settings)
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults,
                         deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings
    model.triggerDelivery()
    await model.waitForDelivery()
    var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(!ledger.remoteFeedPending && ledger.settingsHash == (try? settings.settingsHash()))
    // A settings edit changes the hash and marks the feed pending for the next drain.
    model.deliverySettings.channelTitle = "Renamed Channel"
    await model.waitForSettingsBookkeeping()
    ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(ledger.remoteFeedPending)
    model.triggerDelivery()
    await model.waitForDelivery()
    ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
    #expect(!ledger.remoteFeedPending && transport.calls.contains { $0.method == "PUT" && $0.path.hasSuffix("/feed.xml") })
    await model.shutdown()
}

private func fetchFixture(url: URL) throws -> FetchedPage {
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
                       contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
}

@Test @MainActor func appHealthRequiresVerifiedServicesAndRoutesFailuresWithoutProbes() throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubDeliveryTransport(), credentials = RecordingCredentials(password: "fixture")
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: credentials)
    #expect(model.appHealth == .failure("Reading List needs setup", .general))
    model.sourceReview.plist = root.appendingPathComponent("Bookmarks.plist")
    model.deliverySettings = appDeliverySettings()
    #expect(model.appHealth == .failure("Reading List not checked", .general))
    model.sourceReview.lastSyncedAt = Date()
    #expect(model.appHealth == .failure("Speech setup not checked", .general))
    model.runtimeTestResult = .success
    #expect(model.appHealth == .failure("Publishing not checked", .delivery))
    model.deliveryConnectionVerified = true
    #expect(model.appHealth == .ready && model.appHealth.symbol == "checkmark.circle.fill")
    #expect(model.appHealth.settingsSection == nil)
    model.sourceReview.error = "Synthetic source failure"
    #expect(model.appHealth.settingsSection == .general && model.appHealth.symbol == "xmark.circle.fill")
    model.sourceReview.error = nil
    model.runtimeTestResult = .failure("Synthetic speech failure")
    #expect(model.appHealth == .failure("Speech setup check failed", .general))
    model.runtimeTestResult = .success
    model.deliveryError = "Synthetic connection failure"
    #expect(model.appHealth == .failure("Publishing needs attention", .delivery))
    model.deliveryError = nil; model.deliveryTestResult = .failure("Synthetic probe failure")
    #expect(model.appHealth == .failure("Publishing check failed", .delivery))
    model.deliveryTestResult = .untested; model.deliveryPasswordChecked = true
    #expect(model.appHealth == .failure("Publishing password missing", .delivery))
    model.deliveryPasswordChecked = false; model.deliveryPreflightBusy = true
    #expect(model.appHealth == .checking("Checking Publishing…") && model.appHealth.settingsSection == nil)
    model.deliveryPreflightBusy = false; model.syncBusy = true
    #expect(model.appHealth == .checking("Syncing…"))
    model.syncBusy = false; model.libraryReviewRequired = true
    #expect(model.appHealth == .failure("Library review required", .troubleshooting))
    model.libraryReviewRequired = false
    model.deliverySettings.publicFolderURL = URL(string: "https://podcast.example/changed/")
    #expect(!model.deliveryConnectionVerified && model.appHealth == .failure("Publishing not checked", .delivery))
    #expect(transport.calls.isEmpty && credentials.reads.isEmpty)
}

@Test @MainActor func appHealthCredentialChangesInvalidateInFlightConnectionProof() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = appDeliverySettings(), transport = FeedConfirmationGate(), credentials = RecordingCredentials(password: "fixture")
    _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: article(),
        backend: SyntheticProvider(), storage: storage, delivery: settings)
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: credentials)
    model.deliverySettings = settings
    model.triggerDelivery(); try await transport.waitUntilHeld()
    model.deliveryConnectionVerified = true
    model.deliveryPassword = "replacement fixture"; model.saveDeliveryPassword()
    #expect(!model.deliveryConnectionVerified && !model.canSyncNow)
    await model.waitForCredentialMutation()
    await transport.release(); await model.waitForDelivery()
    #expect(!model.deliveryConnectionVerified) // The older successful drain cannot validate the new credential.
    model.deliveryConnectionVerified = true
    model.clearDeliveryPassword(); await model.waitForCredentialMutation()
    #expect(!model.deliveryConnectionVerified)
    await model.shutdown()
}

@Test @MainActor func syncProgressUsesOnlyMeasuredCurrentPhaseAndClearsWhenIdle() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, defaults: defaults)
    let item = try await FixtureCoordinator().enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let episode = try #require(try NativeStore(url: storage.profile.database).episodes().first { $0.id == item.id })
    model.syncBusy = true; model.processingSpeech = true
    model.batchProgress = QueueBatchProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 8, completedArticles: 0, totalArticles: 2)
    model.uploadProgress[episode.id] = UploadProgress(episode: episode, phase: .transferring, sentBytes: 25, totalBytes: 100)
    for phase in [SyncPhase.readingList, .preparing, .speechCheck] {
        model.syncPhase = phase; #expect(model.syncProgressFraction == nil)
    }
    model.syncPhase = .generating; #expect(model.syncProgressFraction == 0.2)
    for phase in [SyncPhase.reconciling, .publishing] {
        model.syncPhase = phase
        #expect(model.syncProgressFraction == 0.25 && model.syncProgressLabel == "Uploading audio")
    }
    model.uploadProgress[episode.id] = UploadProgress(episode: episode, phase: .verifyingServer)
    #expect(model.syncProgressFraction == nil && model.syncProgressLabel == "Verifying server audio")
    model.uploadProgress = [:]; model.syncPhase = .reconciling
    #expect(model.syncProgressFraction == nil && model.syncProgressLabel == "Checking server audio")
    model.syncBusy = false; model.syncPhase = .generating
    #expect(model.syncProgressFraction == nil)
    await model.shutdown()
}

@Test @MainActor func manualSyncRefreshesAdmitsGeneratesAndPublishesWithoutChangingAutomation() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator(), sourceReads = SyncCounter(), fetches = SyncCounter(), checks = SyncCounter()
    func entry(_ id: String) -> ReadingListEntry {
        ReadingListEntry(id: id, safariID: nil, url: URL(string: "https://synthetic.example/\(id)")!, title: id, addedAt: Date())
    }
    let recorded = entry("recorded"), failed = entry("failed"), fresh = entry("fresh"), unreadable = entry("unreadable"), later = entry("later")
    let entries = [recorded, failed, fresh, unreadable, later]
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [recorded, failed], skippedEntries: 0), stateRoot: storage.stateRoot)
    let old = try await coordinator.enqueue(article("recorded"), storage: storage, preferences: SpeechPreferences(), sourceEntryID: recorded.id)
    try await coordinator.removeFromQueue(old.id, stateRoot: storage.stateRoot)
    var failedItem = try await coordinator.enqueue(article("failed"), storage: storage, preferences: SpeechPreferences(), sourceEntryID: failed.id)
    failedItem.state = .failed; failedItem.lastError = "Manual Retry required"
    do { try NativeStore(url: storage.profile.database).saveQueueItem(failedItem) }
    let transport = StubDeliveryTransport(), credentials = RecordingCredentials(password: "fixture")
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in
        fetches.increment()
        if url.lastPathComponent == "unreadable" { throw SourceFetchError.network }
        return try fetchFixture(url: url)
    }, defaults: defaults, deliveryTransport: { transport }, credentialStore: credentials,
        runtimeSetup: { _, _ in checks.increment() }, readingListReader: { _ in
            sourceReads.increment(); return ReadingListSnapshot(entries: entries, skippedEntries: 0)
        })
    model.sourceReview.plist = root.appendingPathComponent("Bookmarks.plist") // Only the injected reader sees this URL.
    model.deliverySettings = appDeliverySettings()
    model.autoAdmitEnabled = false; model.autoProcessEnabled = false; model.autoHalted = true
    model.syncNow(); model.syncNow() // Coalesced one-shot action.
    #expect(model.syncBusy && !model.canSyncNow && !model.canManageLibrary)
    await model.waitForSync()
    #expect(sourceReads.value == 1 && fetches.value == 3 && checks.value == 1)
    #expect(!model.autoAdmitEnabled && !model.autoProcessEnabled)
    #expect(!model.syncBusy && model.syncPhase == nil && model.syncProgressFraction == nil)
    #expect(model.sourceReview.catalog.entries.count == 5 && model.sourceReview.lastSyncedAt != nil)
    #expect(model.enqueueIssues.count == 1 && model.enqueueIssues[0].hasPrefix("unreadable"))
    #expect(model.queueItems.map(\.id) == [failedItem.id] && model.queueItems[0].state == .failed)
    let summary = try await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: model.deliverySettings)
    #expect(summary.uploadedMedia == 2 && !summary.needsDrain && model.deliveryError == nil)
    #expect(model.appHealth == .ready && credentials.reads.count == 1)
    let mediaPuts = transport.calls.filter { $0.method == "PUT" && $0.path.hasSuffix(".m4a") }.count
    model.syncNow(); await model.waitForSync()
    #expect(sourceReads.value == 2 && checks.value == 1 && fetches.value == 4) // Explicit retry of the unreadable, unrecorded source only.
    #expect(transport.calls.filter { $0.method == "PUT" && $0.path.hasSuffix(".m4a") }.count == mediaPuts)
    #expect(!model.autoAdmitEnabled && !model.autoProcessEnabled)
    await model.shutdown()
}

@Test @MainActor func manualSyncFailedSourceNeverProcessesStaleInventory() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let fetches = SyncCounter(), checks = SyncCounter(), transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in
        fetches.increment(); return try fetchFixture(url: url)
    }, defaults: defaults, deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "fixture"),
        runtimeSetup: { _, _ in checks.increment() }, readingListReader: { _ in throw SourceFetchError.network })
    model.sourceReview.plist = root.appendingPathComponent("Bookmarks.plist")
    model.sourceReview.lastSyncedAt = .distantPast
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [ReadingListEntry(id: "stale", safariID: nil,
        url: URL(string: "https://synthetic.example/stale")!, title: "Stale", addedAt: nil)], skippedEntries: 0))
    model.deliverySettings = appDeliverySettings()
    model.syncNow(); await model.waitForSync()
    #expect(model.sourceReview.error != nil && model.appHealth == .failure("Reading List unavailable", .general))
    #expect(fetches.value == 0 && checks.value == 0 && transport.calls.isEmpty && model.queueItems.isEmpty)
    #expect(!model.syncBusy && model.sourceReview.catalog.entries.count == 1)
    await model.shutdown()
}

@Test @MainActor func manualSyncStopDoesNotRestartReadyWorkOrChangeAutomation() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let entries = ["first", "second"].map { ReadingListEntry(id: $0, safariID: nil,
        url: URL(string: "https://synthetic.example/\($0)")!, title: $0, addedAt: nil) }
    let provider = GateProvider()
    let model = AppModel(storage: storage, backend: { _ in provider }, enqueueFetch: { try fetchFixture(url: $0) },
        defaults: defaults, runtimeSetup: { _, _ in }, readingListReader: { _ in ReadingListSnapshot(entries: entries, skippedEntries: 0) })
    model.sourceReview.plist = root.appendingPathComponent("Bookmarks.plist")
    model.syncNow()
    #expect(try await awaitMainActor { provider.synthesizeEntered })
    model.stopQueue(); provider.openGate()
    await model.waitForSync(); await model.waitForLibraryRefresh()
    #expect(!model.running && !model.syncBusy && model.autoHalted)
    #expect(!model.autoAdmitEnabled && !model.autoProcessEnabled)
    #expect(model.queueItems.count == 2 && model.queueItems.allSatisfy { $0.state == .queued })
    await model.shutdown()
}

@Test @MainActor func manualSyncQuitCancelsOwnedSourceReadAndInertReviewNeverStartsIt() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let reads = SyncCounter()
    let model = AppModel(storage: storage, defaults: defaults, readingListReader: { _ in
        reads.increment(); try await Task.sleep(for: .seconds(10)); return ReadingListSnapshot(entries: [], skippedEntries: 0)
    })
    model.sourceReview.plist = root.appendingPathComponent("Bookmarks.plist")
    model.libraryReviewRequired = true; model.syncNow()
    #expect(!model.syncBusy && reads.value == 0)
    model.libraryReviewRequired = false; model.preview = true; model.syncNow()
    #expect(!model.syncBusy && reads.value == 0)
    model.preview = false; model.syncNow()
    #expect(try await awaitMainActor { reads.value == 1 })
    await model.shutdown()
    #expect(!model.syncBusy && !model.sourceReview.synchronizing && model.syncPhase == nil)
}

@Test @MainActor func autoAdmitAddsCurrentEntriesAndSkipsRecordedOrAbsentOnes() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let recordedReview = try article("recorded")
    let recorded = ReadingListEntry(id: "recorded", safariID: nil, url: recordedReview.page.originalURL,
                                    title: "Recorded", addedAt: nil)
    let fresh = ReadingListEntry(id: "fresh", safariID: nil, url: URL(string: "https://synthetic.example/fresh")!,
                                 title: "Fresh", addedAt: nil)
    let absent = ReadingListEntry(id: "absent", safariID: nil, url: URL(string: "https://synthetic.example/absent")!,
                                  title: "Absent", addedAt: nil)
    // `recorded` already produced an episode whose queue entry was later removed; `absent` left the latest read.
    _ = try await coordinator.reconcile(
        ReadingListSnapshot(entries: [recorded, fresh, absent], skippedEntries: 0), stateRoot: storage.stateRoot)
    let recordedItem = try await coordinator.enqueue(recordedReview, storage: storage,
                                                     preferences: SpeechPreferences(), sourceEntryID: recorded.id)
    try await coordinator.removeFromQueue(recordedItem.id, stateRoot: storage.stateRoot)
    var catalog = try await coordinator.catalog(stateRoot: storage.stateRoot)
    catalog.reconcile(ReadingListSnapshot(entries: [recorded, fresh], skippedEntries: 0))
    let fetches = SyncCounter()
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in
        fetches.increment()
        return try fetchFixture(url: url)
    })
    model.sourceReview.catalog = catalog
    // Disabled auto-admit does nothing.
    model.autoAdmitEnabled = false
    await model.autoAdmitNewEntries()
    #expect(model.pendingAdds.isEmpty && fetches.value == 0)
    model.autoAdmitEnabled = true
    await model.autoAdmitNewEntries()
    await model.waitForEnqueue()
    // Only the fresh current entry was admitted; recorded (prior snapshot) and absent (not current) are skipped.
    #expect(model.queueItems.count == 1 && model.queueItems.first?.sourceEntryID == fresh.id)
    #expect(fetches.value == 1 && model.enqueueIssues.isEmpty)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.sourceEntryID) == [fresh.id])
    // A second pass finds nothing new to admit.
    await model.autoAdmitNewEntries()
    #expect(fetches.value == 1 && model.pendingAdds.isEmpty)
    await model.shutdown()
}

@Test @MainActor func failedAutoAdmissionStaysRetriedOutForSessionButManualBypasses() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let entry = ReadingListEntry(id: "flaky", safariID: nil, url: URL(string: "https://synthetic.example/flaky")!,
                                 title: "Flaky", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0),
                                                  stateRoot: storage.stateRoot)
    let calls = SyncCounter(), fail = MutableFlag(true)
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, enqueueFetch: { url in
        calls.increment()
        if fail.on { throw SourceFetchError.network }
        return try fetchFixture(url: url)
    })
    model.sourceReview.catalog = catalog
    model.autoAdmitEnabled = true
    await model.autoAdmitNewEntries()
    await model.waitForEnqueue()
    #expect(calls.value == 1 && model.queueItems.isEmpty && model.enqueueIssues.count == 1)
    // Automatic admission does not retry the failed entry in this session.
    await model.autoAdmitNewEntries()
    #expect(calls.value == 1 && model.pendingAdds.isEmpty)
    // Manual Add to Queue bypasses the attempt set.
    fail.set(false)
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    await model.waitForEnqueue()
    #expect(calls.value == 2 && model.queueItems.count == 1 && model.enqueueIssues.isEmpty)
    await model.shutdown()
}

@Test @MainActor func autoProcessDrainsReadyQueueAndStopHaltsUntilNewWorkOrGenerate() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    // Disabled automation leaves ready items waiting for a manual Generate.
    model.queueItems = [item]
    model.maybeAutoProcess()
    #expect(!model.running)
    model.autoProcessEnabled = true
    model.maybeAutoProcess()
    #expect(model.running)
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(!model.running && model.queueItems.isEmpty && model.result?.episode.id == item.id)
    // Explicit Stop suspends automation.
    let second = try await coordinator.enqueue(article("second"), storage: storage, preferences: SpeechPreferences())
    model.queueItems = [second]
    model.autoHalted = true
    model.maybeAutoProcess()
    #expect(!model.running)
    // Manual Generate clears the halt and resumes.
    model.runQueue()
    #expect(model.running && !model.autoHalted)
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    await model.shutdown()
}

@Test @MainActor func stopQueueSuspendsAutomationUntilAutoAdmissionArrives() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let provider = GateProvider()
    let model = AppModel(storage: storage, backend: { _ in provider }, enqueueFetch: { url in try fetchFixture(url: url) })
    model.autoProcessEnabled = true; model.autoAdmitEnabled = true
    model.queueItems = [first]
    model.runQueue()
    #expect(try await awaitMainActor { provider.synthesizeEntered })
    model.stopQueue()
    provider.openGate()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(model.autoHalted && !model.running)
    // A newly discovered entry resumes automation: admission clears the halt.
    let entry = ReadingListEntry(id: "new", safariID: nil, url: URL(string: "https://synthetic.example/new")!,
                                 title: "New", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0),
                                                  stateRoot: storage.stateRoot)
    model.sourceReview.catalog = catalog
    await model.autoAdmitNewEntries()
    await model.waitForEnqueue()
    #expect(!model.autoHalted)
    // The committed admission resumes processing; the stopped item and the new one drain.
    provider.openGate()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(model.savedEpisodes.count == 2)
    await model.shutdown()
}

@Test @MainActor func launchRefreshRereadiesInterruptedItemsWhenAutomationEnabled() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    var runningItem = item; runningItem.state = .running; runningItem.attempts = 1
    try NativeStore(url: storage.profile.database).saveQueueItem(runningItem)
    // A failed item stays manual-Retry even with automation on.
    let failed = try await coordinator.enqueue(article("failed"), storage: storage, preferences: SpeechPreferences())
    var failedItem = failed; failedItem.state = .failed; failedItem.lastError = "Synthetic failure"
    try NativeStore(url: storage.profile.database).saveQueueItem(failedItem)
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    model.autoProcessEnabled = true
    model.refreshLibrary()
    await model.waitForLibraryRefresh()
    await model.waitForProcessing()
    await model.waitForLibraryRefresh()
    #expect(!model.running)
    // The interrupted item was re-readied and processed; the failed one was untouched.
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == [failed.id] && queue.first?.state == .failed)
    #expect(model.savedEpisodes.contains { $0.id == item.id })
    await model.shutdown()
}

@Test @MainActor func savedAudioMetaFormatsDurationAndSize() throws {
    let model = AppModel(preview: true)
    func episode(duration: Double?, bytes: Int64) -> Episode {
        var episode = Episode(id: "e", title: "T", stage: .published,
                              settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/tmp")))
        if let duration {
            episode.info = AudioInfo(duration: duration, byteLength: bytes, sampleRate: 24000, channels: 1, codec: "aac")
        }
        return episode
    }
    #expect(AppModel.durationString(0) == "0:00")
    #expect(AppModel.durationString(59.6) == "1:00")
    #expect(AppModel.durationString(272) == "4:32")
    #expect(AppModel.durationString(3661) == "1:01:01")
    #expect(AppModel.durationString(-5) == "0:00")
    #expect(model.savedAudioMeta(episode(duration: nil, bytes: 0)) == nil)
    #expect(model.savedAudioMeta(episode(duration: 0, bytes: 512)) == "Audio · 0:00 · 512 bytes")
    let meta = try #require(model.savedAudioMeta(episode(duration: 3661, bytes: 3_250_000)))
    #expect(meta.hasPrefix("Audio · 1:01:01 · ") && meta.contains("MB"))
}

@Test @MainActor func deliveryPaneAndAutomationControlsConstructInertly() throws {
    let model = AppModel(preview: true)
    _ = DeliveryPaneView(model: model).body
    _ = SettingsView(model: model, initialSection: .delivery)
    #expect(!model.deliveryBusy && !model.deliveryTesting && model.deliveryTestResult == .untested)
    #expect(!model.autoAdmitEnabled && !model.autoProcessEnabled && !model.autoHalted)
}

@Test @MainActor func deliveryCredentialIdentityAndKeychainErrorsAreConsistent() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    var settings = appDeliverySettings(enabled: false)
    settings.username = "  user@example.com\n"
    defaults.set(try JSONEncoder().encode(settings), forKey: "deliverySettings")
    let credentials = RecordingCredentials()
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: credentials)
    #expect(model.deliverySettings.username == "user@example.com")
    // Programmatic values also use the same normalized identity for save/read/delete.
    model.deliverySettings.username = " user@example.com\n"
    model.deliveryPassword = "pw"
    model.saveDeliveryPassword(); await model.waitForCredentialMutation()
    #expect(credentials.writes.last?.username == "user@example.com")
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(credentials.reads.isEmpty) // successful save already populated the shared session
    #expect(model.deliveryTestResult == .success)
    model.deliveryPassword = "replacement"
    #expect(model.deliveryTestResult == .untested)
    credentials.readError = NSError(domain: "private endpoint and password", code: 1)
    model.deliverySettings.feedFolderURL = URL(string: "https://fresh.example/files/")
    let callsBefore = transport.calls.count
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .failure(DeliveryError.credentialNotice))
    #expect(transport.calls.count == callsBefore)
    credentials.readError = DeliveryError.credentialUnavailable("Keychain access was cancelled. Try again.")
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .failure("Keychain access was cancelled. Try again."))
    credentials.readError = nil
    transport.statusFor = { _ in 403 }
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .failure(DeliveryError.permissionNotice))
    model.clearDeliveryPassword(); await model.waitForCredentialMutation()
    #expect(credentials.deletes.last?.username == "user@example.com" && !model.deliveryPasswordStored)
    await model.shutdown()
}

private actor HeldDeliveryTransport: DeliveryTransport {
    private var continuation: CheckedContinuation<DeliveryResponse, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var started = false
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        started = true; entered?.resume(); entered = nil
        // Deliberately ignores cancellation to exercise stale-result guards.
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { entered = $0 } }
    }
    func finish() {
        continuation?.resume(returning: DeliveryResponse(status: 403)); continuation = nil
    }
}

@Test @MainActor func deliverySettingsEditDiscardsInFlightTestResult() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let transport = HeldDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
                         credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings(enabled: false)
    model.testDeliveryConnection()
    await transport.waitUntilStarted()
    model.deliverySettings.username = "new@example.com"
    #expect(model.deliveryTestResult == .untested)
    await transport.finish()
    await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .untested && !model.deliveryTesting)
    await model.shutdown()
}

@Test @MainActor func deliveryDebugLoggingPreferencePersistsAndPreviewsStayInert() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = RecordingCredentials(password: "secret")
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { StubDeliveryTransport() }, credentialStore: credentials)
    #expect(!model.debugLoggingEnabled && model.deliveryDebugLog.text.isEmpty)
    model.debugLoggingEnabled = true
    model.deliverySettings = appDeliverySettings(enabled: false)
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryDebugLog.text.contains("PROPFIND HTTP 207"))
    #expect(!model.deliveryDebugLog.text.contains("secret"))
    let reloaded = AppModel(storage: storage, defaults: defaults, credentialStore: credentials)
    #expect(reloaded.debugLoggingEnabled && reloaded.deliveryDebugLog.enabled)
    let retained = model.deliveryDebugLog.text
    model.debugLoggingEnabled = false
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryDebugLog.text == retained)
    let preview = AppModel(preview: true, defaults: defaults)
    preview.debugLoggingEnabled = true
    #expect(!preview.deliveryDebugLog.enabled && !defaults.bool(forKey: "debugLoggingEnabled"))
    _ = DeliveryDebugControls(model: preview).body
    await model.shutdown(); await reloaded.shutdown(); await preview.shutdown()
}

@Test @MainActor func deliveryTestsAndDrainsShareOneCredentialSession() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = RecordingCredentials(password: "pw")
    let transport = StubDeliveryTransport()
    let item = try await FixtureCoordinator().enqueue(article("session"), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, defaults: defaults,
        deliveryTransport: { transport }, credentialStore: credentials)
    model.deliverySettings = appDeliverySettings(enabled: false)
    for _ in 0..<4 { model.refreshDeliveryCredentialState() }
    #expect(credentials.reads.isEmpty && !model.deliveryPasswordChecked)
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryPasswordStored && model.deliveryPasswordChecked)
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    model.queueItems = [item]; model.runQueue(); await model.waitForProcessing()
    model.deliverySettings.enabled = true
    model.triggerDelivery(force: true); await model.waitForDelivery()
    model.triggerDelivery(force: true); await model.waitForDelivery()
    #expect(credentials.reads.count == 1 && transport.calls.contains { $0.method == "PUT" })
    await model.shutdown()
    #expect(!model.deliveryPasswordStored && !model.deliveryPasswordChecked)
    let reloaded = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: credentials)
    reloaded.testDeliveryConnection(); await reloaded.waitForDeliveryTest()
    #expect(credentials.reads.count == 2)
    await reloaded.shutdown()
}

@Test @MainActor func deliveryCollectionFailureDoesNotReportUpToDateWithNoPendingMedia() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    // Initialize an isolated library with no finalized/pending delivery media.
    _ = try await FixtureCoordinator().enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let transport = StubDeliveryTransport()
    transport.statusFor = { method in method == "PROPFIND" ? 403 : nil }
    let model = AppModel(storage: storage, defaults: defaults,
        deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings()
    model.triggerDelivery(force: true); await model.waitForDelivery()
    #expect(model.deliveryPendingCount == 0 && model.deliveryError != nil)
    #expect(model.deliveryStatus == "Publishing needs attention")
    transport.statusFor = nil
    model.triggerDelivery(force: true); await model.waitForDelivery()
    #expect(model.deliveryError == nil)
    model.triggerDelivery(force: true); await model.waitForDelivery()
    #expect(model.deliveryStatus == "Publishing up to date")
    await model.shutdown()
}

@Test @MainActor func deliveryURLDraftsNormalizeAtomicallyAndExposeSubscriptionURL() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
                         credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings()
    model.deliveryTestResult = .success
    #expect(model.updateDeliveryURLs(feedFolder: "  webdav.example//old/../podcast  ",
                                    publicFolder: "public.example/show/feed.xml#anchor"))
    #expect(model.deliverySettings.feedFolderURL?.absoluteString == "https://webdav.example/podcast/")
    #expect(model.deliverySettings.publicFolderURL?.absoluteString == "https://public.example/show/")
    #expect(model.deliverySubscriptionURL?.absoluteString == "https://public.example/show/feed.xml")
    #expect(model.deliveryTestResult == .untested)
    let saved = model.deliverySettings
    model.testDeliveryConnection()
    // Blur/submit commits an equivalent URL after Test has started; it must not cancel.
    #expect(model.updateDeliveryURLs(feedFolder: "webdav.example/podcast", publicFolder: "public.example/show/"))
    await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .success)
    let count = transport.calls.count
    #expect(!model.updateDeliveryURLs(feedFolder: "https://other.example/show", publicFolder: "https://user:secret@public.example/show"))
    #expect(model.deliverySettings == saved && transport.calls.count == count)
    if case .failure(let message) = model.deliveryTestResult {
        #expect(message.contains("separate fields") && !message.contains("secret"))
    } else { Issue.record("Invalid input did not surface a friendly error") }
    let bytes = try #require(defaults.data(forKey: "deliverySettings"))
    #expect(try JSONDecoder().decode(DeliverySettings.self, from: bytes) == saved)
    await model.shutdown()
}

@Test @MainActor func deliveryConnectionReportsMissingAudioWithoutCreatingIt() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubDeliveryTransport()
    transport.statusForPath = { method, path in method == "PROPFIND" && path.hasSuffix("/audio") ? 404 : nil }
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
                         credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings()
    model.testDeliveryConnection(); await model.waitForDeliveryTest()
    #expect(model.deliveryTestResult == .foldersPending)
    #expect(transport.calls.map(\.method) == ["PROPFIND", "PROPFIND"])
    await model.shutdown()
}

@Test @MainActor func readingListChecksStartupFiveMinuteIntervalsAndPullRefresh() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let reads = SyncCounter(), waits = SyncCounter(), releases = SyncCounter()
    let entries = (1...3).map { index in ReadingListEntry(id: "safari:new-\(index)", safariID: nil,
        url: URL(string: "https://articles.example/\(index)")!, title: "New \(index)", addedAt: nil) }
    let model = SourceReviewModel(stateRoot: root.appendingPathComponent("state"), plist: plist,
        waitForNextSync: { interval in
            #expect(interval == .seconds(300))
            waits.increment(); let count = waits.value
            while releases.value < count { try await Task.sleep(for: .milliseconds(10)) }
        }, snapshotReader: { _ in
            reads.increment()
            return ReadingListSnapshot(entries: Array(entries.prefix(reads.value)), skippedEntries: 0)
        })
    model.startAutomaticSynchronization()
    try await waitUntil("startup committed fresh entries") { model.catalog.entries.count == 1 && waits.value == 1 }
    #expect(model.lastSyncedAt != nil && reads.value == 1)
    model.startAutomaticSynchronization() // Starting again must not duplicate the timer.
    releases.increment()
    try await waitUntil("periodic read committed another entry") { model.catalog.entries.count == 2 && waits.value == 2 }
    await model.refreshSource() // Same awaited action used by native refreshable.
    #expect(model.catalog.entries.count == 3 && reads.value == 3 && model.error == nil)
    #expect(try await FixtureCoordinator().catalog(stateRoot: root.appendingPathComponent("state")).entries.count == 3)
    await model.stop()
    await model.refreshSource()
    #expect(reads.value == 3 && !model.synchronizing)
}

@Test @MainActor func pullRefreshRereadsReplacedSourceFileAndKeepsSafariInputReadOnly() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    func bytes(_ count: Int) throws -> Data {
        let children: [[String: Any]] = (1...count).map { ["URLString": "https://articles.example/new-\($0)",
            "WebBookmarkUUID": "entry-\($0)", "URIDictionary": ["title": "New \($0)"]] }
        return try PropertyListSerialization.data(fromPropertyList: ["Title": "com.apple.ReadingList", "Children": children], format: .binary, options: 0)
    }
    let first = try bytes(1); try first.write(to: plist, options: .atomic)
    let model = SourceReviewModel(stateRoot: root.appendingPathComponent("state"), plist: plist)
    await model.refreshSource()
    #expect(model.catalog.entries.count == 1 && model.error == nil)
    let next = try bytes(2); try next.write(to: plist, options: .atomic)
    await model.refreshSource()
    #expect(model.catalog.entries.count == 2 && model.catalog.currentIDs.count == 2)
    #expect(try Data(contentsOf: plist) == next)
    await model.stop()
}

@Test @MainActor func serverAudioHistorySurvivesTemporaryCleanupAndRelaunchThenRemovesRemoteEpisode() async throws {
    let (root, persistent) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: persistent.audioDirectory, stateRoot: persistent.stateRoot,
        temporaryRoot: persistent.temporaryRoot, temporaryAudio: true)
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = appDeliverySettings(), coordinator = FixtureCoordinator(), transport = StubDeliveryTransport()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences())
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, defaults: defaults,
        deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings; model.queueItems = [item]; model.runQueue()
    await model.waitForProcessing(); await model.waitForDelivery(); await model.waitForLibraryRefresh()
    #expect(model.error == nil && model.deliveryError == nil)
    let saved = try #require(model.savedEpisodes.first)
    #expect(saved.localAudioReleased == true && model.savedAudioDeliveryStatus(saved) == .published)
    #expect(!model.showsUploadNewItems && !FileManager.default.fileExists(atPath: storage.audioDirectory.appendingPathComponent(item.id + ".m4a").path))
    await model.shutdown()
    let relaunched = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, defaults: defaults,
        deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    relaunched.refreshLibrary(); await relaunched.waitForLibraryRefresh()
    #expect(relaunched.savedEpisodes.map(\.id) == [item.id])
    #expect(relaunched.savedAudioDeliveryStatus(try #require(relaunched.savedEpisodes.first)) == .published)
    relaunched.removeSavedAudio(ids: [item.id])
    await relaunched.waitForAudioMutation(); await relaunched.waitForDelivery(); await relaunched.waitForLibraryRefresh()
    #expect(relaunched.error == nil && relaunched.savedEpisodes.isEmpty)
    #expect(transport.calls.contains { $0.method == "DELETE" && $0.path.hasSuffix(item.id + ".m4a") })
    await relaunched.shutdown()
}

@Test @MainActor func deliveryFailureHistoryRefreshDoesNotCreateImmediateRetryLoop() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = appDeliverySettings(), coordinator = FixtureCoordinator(), transport = StubDeliveryTransport()
    _ = try await coordinator.runReviewed(root: storage.stateRoot, review: article(), backend: SyntheticProvider(), storage: storage, delivery: settings)
    transport.statusForPath = { method, path in method == "PUT" && path.hasSuffix("feed.xml") ? 503 : nil }
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings; model.debugLoggingEnabled = true; model.triggerDelivery()
    await model.waitForDelivery(); await model.waitForLibraryRefresh()
    // Allow dispatched completion/refresh callbacks to settle; there is no periodic loop in this fixture.
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.deliveryDebugLog.text.components(separatedBy: "delivery: started").count - 1 == 1)
    #expect(model.savedEpisodes.count == 1 && model.deliveryError != nil && model.showsUploadNewItems)
    await model.shutdown()
}

@Test @MainActor func remoteHistoryDoesNotMaskUnavailableUnuploadedLocalAudio() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator()
    var unavailable = try await coordinator.runReviewed(root: storage.stateRoot, review: article("unavailable"), backend: SyntheticProvider(), storage: storage).episode
    var remote = try await coordinator.runReviewed(root: storage.stateRoot, review: article("remote"), backend: SyntheticProvider(), storage: storage).episode
    unavailable.audioVolumeID = "unavailable-fixture-volume"
    remote.delivery = DeliveryState(status: .uploaded, remotePath: appDeliverySettings().remoteMediaPath(remote.id))
    remote.delivery?.uploadedByteLength = remote.info?.byteLength
    remote.delivery?.destinationURL = appDeliverySettings().feedFolderURL
    try NativeStore(url: storage.profile.database).save(unavailable)
    try NativeStore(url: storage.profile.database).save(remote)
    let model = AppModel(storage: storage, defaults: defaults)
    model.refreshLibrary(); await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.map(\.id) == [remote.id])
    #expect(model.audioCleanupError == "Some saved audio is unavailable. Reconnect its original storage or restore access.")
    await model.shutdown()
}

/// Hold DELETE so tests can inspect the actual pending-removal row, without live I/O.
private actor ServerDeletionGate: DeliveryTransport {
    private let base = StubDeliveryTransport()
    private var armed = false
    private var held = false
    private var failure = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm(failure: Bool) { armed = true; self.failure = failure }
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        if armed && !held && method == "DELETE" {
            held = true
            let timeout = Task { try? await Task.sleep(for: .seconds(10)); self.release() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { await self.release() } }
            timeout.cancel(); try Task.checkCancellation()
        }
        if method == "DELETE" && failure { return DeliveryResponse(status: 503) }
        return try await base.request(method, url: url, body: body, file: file, headers: headers)
    }
    func waitUntilHeld() async throws {
        let end = Date().addingTimeInterval(5)
        while continuation == nil && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        guard continuation != nil else { throw RelayError.tool("Synthetic server deletion did not start.") }
    }
    func release() { continuation?.resume(); continuation = nil }
    func clearFailure() { failure = false }
}

@Test(arguments: [false, true]) @MainActor func serverAudioRemovalStaysVisibleUntilConfirmedAndClicksAreSafe(failDeletion: Bool) async throws {
    let (root, original) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: original.audioDirectory, stateRoot: original.stateRoot,
        temporaryRoot: original.temporaryRoot, temporaryAudio: true)
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let settings = appDeliverySettings(), transport = ServerDeletionGate(), coordinator = FixtureCoordinator()
    defer { Task { await transport.release() } }
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: article(), backend: SyntheticProvider(), storage: storage, delivery: settings)
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport }, credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = settings; model.triggerDelivery()
    await model.waitForDelivery(); await model.waitForLibraryRefresh()
    let ids = [result.episode.id]
    #expect(model.savedEpisodes.map(\.id) == ids)
    await transport.arm(failure: failDeletion)
    model.removeSavedAudio(ids: ids)
    #expect(model.savedEpisodes.map(\.id) == ids)
    #expect(model.savedAudioRemovalStatus(try #require(model.savedEpisodes.first)) == "Removing from server…")
    await model.waitForAudioMutation(); try await transport.waitUntilHeld()
    model.refreshLibrary(); await model.waitForLibraryRefresh()
    let pending = try #require(model.savedEpisodes.first)
    #expect(model.savedEpisodes.map(\.id) == ids && pending.stage == .expired)
    #expect(model.savedAudioRemovalStatus(pending) == "Removing from server…" && !model.canRemoveSavedAudio(pending))
    model.removeSavedAudio(ids: ids) // Simulate a repeated action while DELETE is in flight.
    #expect(model.error == nil && !model.audioMutationBusy)
    await transport.release(); await model.waitForDelivery(); await model.waitForLibraryRefresh()
    if failDeletion {
        let failed = try #require(model.savedEpisodes.first)
        #expect(model.savedAudioRemovalStatus(failed) == "Removal needs retry" && model.canRemoveSavedAudio(failed))
        await transport.clearFailure()
        model.removeSavedAudio(ids: ids)
        await model.waitForAudioMutation(); await model.waitForDelivery(); await model.waitForLibraryRefresh()
    }
    #expect(model.savedEpisodes.isEmpty && model.error == nil)
    model.removeSavedAudio(ids: ids) // Simulate a stale action after the row is removed.
    #expect(model.error == nil && !model.audioMutationBusy)
    await model.shutdown()
}

@Test @MainActor func archivedArticleSettingPersistsAndQueueAdmissionUsesInjectedRecovery() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let source = URL(string: "https://synthetic.example/archived")!
    let entry = ReadingListEntry(id: "cached", safariID: nil, url: source, title: "Cached article", addedAt: nil)
    let model = AppModel(storage: storage, enqueueFetch: { _ in throw SourceFetchError.status(404) },
        archiveFetch: { url, _, _, _ in
            let html: String, type: String
            if url.path.hasPrefix("/timemap/") {
                html = "<https://synthetic.example/archived>; rel=\"original\", <https://archive.ph/Abc12>; rel=\"memento\"; datetime=\"Thu, 01 Jan 2026 00:00:00 GMT\""
                type = "application/link-format"
            } else { html = String(decoding: try FixtureResource.html(), as: UTF8.self); type = "text/html" }
            return FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: type, encoding: "utf-8", fetchedAt: .distantPast)
        }, defaults: defaults)
    #expect(!model.useArchivedArticles)
    model.useArchivedArticles = true
    #expect(defaults.bool(forKey: "useArchivedArticles"))
    model.autoAdmitEnabled = false; model.autoProcessEnabled = false
    model.sourceReview.catalog = try await model.coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    try await waitUntil("Archived article queued") { model.pendingAdds.isEmpty && model.queueItems.count == 1 }
    #expect(model.queueItems.first?.sourceHost == "synthetic.example" && model.enqueueIssues.isEmpty)
    _ = ConfigurationView(model: model).body
    let preview = AppModel(preview: true, defaults: defaults)
    preview.useArchivedArticles = false
    #expect(defaults.bool(forKey: "useArchivedArticles"))
    await model.shutdown()
}

@Test @MainActor func uploadsLocalRemovalHonorsOwnershipGatesAndClearsOnlyLocalOutbox() async throws {
    let (root, base) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: base.audioDirectory, stateRoot: base.stateRoot,
        temporaryRoot: base.temporaryRoot, temporaryAudio: true)
    let generated = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: article(),
        backend: SyntheticProvider(), storage: storage)
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() }, defaults: defaults)
    model.savedEpisodes = [generated.episode]
    let item = try #require(model.uploadItems.first)
    #expect(model.canDiscardLocalUpload(item))
    model.libraryReviewRequired = true
    #expect(!model.canDiscardLocalUpload(item)); model.discardLocalUpload(item)
    #expect(FileManager.default.fileExists(atPath: generated.audioURL.path))
    model.libraryReviewRequired = false; model.deliveryBusy = true
    #expect(!model.canDiscardLocalUpload(item))
    model.deliveryBusy = false; model.running = true
    #expect(!model.canDiscardLocalUpload(item))
    model.running = false
    model.discardLocalUpload(item)
    #expect(model.audioMutationBusy && !model.canDiscardLocalUpload(item))
    await model.waitForAudioMutation()
    #expect(!model.audioMutationBusy && model.uploadItems.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: generated.audioURL.path))
    #expect(model.savedEpisodes.count == 1 && model.savedEpisodes[0].stage == .published)
    #expect(model.audioState(model.savedEpisodes[0]).phase == .discarded)
    #expect(!model.hasNewItemsToUpload)
    await model.shutdown()
}

@Test @MainActor func removingReadingListEntryStopsOwnedSpeechBeforePurgingItsCaches() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("removed"), coordinator = FixtureCoordinator(), provider = CancellableProvider(holdCleanup: true)
    let entry = ReadingListEntry(id: "removed", safariID: nil, url: review.page.originalURL, title: "Removed", addedAt: .distantPast)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id)
    let model = AppModel(storage: storage, backend: { _ in provider })
    model.sourceReview.catalog = catalog; model.queueItems = [item]; model.articleSelection = [entry.id]
    model.runQueue()
    try await waitUntil("owned speech started") { provider.started }
    model.sourceReview.catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
    model.catalogDidChange(removed: [entry])
    #expect(model.allArticleRows.isEmpty && model.articleSelection.isEmpty && model.sourcePruningBusy)
    try await waitUntil("removed work stopping") { model.cancelling }
    #expect(try await coordinator.library(storage: storage).count == 1)
    provider.allowCleanup()
    await model.waitForSourcePruning()
    #expect(provider.finished && !model.running && !model.sourcePruningBusy)
    #expect(try await coordinator.library(storage: storage).isEmpty)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(!model.autoHalted)
    await model.shutdown()
}

@Test @MainActor func removingReadingListEntryCancelsPendingAdmissionWithoutLateRows() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("removed"), coordinator = FixtureCoordinator(), gate = FetchGate()
    let entry = ReadingListEntry(id: "removed", safariID: nil, url: review.page.originalURL, title: "Removed", addedAt: nil)
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let model = AppModel(storage: storage, enqueueFetch: { url in try await gate.wait(for: url) })
    model.sourceReview.catalog = catalog; model.articleSelection = [entry.id]
    model.addSelectedToQueue()
    #expect(model.pendingAdds.count == 1)
    model.sourceReview.catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
    model.catalogDidChange(removed: [entry])
    gate.openGate()
    await model.waitForEnqueue(); await model.waitForSourcePruning(); await model.waitForLibraryRefresh()
    #expect(model.allArticleRows.isEmpty && model.pendingAdds.isEmpty && model.enqueueIssues.isEmpty)
    #expect(try await coordinator.library(storage: storage).isEmpty)
    await model.shutdown()
}

@Test @MainActor func removedArticleCleanupWaitsForFinishLibraryReview() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("removed"), coordinator = FixtureCoordinator()
    let entry = ReadingListEntry(id: "removed", safariID: nil, url: review.page.originalURL, title: "Removed", addedAt: nil)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id)
    let model = AppModel(storage: storage)
    model.libraryReviewRequired = true
    model.sourceReview.catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0), stateRoot: storage.stateRoot)
    model.catalogDidChange(removed: [entry]); await model.waitForLibraryRefresh()
    #expect(model.allArticleRows.isEmpty && !model.sourcePruningBusy)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: item.id) != nil)
    model.libraryReviewRequired = false
    model.refreshLibrary(allowDelivery: false); await model.waitForLibraryRefresh()
    #expect(try await coordinator.library(storage: storage).isEmpty)
    await model.shutdown()
}

@Test @MainActor func deliverySettingsBookkeepingCoalescesAndJoinsOnQuit() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    do { _ = try NativeStore(url: ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)) }
    var ledger = DeliveryLedger(); ledger.settingsHash = try appDeliverySettings().settingsHash(); ledger.remoteFeedPending = false
    try ledger.save(stateRoot: storage.stateRoot)
    let model = AppModel(storage: storage, defaults: defaults)
    model.deliverySettings = appDeliverySettings(); model.deliveryConnectionVerified = true
    model.deliverySettings.channelTitle = "First edit"
    model.deliverySettings.channelTitle = "Final edit"
    #expect(!model.deliveryConnectionVerified)
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).remoteFeedPending == false)
    await model.waitForSettingsBookkeeping()
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).remoteFeedPending)
    ledger.remoteFeedPending = false; try ledger.save(stateRoot: storage.stateRoot)
    model.deliverySettings.channelTitle = "Cancelled edit"
    await model.shutdown()
    await model.waitForSettingsBookkeeping()
    #expect(try DeliveryLedger.load(stateRoot: storage.stateRoot).remoteFeedPending == false)
}

private final class PublishingPreflightGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    private var mainThread = false
    var entered: Bool { lock.withLock { started } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }
    func hold() {
        lock.withLock { started = true; mainThread = Thread.isMainThread }
        _ = release.wait(timeout: .now() + 5)
    }
    func open() { release.signal() }
}

@Test @MainActor func directPublishingPreflightKeepsMainActorResponsiveAndCoalescesRetries() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suite) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubDeliveryTransport()
    let model = AppModel(storage: storage, defaults: defaults, deliveryTransport: { transport },
                         credentialStore: RecordingCredentials(password: "pw"))
    model.deliverySettings = appDeliverySettings()
    // First-session reconciliation needs no ledger readiness read.
    model.triggerDelivery(); await model.waitForDelivery(); await model.waitForLibraryRefresh()
    let gate = PublishingPreflightGate(); defer { gate.open() }
    await model.coordinator.setBeforeDeliveryPreflight { gate.hold() }
    model.triggerDelivery(force: true)
    #expect(model.deliveryBusy && model.deliveryPreflightBusy)
    try await waitUntil("publishing preflight entered off the main actor") { gate.entered }
    #expect(!gate.ranOnMainThread)
    // A separate UI task runs while disk preflight is deliberately stalled.
    let heartbeat = Task { @MainActor in true }
    #expect(await heartbeat.value)
    model.triggerDelivery() // Coalesces rather than blocking or opening another worker.
    gate.open()
    await model.coordinator.setBeforeDeliveryPreflight(nil)
    await model.waitForDelivery(); await model.waitForLibraryRefresh()
    #expect(!model.deliveryBusy && !model.deliveryPreflightBusy && model.deliveryError == nil)
    await model.shutdown()
}

@Test @MainActor func retargetingReadingListEntryStopsOwnedSpeechAndAdmitsReplacement() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("old-address"), replacement = try article("new-address")
    let coordinator = FixtureCoordinator(), provider = CancellableProvider(holdCleanup: true)
    defer { provider.allowCleanup() }
    let original = ReadingListEntry(id: "safari:stable", safariID: "stable", url: review.page.originalURL, title: "Original", addedAt: .distantPast)
    let updated = ReadingListEntry(id: original.id, safariID: original.safariID, url: replacement.page.originalURL, title: "Replacement", addedAt: original.addedAt)
    let catalog = try await coordinator.reconcile(.init(entries: [original], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: .init(), sourceEntryID: original.id)
    let model = AppModel(storage: storage, backend: { episode in
        if episode.id == item.id { return provider }
        return SyntheticProvider()
    },
        enqueueFetch: { _ in replacement.page }, readingListReader: { _ in .init(entries: [updated], skippedEntries: 0) })
    model.sourceReview.plist = root.appendingPathComponent("synthetic-source.plist")
    model.sourceReview.catalog = catalog; model.queueItems = [item]
    model.autoAdmitEnabled = true; model.autoProcessEnabled = false
    model.runQueue()
    try await waitUntil("retargeted source speech started") { provider.started }
    #expect(await model.sourceReview.synchronizeOnce())
    try await waitUntil("retargeted source stops before cleanup") { model.cancelling && model.sourcePruningBusy }
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: item.id) != nil)
    provider.allowCleanup()
    await model.waitForSourcePruning()
    try await waitUntil("replacement source admitted after pruning") { model.pendingAdds[updated.id] != nil || model.queueItems.contains { $0.id != item.id && $0.sourceEntryID == updated.id } }
    await model.waitForEnqueue(); await model.waitForLibraryRefresh()
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    let replacementItem = try #require(queue.first { $0.sourceEntryID == updated.id })
    #expect(provider.finished && !model.running && queue.count == 1 && replacementItem.id != item.id)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: item.id) == nil)
    #expect(try await coordinator.articlePreviewURL(articleID: replacementItem.id, stateRoot: storage.stateRoot) == updated.url)
    await model.shutdown()
}

@Test @MainActor func retargetedEntryWithDuplicateOriginalURLPreservesJobAndAdmitsReplacement() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("retained-address"), replacement = try article("replacement-address"), coordinator = FixtureCoordinator()
    let original = ReadingListEntry(id: "safari:stable", safariID: "stable", url: review.page.originalURL, title: "Original", addedAt: .distantPast)
    let updated = ReadingListEntry(id: original.id, safariID: original.safariID, url: replacement.page.originalURL, title: "Replacement", addedAt: original.addedAt)
    let retained = ReadingListEntry(id: "safari:retained", safariID: "retained", url: original.url, title: original.title, addedAt: original.addedAt)
    let catalog = try await coordinator.reconcile(.init(entries: [original], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: .init(), sourceEntryID: original.id)
    let model = AppModel(storage: storage, enqueueFetch: { _ in replacement.page },
        readingListReader: { _ in .init(entries: [updated, retained], skippedEntries: 0) })
    model.sourceReview.plist = root.appendingPathComponent("synthetic-source.plist")
    model.sourceReview.catalog = catalog; model.queueItems = [item]
    model.autoAdmitEnabled = true; model.autoProcessEnabled = false
    #expect(await model.sourceReview.synchronizeOnce())
    try await waitUntil("replacement source admitted beside retained original") { model.pendingAdds[updated.id] != nil || model.queueItems.count == 2 }
    await model.waitForEnqueue(); await model.waitForLibraryRefresh()
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    let retainedItem = try #require(queue.first { $0.id == item.id })
    #expect(queue.count == 2 && retainedItem.sourceEntryID == retained.id && retainedItem.state == item.state && retainedItem.attempts == item.attempts)
    #expect(!model.sourcePruningBusy)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: item.id) != nil)
    let replacementItem = try #require(queue.first { $0.sourceEntryID == updated.id })
    #expect(try await coordinator.articlePreviewURL(articleID: replacementItem.id, stateRoot: storage.stateRoot) == updated.url)
    await model.shutdown()
}

@Test @MainActor func retargetedEntryReassociatesActiveJobWithoutStoppingSpeechOrBlockingReplacement() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("active-retained-address"), replacement = try article("active-replacement-address")
    let coordinator = FixtureCoordinator(), provider = CancellableProvider(holdCleanup: true)
    defer { provider.allowCleanup() }
    let original = ReadingListEntry(id: "safari:stable", safariID: "stable", url: review.page.originalURL, title: "Original", addedAt: .distantPast)
    let updated = ReadingListEntry(id: original.id, safariID: original.safariID, url: replacement.page.originalURL, title: "Replacement", addedAt: original.addedAt)
    let retained = ReadingListEntry(id: "safari:retained", safariID: "retained", url: original.url, title: original.title, addedAt: original.addedAt)
    let catalog = try await coordinator.reconcile(.init(entries: [original], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: .init(), sourceEntryID: original.id)
    let model = AppModel(storage: storage, backend: { _ in provider }, enqueueFetch: { _ in replacement.page },
        readingListReader: { _ in .init(entries: [updated, retained], skippedEntries: 0) })
    model.sourceReview.plist = root.appendingPathComponent("synthetic-source.plist")
    model.sourceReview.catalog = catalog; model.queueItems = [item]
    model.autoAdmitEnabled = true; model.autoProcessEnabled = false
    model.runQueue()
    try await waitUntil("duplicate original source speech started") { provider.started }
    #expect(await model.sourceReview.synchronizeOnce())
    try await waitUntil("replacement admitted during retained original speech") { model.pendingAdds[updated.id] != nil || model.queueItems.count == 2 }
    await model.waitForEnqueue()
    let active = try #require(model.queueItems.first { $0.id == item.id })
    #expect(model.running && !model.cancelling && !model.sourcePruningBusy)
    #expect(active.sourceEntryID == retained.id && active.state == .running && active.attempts == 1)
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.count == 2 && queue.contains { $0.id != item.id && $0.sourceEntryID == updated.id })
    provider.allowCleanup()
    await model.shutdown()
}

@Test @MainActor func retargetedEntryCanAutomaticallyAdmitNewURLAfterOldURLFailedThisSession() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try article("failed-original-address"), replacement = try article("fresh-replacement-address"), coordinator = FixtureCoordinator()
    let original = ReadingListEntry(id: "safari:stable", safariID: "stable", url: review.page.originalURL, title: "Original", addedAt: .distantPast)
    let updated = ReadingListEntry(id: original.id, safariID: original.safariID, url: replacement.page.originalURL, title: "Replacement", addedAt: original.addedAt)
    let catalog = try await coordinator.reconcile(.init(entries: [original], skippedEntries: 0), stateRoot: storage.stateRoot)
    let fetches = SyncCounter()
    let model = AppModel(storage: storage, enqueueFetch: { url in
        fetches.increment()
        if url == original.url { throw SourceFetchError.network }
        return replacement.page
    }, readingListReader: { _ in .init(entries: [updated], skippedEntries: 0) })
    model.sourceReview.plist = root.appendingPathComponent("synthetic-source.plist")
    model.sourceReview.catalog = catalog; model.autoAdmitEnabled = true; model.autoProcessEnabled = false
    await model.autoAdmitNewEntries(); await model.waitForEnqueue()
    #expect(fetches.value == 1 && !model.enqueueIssues.isEmpty)
    await model.autoAdmitNewEntries(); await model.waitForEnqueue()
    #expect(fetches.value == 1)
    #expect(await model.sourceReview.synchronizeOnce())
    await model.waitForSourcePruning()
    try await waitUntil("new source URL bypasses the previous URL failure") { model.pendingAdds[updated.id] != nil || !model.queueItems.isEmpty }
    await model.waitForEnqueue(); await model.waitForLibraryRefresh()
    #expect(fetches.value == 2 && model.queueItems.count == 1)
    let item = try #require(model.queueItems.first)
    #expect(try await coordinator.articlePreviewURL(articleID: item.id, stateRoot: storage.stateRoot) == updated.url)
    await model.shutdown()
}
