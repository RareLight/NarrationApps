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
    var articleScope: ArticleScope = .all
    var articlesWebsiteFilter: ArticleWebsiteFilter = .all
    var queueWebsiteFilter: ArticleWebsiteFilter = .all
    var retainedArticleSelection: Set<QueueSelectionID> = []
    var queueSavedDates: [String: Date] = [:]
    var settingsSection: SettingsSection = .general
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
    var uploadsFilter: AudioStateFilter = .all
    var serverAudioFilter: AudioStateFilter = .all
    var uploadProgress: [String: UploadProgress] = [:]
    var deliveryVerificationFailedIDs: Set<String> = []
    var deliveryFeedError: String?
    @ObservationIgnored private var uploadRunID = UUID()
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
    @ObservationIgnored private var presentationDeliverySettings: DeliverySettings?
    @ObservationIgnored private var presentationDeliveryIdentity: String?
    var deliveryPreflightBusy = false
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
    var useArchivedArticles = false {
        didSet { if !preview { defaults.set(useArchivedArticles, forKey: "useArchivedArticles") } }
    }
    var sourceReview = SourceReviewModel(preview: true)
    var runtimeProject = SpeechRuntimeSetup.managedRoot
    var runtimeBusy = false
    var runtimeStatus = "Not checked"
    var runtimeError: String?
    var runtimeVerificationFailed = false
    var libraryMaintenanceBusy = false
    var libraryBackupStatus: String?
    var libraryBackupError: String?
    var libraryReviewRequired = false {
        didSet { if !preview { defaults.set(libraryReviewRequired, forKey: "libraryReviewRequired") } }
    }
    @ObservationIgnored private var runtimeTask: Task<Void, Never>?
    @ObservationIgnored private var libraryMaintenanceTask: Task<Void, Never>?
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
    @ObservationIgnored private let archiveFetchOverride: ArticleSourceLoader.ArchiveFetch?
    @ObservationIgnored private let defaults: UserDefaults
    /// Delivery seams: production gets Keychain + URLSession; injected models get nil unless a
    /// test supplies fakes, so isolated models can never touch the network or Keychain.
    @ObservationIgnored private let deliveryTransportFactory: (@Sendable () -> any DeliveryTransport)?
    @ObservationIgnored private let deliveryCredentialStore: SessionDeliveryCredentialStore?

    init(preview: Bool = false, storage: ManagedSpeechStorage? = nil,
         backend: (@Sendable (Episode) throws -> any TTSBackend)? = nil,
         enqueueFetch: (@Sendable (URL) async throws -> FetchedPage)? = nil,
         archiveFetch: ArticleSourceLoader.ArchiveFetch? = nil,
         defaults: UserDefaults = .standard,
         deliveryTransport: (@Sendable () -> any DeliveryTransport)? = nil,
         credentialStore: (any DeliveryCredentialStore)? = nil) {
        storageOverride = storage; backendOverride = backend; enqueueFetchOverride = enqueueFetch
        archiveFetchOverride = archiveFetch
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
        libraryReviewRequired = defaults.bool(forKey: "libraryReviewRequired")
        loadDeliverySettings()
        // Isolated lifecycle tests supply storage/providers and never read user preferences or Safari.
        if storage != nil { return }
        if let bytes = defaults.data(forKey: "speechPreferences") {
            do {
                let saved = try JSONDecoder().decode(SpeechPreferences.self, from: bytes)
                try saved.validate(); preferences = saved
            } catch { self.error = "Saved voice and speed preferences could not be read. Default voice and speed are active." }
        }
        runtimeProject = SpeechRuntimeSetup.preferredRoot(
            saved: defaults.string(forKey: "runtimeProject").map { URL(fileURLWithPath: $0) },
            legacy: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Coding/VoiceRelay"))
        runtimeStatus = speechRuntimeAvailable ? "Existing installation — not checked" : "Setup required"
        autoAdmitEnabled = defaults.object(forKey: "autoAdmitArticles") as? Bool ?? true
        autoProcessEnabled = defaults.object(forKey: "autoProcessArticles") as? Bool ?? true
        useArchivedArticles = defaults.bool(forKey: "useArchivedArticles")
        refreshLibrary()
        startAutomationLoop()
        sourceReview.startAutomaticSynchronization()
        triggerDelivery()
    }
    private func loadDeliverySettings() {
        guard let bytes = defaults.data(forKey: "deliverySettings") else { return }
        guard var saved = try? JSONDecoder().decode(DeliverySettings.self, from: bytes) else {
            self.error = "Saved Publishing settings could not be read. Publishing is disabled until they are fixed."
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
        // Filters are read-only: normalize/hash once per edit, never once per row or byte event.
        presentationDeliverySettings = try? deliverySettings.normalized()
        presentationDeliveryIdentity = try? presentationDeliverySettings?.publicationHash()
        cancelDeliveryTest()
        refreshDeliveryCredentialState()
        guard !preview else { return }
        if let bytes = try? JSONEncoder().encode(deliverySettings) {
            defaults.set(bytes, forKey: "deliverySettings")
        }
        // Restore suspends preferences before staging; don't create or mutate its target ledger.
        guard !libraryMaintenanceBusy else { return }
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
        guard !preview, !stopping, !audioMutationBusy, !libraryMaintenanceBusy, !libraryReviewRequired, !deliveryCredentialBusy, deliverySettings.enabled,
              (try? deliverySettings.validate()) != nil,
              let makeTransport = deliveryTransportFactory, let credential = deliveryCredentialStore else { return }
        if deliveryTask != nil { pendingDeliveryForce = (pendingDeliveryForce ?? false) || force; return }
        if force { credential.retryFailedAccess(username: deliverySettings.credentialUsername, host: deliverySettings.credentialHost) }
        let storage = speechStorage, settings = deliverySettings
        let ledger = try? DeliveryLedger.load(stateRoot: storage.stateRoot)
        deliveryPreflightBusy = !running && (ledger?.destinationURL != settings.feedFolderURL || ledger?.reconciliationAttemptAt == nil || Date().timeIntervalSince(ledger?.reconciliationAttemptAt ?? .distantPast) >= 300)
        deliveryBusy = true
        uploadProgress = [:]
        let uploadToken = UUID(); uploadRunID = uploadToken
        deliveryDebugLog.record(.deliveryStarted)
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                uploadRunID = UUID(); uploadProgress = [:]
                deliveryTask = nil; deliveryBusy = false; deliveryPreflightBusy = false; refreshDeliveryCredentialState()
                audioLibraryRevision = UUID()
                refreshLibrary(allowDelivery: false)
                let again = pendingDeliveryForce; pendingDeliveryForce = nil
                if let again { triggerDelivery(force: again) }
            }
            do {
                let result = try await coordinator.deliverPending(storage: storage, settings: settings,
                    credential: credential, transport: LoggingDeliveryTransport(base: makeTransport(), log: deliveryDebugLog),
                    force: force, debugLog: deliveryDebugLog, progress: { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self, self.uploadRunID == uploadToken, !self.stopping else { return }
                            self.uploadProgress[event.episode.id] = event
                            if let index = self.savedEpisodes.firstIndex(where: { $0.id == event.episode.id }) {
                                self.savedEpisodes[index] = event.episode
                            } else { self.savedEpisodes.append(event.episode) }
                        }
                    })
                try Task.checkCancellation()
                if let summary = try? await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings) {
                    recordDeliveryPublication(summary)
                    deliveryPendingCount = summary.pendingMedia + summary.pendingRemoteDeletes
                    deliveryError = summary.lastError
                }
                // Refresh the outbox even while the inference worker is busy.
                if let episodes = try? await coordinator.savedAudio(storage: storage) { savedEpisodes = episodes }
                uploadRunID = UUID(); uploadProgress = [:]
                deliveryStatus = Self.deliveryStatusText(result, hasError: deliveryError != nil)
                if deliveryError == nil { notices.reset(key: "delivery") }
                if !running {
                    audioLibraryRevision = UUID()
                    refreshLibrary(allowDelivery: false)
                    await waitForLibraryRefresh()
                }
                deliveryDebugLog.record(.deliveryFinished)
            } catch is CancellationError {
            } catch {
                deliveryDebugLog.recordFailure(error)
                deliveryError = (error as? RelayError)?.localizedDescription
                    ?? (error as? DeliveryError)?.localizedDescription
                    ?? "Publishing failed; saved progress is retained."
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
        return parts.isEmpty ? (hasError ? "Publishing needs attention" : "Publishing up to date") : parts.joined(separator: " · ")
    }
    func testDeliveryConnection() {
        guard !preview, !stopping, !deliveryCredentialBusy, !deliveryTesting else { return }
        let settings = deliverySettings
        guard let makeTransport = deliveryTransportFactory, let credential = deliveryCredentialStore else {
            deliveryTestResult = .failure("Publishing is unavailable"); return
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
    var canGenerateAudio: Bool { !deliveryPreflightBusy && !preview && !stopping && !runtimeBusy && !libraryMaintenanceBusy && !libraryReviewRequired && speechRuntimeAvailable && !running && !audioMutationBusy
                                 && !sourceReview.persistenceBusy && (readyQueueCount > 0 || !pendingAdds.isEmpty) }
    var canStopProcessing: Bool { !preview && !stopping && processingSpeech && !cancelling }
    var canResetQueue: Bool { !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !running && !cancelling && !isQueueResetPending
                              && !sourceReview.persistenceBusy && (!queueItems.isEmpty || !pendingAdds.isEmpty) }
    var showsProcessingProgress: Bool { processingSpeech || cancelling }
    var workspaceError: String? {
        guard let error else { return nil }
        if workspaceSection == .articles {
            if articleScope == .queue, queueItems.contains(where: { $0.lastError == error }) { return nil }
            if articleScope == .all, allArticleRows.contains(where: { $0.jobs.count == 1 && $0.jobs[0].lastError == error }) { return nil }
        }
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
        guard !preview, !stopping, !libraryMaintenanceBusy, !running else { return }
        if libraryTask != nil {
            pendingLibraryRefresh = (pendingLibraryRefresh ?? false) || allowDelivery
            return
        }
        let token = progressID, audioRevision = audioLibraryRevision
        let sweepsBlocked = audioMutationBusy || libraryReviewRequired || deliveryPreflightBusy
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
                queueSavedDates = Dictionary(uniqueKeysWithValues: library.compactMap { episode in
                    episode.readingListSavedAt.map { (episode.id, $0) }
                })
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
        allArticleRows.filter(articlesWebsiteFilter.includes).compactMap(\.source).filter { articleSelection.contains($0.id) }
    }
    var eligibleSelectedArticles: [ReadingListEntry] {
        selectedArticles.filter { entry in
            pendingAdds[entry.id] == nil && !queueItems.contains { $0.sourceEntryID == entry.id }
        }
    }
    var canAddSelectedArticles: Bool {
        !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !queueMutationBusy
            && !sourceReview.busy && !sourceReview.persistenceBusy && !eligibleSelectedArticles.isEmpty
    }
    func queueOriginHost(_ item: SpeechQueueItem) -> String? {
        item.sourceHost ?? sourceReview.catalog.entries.first { $0.id == item.sourceEntryID }?.url.host
    }
    /// Adds return immediately; a dedicated background task prepares each entry in order.
    /// Per-entry failures are collected as issues instead of stopping the remaining adds.
    func addSelectedToQueue() {
        guard canAddSelectedArticles else { return }
        let entries = eligibleSelectedArticles
        guard !entries.isEmpty else { return }
        admit(entries: entries, automatic: false)
    }
    /// Shared admission path for manual Add to Queue and automatic discovery adds.
    private func admit(entries: [ReadingListEntry], automatic: Bool) {
        guard !libraryMaintenanceBusy, !stopping else { return }
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
        guard !libraryMaintenanceBusy, !libraryReviewRequired, !deliveryPreflightBusy else { return }
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
                        fetch: fetch, useArchives: useArchivedArticles && (storageOverride == nil || archiveFetchOverride != nil),
                        archiveFetch: archiveFetchOverride, debugLog: deliveryDebugLog, shouldCommit: { [weak self] in
                            await MainActor.run { self != nil && !self!.stopping && self!.pendingTokens[entry.id] == next.token }
                        }, admissionControl: next.control)
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                        if let index = queueItems.firstIndex(where: { $0.id == item.id }) { queueItems[index] = item }
                        else { queueItems.append(item) }
                        transferPreparationSelection(sourceID: entry.id, episodeID: item.id)
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
        ?? (error as? ArticleRecoveryError)?.localizedDescription
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
        guard !preview, !stopping, !libraryMaintenanceBusy, !libraryReviewRequired, !sourceReview.persistenceBusy,
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
        !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !queueMutationBusy && !sourceReview.persistenceBusy && !queueSelection.isEmpty
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
        guard !preview, !stopping, !libraryMaintenanceBusy, !libraryReviewRequired, !sourceReview.persistenceBusy else { return }
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
                if delivery != nil { triggerDelivery(); await waitForDelivery() }
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
        guard !preview, !running, !stopping, !runtimeBusy, !libraryMaintenanceBusy, !libraryReviewRequired, speechRuntimeAvailable, !sourceReview.persistenceBusy else { return }
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
    func savedAudioOrigin(_ episode: Episode) -> ArticleOriginMetadata {
        ArticleOriginMetadata(host: episode.originalSourceHost ?? episode.sourceHost ?? episode.sourceURL?.host,
                              savedAt: episode.readingListSavedAt)
    }
    /// Audio metadata is separate from the original website and Reading List save date.
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
        deliveryVerificationFailedIDs = summary.verificationFailedIDs
        deliveryFeedError = summary.feedError
    }
    func savedAudioDeliveryStatus(_ episode: Episode) -> DeliveryPublicationStatus {
        guard let settings = presentationDeliverySettings else { return .notUploaded }
        if let identity = presentationDeliveryIdentity, identity == deliveryPublicationSettingsHash,
           deliveryPublicationAudioHashes[episode.id] == episode.audioHash,
           let state = deliveryPublicationStates[episode.id] { return state }
        return DeliveryPublicationStatus.unconfirmed(episode, settings: settings)
    }
    func audioState(_ episode: Episode) -> UploadItem {
        UploadItem(episode: episode, publication: savedAudioDeliveryStatus(episode),
            blocked: presentationDeliveryIdentity != nil && deliveryPublicationSettingsHash == presentationDeliveryIdentity && deliveryVerificationFailedIDs.contains(episode.id),
            feedError: presentationDeliveryIdentity != nil && deliveryPublicationSettingsHash == presentationDeliveryIdentity ? deliveryFeedError : nil,
            progress: deliveryBusy ? uploadProgress[episode.id] : nil)
    }
    var uploadItems: [UploadItem] { savedEpisodes.map(audioState).filter(\.isInOutbox) }
    var visibleUploads: [UploadItem] { uploadItems.filter { uploadsFilter.includes($0.phase) } }
    var visibleServerAudio: [Episode] { savedEpisodes.filter { serverAudioFilter.includes(audioState($0).phase) } }
    var uploadsNeedAttention: Bool { uploadItems.contains { $0.phase.needsAttention } }
    var canRetryUploads: Bool {
        !uploadItems.isEmpty && deliverySettings.enabled && !preview && !stopping && !audioMutationBusy && !deliveryBusy
            && !deliveryCredentialBusy && !libraryMaintenanceBusy && !libraryReviewRequired
            && (try? deliverySettings.validate()) != nil && deliveryTransportFactory != nil && deliveryCredentialStore != nil
    }
    func retryUploads() { if canRetryUploads { triggerDelivery(force: true) } }
    var hasNewItemsToUpload: Bool {
        savedEpisodes.contains { $0.stage == .published && $0.localAudioDiscarded != true && $0.manualAudioDeletionRequested != true
            && savedAudioDeliveryStatus($0) != .published }
    }
    var showsUploadNewItems: Bool { deliverySettings.enabled && hasNewItemsToUpload }
    var canUploadNewItems: Bool {
        showsUploadNewItems && !preview && !stopping && !deliveryBusy && !deliveryCredentialBusy
            && !libraryMaintenanceBusy && !libraryReviewRequired
            && (try? deliverySettings.validate()) != nil
            && deliveryTransportFactory != nil && deliveryCredentialStore != nil
    }
    func uploadNewItems() {
        guard canUploadNewItems else { return }
        triggerDelivery(force: true)
    }
    var canDeleteSavedAudio: Bool {
        !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !processingSpeech && !cancelling && !audioMutationBusy
            && !sourceReview.persistenceBusy && !savedEpisodes.isEmpty
    }
    func canRemoveSavedAudio(_ episode: Episode) -> Bool {
        canDeleteSavedAudio && !mutatingSavedAudioIDs.contains(episode.id)
            && !(episode.stage == .expired && deliveryBusy)
    }
    func finishLibraryReview() {
        guard canManageLibrary, libraryReviewRequired else { return }
        libraryReviewRequired = false
        libraryBackupStatus = "Review complete. Automatic processing and delivery stay off until you enable them."
        refreshLibrary(allowDelivery: false)
    }
    func savedAudioRemovalStatus(_ episode: Episode) -> String? {
        if mutatingSavedAudioIDs.contains(episode.id) || (episode.stage == .expired && deliveryBusy) { return "Removing from server…" }
        if episode.stage == .expired || episode.manualAudioDeletionRequested == true { return deliveryError == nil ? "Server removal pending" : "Removal needs retry" }
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
    func canDiscardLocalUpload(_ item: UploadItem) -> Bool {
        canDeleteSavedAudio && !running && !deliveryBusy && !deliveryTesting && !deliveryPreflightBusy
            && item.isInOutbox && !mutatingSavedAudioIDs.contains(item.id)
    }
    func discardLocalUpload(_ item: UploadItem) {
        guard canDiscardLocalUpload(item) else { return }
        let storage = speechStorage, id = item.id
        audioLibraryRevision = UUID(); audioMutationBusy = true; mutatingSavedAudioIDs.insert(id)
        audioMutationTask = Task {
            defer {
                audioMutationTask = nil; audioMutationBusy = false; mutatingSavedAudioIDs.remove(id)
                audioLibraryRevision = UUID(); refreshLibrary()
            }
            do {
                try await coordinator.discardLocalUpload(id: id, storage: storage)
                savedEpisodes = try await coordinator.savedAudio(storage: storage)
            } catch is CancellationError {
            } catch {
                // Reload persisted per-item removal intent even when unlink failed.
                if let episodes = try? await coordinator.savedAudio(storage: storage) { savedEpisodes = episodes }
                self.error = (error as? RelayError)?.localizedDescription ?? "The local upload could not be removed."
                deliveryDebugLog.record(.localCleanupFailed)
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
    func waitForLibraryMaintenance() async { if let libraryMaintenanceTask { await libraryMaintenanceTask.value } }
    func shutdown() async {
        stopping = true
        // Stop owned work before terminating the UI.
        progressID = UUID()
        let current = task, enqueue = enqueueTask, library = libraryTask
        let mutation = queueMutationTask, audioMutation = audioMutationTask, preview = previewTask
        let delivery = deliveryTask, deliveryTest = deliveryTestTask, automation = automationTask, credential = deliveryCredentialTask
        let runtime = runtimeTask, maintenance = libraryMaintenanceTask
        previewRequestID = UUID()
        current?.cancel(); enqueue?.cancel(); library?.cancel(); mutation?.cancel()
        audioMutation?.cancel(); preview?.cancel(); delivery?.cancel(); deliveryTest?.cancel(); automation?.cancel()
        credential?.cancel(); deliveryCredentialStore?.cancelAuthentication()
        runtime?.cancel(); maintenance?.cancel()
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
        if let runtime { await runtime.value }
        if let maintenance { await maintenance.value }
        deliveryCredentialStore?.clearSession()
        deliveryPassword = ""; deliveryPasswordStored = false; deliveryPasswordChecked = false
    }
    func quit() { NSApplication.shared.terminate(nil) }

    var speechRuntimeAvailable: Bool {
        !runtimeVerificationFailed && (storageOverride != nil || backendOverride != nil ||
            (FileManager.default.isExecutableFile(atPath: runtimeProject.appendingPathComponent(".runtime/kokoro/.venv/bin/python").path)
             && ToolRunner.locate("ffmpeg") != nil && ToolRunner.locate("ffprobe") != nil))
    }
    var canManageLibrary: Bool {
        !preview && !stopping && !running && !runtimeBusy && !libraryMaintenanceBusy && pendingAdds.isEmpty
            && !queueMutationBusy && !audioMutationBusy && !deliveryBusy && !deliveryTesting
            && !deliveryCredentialBusy && !sourceReview.busy && !sourceReview.persistenceBusy && libraryTask == nil
    }
    func checkSpeechRuntime() {
        beginRuntimeSetup(install: false)
    }
    func installSpeechRuntime() {
        beginRuntimeSetup(install: true)
    }
    private func beginRuntimeSetup(install: Bool) {
        guard canManageLibrary, storageOverride == nil else { return }
        let root = install ? SpeechRuntimeSetup.managedRoot : runtimeProject
        runtimeBusy = true; runtimeError = nil
        runtimeStatus = install ? "Installing speech runtime…" : "Checking speech runtime…"
        runtimeTask = Task { [weak self] in
            guard let self else { return }
            defer { runtimeTask = nil; runtimeBusy = false }
            let worker = Task.detached {
                if install { try SpeechRuntimeSetup.install(at: root) }
                else { try SpeechRuntimeSetup.check(at: root) }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !stopping else { return }
                if install { runtimeProject = root; defaults.set(root.path, forKey: "runtimeProject") }
                runtimeVerificationFailed = false
                runtimeStatus = "Speech runtime verified"
            } catch {
                guard !stopping else { return }
                if root.standardizedFileURL == runtimeProject.standardizedFileURL { runtimeVerificationFailed = true }
                runtimeStatus = "Needs attention"
                runtimeError = error is CancellationError ? "Speech setup cancelled. You can retry installation."
                    : (error as? RelayError)?.localizedDescription ?? "Speech setup failed. See the setup guide."
            }
        }
    }
    func cancelRuntimeSetup() { runtimeTask?.cancel() }
    func chooseLibraryBackup() {
        guard canManageLibrary else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up VoiceRelay Library"
        panel.nameFieldStringValue = "VoiceRelay-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).voicerelaybackup"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backUpLibrary(to: url)
    }
    func backUpLibrary(to url: URL) {
        guard canManageLibrary else { return }
        let storage = speechStorage
        libraryMaintenanceBusy = true; libraryBackupError = nil; libraryBackupStatus = "Backing up library…"
        audioLibraryRevision = UUID()
        libraryMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            defer { libraryMaintenanceTask = nil; libraryMaintenanceBusy = false }
            do {
                let summary = try await coordinator.backupLibrary(storage: storage, destination: url)
                libraryBackupStatus = "Backed up \(summary.retainedArticles) articles and \(summary.episodes) episode records."
            } catch {
                libraryBackupStatus = nil
                libraryBackupError = (error as? RelayError)?.localizedDescription ?? "Library backup failed. Existing state is unchanged."
            }
        }
    }
    func restoreLibrary(from url: URL) {
        guard canManageLibrary else { return }
        let storage = speechStorage
        libraryMaintenanceBusy = true; libraryBackupError = nil; libraryBackupStatus = "Restoring library…"
        audioLibraryRevision = UUID()
        // Even a post-commit disk error must never resume stale delivery intentions.
        autoAdmitEnabled = false; autoProcessEnabled = false; autoHalted = true
        libraryReviewRequired = true
        defaults.set(false, forKey: "autoAdmitArticles"); defaults.set(false, forKey: "autoProcessArticles")
        deliverySettings.enabled = false
        libraryMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            defer { libraryMaintenanceTask = nil; libraryMaintenanceBusy = false; refreshLibrary(allowDelivery: false) }
            do {
                let previous = try await coordinator.restoreLibrary(backup: url, storage: storage)
                sourceReview.loadCatalog()
                libraryBackupStatus = previous == nil
                    ? "Library restored. Review Queue, Server Audio and Publishing before enabling automation."
                    : "Library restored; the previous library is kept for recovery. Review Queue, Server Audio and Publishing before enabling automation."
            } catch {
                libraryBackupStatus = nil
                libraryBackupError = (error as? RelayError)?.localizedDescription ?? "Library restore failed. Existing state is preserved."
            }
        }
    }
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
    case uploads = "Uploads"
    case savedAudio = "Server Audio"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .articles: "doc.text"
        case .uploads: "tray.and.arrow.up"
        case .savedAudio: "waveform"
        }
    }
}

