import Foundation

public enum SpeechQueueState: String, Codable, Sendable {
    case queued, running, paused, failed, completed
    /// Older builds retained completed rows. Reverify those rows before removing them.
    public var isReady: Bool { self == .queued || self == .completed }
    public var label: String {
        switch self {
        case .queued: "Ready"
        case .running: "Processing"
        case .paused: "Paused"
        case .failed: "Needs attention"
        case .completed: "Speech ready"
        }
    }
}

public struct SpeechQueueItem: Codable, Sendable, Identifiable, Equatable {
    /// The queue references the canonical episode, rather than owning a second identity.
    public let id: String
    public let title: String
    public let sourceEntryID: String?
    public var sourceHost: String?
    public var admissionID: UUID?
    public var state: SpeechQueueState
    public var attempts: Int
    public var lastError: String?
    public init(id: String, title: String, sourceEntryID: String? = nil, admissionID: UUID? = nil,
                state: SpeechQueueState = .queued, attempts: Int = 0, lastError: String? = nil, sourceHost: String? = nil) {
        self.id = id; self.title = title; self.sourceEntryID = sourceEntryID; self.admissionID = admissionID
        self.state = state; self.attempts = attempts; self.lastError = lastError; self.sourceHost = sourceHost
    }
}

/// Progress for the fixed waiting batch captured by an explicit Generate Audio command.
public struct QueueBatchProgress: Codable, Sendable, Equatable {
    public let stage: Stage
    public let completedChunks: Int
    public let totalChunks: Int
    public let completedArticles: Int
    public let totalArticles: Int
    public let currentArticleIndex: Int?
    public let pendingPreparations: Int
    public init(stage: Stage, completedChunks: Int, totalChunks: Int, completedArticles: Int, totalArticles: Int,
                currentArticleIndex: Int? = nil, pendingPreparations: Int = 0) {
        self.stage = stage; self.completedChunks = completedChunks; self.totalChunks = totalChunks
        self.completedArticles = completedArticles; self.totalArticles = totalArticles
        self.currentArticleIndex = currentArticleIndex
        self.pendingPreparations = pendingPreparations
    }
    private enum CodingKeys: String, CodingKey {
        case stage, completedChunks, totalChunks, completedArticles, totalArticles, currentArticleIndex, pendingPreparations
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(Stage.self, forKey: .stage)
        completedChunks = try container.decode(Int.self, forKey: .completedChunks)
        totalChunks = try container.decode(Int.self, forKey: .totalChunks)
        completedArticles = try container.decode(Int.self, forKey: .completedArticles)
        totalArticles = try container.decode(Int.self, forKey: .totalArticles)
        currentArticleIndex = try container.decodeIfPresent(Int.self, forKey: .currentArticleIndex)
        pendingPreparations = try container.decodeIfPresent(Int.self, forKey: .pendingPreparations) ?? 0
    }
    public var fractionCompleted: Double {
        let total = totalChunks + totalArticles
        return total > 0 ? Double(completedChunks + completedArticles) / Double(total) : 0
    }
}

public struct QueueBatchResult: Sendable {
    public let lastResult: FixtureResult?
    public let progress: QueueBatchProgress
    public let failedItems: [SpeechQueueItem]
    public init(lastResult: FixtureResult?, progress: QueueBatchProgress, failedItems: [SpeechQueueItem] = []) {
        self.lastResult = lastResult; self.progress = progress; self.failedItems = failedItems
    }
}

public final class QueueRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    public init() {}
    public func requestStop() { lock.withLock { stopRequested = true } }
    public var discardInterruptedWork: Bool { lock.withLock { stopRequested } }
}

