import SwiftUI
import AppKit
import Observation
import Darwin
import VoiceRelayCore

/// Capture verified results synchronously, including when a later article throws before UI callbacks arrive.
private final class BatchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: FixtureResult?
    func remember(_ result: FixtureResult) { lock.withLock { self.result = result } }
    var latest: FixtureResult? { lock.withLock { result } }
}

@MainActor @Observable
final class AppModel {
    var status = "Select articles to add to the queue"
    var error: String?
    var progress: PipelineProgress?
    var batchProgress: QueueBatchProgress?
    @ObservationIgnored private var progressID = UUID()
    @ObservationIgnored private var completedQueueIDs: Set<String> = []
    var result: FixtureResult?
    var savedEpisodes: [Episode] = []
    var queueItems: [SpeechQueueItem] = []
    var articleSelection: Set<String> = []
    /// In-flight background adds, entry id to title. Not persisted; rows merge below real queue items.
    var pendingAdds: [String: String] = [:]
    var enqueueIssues: [String] = []
    var running = false
    var processingSpeech = false
    var queueMutationBusy = false
    var mutatingQueueEntries: Set<QueueSelectionID> = []
    var audioMutationBusy = false
    var mutatingSavedAudioIDs: Set<String> = []
    var savedAudioSelection: Set<String> = []
    var cancelling = false
    var queueSelection: Set<QueueSelectionID> = []
    var preferences = SpeechPreferences() { didSet { savePreferences() } }
    var audioCleanupError: String?
    /// Set-and-forget automation preferences; storage-injected models stay manual by default.
    var autoAdmitEnabled = false { didSet { saveAutoAdmit() } }
    var autoProcessEnabled = false { didSet { saveAutoProcess() } }
    /// Explicit Stop suspends automation until new work arrives or Generate is pressed.
    var autoHalted = false
    /// Delivery configuration; the password lives only in the credential store, never here.
    var deliverySettings = DeliverySettings() { didSet { deliverySettingsChanged() } }
    var deliveryBusy = false
    var deliveryStatus: String?
    var deliveryError: String?
    var deliveryPendingCount = 0
    var deliveryPublicationStates: [String: DeliveryPublicationStatus] = [:]
    var deliveryPublicationAudioHashes: [String: String] = [:]
    var deliveryPublicationSettingsHash: String?
    var deliveryTesting = false
    var deliveryTestResult: DeliveryTestResult = .untested
    /// Editor field only — never persisted to UserDefaults or files.
    var deliveryPassword = "" { didSet { cancelDeliveryTest() } }
    var deliveryPasswordStored = false
    var deliveryPasswordChecked = false
    var deliveryCredentialBusy = false
    var debugLoggingEnabled = false {
        didSet {
            deliveryDebugLog.enabled = debugLoggingEnabled && !preview
            if !preview { defaults.set(debugLoggingEnabled, forKey: "debugLoggingEnabled") }
        }
    }
    @ObservationIgnored let deliveryDebugLog = DeliveryDebugLog()
    @ObservationIgnored private var deliveryTestID = UUID()
    var isQueueResetPending = false
    let notices = NoticeDismissalState()
    var preview = false
    var sourceReview = SourceReviewModel(preview: true)
    var runtimeProject = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Coding/VoiceRelay")
    @ObservationIgnored let coordinator = FixtureCoordinator()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var enqueueTask: Task<Void, Never>?
    @ObservationIgnored private var queueMutationTask: Task<Void, Never>?
    @ObservationIgnored private var queueMutationRequests:
        [(targets: Set<QueueSelectionID>, work: @MainActor () async -> Void)] = []
    @ObservationIgnored private var audioMutationTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewRequestID = UUID()
    @ObservationIgnored private var queueControl: QueueRunControl?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var pendingTokens: [String: UUID] = [:]
    @ObservationIgnored private var pendingControls: [String: QueueAdmissionControl] = [:]
    @ObservationIgnored private var admissionQueue: [(entry: ReadingListEntry, storage: ManagedSpeechStorage,
                                                       preferences: SpeechPreferences, token: UUID,
                                                       control: QueueAdmissionControl, automatic: Bool)] = []
    /// Entry IDs whose automatic admission failed or was refused this session; manual adds bypass it.
    @ObservationIgnored private var autoAttempted: Set<String> = []
    @ObservationIgnored private var launchResumeDone = false
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    /// Discard saved-audio snapshots read before a removal or delivery confirmation.
    @ObservationIgnored private var audioLibraryRevision = UUID()
    @ObservationIgnored private var pendingLibraryRefresh: Bool?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTestTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryCredentialTask: Task<Void, Never>?
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    /// nil means no follow-up; false is automatic, true preserves a manual override.
    @ObservationIgnored private var pendingDeliveryForce: Bool?
    @ObservationIgnored private(set) var stopping = false
    var workspaceSection: WorkspaceSection? = .articles
    @ObservationIgnored private let storageOverride: ManagedSpeechStorage?
    @ObservationIgnored private let backendOverride: (@Sendable (Episode) throws -> any TTSBackend)?
    @ObservationIgnored private let enqueueFetchOverride: (@Sendable (URL) async throws -> FetchedPage)?
    @ObservationIgnored private let defaults: UserDefaults
    /// Delivery seams: production gets Keychain + URLSession; injected models get nil unless a
    /// test supplies fakes, so isolated models can never touch the network or Keychain.
    @ObservationIgnored private let deliveryTransportFactory: (@Sendable () -> any DeliveryTransport)?
    @ObservationIgnored private let deliveryCredentialStore: SessionDeliveryCredentialStore?

