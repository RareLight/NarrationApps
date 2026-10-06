import Foundation
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
        _ = try ToolRunner.run(PrototypeProfile.fixture(at: directory).ffmpeg,
            ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=300:sample_rate=24000",
             "-t", "0.25", "-ac", "1", "-c:a", "pcm_s16le", wav.path], timeout: 10, directory: directory)
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
    model.queueItems = [first, second]; model.runQueue(); await model.waitForProcessing()
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

@Test @MainActor func audioRetentionRefreshRemovesExpiredAudioFromVisibleLibraryAndInspection() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: article(), backend: SyntheticProvider(), storage: storage)
    let model = AppModel(storage: storage)
    #expect(model.audioRetention == .oneMonth)
    model.audioRetention = .never; await model.waitForLibraryRefresh()
    model.result = result
    #expect(model.savedEpisodes.map(\.id) == [result.episode.id])
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: result.audioURL.path)
    model.refreshLibrary(); await model.waitForLibraryRefresh()
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    model.audioRetention = .oneDay; await model.waitForLibraryRefresh()
    #expect(model.savedEpisodes.isEmpty && model.result == nil && model.audioCleanupError == nil)
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path))
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

@MainActor
private final class StubAgentTransport: AgentTransport {
    var endpoint: AgentEndpoint?
    var autoReply: Result<Data, AgentClientFailure>?
    var activated = false
    var invalidated = false
    var sent: [Data] = []
    private var replyHandler: (@Sendable (Result<Data, AgentClientFailure>) -> Void)?
    func activate(onFailure: @escaping @Sendable (AgentClientFailure) -> Void) throws { activated = true }
    func send(_ data: Data, reply: @escaping @Sendable (Result<Data, AgentClientFailure>) -> Void) {
        sent.append(data); replyHandler = reply
        if let endpoint { Task { reply(.success(await endpoint.handle(data))) } }
        else if let autoReply { Task { @MainActor in reply(autoReply) } }
    }
    func deliver(_ result: Result<Data, AgentClientFailure>) { replyHandler?(result) }
    func invalidate() { invalidated = true }
}

private func agentDiagnosticsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-agentdiag-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test @MainActor func agentDiagnosticsInertModelNeverConnects() async {
    var calls = 0
    let model = AgentDiagnosticsModel(inert: true, client: AgentClient { calls += 1; return StubAgentTransport() })
    model.check()
    await model.waitForCheck()
    #expect(calls == 0 && !model.checking && model.snapshot == nil && model.error == nil)
}

@Test @MainActor func agentDiagnosticsShowsReadOnlyCountsAfterExplicitCheck() async throws {
    let root = try agentDiagnosticsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state")
    let transport = StubAgentTransport()
    transport.endpoint = AgentEndpoint(stateRoot: state)
    var calls = 0
    let model = AgentDiagnosticsModel(client: AgentClient { calls += 1; return transport })
    #expect(calls == 0 && !model.checking)
    model.check()
    #expect(model.checking)
    await model.waitForCheck()
    #expect(calls == 1 && transport.activated && transport.invalidated)
    #expect(model.snapshot?.mode == "readOnlyFoundation" && model.snapshot?.supportedCommands == ["snapshot"])
    #expect(model.snapshot?.articles == 0 && model.error == nil && !model.checking)
    #expect(!FileManager.default.fileExists(atPath: state.path))
}

@Test @MainActor func agentDiagnosticsFailureClearsStaleSnapshotAndExplicitRepeatWorks() async throws {
    let root = try agentDiagnosticsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let failed = StubAgentTransport(); failed.autoReply = .failure(.unavailable)
    let ready = StubAgentTransport(); ready.endpoint = AgentEndpoint(stateRoot: root.appendingPathComponent("state"))
    var transports = [failed, ready]
    let model = AgentDiagnosticsModel(client: AgentClient { transports.removeFirst() })
    model.snapshot = AgentSnapshot(catalog: ReadingListCatalog(), queue: [])
    model.error = "Stale message"
    model.check()
    await model.waitForCheck()
    #expect(model.snapshot == nil && model.error == AgentClientFailure.unavailable.message && !model.checking)
    model.check()
    await model.waitForCheck()
    #expect(model.error == nil && model.snapshot?.mode == "readOnlyFoundation" && ready.invalidated)
}

