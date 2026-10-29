import SwiftUI
import AppPresentation
import PronunciationUI
import NarrationUI
import ProcessingPipeline
import AppKit
import UniformTypeIdentifiers
import LibroCore
import NarrationCore
import NativeSpeech
import Darwin
import AVFoundation
import AudioOutput
import OSLog
@preconcurrency import UserNotifications

@MainActor
@Observable
final class IntakeModel {
    static let shared = IntakeModel()
    var documents: [InputDocument] = []
    var selection = Set<UUID>()
    var names: [UUID: String] = [:]
    var states: [UUID: String] = [:]
    var output: DirectorySelection?
    var workspace: DirectorySelection?
    var status = "Add documents or drop files and folders here."
    var planningError: String?
    var planned: [PlannedDocument] = []
    var scanCount = 0
    private var workBusy = false
    var busy: Bool {
        get { workBusy || droppedFiles.hasOwnedWork }
        set { workBusy = newValue }
    }
    var settings = SpeechSettingsPreference().load() {
        didSet {
            SpeechSettingsPreference().save(settings)
            if oldValue != settings { pronunciationPreview.stop(); voiceSamplePlayer.stop() }
            if oldValue.model != settings.model || oldValue.voice != settings.voice { refreshReadiness() }
        }
    }
    var outputFormat = OutputFormatPreference().load() {
        didSet {
            OutputFormatPreference().save(outputFormat)
            names = names.mapValues { outputFormat.replacingExtension($0) }
            replan()
        }
    }
    var narrationOptions = UserDefaults.standard.data(forKey: "LibroNarrationOptions").flatMap { try? JSONDecoder().decode(NarrationOptions.self, from: $0) } ?? NarrationOptions() {
        didSet { if let data = try? JSONEncoder().encode(narrationOptions) { UserDefaults.standard.set(data, forKey: "LibroNarrationOptions") } }
    }
    private var coverTask: Task<Void, Never>?
    var hasCoverWork: Bool { coverTask != nil }
    func stopCoverWork() async { coverTask?.cancel(); await coverTask?.value }
    var coverDigests = DocumentCoverPreferences().load() {
        didSet { DocumentCoverPreferences().save(coverDigests) }
    }
    var automaticCoverExclusions = DocumentCoverPreferences().loadAutomaticExclusions() {
        didSet { DocumentCoverPreferences().saveAutomaticExclusions(automaticCoverExclusions) }
    }
    var coverScanProgress: String?
    let coverStore = CoverArtworkStore.application("Libro")
    var selectedCoverDigest: String? {
        guard let document = selectedDocument else { return nil }
        return coverDigests[DocumentCoverPreferences.key(document.source)]
    }
    var selectedCoverURL: URL? { selectedCoverDigest.flatMap { try? coverStore.url(for: $0) } }
    var selectionHasCover: Bool { documents.contains { selection.contains($0.id) && coverDigests[DocumentCoverPreferences.key($0.source)] != nil } }
    func chooseCover(_ url: URL) {
        guard !busy, !isGenerating else { return }
        let sources = documents.filter { selection.contains($0.id) }.map(\.source)
        guard !sources.isEmpty else { return }
        busy = true
        let store = coverStore
        coverTask = Task {
            defer { coverTask = nil; busy = scanner != nil || reader != nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try store.save(CoverArtwork.read(url))
                }
                let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                for source in sources { coverDigests[DocumentCoverPreferences.key(source)] = digest }
                automaticCoverExclusions.subtract(sources.map(DocumentCoverPreferences.key))
                replan()
                status = "Cover selected for \(sources.count) document(s)."
            } catch { planningError = error.localizedDescription }
        }
    }
    func useBookCover(_ document: InputDocument) {
        guard !busy, !isGenerating else { return }
        busy = true
        let store = coverStore
        coverTask = Task {
            defer { coverTask = nil; busy = scanner != nil || reader != nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let bytes = try DocumentReader.bookCover(document)
                    guard let bytes else { throw NarrationError.invalidInput("No usable cover was found on this document's cover or first page. Choose an image instead.") }
                    return try store.save(CoverArtwork(data: bytes))
                }
                let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                coverDigests[DocumentCoverPreferences.key(document.source)] = digest
                automaticCoverExclusions.remove(DocumentCoverPreferences.key(document.source))
                replan()
            } catch { planningError = error.localizedDescription }
        }
    }
    func cleanCoverAssets() {
        let store = coverStore, keeping = Set(coverDigests.values)
        busy = true
        coverTask = Task {
            defer { coverTask = nil; busy = scanner != nil || reader != nil }
            do {
                let work = Task.detached(priority: .utility) { try store.removeUnreferenced(keeping: keeping) }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } catch is CancellationError { }
            catch { status = "Cover removed. Some unused cover files could not be cleaned up." }
        }
    }
    func removeCover() {
        guard !busy, !isGenerating else { return }
        let keys = Set(documents.filter { selection.contains($0.id) }.map { DocumentCoverPreferences.key($0.source) })
        automaticCoverExclusions.formUnion(keys)
        coverDigests = coverDigests.filter { !keys.contains($0.key) }
        cleanCoverAssets()
        replan()
    }
    var settingsTab = SettingsTab.general
    var readiness = "Checking prepared model assets…"
    var assetsReady = false
    var checkingAssets = false
    var isPreparingModel = false
    var preparationIsCheck = false
    var setupResult: SpeechSetupStatus = .notChecked
    var setupVerificationFailed = false
    var speechSetupStatus: SpeechSetupStatus { setupResult == .notChecked && !assetsReady ? .notInstalled : setupResult }
    var pronunciationUnavailableReason: String? {
        guard pronunciationConfiguration == nil else { return nil }
        if isPreparingModel || isGenerating || hasOwnedProbe { return NarrationSettingsHelp.previewBusy }
        if setupVerificationFailed { return NarrationSettingsHelp.previewCheckNeeded }
        return NarrationSettingsHelp.previewModelMissing
    }
    var preparationStatus = ""
    var preparationProgress: ModelPreparationProgress?
    var voices = [SpeechSettings.defaultKokoroVoice]
    let voiceSamplePlayer = AudioPreviewPlayer()
    let pronunciationPreview = PronunciationPreview()
    var pronunciationConfiguration: PronunciationPreviewConfiguration? {
        guard assetsReady, !modelStorage.isBusy, !setupVerificationFailed, !isGenerating, !isPreparingModel, !hasOwnedProbe, let root = workspace?.url else { return nil }
        return .init(worker: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker"), workspace: root, settings: settings, priority: .interactive)
    }
    private var onboarding = SpeechSetupOnboarding()
    var needsSpeechSetup: Bool { onboarding.needsSetup }
    func claimSpeechSetup() -> Bool { onboarding.claimPresentation() }
    var describeImages = UserDefaults.standard.object(forKey: "LibroDescribeImages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(describeImages, forKey: "LibroDescribeImages") }
    }
    var activeBatch: BatchRequest?
    var queueControl: BatchQueueControl?
    var queueState: BatchQueueState?
    var batchOrder: [UUID] = []
    let dragSession = UUID()
    var currentJob: UUID? { queueState?.current }
    var pauseRequested: Bool { queueState?.pauseRequested == true }
    var isStopping: Bool { isGenerating && generationTask?.isCancelled == true }
    var activityProgress: BatchActivityProgress?
    var speechProgress: SpeechProgress?
    var generationStatus = ""
    var batchSummary: BatchSummary?
    var notificationSummary: String?
    var notificationStatus: String?
    var importSummary: String?
    var probeStatus = ""
    var outcomes: [UUID: DocumentOutcome] = [:]
    var retryQueued = Set<UUID>()
    var skippedExisting = Set<UUID>()
    var playingDocument: UUID?
    var reopenWindow: (() -> Void)?
    var isGenerating: Bool { activeBatch != nil }
    var activeIDs: Set<UUID> { Set(activeBatch?.documents.map(\.id) ?? []) }
    var candidates: [InputDocument] { documents.filter { !activeIDs.contains($0.id) && !skippedExisting.contains($0.id) && (outcomes[$0.id] == nil || retryQueued.contains($0.id)) } }
    var displayedDocuments: [InputDocument] {
        let active = Dictionary(uniqueKeysWithValues: (activeBatch?.documents.map(\.input) ?? []).map { ($0.id, $0) })
        return batchOrder.compactMap { active[$0] } + documents.filter { !activeIDs.contains($0.id) }
    }
    var hasFinished: Bool { !outcomes.isEmpty || !skippedExisting.isEmpty }
    var selectedDocument: InputDocument? { selection.count == 1 ? displayedDocuments.first { selection.contains($0.id) } : nil }
    var hasSelectedAudio: Bool { selectedDocument.map { outcomes[$0.id]?.state == .published } ?? false }
    var canQueueSelectedAgain: Bool { selectedDocument.map { !busy && !activeIDs.contains($0.id) && !retryQueued.contains($0.id) && (outcomes[$0.id] != nil || skippedExisting.contains($0.id)) } ?? false }
    var generationBlocker: GenerationBlocker? {
        .evaluate(isGenerating: isGenerating, isPreparing: isPreparingModel, busy: busy || debugToolsBusy || modelStorage.isBusy, planning: planning,
                  workspaceAvailable: workspace?.url != nil, outputAvailable: output?.url != nil,
                  checkingAssets: checkingAssets, assetsReady: assetsReady && !setupVerificationFailed, queuedCount: candidates.count,
                  plannedCount: planned.count, hasPlanningError: planningError != nil)
    }
    var canGenerate: Bool { generationBlocker == nil }
    var speechSetupDisabledReason: String? {
        if modelStorage.isBusy { return "Deleting a model." }
        if isGenerating { return "Wait for audio generation to finish before checking or installing a speech model." }
        if isPreparingModel { return "Speech setup is in progress." }
        if checkingAssets { return "Checking local model files." }
        if busy || hasOwnedProbe { return "Wait for the current document or diagnostic operation to finish." }
        if debugToolsBusy { return "Wait for the debug log action to finish." }
        return nil
    }
    var canManageSpeechSetup: Bool { speechSetupDisabledReason == nil }
    let modelStorage = ModelStorageMaintenance()
    var modelStorageRevision = 0
    var canPrepareModel: Bool { workspace?.url != nil && canManageSpeechSetup }
    var cancellable: Bool { hasCoverWork || pronunciationPreview.hasOwnedWork || droppedFiles.hasOwnedWork || scanner != nil || reader != nil || hasOwnedProbe || isGenerating || isPreparingModel }
    var inputCancelLabel: String { droppedFiles.hasOwnedWork || scanner != nil ? "Cancel Import" : (reader != nil ? "Cancel Analysis" : "Cancel Check") }
    var hasOwnedProbe: Bool { probeProcess != nil }
    var activityStatus: String { scanner != nil ? (coverScanProgress ?? "Scanning inputs… \(scanCount) entries checked.") : status }
    var planning: Bool { planner != nil }
    var preview: Preview?
    var issues: [IntakeIssue] = []
    var dropError: String?
    var debugLogging = UserDefaults.standard.bool(forKey: "LibroDebugLogging") {
        didSet { UserDefaults.standard.set(debugLogging, forKey: "LibroDebugLogging") }
    }
    var debugLogURL: URL?
    var debugLogStatus: String?
    var debugToolsBusy = false
    var canManageDebugLog: Bool { workspace?.url != nil && !isGenerating && !isPreparingModel && !hasOwnedProbe && !debugToolsBusy }
    struct FailureDetails: Identifiable {
        let id: UUID
        let name: String
        let message: String
    }
    var failureDetails: FailureDetails?
    private let preferences = DirectoryPreferences()
    private var roots: [URL] = []
    private var removed = Set<String>()
    private var scopes: [String: DirectoryAccess] = [:]
    let droppedFiles = FileDropImport()
    private var scanner: Task<(intake: IntakeResult, covers: [String: String]), Error>?
    private var reader: Task<Void, Error>?
    private var previewOperation: UUID?
    private var planner: Task<[PlannedDocument], Error>?
    private var planOperation = UUID()
    private var operation = UUID()
    private var probeProcess: Process?
    private var probeCancelled = false
    private let coordinator: QueueCoordinator
    private var generationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var readinessTask: Task<(String, [String]), Error>?
    private var preparationTask: Task<Void, Never>?
    private var preparationOperation = UUID()
    private var preparationScopes: [DirectoryAccess] = []
    private var readinessOperation = UUID()
    private var batchScopes: [DirectoryAccess] = []
    private var outputScopes: [UUID: DirectoryAccess] = [:]
    private var savedNames: [UUID: String] = [:]
    private var readinessScopes: [DirectoryAccess] = []
    private var activity: NSObjectProtocol?
    private var completionLedger = CompletionNoticeLedger()
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "org.librotts.Libro", category: "Batch")

    private init() {
        coordinator = QueueCoordinator(configuration: WorkerConfiguration(executable:
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker"), inferencePriority: .interactive, pronunciationStore: .init()))
        voices = [settings.voice]
        output = preferences.load(.output)
        let oldDefault = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Libro/SpeechRuntime")
        workspace = preferences.loadModelStorage(defaultRoot: NativeModelStorage.defaultRoot, previousDefault: oldDefault)
        if let root = workspace?.url { debugLogURL = DebugLog.existingURL(workspace: root) }
        refreshReadiness()
    }

    func openInputs(foldersOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !foldersOnly
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = foldersOnly ? [.folder] : DocumentKind.contentTypes + [.folder]
        panel.prompt = "Add"
        panel.begin { [weak self] result in
            if result == .OK { self?.add(panel.urls) }
        }
    }

    func browse(_ role: DirectoryRole) {
        guard role != .workspace || canManageSpeechSetup else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = role == .output ? "Choose where Libro saves audio." : "Choose a model storage folder."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                if role == .workspace { try NativeModelStorage.prepareRoot(url) }
                let selected = try self.preferences.select(url, role: role)
                if role == .output { self.output = selected } else {
                    if url.resolvingSymlinksInPath().path == NativeModelStorage.defaultRoot.path { self.preferences.clear(.workspace) }
                    self.workspace = selected
                    self.debugLogURL = DebugLog.existingURL(workspace: url)
                    self.debugLogStatus = nil
                }
                self.replan()
                if role == .workspace { self.refreshReadiness() }
            } catch { self.status = error.localizedDescription }
        }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        droppedFiles.cancel()
        let previousScanner = scanner
        let previousReader = reader
        previewOperation = nil; preview = nil
        scanner?.cancel(); reader?.cancel()
        scanner = nil; reader = nil
        for url in urls {
            scopes[url.path] = DirectoryAccess(url)
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            removed = removed.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        roots += urls
        let selection = roots
        let excluded = output?.url
        let token = UUID(); operation = token
        busy = true; scanCount = 0; coverScanProgress = nil; status = "Scanning inputs…"
        let recipient = self
        let references = coverDigests, exclusions = automaticCoverExclusions, store = coverStore
        let removedPaths = removed
        let previousCoverWork = coverTask
        let task = IntakeScanTask.start(replacing: previousScanner, after: previousReader, coverWork: previousCoverWork) {
            let access = selection.map { DirectoryAccess($0) }
            defer { withExtendedLifetime(access) {} }
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Discovering Libro documents")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let result = try InputCollector.collect(selection, excludingOutput: excluded) { count in
                Task { @MainActor in
                    guard recipient.operation == token else { return }
                    recipient.scanCount = count
                }
            }
            let covers = try DocumentCoverPreferences.automaticCovers(
                result.documents.filter { !removedPaths.contains($0.source.path) },
                references: references, excluding: exclusions, store: store,
                progress: { completed, total in
                    guard total > 0 else { return }
                    Task { @MainActor in
                        guard recipient.operation == token, recipient.scanner != nil else { return }
                        recipient.coverScanProgress = "Finding cover art… \(completed) of \(total) documents."
                    }
                })
            return (intake: result, covers: covers)
        }
        scanner = task
        Task {
            do {
                let imported = try await task.value
                guard operation == token else { return }
                guard !task.isCancelled else { throw CancellationError() }
                let result = imported.intake
                let existing = Dictionary(uniqueKeysWithValues: documents.map { ($0.source.path, $0) })
                let discovered = result.documents.filter { !removed.contains($0.source.path) }.map {
                    InputDocument(source: $0.source, kind: $0.kind, relativePath: $0.relativePath,
                                  id: existing[$0.source.path]?.id ?? $0.id,
                                  textEncoding: existing[$0.source.path]?.textEncoding ?? .automatic)
                }
                let discoveredPaths = Set(discovered.map { $0.source.path })
                let retainedActive = activeBatch?.documents.map(\.input).filter { !discoveredPaths.contains($0.source.path) } ?? []
                let byID = Dictionary(uniqueKeysWithValues: (discovered + retainedActive).map { ($0.id, $0) })
                documents = QueueOrdering.retainingOrder(documents.map(\.id), discovered: (discovered + retainedActive).map(\.id)).compactMap { byID[$0] }
                let requeued = QueueIntakePolicy.requeuedIDs(documents: discovered, selected: urls, active: activeIDs)
                skippedExisting.subtract(requeued)
                for id in requeued where outcomes[id] != nil { retryQueued.insert(id) }
                for id in requeued { states[id] = nil }
                let sourceKeys = Set(documents.map { DocumentCoverPreferences.key($0.source) })
                var updatedCovers = coverDigests
                for (key, digest) in imported.covers where sourceKeys.contains(key) &&
                    updatedCovers[key] == nil && !automaticCoverExclusions.contains(key) {
                    updatedCovers[key] = digest
                }
                if updatedCovers != coverDigests { coverDigests = updatedCovers }
                issues = result.issues
                let excluded = result.excludedOutput ? " Selected output subtree excluded." : ""
                status = "\(documents.count) documents; \(result.ignoredCount) unsupported or linked items ignored; \(result.issues.count) input errors.\(excluded)"
                importSummary = status
                if let root = workspace?.url { makeDebugLog(root)?.record("intake settled documents=\(documents.count) ignored=\(result.ignoredCount) errors=\(result.issues.count)") }
                replan()
            } catch is CancellationError {
                if operation == token { status = "Input scan cancelled." }
            } catch { if operation == token { status = error.localizedDescription } }
            if operation == token { busy = hasCoverWork; scanner = nil; coverScanProgress = nil }
        }
    }

    func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Self.logger.info("Receiving file drop: \(providers.count) items")
        dropError = nil
        status = "Receiving dropped files and folders…"
        droppedFiles.start(providers) { [self] result in
            if let root = workspace?.url { makeDebugLog(root)?.record("intake drop items=\(providers.count) resolved=\(result.urls.count) unavailable=\(result.unavailableItems)") }
            guard !result.urls.isEmpty else {
                status = "The dropped items did not provide accessible file locations. Use Add Files or Add Folder to select them."
                announce(status)
                return
            }
            add(result.urls)
            if result.unavailableItems > 0 {
                dropError = "\(result.unavailableItems) dropped items did not provide accessible file locations. Use Add Files or Add Folder to select them."
            }
        }
        return true
    }

    func replan() {
        planner?.cancel()
        let token = UUID(); planOperation = token
        planned = []
        planner = nil
        guard let url = output?.url else { planningError = output?.error ?? "Choose an output folder to preview destinations."; return }
        let inputs = candidates
        let overrides = names
        let format = outputFormat
        planningError = nil
        let task = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: .milliseconds(150))
            let scope = DirectoryAccess(url)
            defer { withExtendedLifetime(scope) {} }
            return try BatchPlanner.plan(inputs, output: url, names: overrides, format: format)
        }
        planner = task
        Task {
            do {
                let result = try await task.value
                if planOperation == token { planned = result; planningError = nil }
            } catch is CancellationError { }
            catch { if planOperation == token { planningError = error.localizedDescription } }
            if planOperation == token { planner = nil }
        }
    }

    func removeSelected() {
        guard !busy, !isGenerating else { return }
        for document in documents where selection.contains(document.id) { removed.insert(document.source.path) }
        documents.removeAll { selection.contains($0.id) }
        names = names.filter { !selection.contains($0.key) }
        states = states.filter { !selection.contains($0.key) }
        outcomes = outcomes.filter { !selection.contains($0.key) }
        if let playingDocument, selection.contains(playingDocument) { stopPlayback() }
        outputScopes = outputScopes.filter { !selection.contains($0.key) }
        savedNames = savedNames.filter { !selection.contains($0.key) }
        retryQueued.subtract(selection)
        skippedExisting.subtract(selection)
        selection.removeAll(); replan()
    }

    var canClearQueue: Bool {
        !isGenerating && !isPreparingModel && !hasOwnedProbe && scanner == nil && reader == nil && !hasCoverWork &&
            !workBusy && (!documents.isEmpty || droppedFiles.hasOwnedWork)
    }

    func clear() {
        guard canClearQueue else { return }
        droppedFiles.cancel()
        busy = false
        documents = []; roots = []; scopes = [:]; removed = []; names = [:]; states = [:]
        outcomes = [:]; retryQueued = []; skippedExisting = []; batchSummary = nil; notificationSummary = nil
        stopPlayback(); outputScopes = [:]; savedNames = [:]
        issues = []; selection = []; importSummary = nil; dropError = nil
        status = "Add documents or drop files and folders here."; replan()
    }

    func cancel() {
        pronunciationPreview.stop()
        cancelIntake()
        if isPreparingModel { preparationStatus = "Cancelling preparation… waiting for the helper to stop."; preparationTask?.cancel() }
        if isGenerating { generationStatus = "Cancelling… waiting for the native worker to stop."; generationTask?.cancel() }
    }

    func togglePause() {
        guard isGenerating else { return }
        queueControl?.setPaused(!pauseRequested)
        queueState = queueControl?.state
    }
    func confirmStop() {
        guard let batch = activeBatch?.id else { return }
        let alert = NSAlert()
        alert.messageText = "Stop the queue?"
        alert.informativeText = "Unfinished audio will be discarded. Saved files are kept."
        alert.addButton(withTitle: "Keep Processing")
        alert.addButton(withTitle: "Stop Queue")
        if alert.runModal() == .alertSecondButtonReturn, activeBatch?.id == batch { cancel() }
    }
    func confirmSkip() {
        guard let control = queueControl, let batch = activeBatch?.id,
              let job = queueState?.current, queueState?.canSkip == true else { return }
        let name = activeBatch?.documents.first { $0.id == job }?.input.source.lastPathComponent ?? "this document"
        let alert = NSAlert()
        alert.messageText = "Skip \(name)?"
        alert.informativeText = "Discard this item's unfinished audio and move to the next item after the current operation finishes. Saved files are kept."
        alert.addButton(withTitle: "Keep Processing")
        alert.addButton(withTitle: "Skip Item")
        if alert.runModal() == .alertSecondButtonReturn {
            guard activeBatch?.id == batch, queueControl === control else { return }
            if control.skip(job: job) { queueState = control.state }
        }
    }
    func canDrag(_ document: InputDocument) -> Bool {
        !busy && (!activeIDs.contains(document.id) || queueState?.pending.contains(document.id) == true)
    }
    func dragPayload(_ document: InputDocument) -> QueueRowDrag {
        let ids = selection.contains(document.id) ? displayedDocuments.filter { selection.contains($0.id) && canDrag($0) }.map(\.id) : [document.id]
        return .init(queue: dragSession, ids: ids)
    }
    func moveQueue(_ items: [QueueRowDrag], to index: Int) {
        guard !busy, !items.isEmpty, items.allSatisfy({ $0.queue == dragSession }) else { return }
        let rows = displayedDocuments, order = rows.map(\.id), ids = Set(items.flatMap(\.ids))
        let pending = Set(queueControl?.state.pending ?? [])
        guard let moved = QueueOrdering.moving(order, ids: ids, to: index, active: batchOrder, pending: pending) else { return }
        if let control = queueControl {
            if ids.isSubset(of: pending) {
                // Current/finished rows and next-batch membership remain fixed.
                guard control.reorderPending(moved.filter { pending.contains($0) }) else { return }
                batchOrder = moved.filter { activeIDs.contains($0) }
                activityProgress?.reorderPending(jobs: batchOrder)
                queueState = control.state
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        documents = moved.compactMap { byID[$0] }
        replan()
    }

    func cancelIntake() {
        let receivingDrop = droppedFiles.hasOwnedWork
        droppedFiles.cancel()
        if scanner == nil && reader == nil && !hasCoverWork {
            busy = false
            if receivingDrop { status = "Input import cancelled." }
        }
        coverTask?.cancel()
        scanner?.cancel(); reader?.cancel()
        if let process = probeProcess, process.isRunning { probeCancelled = true; process.terminate() }
    }

    var hasIntakeWork: Bool { droppedFiles.hasOwnedWork || scanner != nil || reader != nil }
    func stopIntake() async {
        let scan = scanner, read = reader
        scan?.cancel(); read?.cancel()
        await droppedFiles.stop()
        _ = await scan?.result
        _ = await read?.result
    }

    func stopProbe() async {
        guard let process = probeProcess else { return }
        probeCancelled = true
        await Task.detached {
            if process.isRunning { process.terminate() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }.value
        if probeProcess === process { probeProcess = nil }
    }

    func showPreview(_ document: InputDocument) {
        guard !busy else { return }
        let token = UUID(); operation = token; previewOperation = token; busy = true
        status = "Analyzing document text…"
        states[document.id] = "Analyzing text…"
        let imageDescriptions = describeImages, selectedSettings = settings, options = narrationOptions
        let recipient = self
        let task = Task.detached(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Analyzing a Libro document")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let dictionary = try PronunciationStore().load().dictionary
            try await InferenceLease.withPriority(.interactive) {
                try await DocumentPreviewAnalysis.run(document, describeImages: imageDescriptions,
                    settings: selectedSettings, pronunciations: dictionary, options: options) { content in
                        try Task.checkCancellation()
                        try await recipient.receivePreview(content, document: document, token: token)
                    }
            }
        }
        reader = task
        Task {
            do {
                try await task.value
                guard operation == token else { return }
                states[document.id] = "Text ready"
                status = preview == nil ? "Text analysis complete." : "Text preview ready."
            } catch is CancellationError {
                if operation == token {
                    states[document.id] = "Analysis cancelled"; status = "Text analysis cancelled."
                    preview?.issue = "Analysis cancelled. Only the loaded pages are shown."
                }
            } catch {
                if operation == token {
                    states[document.id] = error.localizedDescription; status = "Document text could not be analyzed."
                    preview?.issue = "Analysis could not finish: " + error.localizedDescription
                }
            }
            if operation == token { busy = false; reader = nil }
        }
    }

    private func receivePreview(_ content: DocumentPreviewContent, document: InputDocument, token: UUID) throws {
        guard operation == token, previewOperation == token, !Task.isCancelled else { throw CancellationError() }
        preview = .init(id: document.id, title: document.source.lastPathComponent, content: content)
        if let completed = content.completedPages, let total = content.totalPages {
            states[document.id] = "Analyzing text · \(completed)/\(total) pages available"
            status = "Preview available. Analyzing remaining text…"
        }
    }

    func dismissPreview() {
        previewOperation = nil
        preview = nil
        reader?.cancel()
    }

    func setTextEncoding(_ encoding: TextFileEncoding, for document: InputDocument) {
        guard !busy, !activeIDs.contains(document.id), [.text, .markdown].contains(document.kind),
              outcomes[document.id]?.state != .published || retryQueued.contains(document.id),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].textEncoding = encoding
        skippedExisting.remove(document.id)
        if preview?.id == document.id { preview = nil }
        if outcomes[document.id] != nil { retryQueued.insert(document.id) }
        states[document.id] = "Ready · \(encoding.label)"
        status = "Text encoding set to \(encoding.label). Preview the document to check its text."
        replan()
    }

    func probe() {
        guard !busy, !debugToolsBusy, !isGenerating, !isPreparingModel, probeProcess == nil else { return }
        let token = UUID(); operation = token
        busy = true; probeCancelled = false; status = "Checking embedded Metal runtime…"; probeStatus = status
        do {
            // Spawn on the owning actor before any quit event can arrive.
            let (process, output, ended) = try startProbe()
            probeProcess = process
            Task {
                let result = await Task.detached { finishProbe(process, output: output, ended: ended) }.value
                if probeProcess === process { probeProcess = nil }
                if operation == token { status = probeCancelled ? "Worker probe cancelled." : result; probeStatus = status; busy = false }
            }
        } catch {
            status = "Unable to launch the embedded worker: \(error.localizedDescription)"; probeStatus = status; busy = false
        }
    }

    func refreshReadiness(preserveSetupResult: Bool = false) {
        guard !isPreparingModel else { return }
        if !preserveSetupResult { setupResult = .notChecked; setupVerificationFailed = false }
        readinessTask?.cancel(); readinessTask = nil
        let token = UUID(); readinessOperation = token
        assetsReady = false; checkingAssets = false; readinessScopes = []
        guard let root = workspace?.url else {
            readiness = workspace?.error ?? "Choose the Libro workspace containing models."
            onboarding.assess(installed: false)
            return
        }
        readinessScopes = [DirectoryAccess(root)]
        let selected = settings
        checkingAssets = true; readiness = "Checking \(selected.model.rawValue.capitalized) assets…"
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let store = try NativeWorkspace(root: root)
            let primary = try store.primaryDirectory(for: selected.model, voice: selected.voice)
            var voices = [selected.voice]
            if selected.model == .kokoro {
                try NativeG2P.validate(directory: store.g2pDirectory, workspace: store)
                voices = NativePrimaryCatalog.specification(for: .kokoro).voices.filter {
                    FileManager.default.fileExists(atPath: primary.appendingPathComponent("voices/\($0).safetensors").path)
                }.sorted()
            }
            try Task.checkCancellation()
            return ("\(selected.model.rawValue.capitalized) model files available.", voices)
        }
        readinessTask = task
        Task {
            do {
                let (message, available) = try await task.value
                guard readinessOperation == token else { return }
                readiness = message; assetsReady = true; onboarding.assess(installed: true)
                if selected.model == .kokoro { voices = available }
            } catch is CancellationError {}
            catch { if readinessOperation == token { readiness = error.localizedDescription; onboarding.assess(installed: false) } }
            if readinessOperation == token { checkingAssets = false; readinessTask = nil; readinessScopes = [] }
        }
    }

    func installSpeechRuntime() {
        guard canManageSpeechSetup else { return }
        if let workspace, workspace.url == nil {
            preparationStatus = workspace.error ?? "Choose the unavailable model folder again in Settings."
            setupResult = .failure(preparationStatus)
            return
        }
        do {
            let root = workspace?.url ?? NativeModelStorage.defaultRoot
            try NativeModelStorage.prepareRoot(root)
            if root.resolvingSymlinksInPath().path == NativeModelStorage.defaultRoot.path {
                preferences.clear(.workspace)
                workspace = DirectorySelection(displayPath: root.path, url: root, error: nil)
            } else { workspace = try preferences.select(root, role: .workspace) }
            prepareModel()
        } catch { preparationStatus = error.localizedDescription; setupResult = .failure(preparationStatus) }
    }

    func useDefaultModelStorage() {
        guard canManageSpeechSetup else { return }
        preferences.clear(.workspace)
        workspace = DirectorySelection(displayPath: NativeModelStorage.defaultRoot.path, url: NativeModelStorage.defaultRoot, error: nil)
        modelStorageRevision += 1
        refreshReadiness()
    }

    func playVoiceSample() {
        if settings.voice.hasPrefix("reference:") || settings.effectiveLanguage != "English" {
            if pronunciationPreview.hasOwnedWork { pronunciationPreview.stop(); return }
            guard let configuration = pronunciationConfiguration else { status = "Install and check the selected model before playing a live voice preview."; return }
            stopPlayback()
            let text = NarrationSampleText.text(language: settings.effectiveLanguage)
            pronunciationPreview.play(entry: .init(word: text, spelling: text), dictionary: .empty, configuration: configuration)
            return
        }
        guard let sample = VoiceSamples.sample(model: settings.model, voice: settings.voice) else { return }
        if voiceSamplePlayer.playingID == sample.id { voiceSamplePlayer.stop(); return }
        stopPlayback()
        voiceSamplePlayer.toggle(url: sample.url, id: sample.id)
    }

    func checkSpeechSetup() { prepareModel(checkOnly: true) }

    func prepareModel(checkOnly: Bool = false) {
        guard canPrepareModel, let root = workspace?.url else { return }
        let selected = settings
        let token = UUID(); preparationOperation = token
        isPreparingModel = true; preparationIsCheck = checkOnly; setupResult = .notChecked
        assetsReady = false; preparationProgress = nil
        preparationStatus = "Checking \(selected.model.rawValue.capitalized) assets in \(root.path)."
        preparationScopes = [DirectoryAccess(root)]
        let log = makeDebugLog(root)
        log?.record("preparation started model=\(selected.model.rawValue) revision=\(NativePrimaryCatalog.specification(for: selected.model).revision)")
        let configuration = WorkerConfiguration(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker"), requestTimeout: .seconds(1_800), debugLog: log, inferencePriority: .interactive)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Preparing user-requested Libro models")
        pronunciationPreview.stop()
        preparationTask = Task { [self] in
            await pronunciationPreview.stopAndWait()
            do {
                if checkOnly {
                    try await SpeechSetupCheck.run(configuration: configuration, workspace: root, settings: selected)
                } else {
                    try await ModelPreparation.run(configuration: configuration, workspace: root, settings: selected) { [weak self] value in
                        Task<Void, Never> { @MainActor in
                            guard let self, self.isPreparingModel, !self.preparationIsCheck, self.preparationOperation == token else { return }
                            self.preparationProgress = value
                            let scope = value.scope == .primary ? selected.model.rawValue.capitalized : "English pronunciation assets"
                            self.preparationStatus = "\(value.phase.rawValue.capitalized) \(scope)…"
                        }
                    }
                }
                // Installation validates/downloads assets; verify actual offline initialization too.
                if !checkOnly {
                    preparationIsCheck = true; preparationProgress = nil
                    preparationStatus = "Checking installed speech model offline…"
                    try await SpeechSetupCheck.run(configuration: configuration, workspace: root, settings: selected)
                }
                setupResult = .ready; setupVerificationFailed = false
                preparationStatus = "Speech setup ready. Generation uses local assets."
            } catch is CancellationError {
                setupResult = .cancelled
                preparationStatus = checkOnly ? "Speech setup check cancelled." : "Installation cancelled. Completed asset files remain available for reuse."
            } catch {
                preparationStatus = error.localizedDescription
                setupResult = .failure(preparationStatus); setupVerificationFailed = true
            }
            log?.record("preparation settled: \(preparationStatus)")
            if log?.writeFailed == true { debugLogStatus = "Debug logging stopped because its file could not be written. Processing was unaffected." }
            ProcessInfo.processInfo.endActivity(activity)
            preparationOperation = UUID(); isPreparingModel = false; preparationTask = nil; preparationScopes = []
            modelStorageRevision += 1
            preparationProgress = nil
            status = preparationStatus
            announce(preparationStatus)
            refreshReadiness(preserveSetupResult: true)
        }
    }

    func copyDebugLog() { manageDebugLog(clear: false) }
    func clearDebugLog() { manageDebugLog(clear: true) }
    private func manageDebugLog(clear: Bool) {
        guard canManageDebugLog, let root = workspace?.url else { return }
        debugToolsBusy = true
        Task {
            let access = DirectoryAccess(root)
            defer { withExtendedLifetime(access) {}; debugToolsBusy = false }
            do {
                let text = try await Task.detached {
                    if clear { try DebugLog.clear(workspace: root); return "" }
                    return try DebugLog.read(workspace: root)
                }.value
                guard workspace?.url == root else { return }
                if clear { debugLogURL = nil; debugLogStatus = "Debug log cleared." }
                else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    debugLogStatus = "Debug log copied. It may contain private document text or paths."
                }
            } catch { debugLogStatus = "Debug log action failed: " + error.localizedDescription }
        }
    }

    func stopPreparation() async {
        if let task = readinessTask {
            let token = readinessOperation
            task.cancel()
            _ = try? await task.value
            if readinessOperation == token { setupResult = .cancelled }
        }
        preparationTask?.cancel()
        await preparationTask?.value
    }

    func generate() {
        guard canGenerate, let destination = output?.url, let root = workspace?.url else { return }
        let inputs = planned.map(\.input), references = coverDigests, store = coverStore
        let format = outputFormat, overrides = names, selectedSettings = settings
        let options = narrationOptions, imageDescriptions = describeImages
        busy = true
        coverTask = Task {
            defer { coverTask = nil; busy = scanner != nil || reader != nil }
            do {
                let planningWork = Task.detached(priority: .userInitiated) {
                    let scope = DirectoryAccess(destination)
                    defer { withExtendedLifetime(scope) {} }
                    return try BatchPlanner.plan(inputs, output: destination, names: overrides, format: format)
                }
                let plans = try await withTaskCancellationHandler { try await planningWork.value } onCancel: { planningWork.cancel() }
                try Task.checkCancellation()
                let replacements = plans.filter(\.replacesExisting)
                var choice = ExistingOutputChoice.skip
                if !replacements.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Audio files already exist"
                    let listed = replacements.prefix(12).map(\.relativeOutput).joined(separator: "\n")
                    let remainder = replacements.count > 12 ? "\n…and \(replacements.count - 12) more." : ""
                    alert.informativeText = "\(replacements.count) queued documents already have audio in the selected output folder. Overwrite those files or skip those documents and process the rest.\n\n" + listed + remainder
                    alert.addButton(withTitle: "Skip Existing")
                    alert.addButton(withTitle: "Overwrite Existing")
                    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: choice = .skip
                    case .alertSecondButtonReturn: choice = .overwrite
                    default: choice = .cancel
                    }
                }
                guard let selection = QueueProcessingSelection(plans: plans, choice: choice) else { return }
                try Task.checkCancellation()
                if selection.documents.isEmpty {
                    skippedExisting.formUnion(selection.skipped)
                    retryQueued.subtract(selection.skipped)
                    status = "Skipped \(selection.skipped.count) documents with existing audio. Existing files were kept."
                    generationStatus = status
                    announce(status); replan()
                    return
                }
                let work = Task.detached(priority: .userInitiated) {
                    format.supportsCoverArtwork ? try DocumentCoverPreferences.snapshot(selection.documents.map(\.input), references: references, store: store) : [:]
                }
                let covers = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                skippedExisting.formUnion(selection.skipped)
                retryQueued.subtract(selection.skipped)
                let request = BatchRequest(documents: selection.documents, outputDirectory: destination, workspace: root,
                    settings: selectedSettings, describeImages: imageDescriptions, replaceExisting: selection.replaceExisting,
                    outputFormat: format, coverArtwork: covers, narrationOptions: options)
                beginGeneration(request)
            } catch is CancellationError { status = "Batch start cancelled." }
            catch { planningError = error.localizedDescription }
        }
    }

    private func beginGeneration(_ request: BatchRequest) {
        guard !isGenerating else { return }
        let destination = request.outputDirectory, root = request.workspace
        let log = makeDebugLog(root)
        log?.record("batch=\(request.id) started documents=\(request.documents.count) model=\(request.settings.model.rawValue) voice=\(request.settings.voice) speed=\(request.settings.speed) format=\(request.outputFormat.rawValue) app=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        activityProgress = .init(batch: request.id, jobs: request.documents.map(\.id))
        activeBatch = request; speechProgress = nil; batchSummary = nil; notificationSummary = nil
        batchOrder = request.documents.map(\.id)
        let control = BatchQueueControl(batch: request.id, jobs: batchOrder)
        queueControl = control; queueState = control.state
        retryQueued.subtract(request.documents.map(\.id))
        for document in request.documents { outcomes[document.id] = nil; states[document.id] = "Waiting" }
        let outputScope = DirectoryAccess(destination)
        batchScopes = Array(scopes.values) + [outputScope, DirectoryAccess(root)]
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Generating user-requested Libro audio")
        generationStatus = "Preparing batch. Closing the window keeps processing; quitting offers cancellation."
        Self.logger.info("Starting batch \(request.id.uuidString, privacy: .public), documents \(request.documents.count)")
        let updates = LatestBatchProgress()
        progressTask = Task {
            while !Task.isCancelled {
                if let value = updates.takeText() { receive(.textPreparation(value)) }
                if let value = updates.take() { receive(.speech(value)) }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        requestNotificationAuthorization()
        pronunciationPreview.stop()
        generationTask = Task { [self] in
            await pronunciationPreview.stopAndWait()
            do {
                let summary = try await coordinator.run(request, debugLog: log, control: control) { [weak self] event in
                    if case .speech(let value) = event, value.phase == .chunkWritten { updates.store(value) }
                    else if case .textPreparation(let value) = event { updates.storeText(value) }
                    else { Task { @MainActor in self?.receive(event) } }
                }
                for outcome in summary.documents {
                    outcomes[outcome.id] = outcome
                    if summary.cancelled, outcome.state == .cancelled { retryQueued.insert(outcome.id) }
                    if outcome.state == .published {
                        outputScopes[outcome.id] = outputScope
                        savedNames[outcome.id] = request.documents.first { $0.id == outcome.id }?.relativeOutput
                    }
                }
                batchSummary = summary
                generationStatus = (summary.cancelled ? "Stopped" : "Complete") + ": \(summary.successfulCount) saved; \(summary.failedCount) failed; \(summary.skippedCount) skipped."
                announce(generationStatus)
                Self.logger.info("Settled batch \(summary.id.uuidString, privacy: .public), saved \(summary.successfulCount), failed \(summary.failedCount), cancelled \(summary.cancelled)")
                Task { await notify(summary) }
            } catch is CancellationError {
                generationStatus = "Batch cancelled before generation."
                for document in request.documents {
                    outcomes[document.id] = DocumentOutcome(id: document.id, state: .cancelled, destination: document.destination)
                    retryQueued.insert(document.id)
                }
            } catch {
                generationStatus = error.localizedDescription
                for document in request.documents {
                    outcomes[document.id] = DocumentOutcome(id: document.id, state: .failed,
                        destination: document.destination, message: "Batch could not start: " + error.localizedDescription)
                }
                Self.logger.error("Batch preflight failed \(request.id.uuidString, privacy: .public)")
            }
            log?.record("batch=\(request.id) settled: \(generationStatus)")
            if log?.writeFailed == true { debugLogStatus = "Debug logging stopped because its file could not be written. Processing was unaffected." }
            progressTask?.cancel(); progressTask = nil
            activeBatch = nil; queueControl = nil; queueState = nil; batchOrder = []
            activityProgress = nil; speechProgress = nil; batchScopes = []
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            generationTask = nil; status = generationStatus
            replan()
        }
        replan()
    }

    private func receive(_ event: BatchEvent) {
        guard let batch = activeBatch, generationTask?.isCancelled != true else { return }
        switch event {
        case .control(let value) where value.batch == batch.id:
            guard value.sequence >= (queueState?.sequence ?? 0) else { return }
            queueState = value
        case .preparing(let id, let job) where id == batch.id:
            guard outcomes[job] == nil, activityProgress?.beginPreparation(job: job) == true else { return }
            states[job] = "Preparing text…"
            speechProgress = nil
            generationStatus = "Preparing \(batch.documents.first { $0.id == job }?.input.source.lastPathComponent ?? "document")…"
        case .textPreparation(let value) where value.batch == batch.id:
            guard outcomes[value.job] == nil, activityProgress?.receive(value) == true else { return }
            speechProgress = nil
            states[value.job] = value.progress.status
            let name = batch.documents.first { $0.id == value.job }?.input.source.lastPathComponent ?? "document"
            generationStatus = "\(name) · \(value.progress.status)"
        case .speech(let value) where value.identity.batch == batch.id:
            guard activityProgress?.beginSpeech(job: value.identity.job) == true else { return }

            guard outcomes[value.identity.job] == nil else { return }
            if let current = speechProgress, current.identity.job == value.identity.job {
                guard value.completedChunks >= current.completedChunks else { return }
            }
            speechProgress = value
            let name = batch.documents.first { $0.id == value.identity.job }?.input.source.lastPathComponent ?? "document"
            if value.phase == .publishing {
                states[value.identity.job] = "Saving…"; generationStatus = "Saving \(name)…"
            } else {
                states[value.identity.job] = "Generating: \(value.completedChunks)/\(value.totalChunks) chunks"
                generationStatus = "Generating \(name): \(value.completedChunks) of \(value.totalChunks) chunks."
            }
        case .document(let id, let outcome) where id == batch.id:
            outcomes[outcome.id] = outcome
            if outcome.state == .published { savedNames[outcome.id] = batch.documents.first { $0.id == outcome.id }?.relativeOutput }
            if outcome.state == .failed { announce("A document failed. See its queue row for details.") }
        default: break // Completion notifications come only after run() returns.
        }
    }

    func stopGeneration() async {
        await pronunciationPreview.stopAndWait()
        generationTask?.cancel()
        await coordinator.cancelAndWait()
        await generationTask?.value
    }

    func rowStatus(_ document: InputDocument) -> String {
        if currentJob == document.id {
            switch queueState?.phase {
            case .paused: return "Paused"
            case .pausing: return "Pausing…"
            case .skipping: return "Skipping…"
            default: break
            }
        }
        if skippedExisting.contains(document.id) { return "Skipped: audio already exists" }
        if retryQueued.contains(document.id) { return isGenerating ? "Queued for next batch" : "Queued for retry" }
        if let outcome = outcomes[document.id] {
            switch outcome.state {
            case .published: return "Saved"
            case .failed: return "Failed: " + (outcome.message ?? "Unknown failure. Open Details.")
            case .cancelled: return "Cancelled"
            case .skipped: return "Skipped"
            }
        }
        return states[document.id] ?? (isGenerating ? "Queued for next batch" : "Queued")
    }

    private func makeDebugLog(_ workspace: URL) -> DebugLog? {
        guard debugLogging else { return nil }
        do {
            let log = try DebugLog(workspace: workspace)
            debugLogURL = log.url; debugLogStatus = nil
            return log
        } catch {
            debugLogStatus = "Debug log unavailable in the selected workspace: " + error.localizedDescription
            return nil
        }
    }

    func showFailure(_ document: InputDocument) {
        guard let outcome = outcomes[document.id], outcome.state == .failed else { return }
        failureDetails = .init(id: document.id, name: document.source.lastPathComponent,
                              message: outcome.message ?? "Unknown failure.")
    }

    func outputName(_ document: InputDocument) -> String {
        if outcomes[document.id]?.state == .published, !retryQueued.contains(document.id), let name = savedNames[document.id] { return name }
        return activeBatch?.documents.first { $0.id == document.id }?.relativeOutput ?? names[document.id] ?? BatchPlanner.defaultOutput(document, format: outputFormat)
    }

    func outputDestinationHint(_ document: InputDocument) -> String {
        if let outcome = outcomes[document.id], outcome.state == .published, !retryQueued.contains(document.id) { return outcome.destination.path }
        if let plan = activeBatch?.documents.first(where: { $0.id == document.id }) ?? planned.first(where: { $0.id == document.id }) { return plan.destination.path }
        return output?.url?.appendingPathComponent(outputName(document)).path ?? "Choose an output folder"
    }

    func retry(_ document: InputDocument) {
        skippedExisting.remove(document.id)
        retryQueued.insert(document.id); states[document.id] = "Queued for retry"; replan()
    }

    func previewSelected() { if let document = selectedDocument { showPreview(document) } }
    func playSelected() { if let document = selectedDocument { play(document) } }
    func revealSelected() {
        if let document = selectedDocument, let outcome = outcomes[document.id], outcome.state == .published {
            NSWorkspace.shared.activateFileViewerSelecting([outcome.destination])
        }
    }
    func retrySelected() { if let document = selectedDocument, canQueueSelectedAgain { retry(document) } }

    func clearFinished() {
        guard !busy, !isGenerating else { return }
        selection = Set(outcomes.keys).union(skippedExisting).subtracting(retryQueued)
        removeSelected()
    }

    func retryUnfinished() {
        for document in documents where outcomes[document.id]?.state == .failed || outcomes[document.id]?.state == .cancelled || outcomes[document.id]?.state == .skipped {
            skippedExisting.remove(document.id)
            retryQueued.insert(document.id)
        }
        replan()
    }

    func play(_ document: InputDocument) {
        guard let outcome = outcomes[document.id], outcome.state == .published else { return }
        if playingDocument == document.id { stopPlayback(); return }
        stopPlayback()
        do {
            let audio = try AVAudioPlayer(contentsOf: outcome.destination)
            guard audio.play() else { throw AudioOutputError.storage }
            player = audio; playingDocument = document.id
            playbackTask = Task {
                while audio.isPlaying {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                if player === audio { player = nil; playingDocument = nil; playbackTask = nil }
            }
        } catch { status = "Could not play the saved output: " + error.localizedDescription }
    }

    func stopPlayback() { pronunciationPreview.stop(); voiceSamplePlayer.stop(); playbackTask?.cancel(); playbackTask = nil; player?.stop(); player = nil; playingDocument = nil }

    private func requestNotificationAuthorization() {
        guard notificationAuthorizationTask == nil else { return }
        notificationAuthorizationTask = Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                do { _ = try await center.requestAuthorization(options: [.alert]) }
                catch {
                    notificationStatus = "Completion alerts are unavailable. Batch results remain in this window."
                    Self.logger.error("Completion alert authorization unavailable")
                }
            }
            let authorization = await center.notificationSettings().authorizationStatus
            if authorization == .denied {
                notificationStatus = "Completion alerts are disabled in macOS. Batch results remain in this window."
            } else if authorization == .authorized || authorization == .provisional {
                notificationStatus = nil
            }
            notificationAuthorizationTask = nil
        }
    }

    func refreshNotificationStatus() async {
        let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization == .denied {
            notificationStatus = "Completion alerts are disabled in macOS. Batch results remain in the Libro window."
        } else if authorization == .authorized || authorization == .provisional {
            notificationStatus = "macOS allows completion alerts. Libro sends one private summary after outputs have been published."
        }
    }

    private func notify(_ summary: BatchSummary) async {
        if summary.cancelled { _ = completionLedger.finish(summary, authorized: false); return }
        // Authorization may still be open after a short batch. Waiting here
        // never holds the coordinator, active UI state, or generation activity.
        await notificationAuthorizationTask?.value
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings().authorizationStatus
        guard let notice = completionLedger.finish(summary, authorized: authorization == .authorized || authorization == .provisional) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title; content.body = notice.body
        content.userInfo = ["saved": notice.successfulCount, "failed": notice.failedCount]
        do { try await center.add(UNNotificationRequest(identifier: notice.batchID.uuidString, content: content, trigger: nil)) }
        catch {
            notificationStatus = "Completion alerts are unavailable. Batch results remain in this window."
            Self.logger.error("Completion notification unavailable for batch \(notice.batchID.uuidString, privacy: .public)")
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

// Keep at most one pending update per stream; page callbacks never enqueue UI tasks.
private final class LatestBatchProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpeechProgress?
    private var textValue: TextPreparationProgress?
    func storeText(_ incoming: TextPreparationProgress) {
        lock.withLock {
            if let current = textValue, current.batch == incoming.batch, current.job == incoming.job,
               current.sequence >= incoming.sequence { return }
            textValue = incoming
        }
    }
    func takeText() -> TextPreparationProgress? {
        lock.withLock { let result = textValue; textValue = nil; return result }
    }

    func store(_ value: SpeechProgress) { lock.withLock { self.value = value } }
    func take() -> SpeechProgress? { lock.withLock { let result = value; value = nil; return result } }
}

private func startProbe() throws -> (Process, Pipe, DispatchSemaphore) {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.executableNotLoadable) }
    let process = Process()
    let output = Pipe()
    process.executableURL = executable; process.arguments = ["--probe"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    try process.run()
    return (process, output, ended)
}

private func finishProbe(_ process: Process, output: Pipe, ended: DispatchSemaphore) -> String {
    // The known probe emits one small control record, with library output
    // redirected to stderr. Bound its lifetime before reading that record.
    if ended.wait(timeout: .now() + 15) == .timedOut {
        if process.isRunning { process.terminate() }
        if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return "Worker probe timed out."
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard data.count <= 65_536 else { return "Worker probe returned an invalid record." }
    guard process.terminationStatus == 0 else { return "Worker probe failed (\(process.terminationStatus))." }
    return "Embedded worker: Metal ready\n" + (String(data: data, encoding: .utf8) ?? "")
}