    init(preview: Bool = false, storage: ManagedSpeechStorage? = nil,
         backend: (@Sendable (Episode) throws -> any TTSBackend)? = nil,
         enqueueFetch: (@Sendable (URL) async throws -> FetchedPage)? = nil,
         defaults: UserDefaults = .standard,
         deliveryTransport: (@Sendable () -> any DeliveryTransport)? = nil,
         credentialStore: (any DeliveryCredentialStore)? = nil) {
        storageOverride = storage; backendOverride = backend; enqueueFetchOverride = enqueueFetch
        self.defaults = defaults
        var defaultTransport: (@Sendable () -> any DeliveryTransport)?
        if storage == nil { defaultTransport = { URLSessionDeliveryTransport() } }
        deliveryTransportFactory = deliveryTransport ?? defaultTransport
        let baseCredentialStore = credentialStore ?? (storage == nil ? KeychainCredentialStore() : nil)
        let credentialLog = deliveryDebugLog
        deliveryCredentialStore = baseCredentialStore.map { SessionDeliveryCredentialStore(base: $0, debugLog: credentialLog) }
        self.preview = preview; sourceReview = SourceReviewModel(preview: preview || storage != nil, coordinator: coordinator)
        sourceReview.onCatalogChange = { [weak self] in self?.catalogDidChange() }
        sourceReview.onContextChange = { [weak self] in self?.notices.reset(key: "source") }
        guard !preview else {
            runtimeProject = URL(fileURLWithPath: "/synthetic/VoiceRelay")
            return
        }
        debugLoggingEnabled = defaults.bool(forKey: "debugLoggingEnabled")
        loadDeliverySettings()
        // Isolated lifecycle tests supply storage/providers and never read user preferences or Safari.
        if storage != nil { return }
        if let bytes = defaults.data(forKey: "speechPreferences") {
            do {
                let saved = try JSONDecoder().decode(SpeechPreferences.self, from: bytes)
                try saved.validate(); preferences = saved
            } catch { self.error = "Saved voice and speed preferences could not be read. Default voice and speed are active." }
        }
        if let path = defaults.string(forKey: "runtimeProject") { runtimeProject = URL(fileURLWithPath: path) }
        autoAdmitEnabled = defaults.object(forKey: "autoAdmitArticles") as? Bool ?? true
        autoProcessEnabled = defaults.object(forKey: "autoProcessArticles") as? Bool ?? true
        refreshLibrary()
        startAutomationLoop()
        sourceReview.startAutomaticSynchronization()
        triggerDelivery()
    }
    private func loadDeliverySettings() {
        guard let bytes = defaults.data(forKey: "deliverySettings") else { return }
        guard var saved = try? JSONDecoder().decode(DeliverySettings.self, from: bytes) else {
            self.error = "Saved delivery settings could not be read. Delivery is disabled until they are fixed."
            return
        }
        saved.username = saved.credentialUsername.isEmpty ? nil : saved.credentialUsername
        deliverySettings = saved
        do { try saved.validate() }
        catch {
            self.error = (error as? RelayError)?.localizedDescription ?? "Saved delivery settings are invalid."
        }
    }
    private func saveAutoAdmit() {
        guard !preview, storageOverride == nil else { return }
        defaults.set(autoAdmitEnabled, forKey: "autoAdmitArticles")
    }
    private func saveAutoProcess() {
        guard !preview, storageOverride == nil else { return }
        defaults.set(autoProcessEnabled, forKey: "autoProcessArticles")
    }
    private func deliverySettingsChanged() {
        cancelDeliveryTest()
        refreshDeliveryCredentialState()
        guard !preview else { return }
        if let bytes = try? JSONEncoder().encode(deliverySettings) {
            defaults.set(bytes, forKey: "deliverySettings")
        }
        // New endpoints/folders/titles change the channel; mark the feed stale so the
        // next drain re-uploads it rather than serving a stale copy (Stage-1 concern).
        let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
        guard let hash = try? deliverySettings.settingsHash(),
              var ledger = try? DeliveryLedger.load(stateRoot: root),
              ledger.settingsHash != hash, !ledger.remoteFeedPending else { return }
        ledger.remoteFeedPending = true
        try? ledger.save(stateRoot: root)
    }
    /// Commit drafts atomically so an invalid edit cannot send an explicit action to
    /// the previous destination. Keep text editing separate from URL serialization.
    @discardableResult
    func updateDeliveryURLs(feedFolder: String, publicFolder: String) -> Bool {
        do {
            let feed = try DeliveryURL.folder(feedFolder, label: "Feed folder")
            let published = try DeliveryURL.folder(publicFolder, label: "Public folder")
            var settings = deliverySettings
            settings.feedFolderURL = feed; settings.publicFolderURL = published
            if settings != deliverySettings { deliverySettings = settings }
            return true
        } catch {
            cancelDeliveryTest()
            deliveryTestResult = .failure((error as? RelayError)?.localizedDescription ?? "The folder address could not be read.")
            return false
        }
    }
    var deliverySubscriptionURL: URL? { deliverySettings.publicFeedURL }
    func copyDeliverySubscriptionURL() {
        guard !preview, let url = deliverySubscriptionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    func refreshDeliveryCredentialState() {
        guard deliverySettings.feedFolderURL?.host != nil,
              let store = deliveryCredentialStore else { deliveryPasswordStored = false; deliveryPasswordChecked = false; return }
        let presence = store.presence(username: deliverySettings.credentialUsername, host: deliverySettings.credentialHost)
        deliveryPasswordStored = presence == .stored
        deliveryPasswordChecked = presence != .unchecked
    }
    func saveDeliveryPassword() {
        guard !preview, !stopping, !deliveryCredentialBusy, !deliveryPassword.isEmpty,
              deliverySettings.feedFolderURL?.host != nil,
              let store = deliveryCredentialStore else { return }
        let password = deliveryPassword, settings = deliverySettings
        cancelDeliveryTest(); deliveryCredentialBusy = true
        deliveryCredentialTask = Task {
            defer { deliveryCredentialBusy = false; deliveryCredentialTask = nil; refreshDeliveryCredentialState() }
            do {
                try await Task.detached {
                    try store.writePassword(password, username: settings.credentialUsername, host: settings.credentialHost)
                }.value
                try Task.checkCancellation()
                if deliverySettings.credentialHost == settings.credentialHost,
                   deliverySettings.credentialUsername == settings.credentialUsername, deliveryPassword == password {
                    deliveryPassword = ""
                }
                deliveryError = nil; deliveryDebugLog.record(.credentialSaved)
            } catch is CancellationError {
            } catch {
                deliveryError = (error as? DeliveryError)?.localizedDescription ?? "The delivery password could not be saved."
                deliveryDebugLog.record(.failure(.keychain))
            }
        }
    }
    func clearDeliveryPassword() {
        guard !preview, !stopping, !deliveryCredentialBusy, deliverySettings.feedFolderURL?.host != nil,
              let store = deliveryCredentialStore else {
            deliveryPasswordStored = false; return
        }
        let settings = deliverySettings
        cancelDeliveryTest(); deliveryCredentialBusy = true
        deliveryCredentialTask = Task {
            defer { deliveryCredentialBusy = false; deliveryCredentialTask = nil; refreshDeliveryCredentialState() }
            do {
                try await Task.detached {
                    try store.deletePassword(username: settings.credentialUsername, host: settings.credentialHost)
                }.value
                try Task.checkCancellation()
                deliveryError = nil; deliveryDebugLog.record(.credentialRemoved)
            } catch is CancellationError {
            } catch {
                deliveryError = (error as? DeliveryError)?.localizedDescription ?? "The delivery password could not be removed."
                deliveryDebugLog.record(.failure(.keychain))
            }
        }
    }
    func copyDebugLog() {
        guard !preview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deliveryDebugLog.text, forType: .string)
    }
    /// Coalesced background drain; requests during a drain schedule one follow-up.
    func triggerDelivery(force: Bool = false) {
        guard !preview, !stopping, !deliveryCredentialBusy, deliverySettings.enabled,
              (try? deliverySettings.validate()) != nil,
              let makeTransport = deliveryTransportFactory, let credential = deliveryCredentialStore else { return }
        if deliveryTask != nil { pendingDeliveryForce = (pendingDeliveryForce ?? false) || force; return }
        if force { credential.retryFailedAccess(username: deliverySettings.credentialUsername, host: deliverySettings.credentialHost) }
        let storage = speechStorage, settings = deliverySettings
        deliveryBusy = true
        deliveryDebugLog.record(.deliveryStarted)
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                deliveryTask = nil; deliveryBusy = false; refreshDeliveryCredentialState()
                audioLibraryRevision = UUID()
                refreshLibrary(allowDelivery: false)
                let again = pendingDeliveryForce; pendingDeliveryForce = nil
                if let again { triggerDelivery(force: again) }
            }
            do {
                let result = try await coordinator.deliverPending(storage: storage, settings: settings,
                    credential: credential, transport: LoggingDeliveryTransport(base: makeTransport(), log: deliveryDebugLog),
                    force: force, debugLog: deliveryDebugLog)
                try Task.checkCancellation()
                if let summary = try? await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings) {
                    recordDeliveryPublication(summary)
                    deliveryPendingCount = summary.pendingMedia + summary.pendingRemoteDeletes
                    deliveryError = summary.lastError
                }
                deliveryStatus = Self.deliveryStatusText(result, hasError: deliveryError != nil)
                if deliveryError == nil { notices.reset(key: "delivery") }
                deliveryDebugLog.record(.deliveryFinished)
            } catch is CancellationError {
            } catch {
                deliveryDebugLog.recordFailure(error)
                deliveryError = (error as? RelayError)?.localizedDescription
                    ?? (error as? DeliveryError)?.localizedDescription
                    ?? "Delivery failed; saved progress is retained."
                if let summary = try? await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings) {
                    recordDeliveryPublication(summary)
                    deliveryPendingCount = summary.pendingMedia + summary.pendingRemoteDeletes
                }
            }
        }
    }
    private static func deliveryStatusText(_ result: DeliveryResult, hasError: Bool = false) -> String {
        var parts: [String] = []
        if result.uploadedMedia > 0 { parts.append("Uploaded \(result.uploadedMedia)") }
        if result.feedUploaded { parts.append("Feed updated") }
        if result.remoteDeletes > 0 { parts.append("Removed \(result.remoteDeletes) remote") }
        if result.failed > 0 { parts.append("\(result.failed) failed") }
        if result.retrying > 0 { parts.append("\(result.retrying) retrying") }
        return parts.isEmpty ? (hasError ? "Delivery needs attention" : "Delivery up to date") : parts.joined(separator: " · ")
    }
    func testDeliveryConnection() {
        guard !preview, !stopping, !deliveryCredentialBusy, !deliveryTesting else { return }
        let settings = deliverySettings
        guard let makeTransport = deliveryTransportFactory, let credential = deliveryCredentialStore else {
            deliveryTestResult = .failure("Delivery is unavailable"); return
        }
        do { try settings.validate() }
        catch {
            deliveryTestResult = .failure((error as? RelayError)?.localizedDescription ?? "Invalid configuration")
            return
        }
        deliveryTesting = true
        credential.retryFailedAccess(username: settings.credentialUsername, host: settings.credentialHost)
        deliveryTestResult = .untested
        let testID = UUID(); deliveryTestID = testID
        deliveryDebugLog.record(.connectionStarted)
        deliveryTestTask = Task { [weak self] in
            guard let self else { return }
            defer { deliveryTesting = false; deliveryTestTask = nil; refreshDeliveryCredentialState() }
            guard settings.feedFolderURL?.host != nil else {
                deliveryTestResult = .failure("The WebDAV URL has no host.")
                return
            }
            do {
                let transport = LoggingDeliveryTransport(base: makeTransport(), log: deliveryDebugLog)
                let log = deliveryDebugLog
                let client = try await Task.detached {
                    try WebDAVClient(transport: transport, settings: settings, credential: credential, debugLog: log)
                }.value
                try Task.checkCancellation()
                let foldersExist = try await client.testConnection()
                try Task.checkCancellation()
                guard deliveryTestID == testID else { return }
                deliveryTestResult = foldersExist ? .success : .foldersPending
                deliveryDebugLog.record(foldersExist ? .connectionVerified : .connectionFoldersPending)
            } catch is CancellationError {
            } catch let error as DeliveryError {
                guard deliveryTestID == testID else { return }
                deliveryTestResult = .failure(error.localizedDescription)
                deliveryDebugLog.recordFailure(error)
            } catch {
                guard deliveryTestID == testID else { return }
                deliveryTestResult = .failure("Server unreachable")
                deliveryDebugLog.recordFailure(error)
            }
        }
    }
    func cancelDeliveryTest() {
        deliveryTestID = UUID(); deliveryTestTask?.cancel(); deliveryTestResult = .untested
    }
    /// Periodic set-and-forget tick: drain pending delivery and process ready work.
    private func startAutomationLoop() {
        guard !preview, storageOverride == nil, automationTask == nil, !stopping else { return }
        automationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, !self.stopping else { return }
                self.triggerDelivery()
                self.maybeAutoProcess()
            }
        }
    }
    private func savePreferences() {
        guard !preview, (try? preferences.validate()) != nil,
              let bytes = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(bytes, forKey: "speechPreferences")
    }
    var readyQueueCount: Int { queueItems.filter { $0.state.isReady }.count }
    var canGenerateAudio: Bool { !preview && !stopping && !running && !audioMutationBusy
                                 && !sourceReview.persistenceBusy && (readyQueueCount > 0 || !pendingAdds.isEmpty) }
    var canStopProcessing: Bool { !preview && !stopping && processingSpeech && !cancelling }
    var canResetQueue: Bool { !preview && !stopping && !running && !cancelling && !isQueueResetPending
                              && !sourceReview.persistenceBusy && (!queueItems.isEmpty || !pendingAdds.isEmpty) }
    var showsProcessingProgress: Bool { processingSpeech || cancelling }
    var workspaceError: String? {
        guard let error else { return nil }
        if workspaceSection == .queue, queueItems.contains(where: { $0.lastError == error }) { return nil }
        return error
    }
    var processingFraction: Double? {
        guard showsProcessingProgress else { return nil }
        if let batch = batchProgress { return batch.fractionCompleted }
        guard let progress, progress.totalChunks > 0 else { return nil }
        if progress.stage == .published, progress.completedChunks >= progress.totalChunks { return 1 }
        return Double(progress.completedChunks) / Double(progress.totalChunks + 1)
    }
    var processingStatusLine: String {
        if cancelling { return "Stopping…" }
        if running, let batch = batchProgress {
            var line = batch.stage == .published && batch.completedArticles < batch.totalArticles
                ? "Checking saved audio" : batch.stage.friendlyLabel
            if let index = batch.currentArticleIndex { line += " · article \(index) of \(batch.totalArticles)" }
            return line + " · \(Int((min(1, max(0, batch.fractionCompleted)) * 100).rounded(.down)))%"
        }
        if running, let progress {
            var line = progress.stage == .published && progress.completedChunks < progress.totalChunks
                ? "Checking saved audio" : progress.stage.friendlyLabel
            if let fraction = processingFraction {
                line += " · \(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
            }
            return line
        }
        return status
    }
    func resume(_ episode: Episode) {
        guard !running, !stopping else { return }
        start(saved: episode)
    }
    func refreshLibrary(allowDelivery: Bool = true) {
        guard !preview, !stopping, !running else { return }
        if libraryTask != nil {
            pendingLibraryRefresh = (pendingLibraryRefresh ?? false) || allowDelivery
            return
        }
        let token = progressID, audioRevision = audioLibraryRevision
        let sweepsBlocked = audioMutationBusy
        let deliverySettings = deliverySettings
        let deliveryOn = deliverySettings.enabled
        libraryTask = Task {
            defer {
                libraryTask = nil
                let pending = pendingLibraryRefresh; pendingLibraryRefresh = nil
                if let pending { refreshLibrary(allowDelivery: pending) }
                else if !Task.isCancelled && progressID != token && !running { refreshLibrary() }
            }
            do {
                let storage = speechStorage
                if !sweepsBlocked {
                    try await coordinator.recoverTemporaryAudio(storage: storage,
                        settings: deliverySettings.enabled ? deliverySettings : nil)
                }
                let items = try await coordinator.queue(stateRoot: storage.stateRoot)
                var saved: [Episode] = []
                var library: [Episode] = []
                var cleanupError: String?
                var delivery: DeliverySummary?
                do {
                    if !sweepsBlocked {
                        do { _ = try await coordinator.resumePendingAudioRemovals(storage: storage) }
                        catch is CancellationError { return }
                        catch { cleanupError = (error as? RelayError)?.localizedDescription ?? "Saved audio removal could not finish." }
                        do { _ = try await coordinator.reconcileMissingAudio(storage: storage) }
                        catch is CancellationError { return }
                        catch { cleanupError = cleanupError ?? ((error as? RelayError)?.localizedDescription ?? "Saved audio cleanup could not finish.") }
                    }
                    library = try await coordinator.library(storage: storage)
                    saved = try await coordinator.savedAudio(storage: storage)
                    let shownIDs = Set(saved.map(\.id))
                    if cleanupError == nil && library.contains(where: {
                        ($0.stage == .published || $0.manualAudioDeletionRequested == true)
                            && $0.settings.temporaryAudio != true && $0.localAudioReleased != true
                            && $0.delivery?.status != .uploaded && !shownIDs.contains($0.id)
                    }) {
                        cleanupError = "Some saved audio is unavailable. Reconnect its original storage or restore access."
                    }
                    delivery = try? await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: deliverySettings)
                }
                guard progressID == token, audioLibraryRevision == audioRevision, !running else { return }
                if let result, library.contains(where: { $0.id == result.episode.id && $0.stage == .expired && $0.manualAudioDeletionRequested != true }) { self.result = nil }
                queueItems = items; savedEpisodes = saved; audioCleanupError = cleanupError
                if cleanupError == nil { notices.reset(key: "audio") }
                queueSelection = prunedQueueSelection(queueSelection)
                savedAudioSelection = savedAudioSelection.filter { id in saved.contains(where: { $0.id == id }) }
                if let delivery {
                    recordDeliveryPublication(delivery)
                    if deliveryOn {
                        deliveryPendingCount = delivery.pendingMedia + delivery.pendingRemoteDeletes
                        if deliveryError == nil { deliveryError = delivery.lastError }
                        if allowDelivery && delivery.needsDrain { triggerDelivery() }
                    }
                }
                if !launchResumeDone {
                    launchResumeDone = true
                    await resumeInterruptedForAutomation()
                } else { maybeAutoProcess() }
            }
            catch {
                guard progressID == token, audioLibraryRevision == audioRevision, !running else { return }
                self.error = (error as? RelayError)?.localizedDescription ?? "The saved article library could not be read."
            }
        }
    }
    private func prunedQueueSelection(_ selection: Set<QueueSelectionID>) -> Set<QueueSelectionID> {
        let liveIDs = Set(queueItems.map(\.id))
        return selection.filter {
            switch $0 {
            case .episode(let id): return liveIDs.contains(id)
            case .preparation(let id): return pendingAdds[id] != nil
            }
        }
    }
    private var speechStorage: ManagedSpeechStorage { storageOverride ?? .appStorage() }
    private func backendFactory() -> @Sendable (Episode) throws -> any TTSBackend {
        if let backendOverride { return backendOverride }
        let project = runtimeProject, log = deliveryDebugLog
        return { episode in
            try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: project,
                voice: episode.settings.voice ?? "af_heart", speed: episode.settings.backendSettings["speed"]?.numericValue ?? 1), debugLog: log)
        }
    }
    private func resetProgress() {
        progressID = UUID(); completedQueueIDs.removeAll(); progress = nil; batchProgress = nil
    }
    private func finishProcessing() {
        // Invalidate queued MainActor callbacks before releasing ownership of this task.
        progressID = UUID()
        let wasCancelling = cancelling, wasStopped = stopped
        progress = nil; batchProgress = nil
        if wasCancelling && error == nil {
            status = wasStopped ? "Stopped; unfinished articles are Ready in Queue."
                : "Cancelled; unfinished articles remain in Queue. Retry when ready."
        }
        stopped = false; queueControl = nil
        running = false; processingSpeech = false; cancelling = false; task = nil
        refreshLibrary()
    }
    private var progressHandler: @Sendable (PipelineProgress) -> Void {
        let token = progressID
        return { [weak self] update in Task { @MainActor in
            guard let self, self.progressID == token else { return }
            self.progress = update
        } }
    }
    private var queueHandler: @Sendable (SpeechQueueItem) -> Void {
        let token = progressID
        return { [weak self] item in
            Task { @MainActor in
                guard let self, self.progressID == token else { return }
                if item.state == .completed {
                    self.completedQueueIDs.insert(item.id)
                    self.queueItems.removeAll { $0.id == item.id }
                    self.queueSelection.remove(.episode(item.id)); return
                }
                guard !self.completedQueueIDs.contains(item.id) else { return }
                if item.state == .running {
                    self.queueItems.removeAll { $0.id == item.id }
                    self.queueItems.insert(item, at: 0)
                } else if let index = self.queueItems.firstIndex(where: { $0.id == item.id }) { self.queueItems[index] = item }
                else { self.queueItems.append(item) }
            }
        }
    }
    var selectedArticles: [ReadingListEntry] {
        sourceReview.catalog.newestFirstEntries.filter { articleSelection.contains($0.id) }
    }
    func queueOriginHost(_ item: SpeechQueueItem) -> String? {
        item.sourceHost ?? sourceReview.catalog.entries.first { $0.id == item.sourceEntryID }?.url.host
    }
    /// Adds return immediately; a dedicated background task prepares each entry in order.
    /// Per-entry failures are collected as issues instead of stopping the remaining adds.
    func addSelectedToQueue() {
        guard !preview, !stopping, !queueMutationBusy, !sourceReview.busy, !sourceReview.persistenceBusy else { return }
        let entries = selectedArticles
        guard !entries.isEmpty else { return }
        admit(entries: entries, automatic: false)
    }
    /// Shared admission path for manual Add to Queue and automatic discovery adds.
    private func admit(entries: [ReadingListEntry], automatic: Bool) {
        // Snapshot list order and settings at the click; selection order never changes FIFO.
        let storage = speechStorage, choices = preferences
        if !automatic {
            articleSelection.removeAll()
            enqueueIssues = []
            notices.reset(key: "enqueue")
        }
        var admitted = 0
        for entry in entries where pendingTokens[entry.id] == nil {
            let token = UUID(), control = QueueAdmissionControl()
            pendingTokens[entry.id] = token
            pendingControls[entry.id] = control
            pendingAdds[entry.id] = entry.title
            admissionQueue.append((entry: entry, storage: storage, preferences: choices, token: token,
                                   control: control, automatic: automatic))
            admitted += 1
        }
        guard admitted > 0 else { return }
        if !processingSpeech && !running {
            status = automatic ? "Preparing \(admitted) new articles…" : "Preparing \(admitted) selected articles…"
        }
        startEnqueueIfNeeded()
    }
    private func catalogDidChange() {
        refreshLibrary()
        Task { await autoAdmitNewEntries() }
    }
    /// Set-and-forget admission: only entries still present in the latest source read, with
    /// no queue/pending item and no recorded episode (a removed item is never re-added).
    /// Entries whose admission failed are skipped for the rest of the session.
    func autoAdmitNewEntries() async {
        guard autoAdmitEnabled, !preview, !stopping,
              !sourceReview.busy, !sourceReview.persistenceBusy else { return }
        let catalog = sourceReview.catalog
        let queued = Set(queueItems.compactMap(\.sourceEntryID))
        let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
        let candidates = catalog.entries.filter {
            catalog.currentIDs.contains($0.id) && !queued.contains($0.id)
                && pendingTokens[$0.id] == nil && !autoAttempted.contains($0.id)
        }
        var fresh: [ReadingListEntry] = []
        for entry in candidates where !Task.isCancelled && !stopping {
            if (try? await coordinator.hasRecordedArticle(url: entry.url, stateRoot: root)) != true {
                fresh.append(entry)
            }
        }
        guard !fresh.isEmpty, !stopping else { return }
        admit(entries: fresh, automatic: true)
    }
    /// Automatic processing obeys the same readiness guards as Generate; explicit Stop holds
    /// it until new work arrives or Generate is pressed again.
    func maybeAutoProcess() {
        guard autoProcessEnabled, !autoHalted, canGenerateAudio else { return }
        runQueue()
    }
    /// Launch resume: items left .running by a previous Quit are legitimate unfinished work —
    /// re-ready them once, then let automation drain. Failed items stay manual-Retry.
    private func resumeInterruptedForAutomation() async {
        guard autoProcessEnabled else { return }
        let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
        for index in queueItems.indices where queueItems[index].state == .running && !stopping {
            if let item = try? await coordinator.retryQueued(queueItems[index].id, stateRoot: root) {
                queueItems[index] = item
            }
        }
        maybeAutoProcess()
    }
    private func startEnqueueIfNeeded() {
        guard enqueueTask == nil, !admissionQueue.isEmpty else { return }
        let fetch = enqueueFetchOverride
        enqueueTask = Task {
            defer {
                for pending in admissionQueue {
                    if pendingTokens[pending.entry.id] == pending.token {
                        pendingAdds[pending.entry.id] = nil; pendingTokens[pending.entry.id] = nil
                        pendingControls[pending.entry.id] = nil
                    }
                }
                admissionQueue = []; enqueueTask = nil
            }
            var saved = 0, issues: [String] = []
            while let next = admissionQueue.first {
                if Task.isCancelled { break }
                let entry = next.entry
                if !processingSpeech && !running { status = "Adding \(saved + issues.count + 1): \(entry.title)" }
                do {
                    let item = try await coordinator.enqueueReadingList(entry.id, storage: next.storage, preferences: next.preferences,
                        fetch: fetch, shouldCommit: { [weak self] in
                            await MainActor.run { self != nil && !self!.stopping && self!.pendingTokens[entry.id] == next.token }
                        }, admissionControl: next.control)
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                        if let index = queueItems.firstIndex(where: { $0.id == item.id }) { queueItems[index] = item }
                        else { queueItems.append(item) }
                        if queueSelection.contains(.preparation(entry.id)) {
                            queueSelection.remove(.preparation(entry.id)); queueSelection.insert(.episode(item.id))
                        }
                        saved += 1
                        // Newly arrived work resumes automation suspended by an explicit Stop.
                        autoHalted = false
                        maybeAutoProcess()
                    }
                } catch is CancellationError {
                    if Task.isCancelled { break }
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                        // A removed preparation row is a manual override; do not auto re-add it.
                        if next.automatic { autoAttempted.insert(entry.id) }
                    }
                } catch {
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                    }
                    if next.automatic { autoAttempted.insert(entry.id) }
                    issues.append("\(entry.title) — \(Self.enqueueIssueMessage(error))")
                }
            }
            enqueueIssues = issues
            if !processingSpeech && !running {
                status = issues.isEmpty ? "\(saved) articles saved in queue" : "Saved \(saved); \(issues.count) need attention."
            }
        }
    }
    func removePreparation(_ entryID: String) {
        removeQueueEntries(episodes: [], preparations: [entryID], restore: [])
    }
    private static func enqueueIssueMessage(_ error: any Error) -> String {
        (error as? RelayError)?.localizedDescription ?? (error as? SourceFetchError)?.localizedDescription
            ?? "The article could not be queued. Double-click it in Articles to preview it."
    }
    private func enqueueQueueMutation(targets: Set<QueueSelectionID>, work: @escaping @MainActor () async -> Void) {
        notices.reset(key: "global")
        queueMutationRequests.append((targets: targets, work: work))
        mutatingQueueEntries.formUnion(targets)
        queueMutationBusy = true
        startQueueMutationIfNeeded()
    }
    private func startQueueMutationIfNeeded() {
        guard queueMutationTask == nil, !queueMutationRequests.isEmpty else { return }
        queueMutationTask = Task {
            while !queueMutationRequests.isEmpty {
                if Task.isCancelled { break }
                let request = queueMutationRequests.removeFirst()
                await request.work()
                mutatingQueueEntries = queueMutationRequests.reduce(into: Set<QueueSelectionID>()) {
                    $0.formUnion($1.targets)
                }
            }
            queueMutationTask = nil
            if !queueMutationRequests.isEmpty, !stopping {
                startQueueMutationIfNeeded()
            } else {
                queueMutationRequests = []
                mutatingQueueEntries = []
                queueMutationBusy = false
            }
        }
    }
    func changeQueue(_ id: String, remove: Bool) {
        guard !preview, !stopping, !sourceReview.persistenceBusy,
              !mutatingQueueEntries.contains(.episode(id)) else { return }
        enqueueQueueMutation(targets: [.episode(id)]) { [self] in
            do {
                let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
                if remove {
                    try await coordinator.removeFromQueue(ids: [id], stateRoot: root)
                    queueItems.removeAll { $0.id == id }
                    queueSelection.remove(.episode(id))
                    status = "Removed from queue; saved article retained"
                } else {
                    let item = try await coordinator.retryQueued(id, stateRoot: root)
                    if let index = queueItems.firstIndex(where: { $0.id == item.id }) { queueItems[index] = item }
                    else { queueItems.append(item) }
                    completedQueueIDs.remove(item.id)
                    status = "Article ready in queue"
                }
            } catch { self.error = (error as? RelayError)?.localizedDescription ?? "The queue could not be changed."; status = "Needs attention" }
        }
    }
    var canRemoveQueueSelection: Bool {
        !preview && !stopping && !queueMutationBusy && !sourceReview.persistenceBusy && !queueSelection.isEmpty
            && !(processingSpeech && queueItems.contains { $0.state == .running && queueSelection.contains(.episode($0.id)) })
    }
    func removeSelectedQueueItems() {
        guard canRemoveQueueSelection else { return }
        let selection = queueSelection
        let episodeIDs = selection.compactMap { id -> String? in
            if case .episode(let raw) = id { return raw }; return nil
        }
        let prepIDs = selection.compactMap { id -> String? in
            if case .preparation(let raw) = id { return raw }; return nil
        }
        queueSelection = []
        removeQueueEntries(episodes: episodeIDs, preparations: prepIDs, restore: selection)
    }
    private func removeQueueEntries(episodes: [String], preparations: [String], restore: Set<QueueSelectionID>) {
        guard !preview, !stopping, !sourceReview.persistenceBusy else { return }
        let controls = preparations.compactMap { pendingControls[$0] }
        for control in controls { control.cancel() }
        for id in preparations {
            pendingTokens[id] = nil; pendingAdds[id] = nil; pendingControls[id] = nil
            admissionQueue.removeAll { $0.entry.id == id }
            queueSelection.remove(.preparation(id))
        }
        for id in episodes { queueSelection.remove(.episode(id)) }
        guard !episodes.isEmpty || !controls.isEmpty else {
            status = "Removed from queue; saved article retained"
            return
        }
        let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
        let targets = Set(episodes.map(QueueSelectionID.episode) + preparations.map(QueueSelectionID.preparation))
        enqueueQueueMutation(targets: targets) { [self] in
            do {
                for control in controls {
                    if let row = try await coordinator.cancelAdmission(control.id, stateRoot: root) {
                        queueItems.removeAll { $0.id == row.id }
                    }
                }
                if !episodes.isEmpty {
                    try await coordinator.removeFromQueue(ids: episodes, stateRoot: root)
                    queueItems.removeAll { episodes.contains($0.id) }
                }
                status = "Removed from queue; saved article retained"
            } catch {
                if let rows = try? await coordinator.queue(stateRoot: root) { queueItems = rows }
                queueSelection.formUnion(prunedQueueSelection(restore))
                self.error = (error as? RelayError)?.localizedDescription ?? "The queue could not be changed."
                status = "Needs attention"
            }
        }
    }
    func resetQueue() {
        guard canResetQueue else { return }
        for control in pendingControls.values { control.cancel() }
        pendingAdds = [:]; pendingTokens = [:]; pendingControls = [:]; admissionQueue = []
        let pendingEnqueue = enqueueTask
        enqueueTask?.cancel()
        queueSelection = []
        isQueueResetPending = true
        let targets = Set(queueItems.map { QueueSelectionID.episode($0.id) })
        enqueueQueueMutation(targets: targets) { [self] in
            defer { isQueueResetPending = false }
            if let pendingEnqueue { await pendingEnqueue.value }
            do {
                try await coordinator.resetQueue(stateRoot: storageOverride?.stateRoot ?? AppStorage.managedLibrary)
                queueItems = []
                status = "Queue cleared; Reading List and saved audio are unchanged."
            } catch {
                self.error = (error as? RelayError)?.localizedDescription ?? "The queue could not be reset."
                status = "Needs attention"
            }
        }
    }
    func runQueue() {
        guard canGenerateAudio else { return }
        let storage = speechStorage, factory = backendFactory()
        let completion = BatchCompletion()
        resetProgress()
        let change = queueHandler, token = progressID
        let progress: @Sendable (QueueBatchProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                guard let self, self.progressID == token else { return }
                if let old = self.batchProgress,
                   update.completedChunks + update.completedArticles < old.completedChunks + old.completedArticles { return }
                self.batchProgress = update
                if let index = update.currentArticleIndex { self.status = "Processing article \(index)/\(update.totalArticles)" }
            }
        }
        let control = QueueRunControl()
        queueControl = control
        // Manual or automated Generate both resume automation; publications mark delivery pending.
        autoHalted = false
        let delivery = deliverySettings.enabled && (try? deliverySettings.validate()) != nil ? deliverySettings : nil
        let pendingCount: @Sendable () async -> Int = { [weak self] in
            await MainActor.run { self?.pendingAdds.count ?? 0 }
        }
        let articleDone: @Sendable (FixtureResult) -> Void = { [weak self] outcome in
            completion.remember(outcome)
            Task { @MainActor in
                guard let self else { return }
                // Publication is durable even when Stop invalidates transient progress.
                // Quit's stopping guard prevents starting another owned delivery task.
                self.triggerDelivery()
                guard self.progressID == token else { return }
                self.result = outcome
            }
        }
        running = true; processingSpeech = true; stopped = false; error = nil
        notices.reset(key: "global")
        self.progress = nil; batchProgress = nil; status = "Preparing queue…"
        task = Task {
            defer { finishProcessing() }
            while let mutation = queueMutationTask { await mutation.value }
            do {
                try Task.checkCancellation()
                status = "Generating audio…"
                let completed = try await coordinator.drainQueue(storage: storage, backend: factory, control: control,
                    delivery: delivery, debugLog: deliveryDebugLog, pendingPreparationCount: pendingCount, onQueueChange: change,
                    onArticleComplete: articleDone, onProgress: progress)
                result = completed.lastResult ?? completion.latest
                if let failed = completed.failedItems.first {
                    self.error = failed.lastError
                    status = "Finished with issues; \(completed.failedItems.count) articles need attention."
                } else { status = "Finished \(completed.progress.completedArticles) articles" }
                triggerDelivery()
            } catch is CancellationError {
                result = completion.latest ?? result
            }
            catch {
                result = completion.latest ?? result
                self.error = (error as? RelayError)?.localizedDescription ?? "Queued speech failed. Retry when ready."; status = "Needs attention"
            }
        }
    }
    func stopQueue() {
        guard canStopProcessing else { return }
        autoHalted = true
        cancelling = true; stopped = true; progressID = UUID()
        queueControl?.requestStop()
        task?.cancel()
        status = "Stopping speech and releasing unfinished work…"
    }
    private func start(saved: Episode) {
        guard !preview, !running, !stopping, !sourceReview.persistenceBusy else { return }
        resetProgress()
        running = true; processingSpeech = true; stopped = false; error = nil; progress = nil; result = nil
        notices.reset(key: "global")
        status = "Resuming audio…"
        let storage = speechStorage
        let control = QueueRunControl()
        queueControl = control
        autoHalted = false
        let delivery = deliverySettings.enabled && (try? deliverySettings.validate()) != nil ? deliverySettings : nil
        let progress = progressHandler, change = queueHandler
        task = Task {
            defer { finishProcessing() }
            do {
                let factory = backendFactory()
                if let item = try await coordinator.queue(stateRoot: storage.stateRoot).first(where: { $0.id == saved.id }) {
                    if !item.state.isReady { _ = try await coordinator.retryQueued(item.id, stateRoot: storage.stateRoot) }
                    result = try await coordinator.runQueued(item.id, storage: storage, backend: factory, control: control,
                                                           delivery: delivery, onQueueChange: change, onProgress: progress)
                } else { result = try await coordinator.resume(storage: storage, articleID: saved.id, backend: factory(saved),
                                                               delivery: delivery, onProgress: progress) }
                status = "Speech saved locally"
                triggerDelivery()
            } catch is CancellationError { resetProgress(); status = "Cancelled; completed checkpoints retained" }
            catch {
                resetProgress()
                self.error = (error as? RelayError)?.localizedDescription ?? "Speech failed; completed progress is retained."
                status = "Needs attention"
            }
        }
    }
    func previewQueueItem(_ item: SpeechQueueItem, openWindow: OpenWindowAction) {
        guard !preview, !stopping else { return }
        previewTask?.cancel()
        let request = UUID()
        previewRequestID = request
        previewTask = Task {
            defer { if previewRequestID == request { previewTask = nil } }
            do {
                let url = try await coordinator.articlePreviewURL(articleID: item.id,
                    stateRoot: storageOverride?.stateRoot ?? AppStorage.managedLibrary)
                guard previewRequestID == request, !Task.isCancelled, !stopping else { return }
                ArticlePreviewNavigation.open(url, using: openWindow, inert: preview)
            } catch is CancellationError {
            } catch {
                guard previewRequestID == request, !Task.isCancelled, !stopping else { return }
                self.error = (error as? RelayError)?.localizedDescription ?? "The saved article could not be previewed."
            }
        }
    }
    /// Secondary saved-audio line: `Speech ready · 4:32 · 3.1 MB` style; nil without metadata.
    func savedAudioMeta(_ episode: Episode) -> String? {
        guard let info = episode.info else { return nil }
        let duration = Self.durationString(info.duration)
        let size = ByteCountFormatter.string(fromByteCount: info.byteLength, countStyle: .file)
        return "Audio · \(duration) · \(size)"
    }
    static func durationString(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let seconds = total % 60, minutes = (total / 60) % 60, hours = total / 3600
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var savedAudioResetCandidates: [String] { savedEpisodes.filter(canRemoveSavedAudio).map(\.id) }
    private func recordDeliveryPublication(_ summary: DeliverySummary) {
        deliveryPublicationStates = summary.publicationStates
        deliveryPublicationAudioHashes = summary.publicationAudioHashes
        deliveryPublicationSettingsHash = summary.publicationSettingsHash
    }
    func savedAudioDeliveryStatus(_ episode: Episode) -> DeliveryPublicationStatus {
        guard let settings = try? deliverySettings.normalized() else { return .notUploaded }
        if let identity = try? settings.publicationHash(), identity == deliveryPublicationSettingsHash,
           deliveryPublicationAudioHashes[episode.id] == episode.audioHash,
           let state = deliveryPublicationStates[episode.id] { return state }
        return DeliveryPublicationStatus.unconfirmed(episode, settings: settings)
    }
    var hasNewItemsToUpload: Bool {
        savedEpisodes.contains { $0.stage == .published && $0.manualAudioDeletionRequested != true
            && savedAudioDeliveryStatus($0) != .published }
    }
    var showsUploadNewItems: Bool { deliverySettings.enabled && hasNewItemsToUpload }
    var canUploadNewItems: Bool {
        showsUploadNewItems && !preview && !stopping && !deliveryBusy && !deliveryCredentialBusy
            && (try? deliverySettings.validate()) != nil
            && deliveryTransportFactory != nil && deliveryCredentialStore != nil
    }
    func uploadNewItems() {
        guard canUploadNewItems else { return }
        triggerDelivery(force: true)
    }
    var canDeleteSavedAudio: Bool {
        !preview && !stopping && !processingSpeech && !cancelling && !audioMutationBusy
            && !sourceReview.persistenceBusy && !savedEpisodes.isEmpty
    }
    func canRemoveSavedAudio(_ episode: Episode) -> Bool {
        canDeleteSavedAudio && !mutatingSavedAudioIDs.contains(episode.id)
            && !(episode.stage == .expired && deliveryBusy)
    }
    func savedAudioRemovalStatus(_ episode: Episode) -> String? {
        if mutatingSavedAudioIDs.contains(episode.id) || (episode.stage == .expired && deliveryBusy) { return "Removing…" }
        if episode.stage == .expired || episode.manualAudioDeletionRequested == true { return "Removal pending" }
        return nil
    }
    func removeSavedAudio(ids: [String]) {
        guard canDeleteSavedAudio, !ids.isEmpty else { return }
        let requested = Set(ids)
        let targets = savedEpisodes.filter { requested.contains($0.id) && canRemoveSavedAudio($0) }
        guard !targets.isEmpty else { return }
        let storage = speechStorage, targetIDs = targets.map(\.id)
        let retry = targets.contains { $0.stage == .expired }
        notices.reset(key: "audio"); notices.reset(key: "global")
        audioLibraryRevision = UUID()
        audioMutationBusy = true
        mutatingSavedAudioIDs.formUnion(targetIDs)
        audioMutationTask = Task {
            defer {
                audioMutationTask = nil; audioMutationBusy = false; mutatingSavedAudioIDs = []
                audioLibraryRevision = UUID()
                refreshLibrary()
                // A pending removal's explicit Retry overrides delivery backoff.
                triggerDelivery(force: retry && savedEpisodes.contains { targetIDs.contains($0.id) && $0.stage == .expired })
            }
            do {
                let removed = try await coordinator.removeSavedAudio(ids: targetIDs, storage: storage)
                // Local retirement is not server confirmation. Keep durable pending
                // removals visible instead of optimistically dropping/re-adding rows.
                savedEpisodes = try await coordinator.savedAudio(storage: storage)
                savedAudioSelection.subtract(removed)
            } catch is CancellationError {
            } catch {
                self.error = (error as? RelayError)?.localizedDescription ?? "The server audio could not be removed."
            }
        }
    }
    func waitForAudioMutation() async { if let audioMutationTask { await audioMutationTask.value } }
    func cancel() {
        resetProgress(); error = nil; sourceReview.cancel(); libraryTask?.cancel(); enqueueTask?.cancel()
        queueMutationTask?.cancel()
        if let task {
            cancelling = true; status = "Cancelling; waiting for owned work to stop…"
            task.cancel()
        } else {
            running = false; cancelling = false
            status = "Ready; queued articles and saved progress are retained"
            refreshLibrary()
        }
    }
    func waitForProcessing() async {
        if let task { await task.value }
        while let queueMutationTask { await queueMutationTask.value }
    }
    func waitForEnqueue() async { while let enqueueTask { await enqueueTask.value } }
    func waitForLibraryRefresh() async { while let libraryTask { await libraryTask.value } }
    func waitForDelivery() async { while let deliveryTask { await deliveryTask.value } }
    func waitForDeliveryTest() async { if let deliveryTestTask { await deliveryTestTask.value } }
    func waitForCredentialMutation() async { if let deliveryCredentialTask { await deliveryCredentialTask.value } }
    func shutdown() async {
        stopping = true
        // Stop owned work before terminating the UI.
        progressID = UUID()
        let current = task, enqueue = enqueueTask, library = libraryTask
        let mutation = queueMutationTask, audioMutation = audioMutationTask, preview = previewTask
        let delivery = deliveryTask, deliveryTest = deliveryTestTask, automation = automationTask, credential = deliveryCredentialTask
        previewRequestID = UUID()
        current?.cancel(); enqueue?.cancel(); library?.cancel(); mutation?.cancel()
        audioMutation?.cancel(); preview?.cancel(); delivery?.cancel(); deliveryTest?.cancel(); automation?.cancel()
        credential?.cancel(); deliveryCredentialStore?.cancelAuthentication()
        sourceReview.cancel()
        await sourceReview.stop()
        if let current { await current.value }
        if let enqueue { await enqueue.value }
        if let library { await library.value }
        if let mutation { await mutation.value }
        if let audioMutation { await audioMutation.value }
        if let preview { await preview.value }
        if let delivery { await delivery.value }
        if let deliveryTest { await deliveryTest.value }
        if let credential { await credential.value }
        if let automation { await automation.value }
        deliveryCredentialStore?.clearSession()
        deliveryPassword = ""; deliveryPasswordStored = false; deliveryPasswordChecked = false
    }
    func quit() { NSApplication.shared.terminate(nil) }
}

