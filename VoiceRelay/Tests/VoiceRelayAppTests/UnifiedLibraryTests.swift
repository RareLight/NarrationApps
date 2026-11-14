import AppKit
import AppPresentation
import Foundation
import SwiftUI
import Testing
import Observation
import Synchronization
@testable import VoiceRelayApp
@testable import VoiceRelayCore

private func source(_ id: String, date: Double? = nil) -> ReadingListEntry {
    ReadingListEntry(id: id, safariID: id, url: URL(string: "https://articles.example/\(id)")!,
        title: "Synthetic \(id)", addedAt: date.map { Date(timeIntervalSinceReferenceDate: $0) })
}

@Test @MainActor func recoveredArticleTitleIsVisibleAndSearchableWithoutChangingSafariMetadata() throws {
    let model = AppModel(preview: true)
    let entry = source("report")
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    model.sourceReview.catalog.setResolvedTitle("How Wetlands Protect Coastal Communities", for: entry.id)
    model.articleSearchQuery = "Wetlands"
    #expect(model.visibleArticleRows.map(\.title) == ["How Wetlands Protect Coastal Communities"])
    #expect(model.sourceReview.catalog.entries.first?.title == entry.title)
    model.queueItems = [] // Finishing/removing queue membership must not revert the displayed title.
    #expect(model.allArticleRows.first?.title == "How Wetlands Protect Coastal Communities")
    let restored = try JSONDecoder().decode(ReadingListCatalog.self, from: Files.json(model.sourceReview.catalog))
    model.sourceReview.catalog = restored
    #expect(model.allArticleRows.first?.title == "How Wetlands Protect Coastal Communities")
}

@Test @MainActor func savedArticleTitlePreviewDoesNotRefetchOrRegenerate() throws {
    let url = URL(string: "https://articles.example/report")!
    let html = "<html><head><title>Original title</title></head><body><article><p>This synthetic article contains enough readable text for a saved preview. Its original wording and identity remain intact when a user corrects its display title before starting audio generation.</p></article></body></html>"
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    let review = try ReviewedSource.prepare(page, chunkLimit: 180)
    let model = ArticlePreviewModel(review: review)
    // A file URL is deliberately invalid for article transport even if this guard regresses.
    model.load(URL(fileURLWithPath: "/synthetic/unavailable"))
    #expect(!model.busy && model.review?.document?.article == review.document?.article)
    #expect(model.error == nil)
}

@Test @MainActor func articleTitleGenerationSettingPersistsAndEditAvailabilityUsesCurrentQueueState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-settings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let domain = "title-settings-\(UUID())", defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let model = AppModel(storage: storage, defaults: defaults)
    #expect(!model.generateMissingTitles)
    model.generateMissingTitles = true
    #expect(AppModel(storage: storage, defaults: defaults).generateMissingTitles)
    let unstarted = SpeechQueueItem(id: "queued", title: "A title", state: .queued)
    model.queueItems = [unstarted]
    #expect(model.canRenameArticle(unstarted))
    var current = unstarted; current.state = .running; current.attempts = 1
    model.queueItems = [current]
    #expect(!model.canRenameArticle(unstarted))
    model.queueItems = []
    #expect(!model.canRenameArticle(unstarted))
}
private func job(_ id: String, source: String? = nil, state: SpeechQueueState = .queued) -> SpeechQueueItem {
    SpeechQueueItem(id: id, title: "Synthetic \(id)", sourceEntryID: source, state: state, sourceHost: "articles.example")
}

@Test @MainActor func librarySearchMatchesVisibleArticleFieldsAndKeepsOrdering() throws {
    let model = AppModel(preview: true)
    let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let one = ReadingListEntry(id: "one", safariID: nil, url: URL(string: "https://www.news.example/private-path")!, title: "Café science", addedAt: date)
    let two = ReadingListEntry(id: "two", safariID: nil, url: URL(string: "https://other.example/two")!, title: "Other story", addedAt: date.addingTimeInterval(86401))
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [one, two], skippedEntries: 0))
    var failed = job("failed", source: "one", state: .failed); failed.lastError = "Synthetic checksum failure"
    model.queueItems = [failed, job("ready", source: "two")]
    model.articleSelection = ["one", "two"]
    model.articleSearchQuery = "CAFE news.example"
    #expect(model.visibleArticleRows.map(\.title) == [one.title])
    #expect(model.selectedArticles.map(\.id) == [one.id])
    model.articleSearchQuery = try #require(ArticleOriginMetadata(host: nil, savedAt: date).savedDateText)
    #expect(model.visibleArticleRows.contains { $0.title == one.title })
    // The rendered punctuation is searchable, not only raw fields.
    model.articleSearchQuery = "(\(try #require(ArticleOriginMetadata(host: nil, savedAt: date).savedDateText)))"
    #expect(model.visibleArticleRows.map(\.title) == [one.title])
    let oneRow = try #require(model.allArticleRows.first { $0.title == one.title })
    model.articleSearchQuery = try #require(ArticleOriginMetadata(host: oneRow.host, savedAt: oneRow.savedAt).displayText())
    #expect(model.visibleArticleRows.map(\.title) == [one.title])
    model.articleSearchQuery = "checksum"
    #expect(model.visibleArticleRows.map(\.title) == [one.title])
    model.articleWebsiteSelection = .site("other.example")
    #expect(model.visibleArticleRows.isEmpty)
    model.articleWebsiteSelection = .all
    model.articleSearchQuery = "ready"
    #expect(model.visibleArticleRows.compactMap { $0.jobs.first?.id } == ["ready"])
    #expect(model.eligibleGenerationCount == 1) // Search does not change processing membership.
    model.articleSearchQuery = "private-path"
    #expect(model.visibleArticleRows.isEmpty) // Hidden URLs are not searchable list text.
    model.articleSearchQuery = " \n "
    #expect(model.visibleArticleRows.map(\.title) == [two.title, one.title])
    #expect(model.queueItems.map(\.id) == ["failed", "ready"])
    _ = ArticlesView(model: model).body
}