@Test @MainActor func agentDiagnosticsCancelClearsAndLateReplyDoesNotRevive() async throws {
    let root = try agentDiagnosticsRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = AgentEndpoint(stateRoot: root.appendingPathComponent("state"))
    var transports: [StubAgentTransport] = []
    var first = true
    let model = AgentDiagnosticsModel(client: AgentClient {
        let transport = StubAgentTransport()
        if first { transport.endpoint = endpoint; first = false }
        transports.append(transport)
        return transport
    })
    model.check()
    model.cancel()
    model.check()
    await model.waitForCheck()
    #expect(transports.count == 1)
    #expect(model.error == nil && model.snapshot?.mode == "readOnlyFoundation" && !model.checking)
    model.check()
    for _ in 0..<200 {
        if transports.count > 1 && !transports[1].sent.isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let cancelled = try #require(transports.count > 1 ? transports[1] : nil)
    let staleSent = try #require(cancelled.sent.first)
    model.cancel()
    #expect(!model.checking && model.snapshot == nil && model.error == nil && cancelled.invalidated)
    model.check()
    for _ in 0..<200 {
        if transports.count > 2 && !transports[2].sent.isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let fresh = try #require(transports.count > 2 ? transports[2] : nil)
    let freshSent = try #require(fresh.sent.first)
    cancelled.deliver(.success(await endpoint.handle(staleSent)))
    fresh.deliver(.success(await endpoint.handle(freshSent)))
    await model.waitForCheck()
    #expect(model.error == nil && model.snapshot?.mode == "readOnlyFoundation" && fresh.invalidated)
    #expect(transports.count == 3 && !model.checking)
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
    #expect(!review.busy && !review.persistenceBusy)
    let idle = AppModel(storage: storage)
    await idle.shutdown()
    #expect(idle.stopping && !idle.running)
}

@Test @MainActor func settingsSectionsAreDistinctAndInertViewsConstruct() throws {
    #expect(SettingsSection.allCases == [.general, .troubleshooting])
    #expect(Set(SettingsSection.allCases.map(\.rawValue)) == ["General", "Troubleshooting"])
    let model = AppModel(preview: true)
    let general = SettingsView(model: model)
    let troubleshooting = SettingsView(model: model, initialSection: .troubleshooting)
    _ = general; _ = troubleshooting
    #expect(!model.running && !model.stopping)
}

@Test @MainActor func settingsPanesShareFixedGlassControlLayout() async throws {
    #expect(SettingsView.windowWidth == 880 && SettingsView.windowHeight == 680)
    #expect(SettingsView.paneSelectorWidth == 196 && SettingsView.paneSelectorHeight == 46)
    #expect(SettingsSection.allCases.map(\.systemImage) == ["gearshape", "stethoscope"])
    let model = AppModel(preview: true)
    _ = SettingsView(model: model)
    _ = SettingsView(model: model, initialSection: .troubleshooting)
    for section in SettingsSection.allCases {
        _ = SettingsPaneSelector(selection: .constant(section)).body
    }
    await model.waitForProcessing()
    #expect(!model.running && !model.stopping && model.progress == nil && model.batchProgress == nil)
}

@Test @MainActor func troubleshootingShowsSourceStatusWithoutSavedListOrPreviewControls() throws {
    let model = SourceReviewModel(preview: true)
    let entries = ["one", "two"].map {
        ReadingListEntry(id: $0, safariID: $0, url: URL(string: "https://articles.example/\($0)")!,
                         title: "Synthetic \($0)", addedAt: nil)
    }
    model.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.status = "Synthetic source status"
    _ = SourceReviewView(model: model).body
    model.error = "Synthetic file-access failure; previous entries retained."
    _ = SourceReviewView(model: model).body
    #expect(model.catalog.entries.count == 2 && !model.busy && !model.persistenceBusy)
}

@Test @MainActor func workspaceSectionsAndNativeViewsConstructInertly() async throws {
    #expect(WorkspaceSection.allCases == [.articles, .queue, .savedAudio])
    #expect(Set(WorkspaceSection.allCases.map(\.rawValue)) == ["Articles", "Queue", "Saved Audio"])
    let model = AppModel(preview: true)
    for section in WorkspaceSection.allCases {
        model.workspaceSection = section
        _ = WorkspaceView(model: model)
        _ = RelayMenu(model: model)
    }
    await model.waitForProcessing()
    #expect(!model.running && !model.stopping)
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
    model.workspaceSection = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "Synthetic", state: .failed, lastError: "Synthetic feed failure")]
    model.error = "Synthetic feed failure"
    #expect(model.workspaceError == nil)
    model.error = "A different failure needs attention."
    #expect(model.workspaceError == "A different failure needs attention.")
    model.workspaceSection = .articles
    model.error = "Synthetic feed failure"
    #expect(model.workspaceError == "Synthetic feed failure")
    model.error = nil
    #expect(model.workspaceError == nil)
}