enum QueueSelectionID: Hashable {
    case episode(String)
    case preparation(String)
}

/// Result of the explicit Test Connection action; editing delivery settings resets it.
enum DeliveryTestResult: Equatable {
    case untested
    case success
    case foldersPending
    case failure(String)
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case articles = "Articles"
    case queue = "Queue"
    case savedAudio = "Server Audio"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .articles: "doc.text"
        case .queue: "list.bullet"
        case .savedAudio: "waveform"
        }
    }
}

extension Stage {
    var friendlyLabel: String {
        switch self {
        case .discovered, .fetching: "Preparing article"
        case .extracted: "Preparing audio"
        case .synthesizing: "Generating speech"
        case .encoding, .encoded: "Finishing audio"
        case .published: "Audio saved"
        case .expired: "Audio expired"
        }
    }
}

enum AppTypography {
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 12)
    static let minimumPointSize: CGFloat = 12
}

struct SectionHelpHeader: View {
    let title: String
    var explanation: String?
    @State private var showingInfo = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let explanation {
                Button { showingInfo = true } label: {
                    Image(systemName: "info.circle").font(AppTypography.secondary)
                }
                .buttonStyle(.plain)
                .help(explanation)
                .accessibilityLabel("About \(title)")
                .accessibilityHint(explanation)
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    Text(explanation).font(AppTypography.secondary).textSelection(.enabled)
                        .frame(idealWidth: 280, maxWidth: 320, alignment: .leading).padding(10)
                }
            }
        }
    }
}