@Test @MainActor func audioSearchMatchesOriginSavedDateVerificationAndProgressWithoutChangingRecords() throws {
    let model = AppModel(preview: true)
    var one = Episode(id: "one", title: "Café science", stage: .published,
        settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
    one.originalSourceHost = "news.example"
    // Local midday keeps the displayed Gregorian day identical in every local timezone.
    one.readingListSavedAt = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))
    one.info = AudioInfo(duration: 120, byteLength: 20_000, sampleRate: 24_000, channels: 1, codec: "aac")
    one.localAudioDiscarded = true; one.localCleanupNotice = "Synthetic checksum conflict"
    let two = Episode(id: "two", title: "Second story", stage: .published, settings: one.settings)
    model.savedEpisodes = [one, two]
    model.uploadsSearchText = "CAFE news.example"
    #expect(model.visibleUploads.map(\.id) == ["one"])
    #expect(model.visibleServerAudio.map(\.id) == ["one", "two"])
    model.serverAudioSearchText = try #require(model.savedAudioOrigin(one).savedDateText)
    #expect(model.visibleServerAudio.map(\.id) == ["one"])
    model.serverAudioSearchText = "2026-11-13" // Compact ISO saved date stays searchable.
    #expect(model.visibleServerAudio.map(\.id) == ["one"])
    let audioMeta = try #require(model.savedAudioMeta(one))
    for term in audioMeta.split(separator: " ") where term != "•" {
        model.serverAudioSearchText = String(term) // Duration and file size are searchable.
        #expect(model.visibleServerAudio.map(\.id) == ["one"])
    }
    // The rendered compact line is searchable in both lists, punctuation included.
    model.serverAudioSearchText = "(2026-11-13)"
    #expect(model.visibleServerAudio.map(\.id) == ["one"])
    let originLine = try #require(model.savedAudioOrigin(one).displayText(audioMeta: audioMeta))
    model.serverAudioSearchText = originLine
    #expect(model.visibleServerAudio.map(\.id) == ["one"])
    model.uploadsSearchText = originLine
    #expect(model.visibleUploads.map(\.id) == ["one"])
    model.uploadsSearchText = ""
    model.serverAudioSearchText = "checksum conflict"
    #expect(model.visibleServerAudio.map(\.id) == ["one"])
    model.serverAudioFilter = .waiting
    #expect(model.visibleServerAudio.isEmpty)
    model.serverAudioFilter = .all; model.serverAudioSearchText = "2:00"
    #expect(model.visibleServerAudio.map(\.id) == ["one"])
    model.deliveryBusy = true
    model.uploadProgress["two"] = UploadProgress(episode: two, phase: .transferring, sentBytes: 1000, totalBytes: 2000)
    model.uploadsSearchText = try #require(model.audioState(two).sentBytesText)
    #expect(model.visibleUploads.map(\.id) == ["two"])
    model.uploadsFilter = .attention
    #expect(model.visibleUploads.isEmpty)
    model.uploadsFilter = .all; model.uploadsSearchText = ""; model.serverAudioSearchText = ""
    #expect(model.visibleServerAudio.map(\.id) == ["one", "two"] && model.savedEpisodes.count == 2)
    _ = UploadsView(model: model).body; _ = LibraryView(model: model).body
}

@Test @MainActor func unifiedRowsPreserveNewestAndQueueOrderWithoutHidingJobs() {
    let model = AppModel(preview: true)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("old", date: 1), source("new", date: 3), source("tie", date: 3)], skippedEntries: 0))
    model.queueItems = [job("old-job", source: "old"), job("new-job", source: "new"),
                        job("new-second", source: "new", state: .failed), job("absent", source: "missing")]
    model.queueSavedDates["absent"] = Date(timeIntervalSinceReferenceDate: 2)
    model.pendingAdds = ["tie": "Synthetic tie", "unlisted": "Retained preparation"]
    #expect(model.allArticleRows.map(\.title) == ["Synthetic new", "Synthetic tie", "Synthetic absent", "Synthetic old", "Retained preparation"])
    #expect(model.allArticleRows.first?.jobs.map(\.id) == ["new-job", "new-second"])
    #expect(model.queuedArticleRows.compactMap { $0.jobs.first?.id } == ["old-job", "new-job", "new-second", "absent"])
    #expect(model.queuedArticleRows.suffix(2).compactMap(\.preparationID) == ["tie", "unlisted"])
    #expect(model.queueItems.map(\.id) == ["old-job", "new-job", "new-second", "absent"])
}

@Test @MainActor func unifiedRetainedSourcesDeduplicateButUnrelatedEpisodeIDsStayDistinct() {
    let model = AppModel(preview: true)
    model.queueItems = [job("a", source: "absent"), job("b", source: "absent"), job("c"), job("d")]
    #expect(model.allArticleRows.count == 3)
    #expect(model.allArticleRows.first?.jobs.map(\.id) == ["a", "b"])
    #expect(model.allArticleRows.allSatisfy { $0.retained })
    #expect(model.queuedArticleRows.count == 4)
}

@Test @MainActor func unifiedSelectionDistinguishesSourceAndRetainedIdentities() {
    let model = AppModel(preview: true)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("same")], skippedEntries: 0))
    model.queueItems = [job("same", source: "same"), job("retained")]
    model.unifiedArticleSelection = [.source("same"), .retained(.episode("retained"))]
    #expect(model.articleSelection == ["same"])
    #expect(model.selectedUnifiedQueueIDs == [.episode("same"), .episode("retained")])
    model.queueItems.removeAll { $0.id == "retained" }
    #expect(model.unifiedArticleSelection == [.source("same")])
    #expect(model.queueSelection.isEmpty)
}

@Test @MainActor func unifiedAdmissionOmitsQueueMembershipWithoutHistoryExclusion() {
    let model = AppModel(preview: true)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("new", date: 3), source("queued", date: 2), source("pending", date: 1)], skippedEntries: 0))
    model.articleSelection = ["new", "queued", "pending"]
    model.queueItems = [job("episode", source: "queued")]
    model.pendingAdds["pending"] = "Pending"
    #expect(model.eligibleSelectedArticles.map(\.id) == ["new"])
    model.queueItems = []; model.pendingAdds = [:]
    #expect(model.eligibleSelectedArticles.map(\.id) == ["new", "queued", "pending"])
    #expect(model.selectedUnifiedQueueIDs.isEmpty)
}

@Test @MainActor func unifiedPreparationSelectionTransfersInBothScopes() {
    let model = AppModel(preview: true)
    model.queueSelection = [.preparation("entry")]
    model.retainedArticleSelection = [.preparation("entry")]
    model.articleSelection = ["entry"]
    model.transferPreparationSelection(sourceID: "entry", episodeID: "episode")
    #expect(model.queueSelection == [.episode("episode")])
    #expect(model.retainedArticleSelection == [.episode("episode")])
    #expect(model.articleSelection == ["entry"])
}

private final class UnusedCredentials: DeliveryCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func readPassword(username: String, host: String) throws -> String? { lock.withLock { count += 1 }; return "synthetic" }
    func writePassword(_ password: String, username: String, host: String) throws { lock.withLock { count += 1 } }
    func deletePassword(username: String, host: String) throws { lock.withLock { count += 1 } }
}

@Test @MainActor func publishingReadinessDistinguishesUnknownMissingOffAndFailureWithoutCredentials() {
    let credentials = UnusedCredentials(), model = AppModel(preview: true, credentialStore: credentials)
    #expect(model.publishingReadiness == .needsSetup)
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://public.example/podcast/")
    #expect(model.publishingReadiness == .turnedOff)
    model.deliverySettings.enabled = true
    #expect(model.publishingReadiness == .notChecked)
    model.deliveryPasswordChecked = true
    #expect(model.publishingReadiness == .needsSetup)
    model.deliveryPasswordStored = true
    #expect(model.publishingReadiness == .configured)
    model.deliveryError = "Synthetic permission failure"
    #expect(model.publishingReadiness == .needsAttention)
    #expect(model.publishingSettingsNotice == .needsAttention)
    model.deliverySettings.enabled = false
    #expect(model.publishingReadiness == .turnedOff)
    #expect(credentials.calls == 0)
}