enum PublishingReadiness: Equatable {
    case needsSetup, configured, turnedOff, needsAttention, notChecked
    var title: String {
        switch self {
        case .needsSetup: "Publishing needs setup"
        case .configured: "Publishing configured"
        case .turnedOff: "Publishing is turned off"
        case .needsAttention: "Publishing needs attention"
        case .notChecked: "Publishing has not been checked"
        }
    }
    var detail: String {
        switch self {
        case .needsSetup: "Configure your podcast connection to listen in your podcast app. You can still generate audio."
        case .configured: "Configuration is present; write permission and public access are verified separately."
        case .turnedOff: "Enable Publishing when you want new episodes in your podcast app."
        case .needsAttention: "Review pending transfers and verification issues in Uploads, or check Publishing settings."
        case .notChecked: "The password has not been checked this session. Review Publishing to verify the connection."
        }
    }
    var action: String {
        switch self {
        case .needsSetup: "Set Up Publishing…"
        case .needsAttention: "Review Publishing…"
        default: "Publishing Settings…"
        }
    }
}

extension AppModel {
    /// Read existing presentation state only. This never queries Keychain or the network.
    var publishingReadiness: PublishingReadiness {
        var required = deliverySettings
        required.enabled = true
        if required.feedFolderURL == nil || required.publicFolderURL == nil || (try? required.validate()) == nil {
            return .needsSetup
        }
        if !deliverySettings.enabled { return .turnedOff }
        if deliveryError != nil || uploadsNeedAttention { return .needsAttention }
        if !deliveryPasswordChecked { return .notChecked }
        return deliveryPasswordStored ? .configured : .needsSetup
    }
    var eligibleGenerationCount: Int { readyQueueCount + pendingAdds.count }
    /// Idle setup and errors have dedicated notices; the footer is only for owned work.
    var showsWorkspaceActivity: Bool { showsProcessingProgress || deliveryBusy }
    var generationDisabledReason: String? {
        if libraryReviewRequired { return "Review the restored library before processing resumes." }
        if deliveryPreflightBusy { return "Checking the existing server feed before processing resumes." }
        if libraryMaintenanceBusy { return "Wait for library maintenance to finish." }
        if stopping { return "VoiceRelay is quitting; owned work is stopping." }
        if runtimeBusy { return "Wait for speech setup to finish, or cancel it in General." }
        if !preview && !speechRuntimeAvailable { return "Speech setup is required before generating audio." }
        if cancelling { return "Stopping… Wait for owned work to finish." }
        if running { return "Audio work is already running." }
        if audioMutationBusy || sourceReview.persistenceBusy { return "Waiting for library changes to finish." }
        if eligibleGenerationCount == 0 { return "No Ready articles. Add articles or retry a failed item." }
        return nil
    }
}

