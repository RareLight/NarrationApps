import AudioOutput
import NarrationUI
import AppPresentation
import PronunciationUI
import SwiftUI
import AppKit
import Observation
import Darwin
import VoiceRelayCore

enum SpeechRuntimeTestResult: Equatable {
    case untested, success, cancelled, failure(String)
}

enum SyncPhase: String {
    case readingList = "Reading List"
    case reconciling = "Checking server audio"
    case preparing = "Preparing articles"
    case speechCheck = "Checking speech setup"
    case generating = "Generating audio"
    case publishing = "Publishing"
}

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
    @ObservationIgnored private(set) var progressID = UUID()
    @ObservationIgnored var completedQueueIDs: Set<String> = []
    var result: FixtureResult?
    var savedEpisodes: [Episode] = []
    var queueItems: [SpeechQueueItem] = []
    var articleSelection: Set<String> = []
    var articleScope: ArticleScope = .all
    var articlesWebsiteFilter: ArticleWebsiteFilter = .all
    var queueWebsiteFilter: ArticleWebsiteFilter = .all
    var articlesSearchText = ""
    var queueSearchText = ""
    var uploadsSearchText = ""
    var serverAudioSearchText = ""
    var retainedArticleSelection: Set<QueueSelectionID> = []
    var queueSavedDates: [String: Date] = [:]
    var settingsSection: SettingsSection = .general
    /// In-flight background adds, entry id to title. Not persisted; rows merge below real queue items.
    var pendingAdds: [String: String] = [:]
    var sourcePruningBusy = false
    @ObservationIgnored private var sourcePruneTask: Task<Void, Never>?
    @ObservationIgnored private var sourcePruneRequested = false
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
    let pronunciationPreview = PronunciationPreview()
    var pronunciationIsInert: Bool { preview || storageOverride != nil }
    var pronunciationConfiguration: PronunciationPreviewConfiguration? {
        guard !pronunciationIsInert, !stopping, !running, !runtimeBusy, speechRuntimeAvailable else { return nil }
        return .init(worker: NativeSpeechSetup.workerExecutable, workspace: runtimeProject,
            settings: .init(model: .kokoro, voice: preferences.voice.rawValue, speed: Float(preferences.speed)), priority: .background)
    }
    var preferences = SpeechPreferences() { didSet { if oldValue.voice != preferences.voice { voiceSamplePlayer.stop() }; savePreferences() } }
    var audioCleanupError: String?
    /// Set-and-forget automation preferences; storage-injected models stay manual by default.
    var autoAdmitEnabled = false { didSet { saveAutoAdmit() } }
    var autoProcessEnabled = false { didSet { saveAutoProcess() } }
    /// Explicit Stop suspends automation until new work arrives or Generate is pressed.
    var autoHalted = false
    /// Delivery configuration; the password lives only in the credential store, never here.
    var deliverySettings = DeliverySettings() { didSet {
        if oldValue.enabled && !deliverySettings.enabled {
            // A drain captures its settings. Stop that owned work as well as future
            // drains when the user turns publishing off; durable intent stays pending.
            pendingDeliveryForce = nil; pendingDeliveryCheck = false
            deliveryTask?.cancel()
        } else if oldValue.podcastCoverDigest != deliverySettings.podcastCoverDigest || oldValue.podcastCoverConfigured != deliverySettings.podcastCoverConfigured || oldValue.feedFolderURL != deliverySettings.feedFolderURL || oldValue.publicFolderURL != deliverySettings.publicFolderURL {
            if deliveryTask != nil { pendingDeliveryForce = pendingDeliveryForce ?? false; deliveryTask?.cancel() }
        }
        deliverySettingsChanged()
    } }
    @ObservationIgnored private var coverImportTask: Task<Void, Never>?
    @ObservationIgnored private var preparingDefaultPodcastCover = false
    @ObservationIgnored private let defaultPodcastCoverURL: URL?
    @ObservationIgnored private var deliverySettingsLoadFailed = false
    var podcastCoverError: String?
    var coverImporting = false
    let podcastCoverStore: CoverArtworkStore
    var podcastCoverURL: URL? { deliverySettings.podcastCoverDigest.flatMap { try? podcastCoverStore.url(for: $0) } }
    func choosePodcastCover(_ url: URL) {
        importPodcastCover(url, isDefault: false)
    }
    /// Only an unset choice adopts the bundled cover; explicit Remove survives relaunch.
    func prepareDefaultPodcastCover() {
        guard !preview, !stopping, !deliverySettingsLoadFailed, deliverySettings.podcastCoverDigest == nil,
              deliverySettings.podcastCoverConfigured != true else { return }
        guard let url = defaultPodcastCoverURL else {
            podcastCoverError = "The default podcast cover is unavailable. Choose a cover in Publishing."
            return
        }
        importPodcastCover(url, isDefault: true)
    }
    private func importPodcastCover(_ url: URL, isDefault: Bool) {
        guard !preview, !stopping, !libraryMaintenanceBusy, !coverImporting else { return }
        coverImporting = true; podcastCoverError = nil
        preparingDefaultPodcastCover = isDefault
        let store = podcastCoverStore
        coverImportTask = Task {
            defer {
                coverImporting = false; coverImportTask = nil; preparingDefaultPodcastCover = false
                if isDefault {
                    let force = pendingDeliveryForce ?? false; pendingDeliveryForce = nil
                    let check = pendingDeliveryCheck; pendingDeliveryCheck = false
                    triggerDelivery(force: force, reconcileNow: check)
                }
            }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try store.save(CoverArtwork.read(url, profile: .podcast))
                }
                let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard !stopping, !libraryMaintenanceBusy else { return }
                if isDefault, deliverySettings.podcastCoverDigest != nil || deliverySettings.podcastCoverConfigured == true { return }
                var updated = deliverySettings; updated.podcastCoverDigest = digest; updated.podcastCoverConfigured = true
                deliverySettings = updated
                if !isDefault { deliveryStatus = "Podcast cover selected. It will publish with the next feed update." }
            } catch is CancellationError { }
            catch { podcastCoverError = error.localizedDescription }
        }
    }
    func removePodcastCover() {
        guard !preview, !stopping, !libraryMaintenanceBusy else { return }
        podcastCoverError = nil
        var updated = deliverySettings; updated.podcastCoverDigest = nil; updated.podcastCoverConfigured = true
        deliverySettings = updated
    }
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
    var deliveryConnectionVerified = false
    @ObservationIgnored private var deliveryVerificationID = UUID()
    var syncBusy = false
    var syncPhase: SyncPhase?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var syncPreparing = false
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
    var launchedAtLogin = false
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    private(set) var loginItemBusy = false
    var loginItemError: String?
    @ObservationIgnored private let loginItemService: (any LoginItemService)?
    @ObservationIgnored private var loginItemTask: Task<Void, Never>?
    var launchAtLoginEnabled: Bool { loginItemStatus.requested }
    var canChangeLoginItem: Bool { !preview && !stopping && !loginItemBusy && loginItemService != nil }
    func refreshLoginItemStatus() {
        guard !preview, !loginItemBusy, let loginItemService else { return }
        let status = loginItemService.status
        if status != loginItemStatus { loginItemError = nil }
        loginItemStatus = status
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard canChangeLoginItem, let loginItemService else { return }
        refreshLoginItemStatus()
        guard enabled != launchAtLoginEnabled else { return }
        loginItemBusy = true; loginItemError = nil
        loginItemTask = Task {
            defer { loginItemStatus = loginItemService.status; loginItemBusy = false; loginItemTask = nil }
            do { try await loginItemService.setEnabled(enabled) }
            catch { loginItemError = "The startup setting could not be changed. Check VoiceRelay in System Settings → General → Login Items & Extensions." }
        }
    }
    func openLoginItemSettings() {
        guard canChangeLoginItem else { return }
        loginItemService?.openSettings()
    }
    func waitForLoginItemChange() async { if let loginItemTask { await loginItemTask.value } }
    var textSize = AppTextSize() {
        didSet { if !preview { defaults.set(textSize.percent, forKey: "interfaceTextSizePercent") } }
    }
    var describeArticleImages = true {
        didSet { if !preview { defaults.set(describeArticleImages, forKey: "describeArticleImages") } }
    }
    var generateMissingTitles = false {
        didSet { if !preview { defaults.set(generateMissingTitles, forKey: "generateMissingTitles") } }
    }
    var useArchivedArticles = false {
        didSet { if !preview { defaults.set(useArchivedArticles, forKey: "useArchivedArticles") } }
    }
    var sourceReview = SourceReviewModel(preview: true)
    var runtimeProject = NativeSpeechSetup.managedRoot
    var runtimeBusy = false
    var runtimeTestResult: SpeechRuntimeTestResult = .untested
    var runtimeInstalling = false
    var runtimeVerificationFailed = false
    private var onboarding = SpeechSetupOnboarding()
    var runtimeSetupNeededAtLaunch: Bool { onboarding.needsSetup }
    let voiceSamplePlayer = AudioPreviewPlayer()
    var canPlayVoiceSample: Bool { !preview && !stopping }
    func playVoiceSample() {
        guard canPlayVoiceSample else { return }
        pronunciationPreview.stop()
        guard let sample = VoiceSamples.sample(model: .kokoro, voice: preferences.voice.rawValue) else { return }
        voiceSamplePlayer.toggle(url: sample.url, id: sample.id)
    }
    var libraryMaintenanceBusy = false
    var libraryBackupStatus: String?
    var libraryBackupError: String?
    var libraryReviewRequired = false {
        didSet { if !preview { defaults.set(libraryReviewRequired, forKey: "libraryReviewRequired") } }
    }
    @ObservationIgnored var runtimeTask: Task<Void, Never>?
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
    /// Source URLs whose automatic admission failed or was refused this session; manual adds bypass it.
    @ObservationIgnored private var autoAttempted: Set<URL> = []
    @ObservationIgnored private var launchResumeDone = false
    @ObservationIgnored private(set) var libraryTask: Task<Void, Never>?
    /// Discard saved-audio snapshots read before a removal or delivery confirmation.
    @ObservationIgnored private var audioLibraryRevision = UUID()
    @ObservationIgnored private var pendingLibraryRefresh: Bool?
    @ObservationIgnored private var settingsBookkeepingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSettingsHash: String?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTestTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryCredentialTask: Task<Void, Never>?
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    /// nil means no follow-up; false is automatic, true preserves a manual override.
    @ObservationIgnored private var pendingDeliveryForce: Bool?
    @ObservationIgnored private var pendingDeliveryCheck = false
    /// Once per app session; a persisted cadence timestamp must not skip launch authentication.
    @ObservationIgnored private var startupReconciliationPending = true
    @ObservationIgnored private(set) var stopping = false
    var workspaceSection: WorkspaceSection? = .articles
    @ObservationIgnored let storageOverride: ManagedSpeechStorage?
    @ObservationIgnored let backendOverride: (@Sendable (Episode) throws -> any TTSBackend)?
    @ObservationIgnored private let enqueueFetchOverride: (@Sendable (URL) async throws -> FetchedPage)?
    @ObservationIgnored private let archiveFetchOverride: ArticleSourceLoader.ArchiveFetch?
    @ObservationIgnored let runtimeInstalledOverride: (@Sendable (URL) -> Bool)?
    @ObservationIgnored let runtimeSetupOverride: (@Sendable (Bool, URL) throws -> Void)?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let inertDefaults: InertDefaultsDomain?
    /// Delivery seams: production gets Keychain + URLSession; injected models get nil unless a
    /// test supplies fakes, so isolated models can never touch the network or Keychain.
    @ObservationIgnored private let deliveryTransportFactory: (@Sendable () -> any DeliveryTransport)?
    @ObservationIgnored private let deliveryCredentialStore: SessionDeliveryCredentialStore?

    init(preview: Bool = false, storage: ManagedSpeechStorage? = nil,
         backend: (@Sendable (Episode) throws -> any TTSBackend)? = nil,
         enqueueFetch: (@Sendable (URL) async throws -> FetchedPage)? = nil,
         archiveFetch: ArticleSourceLoader.ArchiveFetch? = nil,
         defaults: UserDefaults? = nil,
         deliveryTransport: (@Sendable () -> any DeliveryTransport)? = nil,
         credentialStore: (any DeliveryCredentialStore)? = nil,
         runtimeSetup: (@Sendable (Bool, URL) throws -> Void)? = nil,
         runtimeInstalled: (@Sendable (URL) -> Bool)? = nil,
         readingListReader: (@Sendable (URL) async throws -> ReadingListSnapshot)? = nil,
         loginItemService: (any LoginItemService)? = nil,
         podcastCoverStore: CoverArtworkStore? = nil,
         defaultPodcastCoverURL: URL? = nil) {
        storageOverride = storage; backendOverride = backend; enqueueFetchOverride = enqueueFetch
        archiveFetchOverride = archiveFetch
        runtimeSetupOverride = runtimeSetup
        runtimeInstalledOverride = runtimeInstalled
        self.loginItemService = preview ? nil : (loginItemService ?? (storage == nil ? MainAppLoginItemService() : nil))
        self.podcastCoverStore = podcastCoverStore ?? .application("VoiceRelay")
        self.defaultPodcastCoverURL = defaultPodcastCoverURL ?? (storage == nil && !preview
            ? Bundle.main.url(forResource: "VoiceRelay_Cover", withExtension: "jpg") : nil)
        let domain = defaults == nil && (preview || storage != nil) ? InertDefaultsDomain() : nil
        let defaults = defaults ?? domain?.defaults ?? .standard
        inertDefaults = domain
        self.defaults = defaults
        var defaultTransport: (@Sendable () -> any DeliveryTransport)?
        if storage == nil { defaultTransport = { URLSessionDeliveryTransport() } }
        deliveryTransportFactory = deliveryTransport ?? defaultTransport
        let baseCredentialStore = credentialStore ?? (storage == nil ? KeychainCredentialStore() : nil)
        let credentialLog = deliveryDebugLog
        deliveryCredentialStore = baseCredentialStore.map { SessionDeliveryCredentialStore(base: $0, debugLog: credentialLog) }
        self.preview = preview
        sourceReview = SourceReviewModel(preview: preview || (storage != nil && readingListReader == nil),
            coordinator: coordinator, stateRoot: storage?.stateRoot, defaults: defaults, snapshotReader: readingListReader)
        sourceReview.onCatalogChange = { [weak self] removed in self?.catalogDidChange(removed: removed) }
        sourceReview.onContextChange = { [weak self] in self?.notices.reset(key: "source") }
        guard !preview else {
            runtimeProject = URL(fileURLWithPath: "/synthetic/VoiceRelay")
            return
        }
        debugLoggingEnabled = defaults.bool(forKey: "debugLoggingEnabled")
        refreshLoginItemStatus()
        textSize = AppTextSize(percent: defaults.object(forKey: "interfaceTextSizePercent") as? Int ?? 100)
        describeArticleImages = defaults.object(forKey: "describeArticleImages") as? Bool ?? true
        generateMissingTitles = defaults.bool(forKey: "generateMissingTitles")
        libraryReviewRequired = defaults.bool(forKey: "libraryReviewRequired")
        loadDeliverySettings()
        // Isolated lifecycle tests supply storage/providers and never read user preferences or Safari.
        if storage != nil {
            if runtimeInstalled != nil { onboarding.assess(installed: speechRuntimeInstalled) }
            return
        }
        prepareDefaultPodcastCover()
        if let bytes = defaults.data(forKey: "speechPreferences") {
            do {
                let saved = try JSONDecoder().decode(SpeechPreferences.self, from: bytes)
                try saved.validate(); preferences = saved
            } catch { self.error = "Saved voice and speed preferences could not be read. Default voice and speed are active." }
        }
        runtimeProject = NativeSpeechSetup.preferredRoot(
            saved: defaults.string(forKey: "runtimeProject").map { URL(fileURLWithPath: $0) })
        autoAdmitEnabled = defaults.object(forKey: "autoAdmitArticles") as? Bool ?? true
        autoProcessEnabled = defaults.object(forKey: "autoProcessArticles") as? Bool ?? true
        useArchivedArticles = defaults.bool(forKey: "useArchivedArticles")
        refreshLibrary()
        onboarding.assess(installed: speechRuntimeInstalled)
        if speechRuntimeAvailable { checkSpeechRuntime() }
        startAutomationLoop()
        sourceReview.startAutomaticSynchronization()
        triggerDelivery()
    }
    private func loadDeliverySettings() {
        guard let bytes = defaults.data(forKey: "deliverySettings") else { return }
        guard var saved = try? JSONDecoder().decode(DeliverySettings.self, from: bytes) else {
            deliverySettingsLoadFailed = true
            self.error = "Saved Publishing settings could not be read. Publishing is disabled until they are fixed."
            return
        }
        saved.username = saved.credentialUsername.isEmpty ? nil : saved.credentialUsername
        deliverySettings = saved
        do { try saved.validate() }
        catch {
            deliverySettingsLoadFailed = true
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
        deliveryConnectionVerified = false; deliveryVerificationID = UUID()
        // Filters are read-only: normalize/hash once per edit, never once per row or byte event.
        presentationDeliverySettings = try? deliverySettings.normalized()
        presentationDeliveryIdentity = try? presentationDeliverySettings?.publicationHash()
        cancelDeliveryTest()
        refreshDeliveryCredentialState()
        guard !preview else { return }
        if let bytes = try? JSONEncoder().encode(deliverySettings) {
            defaults.set(bytes, forKey: "deliverySettings")
        }
        // Coalesce drafts; the coordinator owns disk access and serial metadata commits.
        guard !libraryMaintenanceBusy, !stopping else { return }
        pendingSettingsHash = try? deliverySettings.settingsHash()
        guard settingsBookkeepingTask == nil else { return }
        let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
        settingsBookkeepingTask = Task { [weak self] in
            guard let self else { return }
            defer { settingsBookkeepingTask = nil }
            do {
                while pendingSettingsHash != nil {
                    try await Task.sleep(for: .milliseconds(150))
                    try Task.checkCancellation()
                    guard !stopping, !libraryMaintenanceBusy else { return }
                    let hash = pendingSettingsHash; pendingSettingsHash = nil
                    if let hash { try await coordinator.invalidateDeliveryFeed(stateRoot: root, settingsHash: hash) }
                }
            } catch is CancellationError {} catch {
                deliveryError = "Publishing changes could not be saved; retry publishing."
                deliveryDebugLog.recordFailure(error)
            }
        }
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
    func copyDeliverySubscriptionURL(to pasteboard: NSPasteboard = .general) {
        guard !preview, let url = deliverySubscriptionURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
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
        deliveryConnectionVerified = false; deliveryVerificationID = UUID()
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
        deliveryConnectionVerified = false; deliveryVerificationID = UUID()
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
    func triggerDelivery(force: Bool = false, reconcileNow: Bool = false) {
        guard !preview, !stopping, !audioMutationBusy, !libraryMaintenanceBusy, !libraryReviewRequired, !deliveryCredentialBusy, deliverySettings.enabled,
              (try? deliverySettings.validate()) != nil,
              let makeTransport = deliveryTransportFactory, let credential = deliveryCredentialStore else { return }
        if preparingDefaultPodcastCover {
            pendingDeliveryForce = (pendingDeliveryForce ?? false) || force
            pendingDeliveryCheck = pendingDeliveryCheck || reconcileNow
            return
        }
        if deliveryTask != nil {
            pendingDeliveryForce = (pendingDeliveryForce ?? false) || force
            pendingDeliveryCheck = pendingDeliveryCheck || reconcileNow
            return
        }
        if force || reconcileNow { credential.retryFailedAccess(username: deliverySettings.credentialUsername, host: deliverySettings.credentialHost) }
        let storage = speechStorage, settings = deliverySettings
        let reconcileNow = startupReconciliationPending || reconcileNow
        startupReconciliationPending = false
        let attemptStartedAt = Date(), verificationID = deliveryVerificationID
        // Gate new speech while the coordinator checks whether reconciliation is
        // due. Reading a large/slow ledger here would block a UI button callback.
        deliveryPreflightBusy = !running
        if reconcileNow || force { deliveryConnectionVerified = false }
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
                let checkAgain = pendingDeliveryCheck; pendingDeliveryCheck = false
                if let again { triggerDelivery(force: again, reconcileNow: checkAgain) }
            }
            do {
                let needsPreflight: Bool
                if reconcileNow { needsPreflight = true }
                else { needsPreflight = await coordinator.deliveryPreflightRequired(stateRoot: storage.stateRoot, settings: settings, now: attemptStartedAt) }
                try Task.checkCancellation()
                deliveryPreflightBusy = !running && needsPreflight
                if needsPreflight { deliveryConnectionVerified = false }
                let result = try await coordinator.deliverPending(storage: storage, settings: settings,
                    credential: credential, transport: LoggingDeliveryTransport(base: makeTransport(), log: deliveryDebugLog),
                    force: force, reconcileNow: reconcileNow, now: attemptStartedAt, debugLog: deliveryDebugLog, progress: { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self, self.uploadRunID == uploadToken, !self.stopping else { return }
                            self.recordUploadProgress(event)
                        }
                    }, artworkStore: podcastCoverStore)
                try Task.checkCancellation()
                if let summary = try? await coordinator.deliverySummary(stateRoot: storage.stateRoot, settings: settings) {
                    recordDeliveryPublication(summary)
                    deliveryPendingCount = summary.pendingMedia + summary.pendingTranscripts + summary.pendingRemoteDeletes
                    deliveryError = summary.lastError
                    if deliveryVerificationID == verificationID, deliverySettings == settings,
                       let checkedAt = summary.reconciledAt, checkedAt >= attemptStartedAt {
                        deliveryConnectionVerified = true
                    }
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
                    deliveryPendingCount = summary.pendingMedia + summary.pendingTranscripts + summary.pendingRemoteDeletes
                }
            }
        }
    }
    private static func deliveryStatusText(_ result: DeliveryResult, hasError: Bool = false) -> String {
        var parts: [String] = []
        if result.uploadedMedia > 0 { parts.append("Uploaded \(result.uploadedMedia)") }
        if result.uploadedTranscripts > 0 { parts.append("Transcripts uploaded: \(result.uploadedTranscripts)") }
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
                deliveryConnectionVerified = true
                deliveryDebugLog.record(foldersExist ? .connectionVerified : .connectionFoldersPending)
            } catch is CancellationError {
            } catch let error as DeliveryError {
                guard deliveryTestID == testID else { return }
                deliveryTestResult = .failure(error.localizedDescription)
                deliveryConnectionVerified = false
                deliveryDebugLog.recordFailure(error)
            } catch {
                guard deliveryTestID == testID else { return }
                deliveryTestResult = .failure("Server unreachable")
                deliveryConnectionVerified = false
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
    var canGenerateAudio: Bool { !sourcePruningBusy && !deliveryPreflightBusy && !preview && !stopping && !runtimeBusy && !libraryMaintenanceBusy && !libraryReviewRequired && speechRuntimeAvailable && !running && !audioMutationBusy
                                 && !sourceReview.maintenanceSuspended && (readyQueueCount > 0 || !pendingAdds.isEmpty) }
    var canStopProcessing: Bool { !preview && !stopping && processingSpeech && !cancelling }
    var canResetQueue: Bool { !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !running && !cancelling && !isQueueResetPending
                              && !sourceReview.maintenanceSuspended && (!queueItems.isEmpty || !pendingAdds.isEmpty) }
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
        if let batch = batchProgress { return batch.displayFraction }
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
            guard let fraction = batch.displayFraction else { return line }
            let scope = batch.countsAreFinal ? "" : "current article "
            return line + " · " + scope + "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
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

    func refreshLibrary(allowDelivery: Bool = true) {
        guard !preview, !stopping, !libraryMaintenanceBusy, !running else { return }
        if libraryTask != nil {
            pendingLibraryRefresh = (pendingLibraryRefresh ?? false) || allowDelivery
            return
        }
        let token = progressID, audioRevision = audioLibraryRevision
        let sweepsBlocked = sourcePruningBusy || audioMutationBusy || libraryReviewRequired || deliveryPreflightBusy
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
                var sourceCleanupError: String?
                if !sweepsBlocked {
                    do { try await coordinator.purgeRemovedReadingListCaches(storage: storage, debugLog: deliveryDebugLog) }
                    catch is CancellationError { return }
                    catch { sourceCleanupError = "Removed-article cache cleanup needs attention; it will retry." }
                    try await coordinator.recoverTemporaryAudio(storage: storage,
                        settings: deliverySettings.enabled ? deliverySettings : nil)
                }
                let items = try await coordinator.queue(stateRoot: storage.stateRoot)
                var saved: [Episode] = []
                var library: [Episode] = []
                var cleanupError: String? = sourceCleanupError
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
                        deliveryPendingCount = delivery.pendingMedia + delivery.pendingTranscripts + delivery.pendingRemoteDeletes
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
        let project = runtimeProject
        let dictionaryStore: PronunciationStore? = pronunciationIsInert ? nil : .init()
        return { episode in
            try NativeMLXBackend(configuration: KokoroConfiguration(projectRoot: project,
                voice: episode.settings.voice ?? "af_heart", speed: episode.settings.backendSettings["speed"]?.numericValue ?? 1), pronunciations: dictionaryStore?.load().dictionary ?? .empty, gapSeconds: episode.settings.gapSeconds, narrationOptions: episode.settings.narrationOptions ?? .init())
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
    var selectedArticles: [ReadingListEntry] {
        allArticleRows.filter { articlesWebsiteFilter.includes($0) && matchesArticleSearch($0, query: articlesSearchText) }
            .compactMap(\.source).filter { articleSelection.contains($0.id) }
    }
    var eligibleSelectedArticles: [ReadingListEntry] {
        selectedArticles.filter { entry in
            pendingAdds[entry.id] == nil && !queueItems.contains { $0.sourceEntryID == entry.id }
        }
    }
    var canAddSelectedArticles: Bool {
        canAddArticles(eligibleSelectedArticles)
    }
    func canAddArticles(_ entries: [ReadingListEntry]) -> Bool {
        !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !queueMutationBusy
            && !sourceReview.busy && !sourceReview.maintenanceSuspended && !entries.isEmpty
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
    func catalogDidChange(removed: [ReadingListEntry]) {
        let removedIDs = Set(removed.map(\.id))
        for id in removedIDs {
            pendingControls[id]?.cancel(); pendingControls[id] = nil
            pendingTokens[id] = nil; pendingAdds[id] = nil
            articleSelection.remove(id)
            queueSelection.remove(.preparation(id)); retainedArticleSelection.remove(.preparation(id))
        }
        admissionQueue.removeAll { removedIDs.contains($0.entry.id) }
        let removedJobs = Set(queueItems.filter { $0.sourceEntryID.map(removedIDs.contains) == true }.map(\.id))
        queueItems.removeAll { removedJobs.contains($0.id) }
        queueSelection.subtract(removedJobs.map { .episode($0) })
        retainedArticleSelection.subtract(removedJobs.map { .episode($0) })
        let removedURLs = Set(removed.map(\.url))
        if let result, removedURLs.contains(result.article.originalURL) { self.result = nil }
        enqueueIssues.removeAll { issue in removed.contains { issue.hasPrefix($0.title + " — ") } }
        guard !removed.isEmpty, !preview, !stopping, !libraryReviewRequired, !libraryMaintenanceBusy else {
            refreshLibrary()
            Task { await waitForLibraryRefresh(); await autoAdmitNewEntries() }
            return
        }
        sourcePruneRequested = true; sourcePruningBusy = true
        guard sourcePruneTask == nil else { return }
        sourcePruneTask = Task {
            defer {
                sourcePruneTask = nil; sourcePruningBusy = false
                refreshLibrary(); Task { await autoAdmitNewEntries() }
            }
            while sourcePruneRequested, !stopping, !Task.isCancelled {
                sourcePruneRequested = false
                do {
                    if running, try await coordinator.removedReadingListWorkIsActive(stateRoot: speechStorage.stateRoot) {
                        let halted = autoHalted
                        stopQueue(cancelSync: false); autoHalted = halted
                        if let task { await task.value }
                    }
                    while let mutation = queueMutationTask { await mutation.value }
                    try Task.checkCancellation()
                    try await coordinator.purgeRemovedReadingListCaches(storage: speechStorage, debugLog: deliveryDebugLog)
                    // A finalizer may have produced a result while Stop was joining owned work.
                    if let result, try await coordinator.library(storage: speechStorage)
                        .contains(where: { $0.id == result.episode.id && $0.readingListRemoved == true }) {
                        self.result = nil
                    }
                } catch is CancellationError { break }
                catch { audioCleanupError = "Removed-article cache cleanup needs attention; it will retry." }
            }
        }
    }
    /// Set-and-forget admission: only entries still present in the latest source read, with
    /// no queue/pending item and no recorded episode (a removed item is never re-added).
    /// Entries whose admission failed are skipped for the rest of the session.
    func autoAdmitNewEntries(explicit: Bool = false) async {
        guard !sourcePruningBusy, !libraryMaintenanceBusy, !libraryReviewRequired, !deliveryPreflightBusy else { return }
        guard (explicit || (autoAdmitEnabled && !syncPreparing)), !preview, !stopping,
              !sourceReview.busy, !sourceReview.maintenanceSuspended else { return }
        let catalog = sourceReview.catalog
        let root = storageOverride?.stateRoot ?? AppStorage.managedLibrary
        let liveQueue: [SpeechQueueItem]
        do { liveQueue = try await coordinator.queue(stateRoot: root) }
        catch { return } // An unreadable library cannot authorize fresh admission.
        guard !Task.isCancelled, !stopping, !libraryMaintenanceBusy, !libraryReviewRequired,
              !sourcePruningBusy, !deliveryPreflightBusy, !sourceReview.busy, !sourceReview.maintenanceSuspended,
              (explicit || (autoAdmitEnabled && !syncPreparing)),
              sourceReview.catalog.entries == catalog.entries, sourceReview.catalog.currentIDs == catalog.currentIDs else { return }
        let liveByID = Dictionary(uniqueKeysWithValues: liveQueue.map { ($0.id, $0) })
        // Full refreshes avoid replacing active progress. A source reassociation
        // can still be projected without changing that row's live processing state.
        queueItems = queueItems.map { item in
            guard let live = liveByID[item.id], item.sourceEntryID != live.sourceEntryID else { return item }
            return .init(id: item.id, title: item.title, sourceEntryID: live.sourceEntryID,
                admissionID: item.admissionID, state: item.state, attempts: item.attempts,
                lastError: item.lastError, sourceHost: item.sourceHost)
        }
        let queued = Set(liveQueue.compactMap(\.sourceEntryID))
        let candidates = catalog.entries.filter {
            catalog.currentIDs.contains($0.id) && !queued.contains($0.id)
                && pendingTokens[$0.id] == nil && (explicit || !autoAttempted.contains($0.url))
        }
        var fresh: [ReadingListEntry] = []
        for entry in candidates where !Task.isCancelled && !stopping {
            do { if try await coordinator.hasRecordedArticle(url: entry.url, stateRoot: root) == false { fresh.append(entry) } }
            catch { return }
        }
        guard !fresh.isEmpty, !Task.isCancelled, !stopping, !libraryMaintenanceBusy, !libraryReviewRequired,
              !sourcePruningBusy, !deliveryPreflightBusy, !sourceReview.busy, !sourceReview.maintenanceSuspended,
              (explicit || (autoAdmitEnabled && !syncPreparing)),
              sourceReview.catalog.entries == catalog.entries, sourceReview.catalog.currentIDs == catalog.currentIDs else { return }
        admit(entries: fresh, automatic: true)
    }
    /// Automatic processing obeys the same readiness guards as Generate; explicit Stop holds
    /// it until new work arrives or Generate is pressed again.
    func maybeAutoProcess() {
        guard !syncPreparing, autoProcessEnabled, !autoHalted, canGenerateAudio else { return }
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
            var saved = 0, issues: [(entryID: String, message: String)] = []
            while let next = admissionQueue.first {
                if Task.isCancelled { break }
                let entry = next.entry
                if !processingSpeech && !running { status = "Adding \(saved + issues.count + 1): \(entry.title)" }
                do {
                    let item = try await coordinator.enqueueReadingList(entry.id, storage: next.storage, preferences: next.preferences,
                        fetch: fetch, useArchives: useArchivedArticles && (storageOverride == nil || archiveFetchOverride != nil),
                        archiveFetch: archiveFetchOverride, debugLog: deliveryDebugLog,
                        describeImages: describeArticleImages, generateMissingTitles: generateMissingTitles, shouldCommit: { [weak self] in
                            await MainActor.run { self != nil && !self!.stopping && self!.pendingTokens[entry.id] == next.token }
                        }, admissionControl: next.control)
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                        if let index = queueItems.firstIndex(where: { $0.id == item.id }) { queueItems[index] = item }
                        else { queueItems.append(item) }
                        sourceReview.catalog.setResolvedTitle(item.title, for: entry.id)
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
                        if next.automatic { autoAttempted.insert(entry.url) }
                    }
                } catch {
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                    }
                    if next.automatic { autoAttempted.insert(entry.url) }
                    if sourceReview.catalog.currentIDs.contains(entry.id) {
                        issues.append((entry.id, "\(entry.title) — \(Self.enqueueIssueMessage(error))"))
                    }
                }
            }
            issues.removeAll { !sourceReview.catalog.currentIDs.contains($0.entryID) }
            enqueueIssues = issues.map(\.message)
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
        guard !preview, !stopping, !libraryMaintenanceBusy, !libraryReviewRequired, !sourceReview.maintenanceSuspended,
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
    func canRenameArticle(_ item: SpeechQueueItem) -> Bool {
        guard let current = queueItems.first(where: { $0.id == item.id }) else { return false }
        return !preview && !stopping && !running && !processingSpeech && !libraryMaintenanceBusy && !libraryReviewRequired
            && !queueMutationBusy && !sourceReview.maintenanceSuspended && current.state == .queued && current.attempts == 0
    }
    func renameArticle(_ item: SpeechQueueItem, title: String) {
        guard canRenameArticle(item) else { return }
        enqueueQueueMutation(targets: [.episode(item.id)]) { [self] in
            do {
                let updated = try await coordinator.renameQueuedArticle(item.id, title: title,
                    stateRoot: storageOverride?.stateRoot ?? AppStorage.managedLibrary)
                if let index = queueItems.firstIndex(where: { $0.id == updated.id }) { queueItems[index] = updated }
                if let sourceID = updated.sourceEntryID { sourceReview.catalog.setResolvedTitle(updated.title, for: sourceID) }
                status = "Article title updated"
            } catch { self.error = (error as? RelayError)?.localizedDescription ?? "The title could not be changed." }
        }
    }
    var canRemoveQueueSelection: Bool {
        !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired && !queueMutationBusy && !sourceReview.maintenanceSuspended && !queueSelection.isEmpty
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
        guard !preview, !stopping, !libraryMaintenanceBusy, !libraryReviewRequired, !sourceReview.maintenanceSuspended else { return }
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
        pronunciationPreview.stop()
        running = true; processingSpeech = true; stopped = false; error = nil
        notices.reset(key: "global")
        self.progress = nil; batchProgress = nil; status = "Preparing queue…"
        task = Task {
            defer { finishProcessing() }
            await pronunciationPreview.stopAndWait()
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
    func stopQueue(cancelSync: Bool = true) {
        guard canStopProcessing else { return }
        if cancelSync { syncTask?.cancel() }
        autoHalted = true
        cancelling = true; stopped = true; progressID = UUID()
        queueControl?.requestStop()
        task?.cancel()
        status = "Stopping speech and releasing unfinished work…"
    }
    var previewProfiles: [URL: PrototypeProfile] = [:]
    var previewReviews: [URL: ReviewedSource] = [:]
    var previewSourceTitles: [URL: String] = [:]
    func previewQueueItem(_ item: SpeechQueueItem, openWindow: OpenWindowAction) {
        guard !preview, !stopping else { return }
        previewTask?.cancel()
        let request = UUID()
        previewRequestID = request
        previewTask = Task {
            defer { if previewRequestID == request { previewTask = nil } }
            do {
                let review = try await coordinator.savedArticlePreview(articleID: item.id,
                    stateRoot: storageOverride?.stateRoot ?? AppStorage.managedLibrary)
                let url = review.page.originalURL
                let profile = try await coordinator.articlePreviewProfile(articleID: item.id,
                    stateRoot: storageOverride?.stateRoot ?? AppStorage.managedLibrary)
                guard previewRequestID == request, !Task.isCancelled, !stopping else { return }
                previewProfiles[url] = profile
                // Open windows own their review state; retain only the latest handoff here.
                previewReviews = [url: review]
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
    var visibleUploads: [UploadItem] {
        uploadItems.filter { uploadsFilter.includes($0.phase) && matchesAudioSearch($0, query: uploadsSearchText, outbox: true) }
    }
    var visibleServerAudio: [Episode] {
        savedEpisodes.filter {
            let item = audioState($0)
            return serverAudioFilter.includes(item.phase) && matchesAudioSearch(item, query: serverAudioSearchText, outbox: false)
        }.sorted { left, right in
            switch (left.readingListSavedAt, right.readingListSavedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            // Stable identities keep ties/undated records ordered across reloads and events.
            default: return left.id < right.id
            }
        }
    }
    func matchesAudioSearch(_ item: UploadItem, query: String, outbox: Bool) -> Bool {
        guard LibraryTextSearch.isSearching(query) else { return true }
        let episode = item.episode, origin = savedAudioOrigin(episode)
        let removal = outbox ? nil : savedAudioRemovalStatus(episode)
        var fields: [String?] = [episode.title, origin.host, origin.savedDateText, savedAudioMeta(episode), removal]
        if outbox || removal == nil { fields += [item.phase.title, item.detail] }
        if !outbox, savedAudioMeta(episode) == nil, removal == nil { fields.append("Speech ready") }
        if outbox { fields.append(item.sentBytesText) }
        return LibraryTextSearch.matches(query, fields: fields)
    }
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
            && !sourceReview.maintenanceSuspended && !savedEpisodes.isEmpty
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
        pronunciationPreview.stop()
        syncTask?.cancel()
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
    func waitForPodcastCoverImport() async { if let coverImportTask { await coverImportTask.value } }
    func waitForLibraryMaintenance() async { if let libraryMaintenanceTask { await libraryMaintenanceTask.value } }
    func waitForRuntimeSetup() async { if let runtimeTask { await runtimeTask.value } }
    func waitForSourcePruning() async { if let sourcePruneTask { await sourcePruneTask.value } }
    func waitForSettingsBookkeeping() async { while let settingsBookkeepingTask { await settingsBookkeepingTask.value } }
    func waitForSync() async { if let syncTask { await syncTask.value } }
    func shutdown() async {
        stopping = true
        await pronunciationPreview.stopAndWait()
        voiceSamplePlayer.stop()
        // Stop owned work before terminating the UI.
        progressID = UUID()
        let current = task, enqueue = enqueueTask, library = libraryTask
        let mutation = queueMutationTask, audioMutation = audioMutationTask, preview = previewTask
        let delivery = deliveryTask, deliveryTest = deliveryTestTask, automation = automationTask, credential = deliveryCredentialTask
        let runtime = runtimeTask, maintenance = libraryMaintenanceTask, sourcePrune = sourcePruneTask
        let sync = syncTask, settings = settingsBookkeepingTask, cover = coverImportTask, loginItem = loginItemTask
        previewRequestID = UUID()
        current?.cancel(); enqueue?.cancel(); library?.cancel(); mutation?.cancel()
        audioMutation?.cancel(); preview?.cancel(); delivery?.cancel(); deliveryTest?.cancel(); automation?.cancel()
        credential?.cancel(); deliveryCredentialStore?.cancelAuthentication()
        runtime?.cancel(); maintenance?.cancel(); sourcePrune?.cancel()
        sync?.cancel(); settings?.cancel(); cover?.cancel()
        loginItem?.cancel()
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
        if let sourcePrune { await sourcePrune.value }
        if let sync { await sync.value }
        if let settings { await settings.value }
        if let cover { await cover.value }
        if let loginItem { await loginItem.value }
        deliveryCredentialStore?.clearSession()
        deliveryPassword = ""; deliveryPasswordStored = false; deliveryPasswordChecked = false
    }
    func quit() { NSApplication.shared.terminate(nil) }

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
                await waitForSettingsBookkeeping()
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
                settingsBookkeepingTask?.cancel()
                await waitForSettingsBookkeeping(); pendingSettingsHash = nil
                await sourceReview.suspendForLibraryReplacement()
                defer { sourceReview.finishLibraryReplacement() }
                let previous = try await coordinator.restoreLibrary(backup: url, storage: storage)
                try await sourceReview.reloadAfterLibraryReplacement()
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

/// Own only a disposable preference domain. Injected models never inherit or
/// mutate the user's live settings; explicitly supplied test domains are honored.
private final class InertDefaultsDomain: @unchecked Sendable {
    let name = "VoiceRelay.inert.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}