@Test @MainActor func publishingFailureKeepsSettingsRouteWhenUploadsAlsoNeedAttention() {
    let credentials = UnusedCredentials(), model = AppModel(preview: true, credentialStore: credentials)
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://public.example/podcast/")
    model.deliverySettings.enabled = true
    model.deliveryPasswordChecked = true; model.deliveryPasswordStored = true
    var episode = Episode(id: "failed", title: "Synthetic article", stage: .published,
                          settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
    episode.delivery = DeliveryState(status: .failed, remotePath: model.deliverySettings.remoteMediaPath(episode.id))
    episode.delivery?.lastError = "Synthetic verification failure"
    episode.delivery?.destinationURL = model.deliverySettings.feedFolderURL
    model.savedEpisodes = [episode]
    #expect(model.uploadsNeedAttention && model.publishingSettingsNotice == nil)
    model.deliveryError = "Synthetic connection failure"
    #expect(model.publishingSettingsNotice == .needsAttention)
    #expect(model.publishingSettingsNotice?.action == "Review Publishing…")
    _ = WorkspaceReadinessView(model: model).body
    #expect(credentials.calls == 0)
}

@Test @MainActor func workspaceFooterHidesIdleMessagesButPreservesOwnedProgressAndReadiness() {
    let credentials = UnusedCredentials(), model = AppModel(preview: true, credentialStore: credentials)
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://public.example/podcast/")
    model.deliverySettings.enabled = true
    model.deliveryPasswordChecked = true; model.deliveryPasswordStored = true
    #expect(model.publishingReadiness == .configured)
    #expect(model.eligibleGenerationCount == 0 && model.generationDisabledReason != nil)
    for section in WorkspaceSection.allCases {
        model.workspaceSection = section
        for status in ["Audio generated", "Stopped; unfinished article is Ready", "Cancelled; work retained"] {
            model.status = status
            #expect(!model.showsWorkspaceActivity)
        }
    }
    model.processingSpeech = true
    #expect(model.showsWorkspaceActivity)
    model.processingSpeech = false; model.cancelling = true
    #expect(model.showsWorkspaceActivity)
    model.cancelling = false; model.deliveryBusy = true
    #expect(model.showsWorkspaceActivity)
    model.deliveryBusy = false
    #expect(!model.showsWorkspaceActivity)

    // Actionable notices remain independent of the now-hidden idle footer.
    model.deliveryError = "Synthetic permission failure"
    #expect(model.publishingReadiness == .needsAttention)
    #expect(!model.showsWorkspaceActivity)
    _ = WorkspaceReadinessView(model: model).body
    model.deliveryError = nil; model.deliveryPasswordStored = false
    #expect(model.publishingReadiness == .needsSetup)
    _ = WorkspaceReadinessView(model: model).body
    #expect(credentials.calls == 0)
}

@Test @MainActor func unifiedRestoredReviewBlocksAdmissionRemovalAndPublishingControls() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let suite = "voicerelay-ui-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, defaults: defaults)
    model.queueItems = [job("one")]
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("entry")], skippedEntries: 0))
    model.articleSelection = ["entry"]
    // Enqueue and processing hold until configured publishing completes a server check.
    #expect(!model.canGenerateAudio && !model.canAddSelectedArticles && model.canRemoveQueueIDs([.episode("one")]))
    #expect(model.publishingReadiness == .needsSetup)
    try await markPublishingChecked(model, storage: storage)
    #expect(model.canGenerateAudio && model.canAddSelectedArticles && model.canRemoveQueueIDs([.episode("one")]))
    model.libraryReviewRequired = true
    #expect(!model.canGenerateAudio && !model.canAddSelectedArticles && !model.canResetQueue)
    #expect(!model.canRemoveQueueIDs([.episode("one")]) && !model.canUploadNewItems)
    model.addSelectedToQueue(); model.changeQueue("one", remove: true)
    #expect(model.queueItems.count == 1 && model.pendingAdds.isEmpty && !model.queueMutationBusy)
    model.pendingAdds["entry"] = "Preparing entry"
    model.removePreparation("entry")
    #expect(model.pendingAdds["entry"] != nil)
    await model.shutdown()
}

@Test @MainActor func unifiedRowRemovalStaysIndependentOfPendingMetadataAndActiveSpeech() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-ui-controls-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let suite = "voicerelay-ui-controls-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, defaults: defaults)
    try await markPublishingChecked(model, storage: storage)
    model.queueItems = [job("changing"), job("waiting"), job("active", state: .running)]
    model.queueMutationBusy = true; model.mutatingQueueEntries = [.episode("changing")]
    model.queueSelection = [.episode("waiting")]
    #expect(!model.canRemoveQueueIDs([.episode("changing")]))
    #expect(model.canRemoveQueueIDs([.episode("waiting")]))
    #expect(!model.canRemoveUnifiedSelection && model.canGenerateAudio && model.canResetQueue)
    model.running = true; model.processingSpeech = true
    #expect(!model.canRemoveQueueIDs([.episode("active")]))
    #expect(model.canRemoveQueueIDs([.episode("waiting")]) && model.canStopProcessing)
    model.running = false; model.processingSpeech = false; model.queueMutationBusy = false
    await model.shutdown()
}

@Test @MainActor func unifiedRemovalKeepsSourceSnapshotAndUnrelatedQueueSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-ui-remove-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let suite = "voicerelay-ui-remove-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = FixtureCoordinator(), entry = source("entry", date: 1)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let item = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { url in
        FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    })
    let model = AppModel(storage: storage, defaults: defaults)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    model.queueItems = [item]; model.articleSelection = [entry.id]; model.queueSelection = [.episode("unrelated")]
    model.removeUnifiedSelection(); await model.waitForProcessing()
    #expect(model.queueItems.isEmpty && model.articleSelection == [entry.id])
    #expect(model.allArticleRows.count == 1 && model.allArticleRows[0].jobs.isEmpty)
    #expect(model.queueSelection == [.episode("unrelated")])
    #expect(try await coordinator.articlePreviewURL(articleID: item.id, stateRoot: storage.stateRoot) == entry.url)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    await model.shutdown()
}

@Test @MainActor func unifiedNativeControlsAndReadinessConstructInertly() {
    let model = AppModel(preview: true)
    do {
        _ = ArticlesView(model: model).body
        _ = WorkspaceReadinessView(model: model).body
        _ = WorkspaceActivityView(model: model).body
        _ = GenerateAudioControl(model: model).body
    }
    #expect(SettingsSection.delivery.rawValue == "Publishing")
    #expect(WorkspaceSection.allCases == [.articles, .uploads, .savedAudio])
    #expect(!model.running && !model.deliveryBusy && model.pendingAdds.isEmpty)
}

