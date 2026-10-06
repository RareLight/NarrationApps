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
    var audioRetention = AudioRetention.defaultValue { didSet { saveAudioRetention() } }
    var audioCleanupError: String?
    var isQueueResetPending = false
    let notices = NoticeDismissalState()
    var preview = false
    var sourceReview = SourceReviewModel(preview: true)
    var runtimeProject = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Coding/VoiceRelay")
    var audioDirectory: URL?
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
                                                       control: QueueAdmissionControl)] = []
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLibraryCleanup: Bool?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private(set) var stopping = false
    var workspaceSection: WorkspaceSection? = .articles
    @ObservationIgnored private let storageOverride: ManagedSpeechStorage?
    @ObservationIgnored private let backendOverride: (@Sendable (Episode) throws -> any TTSBackend)?
    @ObservationIgnored private let enqueueFetchOverride: (@Sendable (URL) async throws -> FetchedPage)?

    init(preview: Bool = false, storage: ManagedSpeechStorage? = nil,
         backend: (@Sendable (Episode) throws -> any TTSBackend)? = nil,
         enqueueFetch: (@Sendable (URL) async throws -> FetchedPage)? = nil) {
        storageOverride = storage; backendOverride = backend; enqueueFetchOverride = enqueueFetch
        self.preview = preview; sourceReview = SourceReviewModel(preview: preview || storage != nil, coordinator: coordinator)
        sourceReview.onCatalogChange = { [weak self] in self?.refreshLibrary() }
        sourceReview.onContextChange = { [weak self] in self?.notices.reset(key: "source") }
        guard !preview else {
            runtimeProject = URL(fileURLWithPath: "/synthetic/VoiceRelay")
            audioDirectory = URL(fileURLWithPath: "/synthetic/Audio")
            return
        }
        // Isolated lifecycle tests supply storage/providers and never read user preferences or Safari.
        if let storage { audioDirectory = storage.audioDirectory; return }
        if let bytes = UserDefaults.standard.data(forKey: "speechPreferences") {
            do {
                let saved = try JSONDecoder().decode(SpeechPreferences.self, from: bytes)
                try saved.validate(); preferences = saved
            } catch { self.error = "Saved voice and speed preferences could not be read. Default voice and speed are active." }
        }
        if let bookmark = UserDefaults.standard.data(forKey: "audioDirectoryBookmark") {
            var stale = false
            do {
                audioDirectory = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                         relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale, let audioDirectory { try rememberAudioDirectory(audioDirectory) }
            } catch { self.error = "The saved audio folder is unavailable. Choose it again in Settings." }
        }
        if let path = UserDefaults.standard.string(forKey: "runtimeProject") { runtimeProject = URL(fileURLWithPath: path) }
        if let raw = UserDefaults.standard.string(forKey: "audioRetention"), let saved = AudioRetention(rawValue: raw) {
            audioRetention = saved
        }
        startAudioMaintenance()
        sourceReview.startAutomaticSynchronization()
    }
    private func saveAudioRetention() {
        guard !preview else { return }
        if storageOverride == nil { UserDefaults.standard.set(audioRetention.rawValue, forKey: "audioRetention") }
        libraryTask?.cancel()
        refreshLibrary()
    }
    func startAudioMaintenance() {
        guard !preview, storageOverride == nil, maintenanceTask == nil, !stopping else { return }
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.refreshLibrary()
                do { try await Task.sleep(for: .seconds(15 * 60)) }
                catch { return }
            }
        }
    }
    private func savePreferences() {
        guard !preview, (try? preferences.validate()) != nil,
              let bytes = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(bytes, forKey: "speechPreferences")
    }
    private func rememberAudioDirectory(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "audioDirectoryBookmark")
    }
    func selectAudioDirectory() {
        guard !preview, !running, !stopping, !audioMutationBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.title = "Choose where finished audio files will be saved"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ManagedSpeechStorage(audioDirectory: url).validate()
                try rememberAudioDirectory(url)
                audioDirectory = url; error = nil
                refreshLibrary()
            } catch { self.error = (error as? RelayError)?.localizedDescription ?? "The audio folder could not be saved." }
        }
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
    func refreshLibrary(cleanup: Bool = true) {
        guard !preview, !stopping, !running else { return }
        if libraryTask != nil {
            pendingLibraryCleanup = (pendingLibraryCleanup ?? false) || cleanup
            return
        }
        let audio = audioDirectory, token = progressID, retention = audioRetention
        let sweepsBlocked = audioMutationBusy
        libraryTask = Task {
            defer {
                libraryTask = nil
                let pending = pendingLibraryCleanup; pendingLibraryCleanup = nil
                if let pending { refreshLibrary(cleanup: pending) }
                else if audioRetention != retention || (!Task.isCancelled && progressID != token && !running) { refreshLibrary() }
            }
            do {
                let items = try await coordinator.queue(stateRoot: storageOverride?.stateRoot ?? AppStorage.managedLibrary)
                var saved: [Episode] = []
                var library: [Episode] = []
                var cleanupError: String?
                if let audio {
                    let storage = storage(for: audio)
                    if !sweepsBlocked {
                        do { _ = try await coordinator.resumePendingAudioRemovals(storage: storage) }
                        catch is CancellationError { return }
                        catch { cleanupError = (error as? RelayError)?.localizedDescription ?? "Saved audio removal could not finish." }
                        do { _ = try await coordinator.reconcileMissingAudio(storage: storage) }
                        catch is CancellationError { return }
                        catch { cleanupError = cleanupError ?? ((error as? RelayError)?.localizedDescription ?? "Saved audio cleanup could not finish.") }
                        if cleanup {
                            do { _ = try await coordinator.expireAudio(storage: storage, retention: retention) }
                            catch is CancellationError { return }
                            catch { cleanupError = cleanupError ?? ((error as? RelayError)?.localizedDescription ?? "Audio cleanup could not finish. Check audio folder access; Saved Audio rechecks automatically.") }
                        }
                    }
                    library = try await coordinator.library(storage: storage)
                    saved = try await coordinator.savedAudio(storage: storage)
                    if cleanupError == nil && library.filter({ $0.stage == .published || $0.manualAudioDeletionRequested == true }).count > saved.count {
                        cleanupError = "Some saved audio is unavailable. Reconnect its original storage or restore access."
                    }
                }
                guard progressID == token, !running else { return }
                if let result, library.contains(where: { $0.id == result.episode.id && $0.stage == .expired && $0.manualAudioDeletionRequested != true }) { self.result = nil }
                queueItems = items; savedEpisodes = saved; audioCleanupError = cleanupError
                if cleanupError == nil { notices.reset(key: "audio") }
                queueSelection = prunedQueueSelection(queueSelection)
                savedAudioSelection = savedAudioSelection.filter { id in saved.contains(where: { $0.id == id }) }
            }
            catch {
                guard progressID == token, !running else { return }
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
    private func storage(for audio: URL) -> ManagedSpeechStorage {
        storageOverride ?? ManagedSpeechStorage(audioDirectory: audio)
    }
    private func backendFactory() -> @Sendable (Episode) throws -> any TTSBackend {
        if let backendOverride { return backendOverride }
        let project = runtimeProject
        return { episode in
            try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: project,
                voice: episode.settings.voice ?? "af_heart", speed: episode.settings.backendSettings["speed"]?.numericValue ?? 1))
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
        refreshLibrary(cleanup: !wasCancelling)
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
        sourceReview.catalog.selectedEntries(articleSelection)
    }
    /// Adds return immediately; a dedicated background task prepares each entry in order.
    /// Per-entry failures are collected as issues instead of stopping the remaining adds.
    func addSelectedToQueue() {
        guard !preview, !stopping, !queueMutationBusy, !sourceReview.busy, !sourceReview.persistenceBusy else { return }
        let entries = selectedArticles
        guard !entries.isEmpty else { return }
        guard let audioDirectory else { error = "Choose an audio folder in Settings before adding speech."; return }
        // Snapshot list order and settings at the click; selection order never changes FIFO.
        let storage = storage(for: audioDirectory), choices = preferences
        articleSelection.removeAll()
        enqueueIssues = []
        notices.reset(key: "enqueue")
        var admitted = 0
        for entry in entries where pendingTokens[entry.id] == nil {
            let token = UUID(), control = QueueAdmissionControl()
            pendingTokens[entry.id] = token
            pendingControls[entry.id] = control
            pendingAdds[entry.id] = entry.title
            admissionQueue.append((entry: entry, storage: storage, preferences: choices, token: token, control: control))
            admitted += 1
        }
        guard admitted > 0 else { return }
        if !processingSpeech && !running { status = "Preparing \(admitted) selected articles…" }
        startEnqueueIfNeeded()
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
                    }
                } catch is CancellationError {
                    if Task.isCancelled { break }
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                    }
                } catch {
                    admissionQueue.removeAll { $0.token == next.token }
                    if pendingTokens[entry.id] == next.token {
                        pendingAdds[entry.id] = nil; pendingTokens[entry.id] = nil; pendingControls[entry.id] = nil
                    }
                    issues.append("\(entry.title) — \(Self.enqueueIssueMessage(error))")
                }
            }
            enqueueIssues = issues
            if !processingSpeech && !running {
                status = issues.isEmpty ? "\(saved) selected articles saved in queue" : "Saved \(saved); \(issues.count) need attention."
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
        guard let audioDirectory else {
            error = "Choose an audio folder in Settings before generating speech."
            status = "Choose audio storage"; return
        }
        let storage = storage(for: audioDirectory), factory = backendFactory()
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
        let pendingCount: @Sendable () async -> Int = { [weak self] in
            await MainActor.run { self?.pendingAdds.count ?? 0 }
        }
        let articleDone: @Sendable (FixtureResult) -> Void = { [weak self] outcome in
            completion.remember(outcome)
            Task { @MainActor in
                guard let self, self.progressID == token else { return }
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
                    pendingPreparationCount: pendingCount, onQueueChange: change,
                    onArticleComplete: articleDone, onProgress: progress)
                result = completed.lastResult ?? completion.latest
                if let failed = completed.failedItems.first {
                    self.error = failed.lastError
                    status = "Finished with issues; \(completed.failedItems.count) articles need attention."
                } else { status = "Finished \(completed.progress.completedArticles) articles" }
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
        cancelling = true; stopped = true; progressID = UUID()
        queueControl?.requestStop()
        task?.cancel()
        status = "Stopping speech and releasing unfinished work…"
    }
    private func start(saved: Episode) {
        guard !preview, !running, !stopping, !sourceReview.persistenceBusy else { return }
        guard let audioDirectory else {
            error = "Choose an audio folder in Settings before generating speech."
            status = "Choose audio storage"; return
        }
        resetProgress()
        running = true; processingSpeech = true; stopped = false; error = nil; progress = nil; result = nil
        notices.reset(key: "global")
        status = "Resuming audio…"
        let storage = storage(for: audioDirectory)
        let control = QueueRunControl()
        queueControl = control
        let progress = progressHandler, change = queueHandler
        task = Task {
            defer { finishProcessing() }
            do {
                let factory = backendFactory()
                if let item = try await coordinator.queue(stateRoot: storage.stateRoot).first(where: { $0.id == saved.id }) {
                    if !item.state.isReady { _ = try await coordinator.retryQueued(item.id, stateRoot: storage.stateRoot) }
                    result = try await coordinator.runQueued(item.id, storage: storage, backend: factory, control: control, onQueueChange: change, onProgress: progress)
                } else { result = try await coordinator.resume(storage: storage, articleID: saved.id, backend: factory(saved), onProgress: progress) }
                status = "Speech saved locally"
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
    var savedAudioResetCandidates: [String] { savedEpisodes.map(\.id) }
    var canDeleteSavedAudio: Bool {
        !preview && !stopping && !processingSpeech && !cancelling && !audioMutationBusy
            && !sourceReview.persistenceBusy && !savedEpisodes.isEmpty
    }
    func removeSavedAudio(ids: [String]) {
        guard canDeleteSavedAudio, !ids.isEmpty, let audio = audioDirectory else { return }
        let storage = storage(for: audio)
        let targets = Set(ids)
        notices.reset(key: "audio"); notices.reset(key: "global")
        audioMutationBusy = true
        mutatingSavedAudioIDs.formUnion(targets)
        audioMutationTask = Task {
            defer {
                audioMutationTask = nil; audioMutationBusy = false; mutatingSavedAudioIDs = []
                refreshLibrary(cleanup: false)
            }
            do {
                let removed = try await coordinator.removeSavedAudio(ids: ids, storage: storage)
                savedEpisodes.removeAll { removed.contains($0.id) }
                savedAudioSelection.subtract(removed)
            } catch is CancellationError {
            } catch {
                self.error = (error as? RelayError)?.localizedDescription ?? "The saved audio could not be removed."
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
            refreshLibrary(cleanup: false)
        }
    }
    func waitForProcessing() async {
        if let task { await task.value }
        while let queueMutationTask { await queueMutationTask.value }
    }
    func waitForEnqueue() async { while let enqueueTask { await enqueueTask.value } }
    func waitForLibraryRefresh() async { while let libraryTask { await libraryTask.value } }
    func shutdown() async {
        stopping = true
        // Slice 2 has no background service. Stop owned work before terminating the UI.
        progressID = UUID()
        let current = task, enqueue = enqueueTask, library = libraryTask, maintenance = maintenanceTask
        let mutation = queueMutationTask, audioMutation = audioMutationTask, preview = previewTask
        previewRequestID = UUID()
        current?.cancel(); enqueue?.cancel(); maintenance?.cancel(); library?.cancel(); mutation?.cancel()
        audioMutation?.cancel(); preview?.cancel()
        sourceReview.cancel()
        await sourceReview.stop()
        if let current { await current.value }
        if let enqueue { await enqueue.value }
        if let library { await library.value }
        if let maintenance { await maintenance.value }
        if let mutation { await mutation.value }
        if let audioMutation { await audioMutation.value }
        if let preview { await preview.value }
    }
    func quit() { NSApplication.shared.terminate(nil) }
}

enum QueueSelectionID: Hashable {
    case episode(String)
    case preparation(String)
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case articles = "Articles"
    case queue = "Queue"
    case savedAudio = "Saved Audio"
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
                    Text(explanation).font(AppTypography.secondary).textSelection(.enabled).padding(10)
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
        Button("Saved Audio") { openWorkspace(.savedAudio) }.disabled(model.preview)
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
                Picker("Voice", selection: $model.preferences.voice) {
                    ForEach(SpeechVoice.allCases) { voice in Text(voice.label).tag(voice) }
                }
                Stepper("Speed: \(model.preferences.speed, specifier: "%.2f")×", value: $model.preferences.speed, in: 0.75...1.5, step: 0.05)
            } header: {
                SectionHelpHeader(title: "Speech",
                    explanation: "Voice and speed apply to new articles; queued articles keep their captured choices.")
            }.disabled(model.running)
            Section {
                LabeledContent("Source", value: model.sourceReview.plist?.lastPathComponent ?? "Not chosen")
                Button("Choose Reading List…") { model.sourceReview.selectPlist() }
                    .disabled(model.running || model.sourceReview.busy || model.sourceReview.persistenceBusy || model.preview)
            } header: {
                SectionHelpHeader(title: "Reading List",
                    explanation: "VoiceRelay checks the chosen Reading List file automatically while it runs. The file is strictly read-only; nothing is written back.")
            }
            Section {
                LabeledContent("Audio folder", value: model.audioDirectory?.path ?? "Not chosen")
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.audioDirectory?.path ?? "")
                Button(model.audioDirectory == nil ? "Choose…" : "Change…") { model.selectAudioDirectory() }
                    .disabled(model.running || model.preview)
                Picker("Delete audio older than", selection: $model.audioRetention) {
                    ForEach(AudioRetention.allCases) { policy in Text(policy.label).tag(policy) }
                }.pickerStyle(.menu).disabled(model.running || model.preview)
            } header: {
                SectionHelpHeader(title: "Storage",
                    explanation: "New audio saves here; existing audio keeps its captured folder. Processing and cleanup run while VoiceRelay is running; Quit stops owned work and preserves queued articles and saved text.")
            }
        }.formStyle(.grouped)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case troubleshooting = "Troubleshooting"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .troubleshooting: "stethoscope"
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
                    .help(section == .general ? "Voice, speed, Reading List and storage" : "Reading List diagnostics")
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
        .frame(width: (SettingsView.paneSelectorWidth - 8) / 2, height: SettingsView.paneSelectorHeight)
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
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 680
    static let paneSelectorWidth: CGFloat = 196
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
                case .troubleshooting:
                    SourceReviewView(model: model.sourceReview, notices: model.notices, speechRunning: model.running).padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(AppTypography.body)
        .frame(width: Self.windowWidth, height: Self.windowHeight)
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
        .windowResizability(.contentSize)
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
                                       description: Text("Add articles to the queue, then choose Generate Speech."))
            } else {
                List(selection: $model.queueSelection) {
                    ForEach(model.queueItems) { item in
                        let current = item.state == .running && model.processingSpeech
                        let mutating = model.mutatingQueueEntries.contains(.episode(item.id))
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline).lineLimit(2)
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
                                    .help("Make this article ready, then choose Generate Speech.")
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

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var confirmingReset = false
    @State private var capturedResetIDs: [String] = []
    var body: some View {
        Group {
            if model.savedEpisodes.isEmpty {
                ContentUnavailableView("No Saved Audio", systemImage: "waveform",
                                       description: Text("Add selected articles to the queue, then choose Generate Speech."))
            } else {
                List(selection: $model.savedAudioSelection) {
                    ForEach(model.savedEpisodes, id: \.id) { episode in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.title).font(.headline).lineLimit(2)
                            Text(episode.manualAudioDeletionRequested == true
                                 ? "Removal pending; retry its remove control to finish."
                                 : "Speech ready").font(AppTypography.secondary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button("Show in Finder") { reveal(episode) }.disabled(model.preview)
                                    .buttonStyle(.glass).controlSize(.regular)
                                    .help("Reveal the saved audio file in Finder")
                            }
                        }
                        RowRemovalButton(accessibilityLabel: "Delete \(episode.title) audio",
                            help: "Delete this audio file and remove it from the feed; saved article text is kept",
                            isEnabled: model.canDeleteSavedAudio && !model.mutatingSavedAudioIDs.contains(episode.id)) {
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
                model.refreshLibrary(cleanup: false)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                SelectionManagementControl(selectionCount: model.savedAudioSelection.count,
                    resetTitle: "Reset Saved Audio…", canReset: model.canDeleteSavedAudio,
                    canRemove: model.canDeleteSavedAudio,
                    resetHelp: "Delete all shown audio files and remove them from the feed; saved article text is kept",
                    removeHelp: "Delete the selected audio files and remove them from the feed; saved article text is kept",
                    onReset: {
                        capturedResetIDs = model.savedAudioResetCandidates
                        confirmingReset = true
                    },
                    onRemove: { model.removeSavedAudio(ids: Array(model.savedAudioSelection)) })
            }
        }
        .confirmationDialog("Reset saved audio?", isPresented: $confirmingReset) {
            Button("Reset Saved Audio", role: .destructive) {
                let ids = capturedResetIDs
                capturedResetIDs = []
                model.removeSavedAudio(ids: ids)
            }
            Button("Cancel", role: .cancel) { capturedResetIDs = [] }
        } message: {
            Text("Permanently delete the audio files for all \(capturedResetIDs.count) shown items and remove them from the feed? Saved article text and Reading List entries are kept.")
        }
    }
    private func reveal(_ episode: Episode) {
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { model.error = "The saved audio file is unavailable. Check the audio folder in Settings." }
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
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic queued article"),
                       SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "A synthetic interrupted article", state: .running, attempts: 1)]
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
#Preview("Saved Audio — inert empty library") { LibraryView(model: AppModel(preview: true)) }
#Preview("Saved Audio — inert ready and paused") {
    let model = AppModel(preview: true)
    let settings = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic/Articles"))
    if let bytes = try? JSONEncoder().encode(settings), let profile = try? JSONSerialization.jsonObject(with: bytes) {
        for (index, stage) in [Stage.published, .synthesizing].enumerated() {
            let record: [String: Any] = ["id": "00000000-0000-0000-0000-00000000000\(index)",
                "title": index == 0 ? "A synthetic saved article" : "A synthetic paused article", "stage": stage.rawValue, "settings": profile]
            if let data = try? JSONSerialization.data(withJSONObject: record),
               let episode = try? JSONDecoder().decode(Episode.self, from: data) { model.savedEpisodes.append(episode) }
        }
    }
    return LibraryView(model: model)
}
#endif