@MainActor @Observable
final class NoticeDismissalState {
    private var dismissed: Set<String> = []
    private static func slot(_ message: String, _ key: String) -> String { "\(key)\u{1F}\(message)" }
    func isVisible(message: String, key: String) -> Bool { !dismissed.contains(Self.slot(message, key)) }
    func dismiss(message: String, key: String) { dismissed.insert(Self.slot(message, key)) }
    func reset(key: String) { dismissed = dismissed.filter { !$0.hasPrefix("\(key)\u{1F}") } }
}

struct InlineNotice: View {
    let message: String
    var onDismiss: (() -> Void)? = nil
    @State private var hovering = false
    @FocusState private var dismissFocused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .focused($dismissFocused)
                    .opacity(hovering || dismissFocused ? 1 : 0)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Dismiss error")
                    .help("Hide this message")
                    .frame(width: 18)
            }
        }
        .onHover { hovering = $0 }
        .font(AppTypography.body)
    }
}

struct ProcessingSummary: View {
    let model: AppModel
    var body: some View {
        if model.showsProcessingProgress {
            if let batch = model.batchProgress {
                BatchProgressView(progress: batch, cancelling: model.cancelling, pendingOverride: model.pendingAdds.count)
            } else if model.progress != nil {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = model.processingFraction { ProgressView(value: fraction) }
                    else { ProgressView() }
                    Text(model.processingStatusLine).monospacedDigit()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.processingStatusLine)
                }
            }
        }
    }
}