@Test @MainActor func articleOriginLabelsMatchAcrossLibraryScopesAndNeverUseGenerationDate() throws {
    let model = AppModel(preview: true)
    let entry = source("one", date: 100)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    model.queueItems = [job("episode", source: "one")]
    model.queueSavedDates["episode"] = entry.addedAt
    let all = try #require(model.allArticleRows.first), queued = try #require(model.queuedArticleRows.first)
    var episode = Episode(id: "episode", title: entry.title, stage: .published,
        settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
    episode.originalSourceHost = "articles.example"; episode.sourceHost = "archive.ph"
    episode.sourceURL = URL(string: "https://canonical.example/article")
    episode.readingListSavedAt = entry.addedAt; episode.publicationDate = Date(timeIntervalSinceReferenceDate: 200)
    let metadata = model.savedAudioOrigin(episode)
    #expect(metadata == ArticleOriginMetadata(host: all.host, savedAt: all.savedAt))
    #expect(metadata == ArticleOriginMetadata(host: queued.host, savedAt: queued.savedAt))
    #expect(metadata.savedDateText == AppDateFormatting.date(try #require(entry.addedAt)))
    _ = ArticleOriginLine(metadata: metadata).body
    model.savedEpisodes = [episode]; _ = LibraryView(model: model).body
    episode.readingListSavedAt = nil; episode.originalSourceHost = nil
    #expect(model.savedAudioOrigin(episode) == ArticleOriginMetadata(host: "archive.ph", savedAt: nil))
    #expect(model.savedAudioOrigin(episode).savedDateText == nil)
    episode.sourceHost = nil
    #expect(model.savedAudioOrigin(episode).host == "canonical.example")
    episode.sourceURL = nil
    #expect(model.savedAudioOrigin(episode) == ArticleOriginMetadata(host: nil, savedAt: nil))
    _ = ArticleOriginLine(metadata: model.savedAudioOrigin(episode)).body
    model.queueSavedDates["episode"] = Date(timeIntervalSinceReferenceDate: 50)
    #expect(model.queuedArticleRows.first?.savedAt == Date(timeIntervalSinceReferenceDate: 50))
}

@Test @MainActor func uploadsAndServerAudioFiltersAreIndependentAndIncludeVerificationConflicts() throws {
    let model = AppModel(preview: true)
    var settings = DeliverySettings(); settings.enabled = true
    settings.feedFolderURL = URL(string: "https://dav.example/podcast/")
    settings.publicFolderURL = URL(string: "https://public.example/podcast/"); settings.username = "synthetic"
    model.deliverySettings = settings
    let profile = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic"))
    var waiting = Episode(id: "waiting", title: "Waiting", stage: .published, settings: profile)
    waiting.audioHash = "waiting-hash"
    var verified = Episode(id: "verified", title: "Verified", stage: .published, settings: profile)
    verified.audioHash = "verified-hash"
    var conflict = Episode(id: "conflict", title: "Conflict", stage: .published, settings: profile)
    conflict.audioHash = "conflict-hash"; conflict.localCleanupNotice = "Local copy retained."
    var failure = Episode(id: "failed", title: "Failed", stage: .published, settings: profile)
    failure.delivery = DeliveryState(status: .failed, remotePath: try settings.normalized().remoteMediaPath("failed"), lastError: "Server verification failed.")
    failure.delivery?.verificationFailed = true
    model.savedEpisodes = [waiting, verified, conflict, failure]
    model.deliveryPublicationSettingsHash = try settings.publicationHash()
    model.deliveryPublicationAudioHashes = ["waiting": "waiting-hash", "verified": "verified-hash", "conflict": "conflict-hash"]
    model.deliveryPublicationStates = ["waiting": .awaitingUpload, "verified": .published, "conflict": .published]
    #expect(model.uploadItems.map(\.id) == ["waiting", "conflict", "failed"])
    model.uploadsFilter = .verification
    #expect(model.visibleUploads.map(\.id) == ["conflict", "failed"])
    #expect(model.visibleServerAudio.count == 4)
    model.serverAudioFilter = .published
    #expect(model.visibleServerAudio.map(\.id) == ["verified"])
    #expect(model.visibleUploads.map(\.id) == ["conflict", "failed"])
    model.serverAudioFilter = .attention
    #expect(model.visibleServerAudio.map(\.id) == ["conflict", "failed"])
    #expect(model.uploadsNeedAttention && !model.canRetryUploads)
    model.retryUploads(); #expect(!model.deliveryBusy)
    _ = UploadsView(model: model).body; _ = LibraryView(model: model).body
    _ = AudioVerificationIndicator(item: try #require(model.visibleUploads.first)).body
    model.deliveryBusy = true
    model.uploadProgress["failed"] = UploadProgress(episode: failure, phase: .verifyingServer)
    model.uploadsFilter = .active
    #expect(model.visibleUploads.map(\.id) == ["failed"])
    model.deliveryBusy = false
    #expect(model.visibleUploads.isEmpty)
    var retired = waiting; retired.stage = .expired
    retired.delivery = DeliveryState(status: .uploaded, remotePath: "audio/waiting.m4a", lastError: "Remote removal failed.")
    model.savedEpisodes = [retired]
    model.serverAudioFilter = .attention
    #expect(model.visibleServerAudio.map(\.id) == [retired.id] && model.uploadItems.isEmpty)
    model.serverAudioFilter = .removing
    #expect(model.visibleServerAudio.map(\.id) == [retired.id])
}

@Test func websiteFilterUsesFoundationAndKeepsPublicationSubdomainsDistinct() {
    let key = ArticleWebsiteFilter.siteKey
    #expect(key("https://WWW.Example.com:443/story?tracking=1") == "example.com")
    #expect(key("http://example.com/other") == "example.com")
    #expect(key(" www.example.com. ") == "example.com")
    #expect(key("news.example.com") == "news.example.com")
    #expect(key("alice.substack.com") != key("bob.substack.com"))
    #expect(key("https://bücher.example/article") == key("https://xn--bcher-kva.example/other"))
    #expect(key(nil) == nil && key("") == nil && key("https://") == nil)
    #expect(key("https://private:secret@example.com") == nil)
    #expect(key("file:///tmp/local") == nil)
}

@Test @MainActor func websiteFiltersPreserveOrderAndLimitSelectionActionsToVisibleRows() {
    let model = AppModel(preview: true)
    let entries = ["http://www.news.example/a", "https://other.example/b", "https://news.example/c"].enumerated().map { index, url in
        ReadingListEntry(id: String(index), safariID: String(index), url: URL(string: url)!, title: "Synthetic \(index)",
            addedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.articleSelection = ["0", "1", "2"]
    model.articlesWebsiteFilter = .site("news.example")
    #expect(model.visibleArticleRows.compactMap { $0.source?.id } == ["2", "0"])
    #expect(model.selectedArticles.map(\.id) == ["2", "0"])
    #expect(model.articleWebsiteOptions == [.all, .site("news.example"), .site("other.example")])
    #expect(model.articleWebsiteCounts == [.today: 0, .thisWeek: 0, .all: 3, .site("news.example"): 2, .site("other.example"): 1])
    model.queueItems = [SpeechQueueItem(id: "a", title: "A", sourceEntryID: "0", state: .queued, sourceHost: "www.news.example"),
        SpeechQueueItem(id: "b", title: "B", sourceEntryID: "1", state: .failed, sourceHost: "other.example"),
        SpeechQueueItem(id: "unknown", title: "Unknown", sourceEntryID: nil, state: .queued)]
    #expect(model.visibleArticleRows.compactMap(\.source?.id) == ["2", "0"])
    #expect(model.selectedUnifiedQueueIDs == [.episode("a")])
    #expect(model.queueItems.map(\.id) == ["a", "b", "unknown"])
    model.articleWebsiteSelection = .unknown
    #expect(model.visibleArticleRows.map(\.title) == ["Unknown"])
    #expect(model.selectedUnifiedQueueIDs.isEmpty)
    #expect(model.articleSelection == ["0", "1", "2"])
    model.articlesWebsiteFilter = .site("gone.example")
    #expect(model.visibleArticleRows.isEmpty && model.selectedArticles.isEmpty)
    #expect(model.articleWebsiteOptions.contains(.site("gone.example")))
}

@Test @MainActor func appHelpTopicsRouteAsTypedValuesAndConstructWithoutAppWork() throws {
    for topic in AppHelpTopic.allCases {
        let value = try JSONDecoder().decode(AppHelpTopic.self, from: JSONEncoder().encode(topic))
        #expect(value == topic)
        #expect(Set(topic.sections.map(\.id)).count == topic.sections.count)
        _ = AppHelpView(topic: value).body
        _ = SectionHelpHeader(title: "Synthetic help", explanation: "A brief explanation.", helpTopic: value).body
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AppHelpTopic.self, from: Data("\"unknown-topic\"".utf8))
    }
}

@Test @MainActor func websiteOptionsSortByDescendingScopeCountThenAlphabetically() {
    let model = AppModel(preview: true)
    let urls = ["https://z.example/one", "http://www.z.example/two", "https://z.example/three",
        "https://b.example/one", "https://a.example/one", "https://b.example/two", "https://a.example/two",
        "https://c.example/one"]
    let entries = urls.enumerated().map { index, url in
        ReadingListEntry(id: String(index), safariID: String(index), url: URL(string: url)!,
            title: "Synthetic \(index)", addedAt: nil)
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    let articleOrder = model.visibleArticleRows.map(\.id)
    #expect(model.articleWebsiteOptions == [.all, .site("z.example"), .site("a.example"), .site("b.example"), .site("c.example")])
    #expect(model.articleWebsiteCounts[.site("z.example")] == 3)
    model.articlesWebsiteFilter = .site("absent.example")
    #expect(model.articleWebsiteOptions.last == .site("absent.example"))
    #expect(model.visibleArticleRows.isEmpty)
    model.articlesWebsiteFilter = .all
    #expect(model.visibleArticleRows.map(\.id) == articleOrder)

    let hosts: [String?] = [nil, "www.b.example", "z.example", nil, "a.example", "b.example", nil, "b.example"]
    model.queueItems = hosts.enumerated().map { index, host in
        SpeechQueueItem(id: "job-\(index)", title: "Synthetic job \(index)", sourceEntryID: nil,
            state: .queued, sourceHost: host)
    }
    let queueOrder = model.queueItems.map(\.id)
    #expect(model.articleWebsiteCounts[.unknown] == 3)
    model.articleWebsiteSelection = .unknown
    #expect(model.visibleArticleRows.count == 3)
    #expect(model.queueItems.map(\.id) == queueOrder)
    model.queueItems.removeAll { ArticleWebsiteFilter.siteKey($0.sourceHost) == "b.example" }
    model.articleWebsiteSelection = .all
    // All Articles includes the remaining retained jobs as well as source entries.
    #expect(model.articleWebsiteOptions == [.all, .site("z.example"), .site("a.example"), .unknown, .site("b.example"), .site("c.example")])
    #expect(model.articleWebsiteCounts[.all] == 13)
}

@Test func articleDateFiltersUseSavedDatesLocalCalendarAndExclusivePeriodEnd() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    calendar.firstWeekday = 2 // Locale-dependent weeks are supplied by the user's calendar.
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    let day = try #require(calendar.dateInterval(of: .day, for: now))
    let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
    #expect(day.duration == 25 * 3600) // Fall-back day is not a fixed 24-hour lookback.
    func row(_ saved: Date?) -> ArticleLibraryRow {
        ArticleLibraryRow(id: .source("synthetic"), title: "Synthetic", host: "example.com", savedAt: saved,
            source: nil, jobs: [], preparationID: nil, retained: false)
    }
    #expect(ArticleWebsiteFilter.dateOptions == [.today, .thisWeek])
    #expect(ArticleWebsiteFilter.today.includes(row(day.start), now: now, calendar: calendar))
    #expect(!ArticleWebsiteFilter.today.includes(row(day.start.addingTimeInterval(-1)), now: now, calendar: calendar))
    #expect(!ArticleWebsiteFilter.today.includes(row(day.end), now: now, calendar: calendar))
    #expect(ArticleWebsiteFilter.thisWeek.includes(row(week.start), now: now, calendar: calendar))
    #expect(!ArticleWebsiteFilter.thisWeek.includes(row(week.start.addingTimeInterval(-1)), now: now, calendar: calendar))
    #expect(!ArticleWebsiteFilter.thisWeek.includes(row(week.end), now: now, calendar: calendar))
    #expect(!ArticleWebsiteFilter.today.includes(row(nil), now: now, calendar: calendar))
    #expect(!ArticleWebsiteFilter.thisWeek.includes(row(nil), now: now, calendar: calendar))
}

@Test @MainActor func articleDateFiltersIntersectSearchAndKeepQueueWork() {
    let model = AppModel(preview: true), now = Date()
    let entries = [ReadingListEntry(id: "today", safariID: nil, url: URL(string: "https://one.example/a")!,
        title: "Today's article", addedAt: now),
        ReadingListEntry(id: "old", safariID: nil, url: URL(string: "https://two.example/b")!,
            title: "Old article", addedAt: now.addingTimeInterval(-14 * 86400)),
        ReadingListEntry(id: "undated", safariID: nil, url: URL(string: "https://one.example/c")!,
            title: "Undated", addedAt: nil)]
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.articleSelection = Set(entries.map(\.id)); model.articlesWebsiteFilter = .today
    #expect(model.visibleArticleRows.map(\.title) == ["Today's article"])
    #expect(model.selectedArticles.map(\.id) == ["today"])
    #expect(model.articleWebsiteCounts[.today] == 1 && model.articleWebsiteCounts[.thisWeek] == 1)
    #expect(model.articleWebsiteOptions == [.all, .site("one.example"), .site("two.example")])
    model.articlesSearchText = "two.example"
    #expect(model.visibleArticleRows.isEmpty && model.selectedArticles.isEmpty)
    model.queueItems = entries.map { SpeechQueueItem(id: $0.id, title: $0.title, sourceEntryID: $0.id, state: .queued) }
    #expect(model.articleWebsiteSelection == .today && model.visibleArticleRows.isEmpty)
    model.articleSearchQuery = ""
    model.articleWebsiteSelection = .thisWeek
    #expect(model.visibleArticleRows.map(\.title) == ["Today's article"])
    #expect(model.queueItems.count == 3)
}

@Test @MainActor func serverAudioSortsByCapturedSavedDateAcrossReloadsAndSourceRemoval() {
    let model = AppModel(preview: true)
    func episode(_ id: String, saved: Double?) -> Episode {
        var value = Episode(id: id, title: id, stage: .published,
            settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
        value.readingListSavedAt = saved.map { Date(timeIntervalSinceReferenceDate: $0) }
        value.originalSourceHost = "origin.example"
        // Publication order deliberately disagrees with saved-date order.
        value.publicationDate = Date(timeIntervalSinceReferenceDate: id == "old" ? 9999 : 1)
        return value
    }
    let episodes = [episode("undated-z", saved: nil), episode("old", saved: 100),
        episode("tie-z", saved: 200), episode("undated-a", saved: nil), episode("tie-a", saved: 200)]
    let expected = ["tie-a", "tie-z", "old", "undated-a", "undated-z"]
    model.savedEpisodes = episodes
    #expect(model.visibleServerAudio.map(\.id) == expected)
    let entry = source("temporary-source", date: 99999)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [], skippedEntries: 0))
    model.savedEpisodes.reverse() // A different database/event arrival order changes nothing.
    #expect(model.allArticleRows.isEmpty && model.visibleServerAudio.map(\.id) == expected)
    let latest = episode("latest", saved: 300)
    model.recordUploadProgress(UploadProgress(episode: latest, phase: .transferring))
    #expect(model.visibleServerAudio.map(\.id) == ["latest"] + expected)
    model.savedEpisodes.removeAll { $0.id == "tie-a" }
    #expect(model.visibleServerAudio.map(\.id) == ["latest", "tie-z", "old", "undated-a", "undated-z"])
    #expect(model.savedAudioOrigin(episodes[0]).savedDateText == nil) // No generation-date substitute.
}

@Test @MainActor func serverAudioRowAndFooterHeightsStayStableAcrossCleanupUpdates() {
    let model = AppModel(preview: true)
    model.workspaceSection = .savedAudio
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://public.example/podcast/")
    model.deliverySettings.enabled = true
    model.deliveryPasswordChecked = true; model.deliveryPasswordStored = true
    var settings = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic"))
    settings.temporaryAudio = true
    let episode = Episode(id: "sample", title: "Short title", stage: .published, settings: settings)
    var wrapped = episode
    wrapped.title = String(repeating: "Long synthetic episode title ", count: 8)
    var withMetadata = episode
    withMetadata.originalSourceHost = "articles.example"
    withMetadata.readingListSavedAt = .distantPast
    withMetadata.info = AudioInfo(duration: 3600, byteLength: 512, sampleRate: 24000, channels: 1, codec: "aac")

    var originOnly = episode
    originOnly.originalSourceHost = "articles.example"
    originOnly.readingListSavedAt = .distantPast

    for percent in [80, 100, 200] {
        let textSize = AppTextSize(percent: percent)
        func rowHeight(_ episode: Episode) -> CGFloat {
            NSHostingView(rootView: ServerAudioRow(model: model, episode: episode)
                .appTextSizing(textSize).frame(width: 480)).fittingSize.height
        }
        func footerHeight() -> CGFloat {
            NSHostingView(rootView: WorkspaceActivityView(model: model, reservesSpace: true)
                .appFont(.body).appTextSizing(textSize).frame(width: 480)).fittingSize.height
        }
        func readinessHeight() -> CGFloat {
            NSHostingView(rootView: WorkspaceReadinessView(model: model)
                .appFont(.body).appTextSizing(textSize).frame(width: 480)).fittingSize.height
        }
        let normalHeight = rowHeight(episode)
        #expect(normalHeight > 0)
        #expect(rowHeight(wrapped) > normalHeight)
        #expect(rowHeight(originOnly) > normalHeight)
        // Audio info joins the origin line instead of adding a row.
        #expect(abs(rowHeight(withMetadata) - rowHeight(originOnly)) < 0.5,
            "audio metadata added a row at \(percent)%")
        for original in [episode, wrapped, originOnly, withMetadata] {
            let height = rowHeight(original)
            var pending = original
            pending.stage = .expired
            var failed = pending
            failed.delivery = DeliveryState(status: .failed, remotePath: "", lastError: "Synthetic removal error.")
            var discarded = original
            discarded.localAudioDiscarded = true
            var conflict = discarded
            conflict.localCleanupNotice = String(repeating: "Synthetic verification details. ", count: 12)
            for (status, updated) in [("pending", pending), ("failed", failed), ("discarded", discarded), ("conflict", conflict)] {
                #expect(abs(rowHeight(updated) - height) < 0.5, "\(status) row changed height at \(percent)%")
            }
            model.deliveryBusy = true
            for phase in [UploadPhase.transferring, .verifyingServer, .publishing, .published] {
                model.uploadProgress[original.id] = UploadProgress(episode: original, phase: phase)
                #expect(model.audioState(original).phase == phase)
                #expect(abs(rowHeight(original) - height) < 0.5, "\(phase) row changed height at \(percent)%")
            }
            model.uploadProgress = [:]
            model.deliveryBusy = false
        }
        let idleHeight = footerHeight()
        let idleReadinessHeight = readinessHeight()
        #expect(idleHeight > 0)
        model.audioMutationBusy = true
        #expect(abs(footerHeight() - idleHeight) < 0.5)
        model.audioMutationBusy = false
        model.deliveryBusy = true
        model.deliveryPreflightBusy = true
        #expect(model.publishingReadiness == .checking)
        #expect(abs(readinessHeight() - idleReadinessHeight) < 0.5)
        #expect(abs(footerHeight() - idleHeight) < 0.5)
        model.deliveryPreflightBusy = false
        #expect(abs(footerHeight() - idleHeight) < 0.5)
        model.processingSpeech = true
        #expect(abs(footerHeight() - idleHeight) < 0.5)
        model.deliveryBusy = false
        model.processingSpeech = false
        #expect(abs(footerHeight() - idleHeight) < 0.5)
    }
}

@Test @MainActor func compactOriginMetadataUsesLocalISODatesAndOptionalAudio() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    // Frozen timestamps keep day boundaries and formatting deterministic.
    let overnight = Date(timeIntervalSince1970: 1_794_529_800) // 2026-11-13T00:30:00Z
    #expect(AppDateFormatting.date(overnight, timeZone: utc) == "2026-11-13")
    #expect(AppDateFormatting.date(overnight, timeZone: losAngeles) == "2026-11-12")
    // Calendar year (not week-year) and zero-padded fields, including leap day.
    #expect(AppDateFormatting.date(Date(timeIntervalSince1970: 1_609_461_000), timeZone: utc) == "2021-01-01")
    #expect(AppDateFormatting.date(Date(timeIntervalSince1970: 1_709_208_000), timeZone: utc) == "2024-02-29")
    let published = AppDateFormatting.dateTime(overnight, timeZone: utc)
    #expect(published.hasPrefix("2026-11-13 ") && published.count > "2026-11-13 ".count)

    // Local midday keeps the rendered Gregorian day identical in every local timezone.
    let midday = try #require(Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12)))
    let dated = ArticleOriginMetadata(host: nil, savedAt: midday)
    #expect(dated.savedDateText == "2026-11-13")
    #expect(dated.displayText() == "(2026-11-13)")
    let hosted = ArticleOriginMetadata(host: "website.com", savedAt: midday)
    #expect(hosted.displayText() == "website.com (2026-11-13)")
    #expect(hosted.displayText(audioMeta: "4:32 • 20 KB") == "website.com (2026-11-13): 4:32 • 20 KB")
    #expect(hosted.displayText(audioMeta: "") == "website.com (2026-11-13)")
    #expect(ArticleOriginMetadata(host: "website.com", savedAt: nil).displayText() == "website.com")
    // Audio metadata alone has no leading separator; no fields means no line at all.
    #expect(ArticleOriginMetadata(host: nil, savedAt: nil).displayText(audioMeta: "4:32 • 20 KB") == "4:32 • 20 KB")
    #expect(ArticleOriginMetadata(host: nil, savedAt: nil).displayText() == nil)
    #expect(ArticleOriginMetadata(host: nil, savedAt: nil).displayText(audioMeta: "") == nil)
    #expect(ArticleOriginMetadata(host: "website.com", savedAt: nil)
        .displayText(audioMeta: "4:32 • 20 KB") == "website.com: 4:32 • 20 KB")
    #expect(dated.displayText(audioMeta: "4:32 • 20 KB") == "(2026-11-13): 4:32 • 20 KB")
    _ = ArticleOriginLine(metadata: hosted, audioMeta: "4:32 • 20 KB").body
    _ = ArticleOriginLine(metadata: ArticleOriginMetadata(host: nil, savedAt: nil)).body
}