struct GenerateAudioControl: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.processingSpeech {
            Button { model.stopQueue() } label: {
                Label(model.cancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
            }.disabled(!model.canStopProcessing)
                .help("Stop generation; unfinished article returns to Ready")
        } else {
            Button { model.runQueue() } label: { Label("Generate Audio", systemImage: "waveform") }
                .buttonStyle(.borderedProminent).disabled(!model.canGenerateAudio)
                .help(model.generationDisabledReason ?? "Generate all Ready articles, regardless of selection or filters")
        }
    }
}

struct WorkspaceReadinessView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if model.libraryReviewRequired {
            notice("Review the restored library", detail: "Processing, publishing and cleanup wait until you finish the library review.",
                   symbol: "exclamationmark.triangle", action: "Review Library…", pane: .troubleshooting)
        } else {
            if !model.preview && (!model.speechRuntimeAvailable || model.runtimeBusy) {
                notice(model.runtimeBusy ? "Speech setup is in progress" : "Speech setup required",
                    detail: model.runtimeBusy ? "Wait for setup, or cancel it in General." : "Install or check the speech runtime in General before generating audio.",
                    symbol: "gearshape", action: "Open General", pane: .general)
            }
            if model.uploadsNeedAttention {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Uploads need attention", systemImage: "exclamationmark.triangle").font(.headline)
                    Text("Review the affected files and their verification details in Uploads.").font(AppTypography.secondary).foregroundStyle(.secondary)
                    if model.workspaceSection != .uploads {
                        Button("Review Uploads") { model.workspaceSection = .uploads }.disabled(model.preview || model.stopping)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(alignment: .bottom) { Divider() }
            } else if model.publishingReadiness != .configured {
                let readiness = model.publishingReadiness
                notice(readiness.title, detail: readiness.detail,
                    symbol: readiness == .needsAttention ? "exclamationmark.triangle" : "gearshape",
                    action: readiness.action, pane: .delivery)
            }
        }
    }
    private func notice(_ title: String, detail: String, symbol: String, action: String, pane: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(AppTypography.secondary).foregroundStyle(.secondary)
            Button(action) {
                model.settingsSection = pane
                WindowPresence.shared.prepareToOpen(); openSettings()
            }.disabled(model.preview || model.stopping)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(alignment: .bottom) { Divider() }
    }
}