struct RelayMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text(model.processingStatusLine).font(AppTypography.body)
        Divider()
        if model.processingSpeech {
            Button(model.cancelling ? "Stopping…" : "Stop") { model.stopQueue() }
                .disabled(!model.canStopProcessing)
        } else {
            Button("Process Queue → (\(model.queueItems.count + model.pendingAdds.count))") {
                model.workspaceSection = .queue
                openWorkspace()
                model.runQueue()
            }.disabled(!model.canGenerateAudio)
        }
        Divider()
        Button("Articles") { openWorkspace(.articles) }.disabled(model.preview)
        Button("Queue") { openWorkspace(.queue) }.disabled(model.preview)
        Button("Server Audio") { openWorkspace(.savedAudio) }.disabled(model.preview)
        Divider()
        Button("Settings…") { WindowPresence.shared.prepareToOpen(); openSettings() }.disabled(model.preview)
        Button("Quit VoiceRelay") { model.quit() }.disabled(model.preview)
    }
    private func openWorkspace(_ section: WorkspaceSection? = nil) {
        if let section { model.workspaceSection = section }
        WindowPresence.shared.prepareToOpen()
        openWindow(id: "articles")
    }
}

struct WorkspaceView: View {
    @Bindable var model: AppModel
    private var section: WorkspaceSection { model.workspaceSection ?? .articles }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.workspaceSection) {
                ForEach(WorkspaceSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage).tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .font(AppTypography.body)
        .onAppear { model.refreshLibrary() }
    }
    private var detail: some View {
        VStack(spacing: 0) {
            if model.showsProcessingProgress {
                ProcessingSummary(model: model).padding([.horizontal, .top])
            }
            if let error = model.workspaceError, model.notices.isVisible(message: error, key: "global") {
                InlineNotice(message: error) { model.notices.dismiss(message: error, key: "global") }
                    .padding([.horizontal, .top])
            }
            if let warning = model.audioCleanupError, warning != model.workspaceError,
               model.notices.isVisible(message: warning, key: "audio") {
                InlineNotice(message: warning) { model.notices.dismiss(message: warning, key: "audio") }
                    .padding([.horizontal, .top])
            }
            switch section {
            case .articles: ArticlesView(model: model)
            case .queue: QueueView(model: model)
            case .savedAudio: LibraryView(model: model)
            }
        }
        .navigationTitle(section.rawValue)
    }
}