@Test @MainActor func updateLabelUsesTodayClockISODateOrUnknown() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    // Frozen now/date pairs keep calendar-day comparison deterministic.
    let now = Date(timeIntervalSince1970: 1_794_596_700) // 2026-11-13T19:05:00Z
    let morning = Date(timeIntervalSince1970: 1_794_560_700) // 2026-11-13T09:05:00Z
    #expect(AppDateFormatting.updateLabel(for: morning, now: now, timeZone: utc) == "Updated: 09:05")
    // Calendar days, not elapsed hours: late evening is still a different day.
    let latePrior = Date(timeIntervalSince1970: 1_794_527_940) // 2026-11-12T23:59:00Z
    #expect(AppDateFormatting.updateLabel(for: latePrior, now: now, timeZone: utc) == "Updated: 2026-11-12")
    // The same instant is "today" in UTC but yesterday in Los Angeles.
    let overnight = Date(timeIntervalSince1970: 1_794_529_800) // 2026-11-13T00:30:00Z = Nov 12 16:30 PST
    let utcNow = Date(timeIntervalSince1970: 1_794_588_600) // 2026-11-13T16:50:00Z = Nov 13 08:50 PST
    #expect(AppDateFormatting.updateLabel(for: overnight, now: utcNow, timeZone: utc) == "Updated: 00:30")
    #expect(AppDateFormatting.updateLabel(for: overnight, now: utcNow, timeZone: losAngeles) == "Updated: 2026-11-12")
    // Leap day and year boundaries keep the Gregorian ISO form.
    let leap = Date(timeIntervalSince1970: 1_709_208_000) // 2024-02-29T12:00:00Z
    #expect(AppDateFormatting.updateLabel(for: leap, now: now, timeZone: utc) == "Updated: 2024-02-29")
    #expect(AppDateFormatting.updateLabel(for: nil, now: now, timeZone: utc) == "Updated: Unknown")
    // A far-future date on another calendar day renders as a date, never a clock time.
    let future = Date(timeIntervalSince1970: 1_794_596_700 + 86_400 * 40)
    #expect(AppDateFormatting.updateLabel(for: future, now: now, timeZone: utc) == "Updated: 2026-12-23")
}