struct WorkspaceActivityView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showsProcessingProgress { ProcessingSummary(model: model) }
            if model.deliveryBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Publishing… · \(model.deliveryPendingCount) server operations pending").monospacedDigit()
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

extension Stage {
    var friendlyLabel: String {
        switch self {
        case .discovered, .fetching: "Preparing article"
        case .extracted: "Preparing audio"
        case .synthesizing: "Generating audio"
        case .encoding, .encoded: "Finishing audio"
        case .published: "Audio generated"
        case .expired: "Audio expired"
        }
    }
}

enum AppTypography {
    static let body = Font.body
    static let secondary = Font.system(size: 12)
    static let minimumPointSize: CGFloat = 12
}

struct ArticleOriginMetadata: Equatable {
    let host: String?
    let savedAt: Date?
    var savedDateText: String? { savedAt.map { "Saved \($0.formatted(date: .abbreviated, time: .omitted))" } }
}

/// Shared identity line for All Articles, Queue/preparing rows and Server Audio.
struct ArticleOriginLine: View {
    let metadata: ArticleOriginMetadata
    var body: some View {
        if metadata.host != nil || metadata.savedAt != nil {
            HStack(spacing: 6) {
                if let host = metadata.host { Text(host) }
                if let date = metadata.savedDateText { Text(date) }
            }.font(AppTypography.secondary).foregroundStyle(.secondary)
        }
    }
}