struct ConfigurationView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Language & Region", selection: $model.preferences.languageRegion) {
                    ForEach(SpeechLanguageRegion.allCases) { region in Text(region.label).tag(region) }
                }
                Picker("Voice", selection: $model.preferences.voice) {
                    ForEach(model.preferences.languageRegion.voices) { voice in Text(voice.label).tag(voice) }
                }
                Stepper("Speed: \(model.preferences.speed, specifier: "%.2f")×", value: $model.preferences.speed, in: 0.75...1.5, step: 0.05)
            } header: {
                SectionHelpHeader(title: "Speech",
                    explanation: "Language, region, voice and speed apply to new articles.\nQueued articles keep their captured choices.\nChoose from up to ten voices, ordered by Kokoro’s published quality grades. UK English has eight voices. Popularity statistics are not published.\nChanging region selects its highest-rated voice.")
            }.disabled(model.running)
            Section {
                LabeledContent("Source", value: model.sourceReview.plist?.lastPathComponent ?? "Not chosen")
                Button("Choose Reading List…") { model.sourceReview.selectPlist() }
                    .disabled(model.running || model.sourceReview.busy || model.sourceReview.persistenceBusy || model.preview)
                Toggle("Add new articles to Queue automatically", isOn: $model.autoAdmitEnabled)
                    .disabled(model.preview || model.stopping)
                Toggle("Process queued articles automatically", isOn: $model.autoProcessEnabled)
                    .disabled(model.preview || model.stopping)
            } header: {
                SectionHelpHeader(title: "Reading List",
                    explanation: "VoiceRelay checks the chosen Reading List file automatically while it runs.\nThe file is strictly read-only — nothing is written back.\nWith automatic processing on, newly discovered articles are added to the queue and processed without a click.\nStop suspends this until new work arrives or Generate is pressed.")
            }
        }.formStyle(.grouped)
    }
}

struct DeliveryPaneView: View {
    @Bindable var model: AppModel
    @State private var feedFolderText: String
    @State private var publicFolderText: String
    @FocusState private var focusedURL: URLField?
    private enum URLField: Hashable { case feed, published }
    init(model: AppModel) {
        self.model = model
        _feedFolderText = State(initialValue: model.deliverySettings.feedFolderURL?.absoluteString ?? "")
        _publicFolderText = State(initialValue: model.deliverySettings.publicFolderURL?.absoluteString ?? "")
    }
    @discardableResult private func commitURLs() -> Bool {
        guard model.updateDeliveryURLs(feedFolder: feedFolderText, publicFolder: publicFolderText) else { return false }
        feedFolderText = model.deliverySettings.feedFolderURL?.absoluteString ?? ""
        publicFolderText = model.deliverySettings.publicFolderURL?.absoluteString ?? ""
        return true
    }
    private var draftSubscriptionURL: URL? {
        (try? DeliveryURL.folder(publicFolderText))?.appendingPathComponent("feed.xml")
    }
    private var usernameBinding: Binding<String> {
        Binding(get: { model.deliverySettings.username ?? "" },
                set: {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.deliverySettings.username = trimmed.isEmpty ? nil : trimmed
                })
    }
    private var canSavePassword: Bool {
        !model.deliveryPassword.isEmpty && (try? DeliveryURL.folder(feedFolderText))?.host != nil
    }
    var body: some View {
        Form {
            Section {
                Toggle("Publish a private podcast feed", isOn: Binding(
                    get: { model.deliverySettings.enabled },
                    set: { enabled in if !enabled || commitURLs() { model.deliverySettings.enabled = enabled } }))
            } header: {
                SectionHelpHeader(title: "Publishing",
                    explanation: "While enabled, finished audio and a private RSS feed upload to the configured WebDAV folder whenever VoiceRelay runs — after processing, after removals, and periodically.\nNothing uploads until the connection is configured.")
            }
            Section {
                TextField("Feed folder URL", text: $feedFolderText)
                    .focused($focusedURL, equals: .feed)
                    .onSubmit { commitURLs() }
                    .help("The complete upload folder address, for example https://webdav.example/podcast. VoiceRelay puts feed.xml and audio/ here.")
                TextField("Username", text: usernameBinding)
                    .help("For WebDAV hosting, use your original full login username, not an alias, and an app password with Files access")
                SecureField("Password", text: $model.deliveryPassword)
                    .help("Test Connection uses the password saved in Keychain. Click Save Password after editing this field.")
                HStack(spacing: 8) {
                    Button("Save Password") { if commitURLs() { model.saveDeliveryPassword() } }
                        .disabled(!canSavePassword || model.deliveryCredentialBusy)
                        .help("Store the password in the Keychain for the configured host")
                    Button("Clear") { if commitURLs() { model.clearDeliveryPassword() } }
                        .disabled((try? DeliveryURL.folder(feedFolderText))?.host == nil || model.preview || model.deliveryCredentialBusy)
                    if model.deliveryPasswordStored {
                        Label("Stored in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                    } else if !model.deliveryPasswordChecked, model.deliverySettings.feedFolderURL?.host != nil {
                        Text("Password not checked").foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionHelpHeader(title: "Upload destination",
                    explanation: "Enter one complete Feed folder URL. VoiceRelay writes feed.xml there and creates audio/ beneath it for .m4a files. HTTPS is added when omitted; spaces, trailing slashes and dot segments are normalized when you finish editing. Existing folders are checked first; uploads create missing folders in parent order.\nThe password persists in the protected Keychain. Touch ID, a supported paired Apple Watch or the Mac password can unlock delivery once per app session. Opening Settings never unlocks Keychain; denial is not retried automatically. Save the password again when first using this protected store. macOS may require separate approval for replacement or removal.")
            }
            Section {
                TextField("Public folder URL", text: $publicFolderText)
                    .focused($focusedURL, equals: .published)
                    .onSubmit { commitURLs() }
                    .help("The public website folder serving the same files as your upload folder. Paste its URL or an existing feed.xml URL. WebDAV hosting: https://public.example/podcast/")
                LabeledContent("Subscription URL") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(draftSubscriptionURL?.absoluteString ?? "Enter a public folder URL")
                            .textSelection(.enabled).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Button("Copy", systemImage: "doc.on.doc") {
                            if commitURLs() { model.copyDeliverySubscriptionURL() }
                        }.disabled(draftSubscriptionURL == nil || model.preview)
                    }
                }
                TextField("Channel title", text: $model.deliverySettings.channelTitle)
                TextField("Channel description", text: $model.deliverySettings.channelDescription)
            } header: {
                SectionHelpHeader(title: "Public feed",
                    explanation: "The public folder determines the subscription URL and audio links written into feed.xml. The filename is always feed.xml, and audio is always in audio/. Copy the displayed Subscription URL into your podcast app. the hosting provider’s website settings selects which folder the website publishes. Its public URL paths are relative to that folder, while the Feed folder URL is the complete WebDAV destination. Both must serve the same feed.xml and audio/ files.\nFor WebDAV hosting encrypted websites, use https://public.example/podcast/ followed by the public file path. The remote feed lists only byte-confirmed uploads.")
            }
            Section {
                LabeledContent("Pending uploads", value: "\(model.deliveryPendingCount)")
                LabeledContent("Last upload", value: model.deliveryStatus ?? "Not run yet")
                if let error = model.deliveryError, model.notices.isVisible(message: error, key: "delivery") {
                    InlineNotice(message: error) { model.notices.dismiss(message: error, key: "delivery") }
                }
                HStack(spacing: 8) {
                    Button(model.deliveryTesting ? "Testing…" : "Test Connection") { if commitURLs() { model.testDeliveryConnection() } }
                        .disabled(model.deliveryTesting || model.preview || model.stopping || model.deliveryCredentialBusy)
                    testIndicator
                }
                Button(model.deliveryBusy ? "Uploading…" : "Upload Now") { if commitURLs() { model.triggerDelivery(force: true) } }
                    .disabled(model.deliveryBusy || !model.deliverySettings.enabled || model.preview || model.stopping || model.deliveryCredentialBusy)
                    .help("Upload pending audio and the feed now, including items still backing off")
            } header: {
                SectionHelpHeader(title: "Status",
                    explanation: "Test Connection checks WebDAV folders read-only. It does not check the public website mapping or write permission. Missing folders can be created by Upload Now.\nUpload Now retries credential, permission and remote-size verification failures. Uploads confirm size through HEAD or WebDAV file metadata. Automatic drains also run while the app is open.")
            }
        }
        .formStyle(.grouped)
        .disabled(model.stopping)
        .onAppear { model.refreshDeliveryCredentialState() }
        .onChange(of: feedFolderText) { _, value in
            if value != (model.deliverySettings.feedFolderURL?.absoluteString ?? "") { model.cancelDeliveryTest() }
        }
        .onChange(of: publicFolderText) { _, value in
            if value != (model.deliverySettings.publicFolderURL?.absoluteString ?? "") { model.cancelDeliveryTest() }
        }
        .onChange(of: focusedURL) { old, _ in if old != nil { commitURLs() } }
        .onDisappear { commitURLs(); model.cancelDeliveryTest() }
    }
    @ViewBuilder private var testIndicator: some View {
        switch model.deliveryTestResult {
        case .untested:
            if model.deliveryTesting { ProgressView().controlSize(.small) }
            else { Text("Not tested").foregroundStyle(.secondary) }
        case .success:
            Label("Folders verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .foldersPending:
            Label("Connected; folders created on upload", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                .lineLimit(2).help(message)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case delivery = "Delivery"
    case troubleshooting = "Troubleshooting"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .delivery: "antenna.radiowaves.left.and.right"
        case .troubleshooting: "stethoscope"
        }
    }
    var help: String {
        switch self {
        case .general: "Voice, speed, Reading List and storage"
        case .delivery: "Private podcast feed upload"
        case .troubleshooting: "Reading List diagnostics"
        }
    }
}

struct SettingsPaneSelector: View {
    @Binding var selection: SettingsSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectedTile
    @FocusState private var focusedPane: SettingsSection?
    @State private var keyboardNavigation = false
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        if NSApp.currentEvent?.type == .keyDown {
                            keyboardNavigation = true
                        } else {
                            focusedPane = nil; keyboardNavigation = false
                        }
                        if reduceMotion { selection = section }
                        else { withAnimation(.smooth(duration: 0.2)) { selection = section } }
                    } label: {
                        paneLabel(section)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedPane, equals: section)
                    .focusEffectDisabled()
                    .accessibilityLabel(section.rawValue)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                    .help(section.help)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings panes")
        .frame(width: SettingsView.paneSelectorWidth, height: SettingsView.paneSelectorHeight)
        .onChange(of: focusedPane) { _, focused in
            if focused != nil, NSApp.currentEvent?.type == .keyDown { keyboardNavigation = true }
        }
    }
    @ViewBuilder private func paneLabel(_ section: SettingsSection) -> some View {
        let selected = selection == section
        let label = VStack(spacing: 4) {
            Image(systemName: section.systemImage).font(.system(size: SettingsView.paneSymbolSize))
            Text(section.rawValue).font(.system(size: SettingsView.paneLabelSize)).lineLimit(1)
        }
        .frame(width: (SettingsView.paneSelectorWidth - 8 * CGFloat(SettingsSection.allCases.count - 1))
               / CGFloat(SettingsSection.allCases.count), height: SettingsView.paneSelectorHeight)
        .contentShape(Rectangle())
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .overlay {
            if keyboardNavigation && focusedPane == section {
                RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 1.5)
                    .padding(-2).allowsHitTesting(false)
            }
        }
        if selected {
            label
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
                .glassEffectID("selected-settings-pane", in: selectedTile)
        } else {
            label
        }
    }
}