@Test @MainActor func libraryRowSymbolsAndActionsShareUniformGeometryAcrossTextSizes() {
    let symbols = ["clock", "checkmark.icloud", "exclamationmark.triangle.fill", "xmark", "arrow.clockwise"]
    for percent in [80, 100, 200] {
        for dynamic in [DynamicTypeSize.large, .accessibility3] {
            let textSize = AppTextSize(percent: percent)
            let scale = AppTypography.scale(size: textSize, dynamic: dynamic)
            func fitting(_ view: some View) -> CGSize {
                NSHostingView(rootView: view
                    .environment(\.appTextSize, textSize).environment(\.dynamicTypeSize, dynamic)).fittingSize
            }
            // Different glyphs must occupy identical slots.
            for name in symbols {
                let size = fitting(LibraryRowSymbol(systemName: name))
                #expect(abs(size.width - 20 * scale) < 0.5 && abs(size.height - 20 * scale) < 0.5,
                    "\(name) slot \(size) diverged at \(percent)%/\(dynamic)")
            }
            let pair = fitting(LibraryRowActions {
                LibraryRowSymbol(systemName: "clock")
                LibraryRowSymbol(systemName: "xmark")
            })
            // fittingSize rounds fractional ideal widths up to integral points.
            #expect(abs(pair.width - 46 * scale) < 1 && abs(pair.height - 20 * scale) < 0.5,
                "row action spacing \(pair) diverged at \(percent)%/\(dynamic)")
        }
    }
}