enum AppHelpTopic: String, Codable, CaseIterable, Identifiable {
    case publishing, libraryBackup
    var id: Self { self }
    var title: String {
        switch self {
        case .publishing: "Publishing and Uploads"
        case .libraryBackup: "Library Backup and Restore"
        }
    }
    var sections: [AppHelpSection] {
        switch self {
        case .publishing: [
            AppHelpSection(title: "Connect your podcast", text: "In Publishing settings, enter the WebDAV Feed folder and the Public folder that serves the same files. VoiceRelay creates feed.xml and audio/ under that folder. Copy the Subscription URL into your podcast app. Test Connection checks folder access; confirm public playback in your podcast app separately."),
            AppHelpSection(title: "Save your password", text: "Use your provider’s upload username and password or app password. Click Save Password after editing. macOS may offer Touch ID, a supported paired Apple Watch, or your Mac password to unlock Keychain. Opening Settings does not unlock it. Replacing or clearing a password may need separate approval."),
            AppHelpSection(title: "Watch pending uploads", text: "Publishing runs automatically while enabled and VoiceRelay is running. Uploads shows pending transfers and verification issues. An item clears after its audio and feed entry are confirmed, unless local cleanup needs attention. Fully sent bytes alone do not confirm publication. Use Retry Uploads after resolving an error; other items can continue."),
            AppHelpSection(title: "Remove a copy", text: "Uploads × discards the local copy and cancels its pending generation job, keeping server audio and saved article text. It will not automatically regenerate. Add the article to Queue to request it again. Server Audio × removes the episode from the feed and deletes its audio, including a matching local copy. Saved article text is kept. Files that cannot be safely removed stay listed."),
            AppHelpSection(title: "Existing server episodes", text: "VoiceRelay checks for matching server audio before generating or uploading again. It verifies complete copies and prefers longer valid audio at comparable voice and speed; ties and uncertain variants keep the server copy. For persistent errors, enable debug logging in Troubleshooting and copy the log.")
        ]
        case .libraryBackup: [
            AppHelpSection(title: "What a backup contains", text: "A library backup contains saved article text, Reading List inventory, Queue, episode history and publishing records. It includes private article URLs and server paths; keep it private. Passwords, preferences, audio, speech models and temporary chunks are excluded."),
            AppHelpSection(title: "Restore safely", text: "Stop processing and wait for uploads and additions to finish. Choose Restore Library in Troubleshooting. VoiceRelay validates the backup, keeps the previous library for recovery and turns off automatic processing and publishing. Restoring does not change Safari or contact the server."),
            AppHelpSection(title: "Finish your review", text: "Review Articles, Uploads, Server Audio and Publishing settings, then choose Finish Library Review. Until then, local cleanup and server changes are blocked, including after relaunch. Finishing review does not turn automation back on; enable it when ready. Missing pending audio can be regenerated from saved text.")
        ]
        }
    }
}
struct AppHelpSection: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}
struct AppHelpView: View {
    let topic: AppHelpTopic
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(topic.title).font(.title2)
                ForEach(topic.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.headline)
                        Text(section.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.font(AppTypography.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.navigationTitle(topic.title)
    }
}

struct SectionHelpHeader: View {
    let title: String
    var explanation: String?
    var helpTopic: AppHelpTopic? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var showingInfo = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let explanation {
                Button { showingInfo = true } label: {
                    Image(systemName: "info.circle").font(AppTypography.secondary)
                }
                .buttonStyle(.plain)
                .help("About \(title)")
                .accessibilityLabel("About \(title)")
                .accessibilityHint("Show a brief explanation")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(explanation).textSelection(.enabled)
                        if let helpTopic {
                            Button("More Help…") {
                                showingInfo = false
                                WindowPresence.shared.prepareToOpen(); openWindow(value: helpTopic)
                            }
                        }
                    }.font(AppTypography.secondary)
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
            Button("Generate Audio") {
                model.workspaceSection = .articles; model.articleScope = .queue
                openWorkspace()
                model.runQueue()
            }.disabled(!model.canGenerateAudio)
        }
        Divider()
        Button("Articles") { model.articleScope = .all; openWorkspace(.articles) }.disabled(model.preview)
        Button("Queue") { model.articleScope = .queue; openWorkspace(.articles) }.disabled(model.preview)
        Button("Uploads") { openWorkspace(.uploads) }.disabled(model.preview)
        Button("Server Audio") { openWorkspace(.savedAudio) }.disabled(model.preview)
        Divider()
        Button("Publishing Settings…") { model.settingsSection = .delivery; WindowPresence.shared.prepareToOpen(); openSettings() }.disabled(model.preview)
        Button("Settings…") { model.settingsSection = .general; WindowPresence.shared.prepareToOpen(); openSettings() }.disabled(model.preview)
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
        .disabled(model.libraryMaintenanceBusy)
        .onAppear { model.refreshLibrary() }
    }
    private var detail: some View {
        VStack(spacing: 0) {
            if section != .articles { WorkspaceReadinessView(model: model) }
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
            case .uploads: UploadsView(model: model)
            case .savedAudio: LibraryView(model: model)
            }
            if model.showsWorkspaceActivity {
                Divider()
                WorkspaceActivityView(model: model)
            }
        }
        .navigationTitle(section == .articles && model.articleScope == .queue ? "Articles — Queue" : section.rawValue)
    }
}