@Test @MainActor func appResumeSavedEpisodeUsesCapturedSettingsAndPreservesQueueRecovery() async throws {
    let (root, storage) = try isolatedStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(article(), storage: storage, preferences: SpeechPreferences(voice: .bella, speed: 0.9))
    let saved = try #require(try await coordinator.library(storage: storage).first(where: { $0.id == item.id }))
    let model = AppModel(storage: storage, backend: { _ in SyntheticProvider() })
    model.queueItems = [item]
    model.resume(saved)
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
    model.addSelectedToQueue()
    #expect(model.enqueueIssues.isEmpty)
    await model.waitForEnqueue()
    #expect(model.enqueueIssues.isEmpty && model.queueItems.count == 1 && !model.running)
    await model.shutdown()
    #expect(model.pendingAdds.isEmpty)
}

@Test @MainActor func articlePreviewWindowAndQueuePendingRowsConstructInertly() async throws {
    let model = AppModel(preview: true)
    model.pendingAdds = ["one": "Synthetic article one"]
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "Synthetic queued article")]
    _ = QueueView(model: model)
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

@Test @MainActor func selectionManagementControlSwitchesToBulkAboveOneSelection() throws {
    func control(_ count: Int) -> SelectionManagementControl {
        SelectionManagementControl(selectionCount: count, resetTitle: "Reset…", canReset: true, canRemove: true,
                                   resetHelp: "reset", removeHelp: "remove", onReset: {}, onRemove: {})
    }
    #expect(!control(0).usesBulkRemoval && !control(1).usesBulkRemoval)
    #expect(control(2).usesBulkRemoval && control(9).usesBulkRemoval)
    let model = AppModel(preview: true)
    _ = QueueView(model: model)
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
        let holder = try NativeStore(url: storage.profile.database)
        model.changeQueue(first.id, remove: true)
        #expect(model.queueMutationBusy)
        model.runQueue()
        try await Task.sleep(for: .milliseconds(200))
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
        try await Task.sleep(for: .milliseconds(200))
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
    #expect(SettingsView.paneSelectorWidth == 196 && SettingsView.paneSelectorHeight == 46)
    #expect(SettingsView.paneSymbolSize == 16 && SettingsView.paneLabelSize >= 12)
    #expect(SettingsView.windowWidth == 880 && SettingsView.windowHeight == 680)
}

@Test @MainActor func autoSyncWithoutChosenSourceNeverReadsPlist() async throws {
    let (root, _) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let calls = SyncCounter()
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state")) { url in
        calls.increment()
        return try ReadingList.read(url)
    }
    model.startAutomaticSynchronization()
    try await waitForCatalog(model)
    #expect(await model.synchronizeOnce() && calls.value == 0)
    try await waitUntil("unset source guides source choice") {
        model.status.contains("Choose a Reading List source")
    }
    await model.stop()
    #expect(await model.synchronizeOnce() == false && calls.value == 0)
}

@Test @MainActor func chosenSourceSyncsAndRetainsAbsentInventory() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try Data(contentsOf: plist)
    let calls = SyncCounter()
    let one = ReadingListEntry(id: "safari:one", safariID: "one", url: URL(string: "https://articles.example/one")!, title: "One", addedAt: nil)
    let two = ReadingListEntry(id: "safari:two", safariID: "two", url: URL(string: "https://articles.example/two")!, title: "Two", addedAt: nil)
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist) { url in
        #expect(url == plist)
        let index = calls.value; calls.increment()
        return ReadingListSnapshot(entries: index == 0 ? [one, two] : [two], skippedEntries: 0)
    }
    try await waitForCatalog(model)
    #expect(await model.synchronizeOnce() && calls.value == 1)
    #expect(model.catalog.currentIDs == [one.id, two.id] && model.error == nil)
    #expect(await model.synchronizeOnce() && calls.value == 2)
    #expect(model.catalog.currentIDs == [two.id])
    #expect(model.catalog.entries.map(\.id) == [one.id, two.id])
    #expect(try Data(contentsOf: plist) == bytes)
    await model.stop()
}

@Test @MainActor func failedSourceReadPreservesInventoryAndSuccessClearsError() async throws {
    let (root, plist) = try sourceFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let mode = SyncCounter()
    let entry = ReadingListEntry(id: "safari:one", safariID: "one", url: URL(string: "https://articles.example/one")!, title: "One", addedAt: nil)
    struct Failed: Error {}
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist) { _ in
        if mode.value == 1 { throw Failed() }
        return ReadingListSnapshot(entries: [entry], skippedEntries: 0)
    }
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
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist) { _ in
        started.increment()
        try await Task.sleep(for: .seconds(30))
        return ReadingListSnapshot(entries: [], skippedEntries: 0)
    }
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
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: oldPlist) { url in
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
    }
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
    let model = SourceReviewModel(preview: false, stateRoot: root.appendingPathComponent("state"), plist: plist) { _ in
        calls.increment()
        let deadline = Date().addingTimeInterval(5)
        while release.value == 0 && !Task.isCancelled && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return ReadingListSnapshot(entries: [entry], skippedEntries: 0)
    }
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
    model.refreshLibrary(cleanup: false)
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