@Test @MainActor func articleRowFillsNativeCellHeightForCenteredActions() {
    let entry = ReadingListEntry(id: "row", safariID: nil,
        url: URL(string: "https://synthetic.example/row")!, title: "Row", addedAt: nil)
    let savedAt = Date(timeIntervalSince1970: 1_794_500_000)
    for title in ["Short row", "A much longer article title that wraps onto a second line inside the row"] {
        for percent in [80, 100, 200] {
            for dynamic in [DynamicTypeSize.large, .accessibility3] {
                let textSize = AppTextSize(percent: percent)
                let scale = AppTypography.scale(size: textSize, dynamic: dynamic)
                let row = ArticleLibraryRow(id: .source(entry.id), title: title,
                    host: "synthetic.example", savedAt: savedAt, source: entry, jobs: [],
                    preparationID: nil, retained: false, narrationComplete: true)
                let view = ArticleLibraryRowView(model: AppModel(preview: true), row: row)
                    .environment(\.appTextSize, textSize).environment(\.dynamicTypeSize, dynamic)
                let intrinsic = NSHostingView(rootView: view.frame(width: 480)).fittingSize.height
                // A native List cell proposes more than the intrinsic height; the
                // row must consume it so title and actions center vertically.
                let proposed = intrinsic + 40 * scale
                let filled = NSHostingController(rootView: view)
                    .sizeThatFits(in: CGSize(width: 480, height: proposed))
                #expect(abs(filled.height - proposed) <= 1,
                    "row ignored proposed cell height \(filled) vs \(proposed) at \(percent)%/\(dynamic)")
            }
        }
    }
}