public final class QueueAdmissionControl: @unchecked Sendable {
    public let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

extension FixtureCoordinator {
    private func metadataReader(_ root: URL) throws -> NativeStore? {
        guard root.isFileURL else { throw RelayError.setup("The private library must be local.") }
        let database = PrototypeProfile.fixture(at: root).database
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        try ManagedSpeechStorage.validateLibrary(stateRoot: root)
        return try NativeStore(url: database, readOnly: true)
    }
    /// Writers are short-lived; a bounded wait lets interactive work (for example queue adds)
    /// proceed between commits while another coordinator briefly holds the lock.
    private func metadataWriter(_ root: URL) throws -> NativeStore {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            do {
                return try NativeStore(url: ManagedSpeechStorage.prepareLibrary(stateRoot: root))
            } catch RelayError.writerBusy {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw RelayError.writerBusy }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    public func catalog(stateRoot: URL = AppStorage.managedLibrary) throws -> ReadingListCatalog {
        try metadataReader(stateRoot)?.catalog() ?? ReadingListCatalog()
    }
    public func reconcile(_ snapshot: ReadingListSnapshot, stateRoot: URL = AppStorage.managedLibrary) throws -> ReadingListCatalog {
        try Task.checkCancellation()
        for entry in snapshot.entries { try ArticleURL.validate(entry.url) }
        let store = try metadataWriter(stateRoot)
        var catalog = try store.catalog(); catalog.reconcile(snapshot)
        // Legacy exclusions are still decodable but no longer honored; each save clears them.
        catalog.excludedIDs = []
        try store.saveCatalog(catalog)
        return catalog
    }
    public func queue(stateRoot: URL = AppStorage.managedLibrary) throws -> [SpeechQueueItem] {
        let items = try metadataReader(stateRoot)?.queue() ?? []
        guard items.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.attempts >= 0 }) else {
            throw RelayError.setup("The saved speech queue is invalid.")
        }
        return items
    }
    /// Explicit enqueue from Reading List prepares new text; previously saved text is reused offline.
    /// Fetch injection keeps this command independently testable without network or inference.
    public func enqueueReadingList(_ entryID: String, storage: ManagedSpeechStorage, preferences: SpeechPreferences,
                                   fetch: (@Sendable (URL) async throws -> FetchedPage)? = nil,
                                   shouldCommit: @Sendable () async -> Bool = { true },
                                   admissionControl: QueueAdmissionControl? = nil) async throws -> SpeechQueueItem {
        try Task.checkCancellation(); try preferences.validate(); try storage.validate()
        let savedCatalog = try catalog(stateRoot: storage.stateRoot)
        guard let entry = savedCatalog.entries.first(where: { $0.id == entryID }) else {
            throw RelayError.setup("Choose an available Reading List article before adding it to the queue.")
        }
        try ArticleURL.validate(entry.url)
        let key = "reviewed-url-v1-" + Files.hash(Data(entry.url.absoluteString.utf8))
        if let store = try metadataReader(storage.stateRoot), let episode = try store.existingEpisode(sourceKey: key),
           let bytes = try store.snapshot(articleID: episode.id) {
            let saved = try JSONDecoder().decode(StoredExtraction.self, from: bytes).review()
            guard await shouldCommit() else { throw CancellationError() }
            return try enqueue(saved, storage: storage, preferences: preferences, sourceEntryID: entryID,
                               admissionControl: admissionControl)
        }
        let page: FetchedPage
        if let fetch { page = try await fetch(entry.url) }
        else {
            let limits = try FetchLimits(maximumBytes: storage.profile.maxArticleBytes,
                                         timeout: Double(storage.profile.httpTimeoutSeconds))
            page = try await PageFetcher(limits: limits).fetch(entry.url)
        }
        try Task.checkCancellation()
        guard page.originalURL == entry.url, page.bytes.count <= storage.profile.maxArticleBytes else {
            throw RelayError.setup("The fetched article does not match the selected Reading List entry or exceeds its size limit.")
        }
        let limit = storage.profile.chunkMaxCharacters
        let extraction = Task.detached { try Task.checkCancellation(); return try ReviewedSource.prepare(page, chunkLimit: limit) }
        let review = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
        try Task.checkCancellation()
        if let issue = review.issue { throw RelayError.setup(issue.message + " Double-click the article in Articles to preview it.") }
        guard await shouldCommit() else { throw CancellationError() }
        // enqueue rechecks persisted membership after the asynchronous fetch.
        return try enqueue(review, storage: storage, preferences: preferences, sourceEntryID: entryID,
                           admissionControl: admissionControl)
    }
    /// Enqueue commits approved text, captured settings and episode identity together, without TTS or scratch files.
    public func enqueue(_ review: ReviewedSource, storage: ManagedSpeechStorage, preferences: SpeechPreferences,
                        sourceEntryID: String? = nil, admissionControl: QueueAdmissionControl? = nil) throws -> SpeechQueueItem {
        try Task.checkCancellation(); try preferences.validate(); try storage.validate()
        guard review.issue == nil, let document = review.document, let plan = review.narration, !plan.chunks.isEmpty,
              document.article.originalURL == review.page.originalURL, document.article.finalURL == review.page.finalURL,
              review.page.bytes.count <= storage.profile.maxArticleBytes else { throw RelayError.setup("Select a readable article before adding speech.") }
        try ArticleURL.validate(review.page.originalURL); try ArticleURL.validate(review.page.finalURL)
        let store = try metadataWriter(storage.stateRoot)
        let catalog = try store.catalog()
        let sourceEntry = catalog.entries.first { $0.id == sourceEntryID && $0.url == review.page.originalURL }
        if sourceEntryID != nil {
            guard sourceEntry != nil else {
                throw RelayError.setup("This Reading List article does not match the saved source.")
            }
        }
        var settings = storage.profile
        settings.backendSelector = "reviewed-article-speech"; settings.channelTitle = "VoiceRelay Articles"
        settings.channelDescription = "Private local speech; remote delivery disabled"
        settings.voice = preferences.voice.rawValue; settings.backendSettings = ["speed": .number(preferences.speed)]
        settings.language = preferences.languageRegion.rawValue
        try settings.validate()
        if admissionControl?.isCancelled == true { throw CancellationError() }
        try store.execute("BEGIN IMMEDIATE")
        do {
            var episode = try store.episode(sourceKey: "reviewed-url-v1-" + Files.hash(Data(review.page.originalURL.absoluteString.utf8)), settings: settings)
            if let bytes = try store.snapshot(articleID: episode.id) {
                let saved = try JSONDecoder().decode(StoredExtraction.self, from: bytes).review()
                guard Files.hash(saved.page.bytes) == Files.hash(review.page.bytes) else {
                    throw RelayError.setup("This article already has saved speech or queued text from another source revision. Existing progress is preserved.")
                }
            } else {
                guard episode.stage != .published else { throw RelayError.artifact("Published article text is missing. Existing audio is preserved.") }
                let snapshot = try StoredExtraction(review: review, chunkLimit: episode.settings.chunkMaxCharacters)
                try store.saveSnapshot(articleID: episode.id, data: Files.json(snapshot))
                episode.title = document.article.title; episode.stage = .extracted
            }
            if let saved = sourceEntry?.addedAt { episode.readingListSavedAt = saved }
            try store.execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
            var item = try store.queue().first(where: { $0.id == episode.id }) ?? SpeechQueueItem(
                id: episode.id, title: episode.title, sourceEntryID: sourceEntryID,
                admissionID: admissionControl?.id, state: .queued, sourceHost: review.page.originalURL.host)
            if item.sourceEntryID == nil, let sourceEntryID {
                item = SpeechQueueItem(id: item.id, title: item.title, sourceEntryID: sourceEntryID,
                                       admissionID: item.admissionID,
                                       state: item.state, attempts: item.attempts, lastError: item.lastError, sourceHost: item.sourceHost)
            }
            if item.sourceHost == nil { item.sourceHost = review.page.originalURL.host }
            try store.saveQueueItem(item)
            beforeEnqueueCommit?()
            if admissionControl?.isCancelled == true { throw CancellationError() }
            try store.execute("COMMIT")
            return item
        } catch { try? store.execute("ROLLBACK"); throw error }
    }
    /// Temporary files can be evicted by macOS. Recover unconfirmed output from retained
    /// text, or recreate a released copy when the user changes the upload destination.
    /// Failed queue rows remain manual Retry; confirmed remote-only history stays intact.
    public func recoverTemporaryAudio(storage: ManagedSpeechStorage, settings: DeliverySettings?) throws {
        let database = storage.profile.database
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        let store = try metadataWriter(storage.stateRoot)
        let settings = try settings?.normalized()
        try store.execute("BEGIN IMMEDIATE")
        do {
            let existing = Set(try store.queue().map(\.id))
            for episode in try store.published() where episode.settings.temporaryAudio == true || episode.localAudioReleased == true {
                guard !existing.contains(episode.id), temporaryAudioIsMissing(episode) else { continue }
                if let settings, DeliveryPublicationStatus.unconfirmed(episode, settings: settings) == .uploaded { continue }
                // Disabled delivery retains confirmed history, without repeatedly regenerating it.
                if settings == nil, episode.delivery?.status == .uploaded { continue }
                guard try store.snapshot(articleID: episode.id) != nil else {
                    throw RelayError.storage("Temporary audio is missing and its saved article text is unavailable.")
                }
                try store.saveQueueItem(SpeechQueueItem(id: episode.id, title: episode.title,
                    sourceEntryID: nil, state: .queued, sourceHost: episode.sourceHost))
            }
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
    }
    public func retryQueued(_ id: String, stateRoot: URL = AppStorage.managedLibrary) throws -> SpeechQueueItem {
        try Task.checkCancellation()
        let store = try metadataWriter(stateRoot)
        guard var item = try store.queue().first(where: { $0.id == id }) else { throw RelayError.setup("The queued article is unavailable.") }
        if item.state != .completed { item.state = .queued; item.lastError = nil; try store.saveQueueItem(item) }
        return item
    }
    public func removeFromQueue(_ id: String, stateRoot: URL = AppStorage.managedLibrary) throws {
        try removeFromQueue(ids: [id], stateRoot: stateRoot)
    }
    public func removeFromQueue(ids: [String], stateRoot: URL = AppStorage.managedLibrary) throws {
        try Task.checkCancellation()
        let store = try metadataWriter(stateRoot)
        let items = try store.queue()
        let known = Set(items.map(\.id))
        let targets = ids.filter { known.contains($0) }
        guard !targets.isEmpty else { return }
        guard !items.contains(where: { targets.contains($0.id) && $0.state == .running }) else {
            throw RelayError.setup("Pause or retry the interrupted item before removing it from the queue.")
        }
        // Removing a queue entry preserves its episode, snapshots and any published audio.
        try store.execute("BEGIN IMMEDIATE")
        do {
            for id in targets { try store.execute("DELETE FROM speech_queue WHERE article_id=?", [id]) }
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
    }
    public func cancelAdmission(_ id: UUID, stateRoot: URL = AppStorage.managedLibrary) throws -> SpeechQueueItem? {
        try Task.checkCancellation()
        let store = try metadataWriter(stateRoot)
        guard let item = try store.queue().first(where: { $0.admissionID == id }) else { return nil }
        guard item.state != .running else {
            throw RelayError.setup("During preparation completion this article began processing. Stop before removing it.")
        }
        try store.execute("BEGIN IMMEDIATE")
        do {
            try store.execute("DELETE FROM speech_queue WHERE article_id=?", [item.id])
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
        return item
    }
    public func resetQueue(stateRoot: URL = AppStorage.managedLibrary) throws {
        try Task.checkCancellation()
        let database = PrototypeProfile.fixture(at: stateRoot).database
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        try ManagedSpeechStorage.validateLibrary(stateRoot: stateRoot)
        let store = try NativeStore(url: database)
        try Task.checkCancellation()
        try store.execute("DELETE FROM speech_queue")
    }
    private func claimQueued(_ id: String, stateRoot: URL, allowingRunning: Bool = false) throws -> Episode {
        let store = try metadataWriter(stateRoot)
        let items = try store.queue()
        guard allowingRunning || !items.contains(where: { $0.state == .running }) else {
            throw RelayError.setup("A queue item was interrupted. Retry it explicitly before continuing.")
        }
        guard var item = items.first(where: { $0.id == id }), item.state.isReady, item.attempts < Int.max else { throw RelayError.setup("Retry this queue item before running it.") }
        guard let episode = try store.episodes().first(where: { $0.id == id }) else { throw RelayError.setup("The queued episode is unavailable.") }
        item.state = .running; item.attempts += 1; item.lastError = nil; try store.saveQueueItem(item)
        return episode
    }
    private func finishQueued(_ id: String, state: SpeechQueueState, error: String?, stateRoot: URL) throws -> SpeechQueueItem {
        let store = try metadataWriter(stateRoot)
        guard var item = try store.queue().first(where: { $0.id == id }) else { throw RelayError.setup("The queued article is unavailable.") }
        item.state = state; item.lastError = error
        if state == .completed {
            // Called only after resume returns: media hash/probe/decode and local feed commit succeeded.
            try store.execute("DELETE FROM speech_queue WHERE article_id=?", [id])
        } else { try store.saveQueueItem(item) }
        return item
    }
    private func refuseCompetingDrain(_ root: URL) throws {
        if activeDrainRoots.contains(root.resolvingSymlinksInPath().standardizedFileURL.path) {
            throw RelayError.setup("A queue drain is already processing this library.")
        }
    }
    public func runQueued(_ id: String, storage: ManagedSpeechStorage,
                          backend: @Sendable (Episode) throws -> any TTSBackend,
                          control: QueueRunControl? = nil,
                          delivery: DeliverySettings? = nil,
                          onQueueChange: @escaping @Sendable (SpeechQueueItem) -> Void = { _ in },
                          onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult {
        try Task.checkCancellation()
        try refuseCompetingDrain(storage.stateRoot)
        _ = try reconcileMissingAudio(storage: storage)
        let episode = try claimQueued(id, stateRoot: storage.stateRoot)
        var provider: (any TTSBackend)?
        defer { provider?.cancel() }
        return try await runClaimed(episode, storage: storage, provider: {
            let made = try backend(episode); provider = made; return made
        }, control: control, delivery: delivery, onQueueChange: onQueueChange, onProgress: onProgress)
    }
    /// Claimed-item body shared by single-shot and batch runs; the caller owns the provider's lifetime.
    private func runClaimed(_ episode: Episode, storage: ManagedSpeechStorage,
                            provider makeProvider: () throws -> any TTSBackend,
                            control: QueueRunControl? = nil,
                            delivery: DeliverySettings? = nil, context: SpeechArticleContext? = nil,
                            onQueueChange: @escaping @Sendable (SpeechQueueItem) -> Void,
                            onProgress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> FixtureResult {
        if let item = try queue(stateRoot: storage.stateRoot).first(where: { $0.id == episode.id }) { onQueueChange(item) }
        do {
            let provider = try makeProvider()
            let result = try await resumeWork(storage: storage, articleID: episode.id, backend: provider,
                                          delivery: delivery, context: context, onProgress: onProgress)
            if context?.finishAfterStop == true && Task.isCancelled {
                let completion = Task { try self.finishQueued(episode.id, state: .completed, error: nil, stateRoot: storage.stateRoot) }
                onQueueChange(try await completion.value)
            } else { onQueueChange(try finishQueued(episode.id, state: .completed, error: nil, stateRoot: storage.stateRoot)) }
            return result
        } catch {
            let interrupted = error is CancellationError || error as? RelayError == .interrupted
            if control?.discardInterruptedWork == true, Task.isCancelled || interrupted {
                let cleanup = Task {
                    try self.abandonInterruptedWork(episodeID: episode.id, storage: storage, pipeline: context?.pipeline)
                    return try self.finishQueued(episode.id, state: .queued, error: nil, stateRoot: storage.stateRoot)
                }
                do {
                    onQueueChange(try await cleanup.value)
                } catch let cleanupError {
                    let message = (cleanupError as? RelayError)?.localizedDescription
                        ?? "Interrupted work could not be discarded. Retry or remove the queue item."
                    _ = try? finishQueued(episode.id, state: .failed, error: message, stateRoot: storage.stateRoot)
                    throw cleanupError
                }
                throw CancellationError()
            }
            let message = interrupted ? "Speech paused; saved progress is retained." : (error as? RelayError)?.localizedDescription ?? "Speech failed. Retry when ready."
            onQueueChange(try finishQueued(episode.id, state: interrupted ? .paused : .failed, error: message, stateRoot: storage.stateRoot))
            throw error
        }
    }
    public func runNextQueued(storage: ManagedSpeechStorage,
                              backend: @Sendable (Episode) throws -> any TTSBackend,
                              onQueueChange: @escaping @Sendable (SpeechQueueItem) -> Void = { _ in },
                              onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult? {
        try Task.checkCancellation()
        try refuseCompetingDrain(storage.stateRoot)
        let items = try queue(stateRoot: storage.stateRoot)
        guard !items.contains(where: { $0.state == .running }) else { throw RelayError.setup("A queue item was interrupted. Retry it explicitly before continuing.") }
        guard let first = items.first(where: { $0.state.isReady }) else { return nil }
        return try await runQueued(first.id, storage: storage, backend: backend, onQueueChange: onQueueChange, onProgress: onProgress)
    }
    private func waitingBatch(stateRoot: URL, allowingRunning: Bool = false) throws -> [(id: String, chunks: Int)] {
        let items = try queue(stateRoot: stateRoot)
        guard allowingRunning || !items.contains(where: { $0.state == .running }) else { throw RelayError.setup("A queue item was interrupted. Retry it explicitly before continuing.") }
        guard let store = try metadataReader(stateRoot) else { return [] }
        let episodes = Dictionary(uniqueKeysWithValues: try store.episodes().map { ($0.id, $0) })
        return try items.filter { $0.state.isReady }.map { item in
            guard let data = try store.snapshot(articleID: item.id) else {
                throw RelayError.artifact("Queued article text is unavailable. Existing progress is preserved.")
            }
            let review = try JSONDecoder().decode(StoredExtraction.self, from: data).review()
            guard var plan = review.narration, !plan.chunks.isEmpty,
                  let episode = episodes[item.id] else {
                throw RelayError.artifact("Queued article text is unavailable. Existing progress is preserved.")
            }
            // Resume upgrades unfinished narration. Count that same plan before running
            // so older queued snapshots cannot under-report the new boundary chunks.
            if episode.stage != .published, plan.version != Narration.version, let article = review.document?.article {
                plan = try Narration.prepare(article, limit: episode.settings.chunkMaxCharacters)
            }
            return (item.id, plan.chunks.count)
        }
    }
    /// Fixed FIFO membership prevents totals from changing when more articles are added later.
    public func runQueuedBatch(storage: ManagedSpeechStorage,
                               backend: @Sendable (Episode) throws -> any TTSBackend,
                               onQueueChange: @escaping @Sendable (SpeechQueueItem) -> Void = { _ in },
                               onArticleComplete: @escaping @Sendable (FixtureResult) -> Void = { _ in },
                               onProgress: @escaping @Sendable (QueueBatchProgress) -> Void = { _ in }) async throws -> QueueBatchResult {
        try Task.checkCancellation()
        try refuseCompetingDrain(storage.stateRoot)
        let batch = try waitingBatch(stateRoot: storage.stateRoot)
        let plannedTotal = batch.reduce(0) { $0 + $1.chunks }
        onProgress(QueueBatchProgress(stage: .extracted, completedChunks: 0, totalChunks: plannedTotal,
                                      completedArticles: 0, totalArticles: batch.count))
        var completedChunks = 0
        var last: FixtureResult?
        // A backend with the same identity keeps its prepared helper session across batch items,
        // avoiding a model reload between articles. The active provider is cancelled exactly once.
        var active: (any TTSBackend)?
        defer { active?.cancel() }
        for (index, item) in batch.enumerated() {
            try Task.checkCancellation()
            let offset = completedChunks, remaining = batch.dropFirst(index + 1).reduce(0) { $0 + $1.chunks }
            onProgress(QueueBatchProgress(stage: .extracted, completedChunks: offset, totalChunks: offset + item.chunks + remaining,
                completedArticles: index, totalArticles: batch.count, currentArticleIndex: index + 1))
            _ = try reconcileMissingAudio(storage: storage)
            let episode = try claimQueued(item.id, stateRoot: storage.stateRoot)
            let result = try await runClaimed(episode, storage: storage, provider: {
                let candidate = try backend(episode)
                if let current = active, current.identity.id == candidate.identity.id { return current }
                active?.cancel(); active = candidate
                return candidate
            }, onQueueChange: onQueueChange) { update in
                let total = update.totalChunks > 0 ? update.totalChunks : item.chunks
                let done = min(total, max(0, update.completedChunks))
                // Encoding/publication is one additional unit per article; synthesized chunks alone never finish the bar.
                onProgress(QueueBatchProgress(stage: update.stage, completedChunks: offset + done,
                    totalChunks: offset + total + remaining, completedArticles: index, totalArticles: batch.count,
                    currentArticleIndex: index + 1))
            }
            last = result; completedChunks += result.narration.chunks.count
            onProgress(QueueBatchProgress(stage: .published, completedChunks: completedChunks,
                totalChunks: completedChunks + remaining, completedArticles: index + 1, totalArticles: batch.count,
                currentArticleIndex: index + 1))
            onArticleComplete(result)
        }
        let final = QueueBatchProgress(stage: .published, completedChunks: completedChunks, totalChunks: completedChunks,
                                       completedArticles: batch.count, totalArticles: batch.count)
        onProgress(final)
        return QueueBatchResult(lastResult: last, progress: final)
    }
    public func drainQueue(storage: ManagedSpeechStorage,
                           backend: @escaping @Sendable (Episode) throws -> any TTSBackend,
                           control: QueueRunControl = QueueRunControl(),
                           delivery: DeliverySettings? = nil, debugLog: DeliveryDebugLog? = nil,
                           pendingPreparationCount: @escaping @Sendable () async -> Int = { 0 },
                           onQueueChange: @escaping @Sendable (SpeechQueueItem) -> Void = { _ in },
                           onArticleComplete: @escaping @Sendable (FixtureResult) -> Void = { _ in },
                           onProgress: @escaping @Sendable (QueueBatchProgress) -> Void = { _ in }) async throws -> QueueBatchResult {
        try Task.checkCancellation()
        let root = storage.stateRoot.resolvingSymlinksInPath().standardizedFileURL
        guard activeDrainRoots.insert(root.path).inserted else {
            throw RelayError.setup("A queue drain is already processing this library.")
        }
        defer { activeDrainRoots.remove(root.path) }
        // Refuse interrupted membership before allowing our own two in-flight stages.
        _ = try waitingBatch(stateRoot: storage.stateRoot)
        let pipeline = SingleWorkerSpeechPipeline(database: storage.profile.database, debugLog: debugLog)
        let start = ProcessInfo.processInfo.systemUptime
        defer { pipeline.close(); pipeline.diagnostics.record(.queue, seconds: ProcessInfo.processInfo.systemUptime - start) }
        let progress = SpeechDrainProgress(callback: onProgress)
        var failed: [SpeechQueueItem] = []
        var last: FixtureResult?
        var inFlight = Set<String>()
        var previous: SpeechTurn?
        var interrupted = false
        return try await withThrowingTaskGroup(of: SpeechArticleOutcome.self) { group in
            while true {
                if Task.isCancelled || interrupted { group.cancelAll() }
                let plans = Task.isCancelled || interrupted ? [] : try waitingBatch(stateRoot: storage.stateRoot, allowingRunning: true)
                let pending = Task.isCancelled || interrupted ? 0 : await pendingPreparationCount()
                progress.observe(plans, pending: pending)
                if !Task.isCancelled && !interrupted {
                    for item in plans where !inFlight.contains(item.id) {
                        guard inFlight.count < 2 else { break }
                        let context = SpeechArticleContext(pipeline: pipeline, previous: previous, control: control)
                        previous = context.turn; inFlight.insert(item.id)
                        group.addTask {
                            await self.runPipelineArticle(item, storage: storage, backend: backend, context: context,
                                delivery: delivery, progress: progress, onQueueChange: onQueueChange)
                        }
                    }
                }
                if inFlight.isEmpty {
                    try Task.checkCancellation()
                    if interrupted { throw CancellationError() }
                    if pending > 0 {
                        progress.idle()
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    break
                }
                guard let outcome = try await group.next() else { break }
                inFlight.remove(outcome.id)
                if let result = outcome.result {
                    last = result
                    progress.complete(outcome.id, chunks: result.narration.chunks.count)
                    onArticleComplete(result)
                }
                if let failure = outcome.failure { failed.append(failure) }
                if outcome.interrupted { interrupted = true; group.cancelAll() }
            }
            try Task.checkCancellation()
            if interrupted { throw CancellationError() }
            return QueueBatchResult(lastResult: last, progress: progress.finish(), failedItems: failed)
        }
    }
    private func runPipelineArticle(_ item: (id: String, chunks: Int), storage: ManagedSpeechStorage,
                                    backend: @Sendable (Episode) throws -> any TTSBackend, context: SpeechArticleContext,
                                    delivery: DeliverySettings?, progress: SpeechDrainProgress,
                                    onQueueChange: @escaping @Sendable (SpeechQueueItem) -> Void) async -> SpeechArticleOutcome {
        defer { context.finishSpeech() }
        var claimed = false
        do {
            // Keep the next row removable/Ready until the current speech turn ends.
            if let previous = context.previous { try await previous.wait() }
            try Task.checkCancellation()
            guard try queue(stateRoot: storage.stateRoot).contains(where: { $0.id == item.id && $0.state.isReady }) else {
                return SpeechArticleOutcome(id: item.id)
            }
            _ = try reconcileMissingAudio(storage: storage)
            let episode = try claimQueued(item.id, stateRoot: storage.stateRoot, allowingRunning: true)
            claimed = true; progress.start(item.id, chunks: item.chunks)
            let result = try await runClaimed(episode, storage: storage,
                provider: { context.pipeline.provider(try backend(episode)) }, control: context.control,
                delivery: delivery, context: context, onQueueChange: onQueueChange) { progress.update(item.id, $0) }
            return SpeechArticleOutcome(id: item.id, result: result)
        } catch {
            let interrupted = error is CancellationError || error as? RelayError == .interrupted
            if !claimed && !interrupted,
               let row = try? finishQueued(item.id, state: .failed,
                    error: (error as? RelayError)?.localizedDescription ?? "The queued article could not be started.", stateRoot: storage.stateRoot) {
                progress.start(item.id, chunks: item.chunks); onQueueChange(row)
            }
            let failure = interrupted ? nil : try? queue(stateRoot: storage.stateRoot).first(where: { $0.id == item.id })
            return SpeechArticleOutcome(id: item.id, failure: failure, interrupted: interrupted)
        }
    }
    func abandonInterruptedWork(episodeID: String, storage: ManagedSpeechStorage, pipeline: SingleWorkerSpeechPipeline? = nil) throws {
        let root = storage.stateRoot
        try ManagedSpeechStorage.validateLibrary(stateRoot: root)
        guard UUID(uuidString: episodeID) != nil else { throw RelayError.setup("The interrupted episode is invalid.") }
        let p = storage.profile
        let lease: PipelineLease?
        if let pipeline { try pipeline.ensureLease(p.database); lease = nil }
        else { lease = try PipelineLease(database: p.database) }
        defer { lease?.release() }
        let store = try metadataWriter(root)
        guard let episode = try store.episodes().first(where: { $0.id == episodeID }) else {
            throw RelayError.setup("The interrupted episode is unavailable.")
        }
        guard Files.samePath(episode.settings.database, p.database), Files.samePath(episode.settings.feed, p.feed),
              Files.samePath(episode.settings.work, p.work), episode.settings.backendSelector == "reviewed-article-speech",
              episode.settings.webdavURL == nil else {
            throw RelayError.setup("The interrupted work does not match this library.")
        }
        let directory = p.work.appendingPathComponent(episodeID)
        guard Files.contains(p.work, directory), Files.contains(storage.temporaryRoot, directory),
              !Files.hasSymlink(directory, below: storage.temporaryRoot) else {
            throw RelayError.setup("Interrupted work storage is invalid; nothing was removed.")
        }
        let destination = episode.settings.audio.appendingPathComponent(episodeID + ".m4a")
        guard episode.stage != .published, !FileManager.default.fileExists(atPath: destination.path) else { return }
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
                throw RelayError.setup("Interrupted work storage is invalid; nothing was removed.")
            }
            try FileManager.default.removeItem(at: directory)
        } else if errno != ENOENT {
            throw RelayError.setup("Unfinished working files are inaccessible. Restore temporary-storage access before discarding them; saved article text is preserved.")
        }
        var reset = episode
        reset.encodedHash = nil; reset.audioHash = nil; reset.info = nil
        reset.synthesisFingerprint = nil; reset.publicationDate = nil; reset.stage = .extracted
        try store.execute("BEGIN IMMEDIATE")
        do {
            try store.execute("DELETE FROM chunks WHERE article_id=?", [episodeID])
            try store.execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: try Files.json(reset), as: UTF8.self), episodeID])
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
    }
}

private final class ObservedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = 0
    func set(_ value: Int) { lock.withLock { chunks = value } }
    var value: Int { lock.withLock { chunks } }
}