struct ConfigurationView: View {
    @Bindable var model: AppModel
    @State private var confirmingInstallation = false
    var body: some View {
        Form {
            if !model.speechRuntimeAvailable { speechSetup }
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
                    explanation: "Voice and speed apply to newly added articles. Queued articles keep their original settings.")
            }.disabled(model.running)
            Section {
                LabeledContent("Source", value: model.sourceReview.plist?.lastPathComponent ?? "Not chosen")
                Button("Choose Reading List…") { model.sourceReview.selectPlist() }
                    .disabled(model.running || model.sourceReview.busy || model.sourceReview.persistenceBusy || model.preview)
                Toggle("Add new articles to Queue automatically", isOn: $model.autoAdmitEnabled)
                    .disabled(model.preview || model.stopping)
                Toggle("Process queued articles automatically", isOn: $model.autoProcessEnabled)
                    .disabled(model.preview || model.stopping)
                Toggle("Try archived copies when articles fail", isOn: $model.useArchivedArticles)
                    .disabled(model.preview || model.stopping)
            } header: {
                SectionHelpHeader(title: "Reading List",
                    explanation: "Your Reading List is checked every five minutes and never modified. Automation handles new articles while the app runs. Optional archive recovery sends eligible public article URLs to Archive.ph or the Wayback Machine; copies may be older.")
            }
            if model.speechRuntimeAvailable { speechSetup }
        }.formStyle(.grouped)
            .confirmationDialog("Install speech runtime?", isPresented: $confirmingInstallation) {
                Button("Install Speech Runtime") { model.installSpeechRuntime() }
            } message: {
                Text("Download the pinned Python environment, packages and Kokoro model into VoiceRelay’s private runtime folder? Existing installations remain active until this installation succeeds.")
            }
    }
    private var speechSetup: some View {
            Section {
                LabeledContent("Status", value: model.runtimeStatus)
                if let error = model.runtimeError {
                    InlineNotice(message: error)
                }
                HStack {
                    Button("Check Speech Runtime") { model.checkSpeechRuntime() }.disabled(!model.canManageLibrary)
                    if model.runtimeBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelRuntimeSetup() }
                    }
                }
                Button("Install Speech Runtime…") { confirmingInstallation = true }.disabled(!model.canManageLibrary)
            } header: {
                SectionHelpHeader(title: "Speech setup",
                    explanation: "Install downloads the speech tools and model; existing installations stay active until setup succeeds. Requires python3, uv, ffmpeg and ffprobe. Check works offline.")
            }
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
                    explanation: "Uploads finished audio and updates your podcast feed while publishing is enabled and the app runs.")
            }
            Section {
                TextField("Feed folder URL", text: $feedFolderText)
                    .focused($focusedURL, equals: .feed)
                    .onSubmit { commitURLs() }
                    .help("Upload folder for feed.xml and audio/")
                TextField("Username", text: usernameBinding)
                    .help("Your WebDAV login username")
                SecureField("Password", text: $model.deliveryPassword)
                    .help("Click Save Password after editing")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { credentialActions; credentialPresence }
                    VStack(alignment: .leading, spacing: 8) { credentialActions; credentialPresence }
                }

            } header: {
                SectionHelpHeader(title: "Upload destination",
                    explanation: "Feed folder holds feed.xml and audio/. Save your upload password in Keychain; macOS may ask you to unlock it.", helpTopic: .publishing)
            }
            Section {
                TextField("Public folder URL", text: $publicFolderText)
                    .focused($focusedURL, equals: .published)
                    .onSubmit { commitURLs() }
                    .help("Public address serving your uploaded files")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Subscription URL").font(.headline)
                    Text(draftSubscriptionURL?.absoluteString ?? "Enter a public folder URL")
                        .textSelection(.enabled).font(AppTypography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy", systemImage: "doc.on.doc") {
                        if commitURLs() { model.copyDeliverySubscriptionURL() }
                    }.disabled(draftSubscriptionURL == nil || model.preview)
                }
                TextField("Channel title", text: $model.deliverySettings.channelTitle)
                TextField("Channel description", text: $model.deliverySettings.channelDescription)
            } header: {
                SectionHelpHeader(title: "Public feed",
                    explanation: "Public folder must serve the same files as Feed folder. Copy the Subscription URL into your podcast app.", helpTopic: .publishing)
            }
            Section {
                LabeledContent("Pending uploads", value: "\(model.deliveryPendingCount)")
                LabeledContent("Last upload", value: model.deliveryStatus ?? "Not run yet")
                if let error = model.deliveryError, model.notices.isVisible(message: error, key: "delivery") {
                    InlineNotice(message: error) { model.notices.dismiss(message: error, key: "delivery") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(model.deliveryTesting ? "Testing…" : "Test Connection") { if commitURLs() { model.testDeliveryConnection() } }
                        .disabled(model.deliveryTesting || model.preview || model.stopping || model.deliveryCredentialBusy)
                    testIndicator
                }
                Button(model.deliveryBusy ? "Uploading…" : "Upload Now") { if commitURLs() { model.triggerDelivery(force: true) } }
                    .disabled(model.deliveryBusy || !model.deliverySettings.enabled || model.preview || model.stopping || model.deliveryCredentialBusy)
                    .help("Retry pending uploads now")
            } header: {
                SectionHelpHeader(title: "Status",
                    explanation: "Test Connection checks upload folders, not write access or public playback. Uploads shows pending work and verification issues.", helpTopic: .publishing)
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
    private var credentialActions: some View {
        HStack(spacing: 8) {
                    Button("Save Password") { if commitURLs() { model.saveDeliveryPassword() } }
                        .disabled(!canSavePassword || model.deliveryCredentialBusy)
                        .help("Save in Keychain")
                    Button("Clear") { if commitURLs() { model.clearDeliveryPassword() } }
                        .disabled((try? DeliveryURL.folder(feedFolderText))?.host == nil || model.preview || model.deliveryCredentialBusy)
        }
    }
    @ViewBuilder private var credentialPresence: some View {
                    if model.deliveryPasswordStored {
                        Label("Stored in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                    } else if !model.deliveryPasswordChecked, model.deliverySettings.feedFolderURL?.host != nil {
                        Text("Password not checked").foregroundStyle(.secondary)
                    }
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case delivery = "Publishing"
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
        case .general: "Speech, Reading List and automation"
        case .delivery: "Podcast connection, publishing and subscription URL"
        case .troubleshooting: "Reading List diagnostics, library backup and logs"
        }
    }
}

struct SettingsPaneSelector: View {
    @Binding var selection: SettingsSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
            if reduceTransparency {
                label.background(.background, in: .rect(cornerRadius: 8))
            } else {
                label
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
                    .glassEffectID("selected-settings-pane", in: selectedTile)
            }
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
    private let initialSection: SettingsSection?
    private var section: SettingsSection { model.settingsSection }
    init(model: AppModel, initialSection: SettingsSection? = nil) {
        self.model = model; self.initialSection = initialSection
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SettingsPaneSelector(selection: $model.settingsSection)
            }
            .padding(.vertical, 12)
            Divider()
            Group {
                switch section {
                case .general:
                    ConfigurationView(model: model).padding(.horizontal, 8)
                case .delivery:
                    DeliveryPaneView(model: model).padding(.horizontal, 8)
                case .troubleshooting:
                    SourceReviewView(model: model.sourceReview, notices: model.notices, speechRunning: model.running, debugModel: model).padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { if let initialSection { model.settingsSection = initialSection } }
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
    init() {
        umask(0o077)
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.model = model
    }
    var body: some Scene {
        Group {
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
            .commands { LibraryCommands(model: model) }
            WindowGroup("VoiceRelay Help", for: AppHelpTopic.self) { $topic in
                if let topic {
                    AppHelpView(topic: topic)
                        .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                        .frame(minWidth: 420, minHeight: 320)
                }
            }.defaultSize(width: 560, height: 500)
        }.commands { AppHelpCommands(model: model) }
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

/// Shared by all scenes; reading Help never accesses application data or starts work.
struct AppHelpCommands: Commands {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            ForEach(AppHelpTopic.allCases) { topic in
                Button(topic.title) {
                    WindowPresence.shared.prepareToOpen(); openWindow(value: topic)
                }.disabled(model.preview || model.stopping)
            }
        }
    }
}

struct LibraryCommands: Commands {
    @Bindable var model: AppModel
    @FocusedValue(\.libraryListActions) private var selection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some Commands {
        CommandMenu("Articles") {
            Button("Add to Queue") { selection?.add() }.disabled(selection?.canAdd != true)
            Button("Preview Article") { selection?.preview() }.disabled(selection?.canPreview != true)
            Button("Remove Selections") { selection?.remove() }.disabled(selection?.canRemove != true)
            Divider()
            Button("Generate Audio") {
                model.workspaceSection = .articles; model.articleScope = .queue
                WindowPresence.shared.prepareToOpen(); openWindow(id: "articles")
                model.runQueue()
            }.disabled(!model.canGenerateAudio).keyboardShortcut("g", modifiers: [.command, .shift])
            Button(model.cancelling ? "Stopping…" : "Stop") { model.stopQueue() }
                .disabled(!model.canStopProcessing).keyboardShortcut(".", modifiers: .command)
            Button("Upload New Items") { model.uploadNewItems() }.disabled(!model.canUploadNewItems)
            Divider()
            Button("Publishing Settings…") {
                model.settingsSection = .delivery
                WindowPresence.shared.prepareToOpen(); openSettings()
            }.disabled(model.preview || model.stopping)
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
            if progress.totalChunks + progress.totalArticles > 0 {
                ProgressView(value: min(1, max(0, progress.fractionCompleted)))
            } else { ProgressView() }
            Text("\(phase) · \(progress.completedArticles)/\(progress.totalArticles) articles complete")
                .monospacedDigit()
            if pending > 0 {
                Text("Preparing \(pending) additional articles…").font(AppTypography.secondary).monospacedDigit()
            }
        }
    }
    private var phase: String {
        if cancelling { return "Stopping…" }
        if progress.stage == .published && progress.completedArticles < progress.totalArticles {
            return "Verifying generated audio"
        }
        return progress.stage.friendlyLabel
    }
}

enum AudioStateFilter: String, CaseIterable, Identifiable {
    case all = "All Items", waiting = "Awaiting Upload", active = "Transferring / Verifying"
    case publication = "Awaiting Publication", published = "Published", attention = "Needs Attention"
    case verification = "Failed Verification", removing = "Pending Removal", discarded = "Local Upload Removed"
    var id: Self { self }
    static var outbox: [Self] { [.all, .waiting, .active, .publication, .attention, .verification] }
    func includes(_ phase: UploadPhase) -> Bool {
        switch self {
        case .all: true
        case .discarded: phase == .discarded
        case .waiting: phase == .waiting
        case .active: phase.active
        case .publication: phase == .publishing
        case .published: phase == .published
        case .attention: phase.needsAttention
        case .verification: phase == .verificationFailed || phase == .localConflict
        case .removing: phase == .removing || phase == .removalFailed
        }
    }
}

struct AudioStateFilterControl: View {
    @Binding var selection: AudioStateFilter
    let options: [AudioStateFilter]
    let items: [UploadItem]
    var body: some View {
        Picker("Filter", selection: $selection) {
            ForEach(options) { filter in
                Text("\(filter.rawValue) (\(items.filter { filter.includes($0.phase) }.count))").tag(filter)
            }
        }.pickerStyle(.menu).help("Filter by status")
    }
}

struct AudioVerificationIndicator: View {
    let item: UploadItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.phase.title, systemImage: symbol)
                .font(AppTypography.secondary)
                .foregroundStyle(item.phase.needsAttention ? Color.orange : item.phase == .published ? Color.green : Color.secondary)
            if let detail = item.detail { Text(detail).font(AppTypography.secondary).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
    private var symbol: String {
        if item.phase.needsAttention { return "exclamationmark.triangle" }
        if item.phase == .published { return "checkmark.icloud" }
        return item.phase.active ? "arrow.up.circle" : "clock"
    }
}

struct UploadsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.deliveryBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.uploadProgress.isEmpty ? "Reconciling server and local records…" : "Publishing pending items…")
                        .font(AppTypography.secondary)
                    Spacer()
                }.padding(12)
                Divider()
            }
            if model.visibleUploads.isEmpty {
                ContentUnavailableView(model.uploadItems.isEmpty ? "No Pending Uploads" : "No Matching Uploads",
                    systemImage: "tray.and.arrow.up", description: Text(model.uploadItems.isEmpty
                        ? "Verified, published episodes clear from this outbox automatically."
                        : "Choose another state filter to see other uploads."))
            } else {
                List(model.visibleUploads) { item in
                    HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.episode.title).font(.headline).lineLimit(2)
                        ArticleOriginLine(metadata: model.savedAudioOrigin(item.episode))
                        AudioVerificationIndicator(item: item)
                        if let meta = model.savedAudioMeta(item.episode) { Text(meta).font(AppTypography.secondary).foregroundStyle(.secondary) }
                        if item.phase.active {
                            if let fraction = item.progress?.fraction {
                                ProgressView(value: fraction)
                                if let sent = item.progress?.sentBytes, let total = item.progress?.totalBytes {
                                    Text("\(ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) sent")
                                        .font(AppTypography.secondary).monospacedDigit().foregroundStyle(.secondary)
                                }
                            } else { ProgressView().controlSize(.small) }
                        }
                    }
                    Spacer(minLength: 8)
                    RowRemovalButton(accessibilityLabel: "Remove \(item.episode.title) local upload",
                        help: "Delete local copy; keep server audio",
                        isEnabled: model.canDiscardLocalUpload(item)) { model.discardLocalUpload(item) }
                    }.padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                AudioStateFilterControl(selection: $model.uploadsFilter, options: AudioStateFilter.outbox, items: model.uploadItems)
            }
            if !model.uploadItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.retryUploads() } label: {
                        Label(model.uploadsNeedAttention ? "Retry Uploads" : "Upload New Items", systemImage: "icloud.and.arrow.up")
                    }
                        .disabled(!model.canRetryUploads).help("Retry pending publishing and verification")
                }
            }
        }
        .task {
            guard !model.preview else { return }
            while !Task.isCancelled, !model.stopping {
                model.refreshLibrary()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var confirmingReset = false
    @State private var capturedResetIDs: [String] = []
    var body: some View {
        Group {
            if model.visibleServerAudio.isEmpty {
                ContentUnavailableView(model.savedEpisodes.isEmpty ? "No Server Audio" : "No Matching Episodes", systemImage: "waveform",
                                       description: Text(model.savedEpisodes.isEmpty ? "Add selected articles to the queue, then choose Generate Audio." : "Choose another state filter to see other episodes."))
            } else {
                List(selection: $model.savedAudioSelection) {
                    ForEach(model.visibleServerAudio, id: \.id) { episode in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.title).font(.headline).lineLimit(2)
                            ArticleOriginLine(metadata: model.savedAudioOrigin(episode))
                            let meta = model.savedAudioMeta(episode)
                            let removal = model.savedAudioRemovalStatus(episode)
                            Text(removal.map { "\($0)\(meta.map { " · " + $0 } ?? "")" }
                                 ?? meta ?? "Speech ready").font(AppTypography.secondary).foregroundStyle(.secondary)
                            if removal == nil {
                                AudioVerificationIndicator(item: model.audioState(episode))
                            }
                        }
                        Spacer()
                        if episode.settings.temporaryAudio != true && episode.localAudioReleased != true {
                        Button("Show in Finder") { reveal(episode) }.disabled(model.preview)
                            .buttonStyle(.borderless).help("Show local audio in Finder")
                        }
                        RowRemovalButton(accessibilityLabel: "Delete \(episode.title) audio",
                            help: "Remove episode and delete its audio",
                            isEnabled: model.canRemoveSavedAudio(episode)) {
                            model.removeSavedAudio(ids: [episode.id])
                        }
                    }
                    .tag(episode.id)
                    }
                }
            }
        }
        .onChange(of: model.serverAudioFilter) {
            model.savedAudioSelection.formIntersection(Set(model.visibleServerAudio.map(\.id)))
        }
        .onDeleteCommand { removeSelection() }
        .focusedValue(\.libraryListActions, LibraryListActions(
            canRemove: canRemoveSelection, remove: { removeSelection() }))
        .task {
            guard !model.preview else { return }
            while !Task.isCancelled, !model.stopping {
                model.refreshLibrary()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .toolbar {
            ToolbarItem {
                AudioStateFilterControl(selection: $model.serverAudioFilter, options: AudioStateFilter.allCases, items: model.savedEpisodes.map(model.audioState))
            }
            ToolbarItem {
                Menu {
                    Button("Publishing Settings…") {
                        model.settingsSection = .delivery
                        WindowPresence.shared.prepareToOpen(); openSettings()
                    }
                } label: { Label("Actions", systemImage: "ellipsis") }
            }
            if model.showsUploadNewItems {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.uploadNewItems() } label: {
                        Label(model.deliveryBusy ? "Uploading…" : "Upload New Items", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!model.canUploadNewItems)
                    .help("Upload new episodes")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                SelectionManagementControl(selectionCount: model.savedAudioSelection.count,
                    resetTitle: "Reset Server Audio…", canReset: !model.visibleServerAudio.filter(model.canRemoveSavedAudio).isEmpty,
                    canRemove: model.visibleServerAudio.contains { model.savedAudioSelection.contains($0.id) && model.canRemoveSavedAudio($0) },
                    resetHelp: "Remove all shown episodes and their audio",
                    removeHelp: "Remove selected episodes and their audio",
                    onReset: {
                        capturedResetIDs = model.visibleServerAudio.filter(model.canRemoveSavedAudio).map(\.id)
                        confirmingReset = true
                    },
                    onRemove: { model.removeSavedAudio(ids: model.visibleServerAudio.filter { model.savedAudioSelection.contains($0.id) }.map(\.id)) })
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
    private var canRemoveSelection: Bool {
        !model.savedAudioSelection.isEmpty && model.visibleServerAudio.contains {
            model.savedAudioSelection.contains($0.id) && model.canRemoveSavedAudio($0)
        }
    }
    private func removeSelection() {
        guard canRemoveSelection else { return }
        model.removeSavedAudio(ids: model.visibleServerAudio.filter { model.savedAudioSelection.contains($0.id) }.map(\.id))
    }
    private func reveal(_ episode: Episode) {
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { model.error = "The temporary audio file is unavailable; published episodes remain on the server." }
    }
}

#if DEBUG
private struct UploadPreviewEpisode: Encodable {
    let id: String, title: String
    let stage: Stage
    let settings: PrototypeProfile
}
@MainActor private func uploadPreviewModel(active: Bool = false) -> AppModel {
    let model = AppModel(preview: true)
    var profile = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")); profile.temporaryAudio = true
    let seed = UploadPreviewEpisode(id: "synthetic-upload", title: "How the coast changes with the seasons", stage: .published, settings: profile)
    guard let data = try? JSONEncoder().encode(seed), var episode = try? JSONDecoder().decode(Episode.self, from: data) else { return model }
    episode.originalSourceHost = "articles.example"; episode.readingListSavedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    if active {
        model.deliveryBusy = true
        model.uploadProgress[episode.id] = UploadProgress(episode: episode, phase: .transferring, sentBytes: 750_000, totalBytes: 1_000_000)
    } else {
        episode.delivery = DeliveryState(status: .failed, remotePath: "audio/synthetic-upload.m4a", lastError: "The remote bytes could not be verified. The local audio is retained for retry.")
        episode.delivery?.verificationFailed = true
    }
    model.savedEpisodes = [episode]; model.workspaceSection = .uploads
    return model
}
#Preview("Uploads — inert verification issue") { UploadsView(model: uploadPreviewModel()).frame(width: 720, height: 480) }
#Preview("Uploads — inert transfer progress") { UploadsView(model: uploadPreviewModel(active: true)).frame(width: 720, height: 480) }
#Preview("Uploads — inert empty outbox") { UploadsView(model: AppModel(preview: true)).frame(width: 720, height: 480) }
#Preview("Server Audio — inert errors filter") {
    let model = uploadPreviewModel(); model.serverAudioFilter = .attention
    return LibraryView(model: model).frame(width: 720, height: 480)
}
#Preview("Menu — inert idle") { RelayMenu(model: AppModel(preview: true)) }
#Preview("Menu — inert processing") {
    let model = AppModel(preview: true)
    model.running = true
    model.batchProgress = QueueBatchProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 8, completedArticles: 0, totalArticles: 2, currentArticleIndex: 1)
    return RelayMenu(model: model)
}
#Preview("Workspace — inert empty") { WorkspaceView(model: AppModel(preview: true)) }
#Preview("Workspace — inert unified articles") {
    let model = AppModel(preview: true)
    let entries = (1...3).map { index in
        ReadingListEntry(id: "synthetic-\(index)", safariID: "synthetic-\(index)",
            url: URL(string: "https://articles.example/\(index)")!, title: "A synthetic article \(index)",
            addedAt: Date(timeIntervalSinceReferenceDate: Double(index * 86_400)))
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.queueItems = [SpeechQueueItem(id: "synthetic-job", title: entries[1].title,
        sourceEntryID: entries[1].id, sourceHost: "articles.example")]
    model.articleSelection = [entries[0].id]
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert restored library review") {
    let model = AppModel(preview: true)
    model.libraryReviewRequired = true
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert Publishing attention") {
    let model = AppModel(preview: true)
    model.deliverySettings.enabled = true
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://podcast.example/")
    model.deliveryPasswordChecked = true; model.deliveryPasswordStored = true
    model.deliveryError = "Synthetic permission failure"
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert queue processing") {
    let model = AppModel(preview: true)
    model.running = true
    model.processingSpeech = true
    model.workspaceSection = .articles; model.articleScope = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic queued article", sourceHost: "articles.example"),
                       SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "A synthetic interrupted article", state: .running, attempts: 1, sourceHost: "journal.example")]
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2, currentArticleIndex: 1)
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert queue failure") {
    let model = AppModel(preview: true)
    model.workspaceSection = .articles; model.articleScope = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic failed article", state: .failed, attempts: 1, lastError: "Synthetic feed failure")]
    model.error = "Synthetic feed failure"
    return WorkspaceView(model: model)
}
#Preview("Settings — inert defaults") { SettingsView(model: AppModel(preview: true)) }
#Preview("Settings — inert Publishing") { SettingsView(model: AppModel(preview: true), initialSection: .delivery) }
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
    model.articleScope = .queue
    return ArticlesView(model: model)
}
#Preview("Queue — global encoding progress") {
    let model = AppModel(preview: true)
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2)
    model.articleScope = .queue
    return ArticlesView(model: model)
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
                "originalSourceHost": "articles.example",
                "readingListSavedAt": Double(86_400 * (index + 1)),
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

#Preview("Publishing — inert automatic reconciliation issue") {
    let model = AppModel(preview: true)
    model.deliveryError = "Server reconciliation: 1 item needs attention; other items continued."
    return SettingsView(model: model, initialSection: .delivery)
}

#Preview("Help — publishing and uploads") { AppHelpView(topic: .publishing).frame(width: 560, height: 500) }
#Preview("Help — library backup and restore") { AppHelpView(topic: .libraryBackup).frame(width: 560, height: 500) }