@Test @MainActor func audioSearchAndFiltersTrackChangingRecordsWithoutSourceInventoryOrStaleMetadata() throws {
    let model = AppModel(preview: true)
    let savedAt = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
    var original = Episode(id: "episode", title: "Original title", stage: .published,
        settings: PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")))
    original.readingListSavedAt = savedAt; original.originalSourceHost = "origin.example"
    original.originalSourceIdentity = "synthetic-identity"
    model.savedEpisodes = [original]
    model.serverAudioSearchText = "origin.example " + (try #require(model.savedAudioOrigin(original).savedDateText))
    #expect(model.sourceReview.catalog.entries.isEmpty && model.visibleServerAudio.map(\.id) == [original.id])
    var stale = original
    stale.readingListSavedAt = nil; stale.originalSourceHost = nil; stale.originalSourceIdentity = nil
    stale.title = "Updated title"; stale.sourceHost = "redirect.example"
    model.deliveryBusy = true
    model.recordUploadProgress(UploadProgress(episode: stale, phase: .verificationFailed))
    #expect(model.visibleServerAudio.map(\.id) == [original.id])
    let updated = try #require(model.savedEpisodes.first)
    #expect(updated.readingListSavedAt == savedAt && updated.originalSourceHost == "origin.example")
    #expect(updated.originalSourceIdentity == original.originalSourceIdentity)
    model.serverAudioFilter = .attention; model.uploadsFilter = .attention
    model.serverAudioSearchText = "Updated verification failed"
    model.uploadsSearchText = "Updated origin.example"
    #expect(model.visibleServerAudio.map(\.id) == [original.id] && model.visibleUploads.map(\.id) == [original.id])
    model.serverAudioSearchText = "Original"
    #expect(model.visibleServerAudio.isEmpty) // Replaced title is no longer indexed.
    model.serverAudioSearchText = "Updated"
    model.savedEpisodes.removeAll() // A stale progress record cannot keep a deleted row searchable.
    #expect(model.visibleServerAudio.isEmpty && model.visibleUploads.isEmpty)
    #expect(model.serverAudioSearchText == "Updated" && model.serverAudioFilter == .attention)
    var replacement = original
    replacement.title = "Updated replacement"; replacement.localAudioDiscarded = true
    replacement.localCleanupNotice = "Synthetic conflict"
    model.deliveryBusy = false
    model.savedEpisodes = [replacement]
    #expect(model.visibleServerAudio.map(\.id) == [original.id] && model.visibleUploads.map(\.id) == [original.id])
    #expect(model.serverAudioFilter == .attention && model.uploadsFilter == .attention)
}

@Test @MainActor func articleSelectionUpdatesActionsWithoutInvalidatingContentProjection() {
    let model = AppModel(preview: true)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("one"), source("two")], skippedEntries: 0))
    do {
        model.queueItems = [job("one-job", source: "one"), job("two-job", source: "two")]
        let contentChanged = Synchronization.Mutex(false)
        withObservationTracking {
            _ = ArticlesView(model: model).body
        } onChange: {
            contentChanged.withLock { $0 = true }
        }
        let rows = model.unfilteredArticleRows
        let projection = ArticleListProjection(rows: rows, visibleRows: model.visibleArticleRows(in: rows))
        let actionsChanged = Synchronization.Mutex(false)
        withObservationTracking {
            _ = ArticleSelectionList(model: model, projection: projection).body
        } onChange: {
            actionsChanged.withLock { $0 = true }
        }
        model.unifiedArticleSelection = [rows[0].id]
        model.unifiedArticleSelection = [rows[1].id]
        #expect(!contentChanged.withLock { $0 })
        #expect(actionsChanged.withLock { $0 })
        // Data changes still rebuild the parent; there is no long-lived index.
        model.queueItems.append(job("late"))
        #expect(contentChanged.withLock { $0 })
    }
}

@Test @MainActor func articleProjectionSelectionRespectsFiltersOrderAndChangingContent() {
    let model = AppModel(preview: true)
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("old", date: 1), source("new", date: 3)], skippedEntries: 0))
    model.queueItems = [job("retained")]
    model.unifiedArticleSelection = [.source("old"), .source("new"), .source("missing"), .retained(.episode("retained"))]
    func projection() -> ArticleListProjection {
        let rows = model.unfilteredArticleRows
        return ArticleListProjection(rows: rows, visibleRows: model.visibleArticleRows(in: rows))
    }
    #expect(projection().selectedRows(model.articleListSelection).map(\.title) == ["Synthetic new", "Synthetic old", "Synthetic retained"])
    model.articleSearchQuery = "old"
    #expect(projection().selectedRows(model.articleListSelection).map(\.title) == ["Synthetic old"])
    #expect(model.articleSelection == ["old", "new", "missing"]) // Hidden selections stay scope-local.
    model.articleSearchQuery = ""
    model.sourceReview.catalog = ReadingListCatalog()
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: [source("new", date: 3), source("later", date: 4)], skippedEntries: 0))
    model.queueItems = []
    let updated = projection()
    #expect(updated.selectedRows(model.articleListSelection).map(\.title) == ["Synthetic new"])
    #expect(model.articleListSelection.intersection(updated.rowIDs) == [.source("new")])
    #expect(updated.visibleRows.map(\.title) == ["Synthetic later", "Synthetic new"])
}

@Test @MainActor func articleAttentionShowsAllActionableRowsAndRestoresThePreviousSearch() {
    let model = AppModel(preview: true)
    let entries = [source("ready", date: 5), source("preparation", date: 4), source("failed", date: 3), source("waiting", date: 2)]
    model.sourceReview.catalog.reconcile(.init(entries: entries, skippedEntries: 0))
    model.articlePreparationFailures["preparation"] = "Source could not be read."
    model.pendingAdds["waiting"] = "Preparing"
    let failed = job("broken", source: "failed", state: .failed)
    let paused = job("paused", source: "failed", state: .paused)
    let interrupted = job("interrupted", state: .running)
    model.queueItems = [job("ready-job", source: "ready"), failed, paused, interrupted]
    model.articleWebsiteSelection = .site("articles.example")
    model.articleSearchQuery = "ready"
    model.unifiedArticleSelection = [.source("ready"), .source("failed")]
    #expect(model.visibleArticleRows.map(\.id) == [.source("ready")])
    #expect(model.articlesNeedingAttention(in: model.allArticleRows).map(\.id) == [
        .source("preparation"), .source("failed"), .retained(.episode("interrupted"))
    ])

    model.showArticlesNeedingAttention()
    #expect(model.visibleArticleRows.count == 3)
    #expect(model.selectedUnifiedQueueIDs == [.episode("broken"), .episode("paused")])
    model.articleSearchQuery = "could not be read"
    #expect(model.visibleArticleRows.map(\.id) == [.source("preparation")])
    model.articlePreparationFailures["preparation"] = nil
    #expect(model.visibleArticleRows.isEmpty)
    model.articleSearchQuery = ""
    model.processingSpeech = true
    #expect(model.visibleArticleRows.map(\.id) == [.source("failed")])
    model.queueItems.removeAll { $0.id == failed.id || $0.id == paused.id }
    #expect(model.visibleArticleRows.isEmpty && model.articlesNeedAttentionOnly)
    model.articlesNeedAttentionOnly = false
    #expect(model.articleSearchQuery == "ready" && model.articleWebsiteSelection == .site("articles.example"))
    #expect(model.visibleArticleRows.map(\.id) == [.source("ready")])
    #expect(model.queueItems.map(\.id) == ["ready-job", "interrupted"])
}