struct SettingsView: View {
    static let windowWidth: CGFloat = 400
    static let windowHeight: CGFloat = 680
    static let minWindowWidth: CGFloat = 360
    static let minWindowHeight: CGFloat = 540
    static let paneSelectorWidth: CGFloat = 292 // 3 tiles × 92 + 2 × 8 spacing
    static let paneSelectorHeight: CGFloat = 46
    static let paneSymbolSize: CGFloat = 16
    static let paneLabelSize: CGFloat = 12
    @Bindable var model: AppModel
    @State private var section: SettingsSection
    init(model: AppModel, initialSection: SettingsSection = .general) {
        self.model = model
        _section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(section.rawValue).font(.title2.bold())
                    .frame(height: 28)
                SettingsPaneSelector(selection: $section)
            }
            .padding(.vertical, 12)
            Divider()
            Group {
                switch section {
                case .general:
                    ConfigurationView(model: model).padding()
                case .delivery:
                    DeliveryPaneView(model: model).padding()
                case .troubleshooting:
                    SourceReviewView(model: model.sourceReview, notices: model.notices, speechRunning: model.running, debugModel: model).padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(AppTypography.body)
        .frame(minWidth: Self.minWindowWidth, idealWidth: Self.windowWidth, maxWidth: .infinity,
               minHeight: Self.minWindowHeight, idealHeight: Self.windowHeight, maxHeight: .infinity)
    }
}

@MainActor
final class VoiceRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminationTask: Task<Void, Never>?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task {
                defer { terminationTask = nil }
                await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main @MainActor
struct VoiceRelayApp: App {
    @NSApplicationDelegateAdaptor(VoiceRelayApplicationDelegate.self) private var delegate
    @State private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    init() {
        umask(0o077)
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.model = model
    }
    var body: some Scene {
        MenuBarExtra("VoiceRelay", systemImage: "waveform") {
            RelayMenu(model: model)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            SettingsView(model: model).background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
        }
        .windowResizability(.contentMinSize)
        Window("VoiceRelay", id: "articles") {
            WorkspaceView(model: model)
                .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)
        WindowGroup("Article Preview", for: URL.self) { $url in
            if let url {
                ArticlePreviewView(url: url, inert: model.preview)
                    .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                    .frame(minWidth: 560, minHeight: 420)
            }
        }
        .defaultSize(width: 720, height: 560)
        .commands {
            CommandMenu("Audio") {
                if model.processingSpeech {
                    Button(model.cancelling ? "Stopping…" : "Stop Generating") { model.stopQueue() }
                        .disabled(!model.canStopProcessing)
                } else {
                    Button("Generate Speech (\(model.queueItems.count + model.pendingAdds.count))") {
                        model.workspaceSection = .queue
                        WindowPresence.shared.prepareToOpen()
                        openWindow(id: "articles")
                        model.runQueue()
                    }.disabled(!model.canGenerateAudio)
                }
            }
        }
    }
}

struct SelectionManagementControl: View {
    let selectionCount: Int
    let resetTitle: String
    let canReset: Bool
    let canRemove: Bool
    let resetHelp: String
    let removeHelp: String
    let onReset: () -> Void
    let onRemove: () -> Void
    var usesBulkRemoval: Bool { selectionCount > 1 }
    var body: some View {
        Button(usesBulkRemoval ? "Remove Selections" : resetTitle, role: .destructive) {
            usesBulkRemoval ? onRemove() : onReset()
        }
        .frame(minWidth: 128)
        .disabled(usesBulkRemoval ? !canRemove : !canReset)
        .help(usesBulkRemoval ? removeHelp : resetHelp)
    }
}

struct RowRemovalButton: View {
    let accessibilityLabel: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .help(help)
    }
}

struct QueueView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingReset = false
    private func symbol(for state: SpeechQueueState) -> String {
        switch state {
        case .queued: "checkmark.circle"
        case .running: "play.circle"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .completed: "checkmark.circle.fill"
        }
    }
    /// In-flight adds display in Reading List order below real items until each commit lands.
    private var pendingRows: [(id: String, title: String)] {
        let ordered = model.sourceReview.catalog.entries.filter { model.pendingAdds[$0.id] != nil }
            .map { (id: $0.id, title: $0.title) }
        let listed = Set(ordered.map(\.id))
        let extra = model.pendingAdds.filter { !listed.contains($0.key) }
            .sorted { $0.key < $1.key }.map { (id: $0.key, title: $0.value) }
        return ordered + extra
    }
    var body: some View {
        Group {
            if model.queueItems.isEmpty && model.pendingAdds.isEmpty {
                ContentUnavailableView("Queue Is Empty", systemImage: "list.bullet",
                                       description: Text("Add articles to the queue, then choose Generate Audio."))
            } else {
                List(selection: $model.queueSelection) {
                    ForEach(model.queueItems) { item in
                        let current = item.state == .running && model.processingSpeech
                        let mutating = model.mutatingQueueEntries.contains(.episode(item.id))
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline).lineLimit(2)
                                if let host = model.queueOriginHost(item) {
                                    Text(host).font(AppTypography.secondary).foregroundStyle(.secondary)
                                }
                                Label(item.state == .running && !model.processingSpeech ? "Interrupted; retry required" : item.state.label,
                                      systemImage: symbol(for: item.state)).foregroundStyle(.secondary)
                                if let message = item.lastError,
                                   model.notices.isVisible(message: message, key: "queue:\(item.id):\(item.attempts):\(item.state)") {
                                    InlineNotice(message: message) {
                                        model.notices.dismiss(message: message,
                                            key: "queue:\(item.id):\(item.attempts):\(item.state)")
                                    }
                                }
                            }
                            Spacer()
                            if [.paused, .failed, .running].contains(item.state) {
                                Button("Retry") { model.changeQueue(item.id, remove: false) }
                                    .disabled(model.preview || model.stopping || current || mutating)
                                    .help("Make this article ready, then choose Generate Audio.")
                            }
                            RowRemovalButton(accessibilityLabel: "Remove \(item.title) from queue",
                                help: current ? "Stop generating speech first" : "Remove from queue; saved article and audio are kept",
                                isEnabled: !model.preview && !model.stopping && !current && !mutating
                                    && !model.sourceReview.persistenceBusy) {
                                model.changeQueue(item.id, remove: true)
                            }
                        }
                        .tag(QueueSelectionID.episode(item.id))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.previewQueueItem(item, openWindow: openWindow) }
                        .contextMenu { Button("Preview Article") { model.previewQueueItem(item, openWindow: openWindow) } }
                    }
                    ForEach(pendingRows, id: \.id) { pending in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(pending.title).font(.headline).lineLimit(2)
                                if let host = model.sourceReview.catalog.entries.first(where: { $0.id == pending.id })?.url.host {
                                    Text(host).font(AppTypography.secondary).foregroundStyle(.secondary)
                                }
                                Label("Preparing…", systemImage: "clock").foregroundStyle(.secondary)
                            }
                            Spacer()
                            RowRemovalButton(accessibilityLabel: "Remove \(pending.title) preparation",
                                help: "Cancel this article preparation before it commits",
                                isEnabled: !model.preview && !model.stopping
                                    && !model.mutatingQueueEntries.contains(.preparation(pending.id))) {
                                model.removePreparation(pending.id)
                            }
                        }
                        .tag(QueueSelectionID.preparation(pending.id))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if let entry = model.sourceReview.catalog.entries.first(where: { $0.id == pending.id }) {
                                ArticlePreviewNavigation.open(entry.url, using: openWindow, inert: model.preview)
                            }
                        }
                        .contextMenu {
                            if let entry = model.sourceReview.catalog.entries.first(where: { $0.id == pending.id }) {
                                Button("Preview Article") {
                                    ArticlePreviewNavigation.open(entry.url, using: openWindow, inert: model.preview)
                                }
                            }
                        }
                    }
                }
            }
        }.onAppear { model.refreshLibrary() }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                SelectionManagementControl(selectionCount: model.queueSelection.count,
                    resetTitle: "Reset Queue…", canReset: model.canResetQueue,
                    canRemove: model.canRemoveQueueSelection,
                    resetHelp: "Remove all queued items; Reading List entries, saved text and audio are kept",
                    removeHelp: "Remove the selected items; saved text and audio are kept",
                    onReset: { confirmingReset = true }, onRemove: { model.removeSelectedQueueItems() })
            }
            ToolbarItem(placement: .primaryAction) {
                if model.processingSpeech {
                    Button {
                        model.stopQueue()
                    } label: {
                        Label(model.cancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    }
                    .disabled(!model.canStopProcessing)
                    .help("Stop speech; the unfinished article returns to Ready")
                } else {
                    Button {
                        model.runQueue()
                    } label: {
                        Label("Generate Speech (\(model.queueItems.count + model.pendingAdds.count))", systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canGenerateAudio)
                    .help("Generate speech for every ready and preparing article")
                }
            }
        }
        .confirmationDialog("Reset queue?", isPresented: $confirmingReset) {
            Button("Reset Queue", role: .destructive) { model.resetQueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all queued items? Reading List entries, saved article text and existing audio files will be kept.")
        }
    }
}

struct BatchProgressView: View {
    let progress: QueueBatchProgress
    var cancelling = false
    var pendingOverride: Int? = nil
    var body: some View {
        let pending = pendingOverride ?? progress.pendingPreparations
        VStack(alignment: .leading, spacing: 5) {
            if pending > 0 { ProgressView() }
            else { ProgressView(value: progress.fractionCompleted) }
            Text("\(phase) · \(progress.completedArticles)/\(progress.totalArticles) articles complete")
                .monospacedDigit()
            if pending > 0 {
                Text("Preparing \(pending) articles…").monospacedDigit()
            }
            if let index = progress.currentArticleIndex {
                Text("Article \(index) of \(progress.totalArticles)").monospacedDigit()
            }
        }
    }
    private var phase: String {
        if cancelling { return "Stopping…" }
        if progress.stage == .published && progress.completedArticles < progress.totalArticles {
            return "Checking saved audio"
        }
        return progress.stage.friendlyLabel
    }
}

struct SavedAudioDeliveryIndicator: View {
    let status: DeliveryPublicationStatus
    var body: some View {
        Label(title, systemImage: symbol)
            .font(AppTypography.secondary)
            .foregroundStyle(status == .published ? Color.green : status == .failed ? Color.orange : Color.secondary)
            .help(detail)
    }
    private var title: String {
        switch status {
        case .notUploaded: "Not uploaded"
        case .awaitingUpload: "Awaiting upload"
        case .uploaded: "Uploaded · awaiting publication"
        case .published: "Published"
        case .failed: "Upload failed"
        }
    }
    private var symbol: String {
        switch status {
        case .notUploaded: "icloud"
        case .awaitingUpload: "icloud.and.arrow.up"
        case .uploaded: "clock"
        case .published: "checkmark.icloud"
        case .failed: "exclamationmark.icloud"
        }
    }
    private var detail: String {
        switch status {
        case .notUploaded: "This audio has no confirmed upload to the configured server."
        case .awaitingUpload: "This audio is waiting to upload."
        case .uploaded: "The audio upload is confirmed; publishing the updated server feed is still pending."
        case .published: "The audio upload and inclusion in the server feed are confirmed."
        case .failed: "Upload needs attention. Retry with Upload New Items or check Delivery settings."
        }
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var confirmingReset = false
    @State private var capturedResetIDs: [String] = []
    var body: some View {
        Group {
            if model.savedEpisodes.isEmpty {
                ContentUnavailableView("No Server Audio", systemImage: "waveform",
                                       description: Text("Add selected articles to the queue, then choose Generate Audio."))
            } else {
                List(selection: $model.savedAudioSelection) {
                    ForEach(model.savedEpisodes, id: \.id) { episode in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.title).font(.headline).lineLimit(2)
                            let meta = model.savedAudioMeta(episode)
                            let removal = model.savedAudioRemovalStatus(episode)
                            Text(removal.map { "\($0)\(meta.map { " · " + $0 } ?? "")" }
                                 ?? meta ?? "Speech ready").font(AppTypography.secondary).foregroundStyle(.secondary)
                            if removal == nil {
                                SavedAudioDeliveryIndicator(status: model.savedAudioDeliveryStatus(episode))
                            }
                        }
                        Spacer()
                        if episode.settings.temporaryAudio != true && episode.localAudioReleased != true {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button("Show in Finder") { reveal(episode) }.disabled(model.preview)
                                    .buttonStyle(.glass).controlSize(.regular)
                                    .help("Reveal the saved audio file in Finder")
                            }
                        }
                        }
                        RowRemovalButton(accessibilityLabel: "Delete \(episode.title) audio",
                            help: "Remove this episode from the server feed and delete its audio; saved article text is kept",
                            isEnabled: model.canRemoveSavedAudio(episode)) {
                            model.removeSavedAudio(ids: [episode.id])
                        }
                    }
                    .tag(episode.id)
                    }
                }
            }
        }.task {
            guard !model.preview else { return }
            while !Task.isCancelled, !model.stopping {
                model.refreshLibrary()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .toolbar {
            if model.showsUploadNewItems {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.uploadNewItems() } label: {
                        Label(model.deliveryBusy ? "Uploading…" : "Upload New Items", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!model.canUploadNewItems)
                    .help("Upload pending audio and publish the updated feed using Delivery settings")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                SelectionManagementControl(selectionCount: model.savedAudioSelection.count,
                    resetTitle: "Reset Server Audio…", canReset: !model.savedAudioResetCandidates.isEmpty,
                    canRemove: model.savedEpisodes.contains { model.savedAudioSelection.contains($0.id) && model.canRemoveSavedAudio($0) },
                    resetHelp: "Remove all shown episodes and their server audio; saved article text is kept",
                    removeHelp: "Remove selected episodes and their server audio; saved article text is kept",
                    onReset: {
                        capturedResetIDs = model.savedAudioResetCandidates
                        confirmingReset = true
                    },
                    onRemove: { model.removeSavedAudio(ids: Array(model.savedAudioSelection)) })
            }
        }
        .confirmationDialog("Remove all server audio?", isPresented: $confirmingReset) {
            Button("Reset Server Audio", role: .destructive) {
                let ids = capturedResetIDs
                capturedResetIDs = []
                model.removeSavedAudio(ids: ids)
            }
            Button("Cancel", role: .cancel) { capturedResetIDs = [] }
        } message: {
            Text("Remove the episodes and server audio for all \(capturedResetIDs.count) shown items and remove them from the feed? Saved article text and Reading List entries are kept.")
        }
    }
    private func reveal(_ episode: Episode) {
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { model.error = "The temporary audio file is unavailable; published episodes remain on the server." }
    }
}

#if DEBUG
#Preview("Menu — inert idle") { RelayMenu(model: AppModel(preview: true)) }
#Preview("Menu — inert processing") {
    let model = AppModel(preview: true)
    model.running = true
    model.batchProgress = QueueBatchProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 8, completedArticles: 0, totalArticles: 2, currentArticleIndex: 1)
    return RelayMenu(model: model)
}
#Preview("Workspace — inert empty") { WorkspaceView(model: AppModel(preview: true)) }
#Preview("Workspace — inert queue processing") {
    let model = AppModel(preview: true)
    model.running = true
    model.processingSpeech = true
    model.workspaceSection = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic queued article", sourceHost: "articles.example"),
                       SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "A synthetic interrupted article", state: .running, attempts: 1, sourceHost: "journal.example")]
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2, currentArticleIndex: 1)
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert queue failure") {
    let model = AppModel(preview: true)
    model.workspaceSection = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic failed article", state: .failed, attempts: 1, lastError: "Synthetic feed failure")]
    model.error = "Synthetic feed failure"
    return WorkspaceView(model: model)
}
#Preview("Settings — inert defaults") { SettingsView(model: AppModel(preview: true)) }
#Preview("Settings — inert UK English voices") {
    let model = AppModel(preview: true)
    model.preferences = SpeechPreferences(voice: .george)
    return SettingsView(model: model)
}
#Preview("Settings — inert troubleshooting") { SettingsView(model: AppModel(preview: true), initialSection: .troubleshooting) }
#Preview("Queue — inert waiting and interrupted") {
    let model = AppModel(preview: true)
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic queued article"),
                       SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "A synthetic interrupted article", state: .running, attempts: 1)]
    return QueueView(model: model)
}
#Preview("Queue — global encoding progress") {
    let model = AppModel(preview: true)
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2)
    return QueueView(model: model)
}
#Preview("Server Audio — inert empty library") { LibraryView(model: AppModel(preview: true)) }
#Preview("Server Audio — inert delivery states") {
    let model = AppModel(preview: true)
    model.deliverySettings.enabled = true
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://podcast.example/")
    model.deliveryPublicationSettingsHash = try? model.deliverySettings.publicationHash()
    let settings = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic/Articles"))
    if let bytes = try? JSONEncoder().encode(settings), let profile = try? JSONSerialization.jsonObject(with: bytes) {
        for (index, state) in [DeliveryPublicationStatus.notUploaded, .awaitingUpload, .uploaded, .published, .failed].enumerated() {
            let id = "00000000-0000-0000-0000-00000000000\(index)", hash = "synthetic-copy-\(index)"
            let record: [String: Any] = ["id": "00000000-0000-0000-0000-00000000000\(index)",
                "title": "A synthetic saved article \(index + 1)", "stage": Stage.published.rawValue,
                "audioHash": hash, "settings": profile]
            if let data = try? JSONSerialization.data(withJSONObject: record),
               let episode = try? JSONDecoder().decode(Episode.self, from: data) { model.savedEpisodes.append(episode) }
            model.deliveryPublicationStates[id] = state
            model.deliveryPublicationAudioHashes[id] = hash
        }
    }
    return LibraryView(model: model)
}
#endif
