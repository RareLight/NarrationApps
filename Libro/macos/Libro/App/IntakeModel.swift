import SwiftUI
import AppPresentation
import PronunciationUI
import NarrationUI
import ProcessingPipeline
import AppKit
import UniformTypeIdentifiers
import LibroCore
import NarrationCore
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
    var busy = false
    var settings = SpeechSettings() {
        didSet {
            if oldValue.model != settings.model || oldValue.voice != settings.voice { voiceSamplePlayer.stop(); refreshReadiness() }
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
            defer { busy = false; coverTask = nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try store.save(CoverArtwork.read(url))
                }
                let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                for source in sources { coverDigests[DocumentCoverPreferences.key(source)] = digest }
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
            defer { busy = false; coverTask = nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let bytes = try DocumentReader.bookCover(document)
                    guard let bytes else { throw NarrationError.invalidInput("This EPUB does not declare a supported JPEG or PNG cover. Choose an image instead.") }
                    return try store.save(CoverArtwork(data: bytes))
                }
                let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                coverDigests[DocumentCoverPreferences.key(document.source)] = digest
                replan()
            } catch { planningError = error.localizedDescription }
        }
    }
    func cleanCoverAssets() {
        let store = coverStore, keeping = Set(coverDigests.values)
        busy = true
        coverTask = Task {
            defer { busy = false; coverTask = nil }
            do {
                let work = Task.detached(priority: .utility) { try store.removeUnreferenced(keeping: keeping) }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } catch is CancellationError { }
            catch { status = "Cover removed. Some unused cover files could not be cleaned up." }
        }
    }
    func removeCover() {
        guard !busy, !isGenerating else { return }
        for source in documents.filter({ selection.contains($0.id) }).map(\.source) { coverDigests[DocumentCoverPreferences.key(source)] = nil }
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
        guard assetsReady, !setupVerificationFailed, !isGenerating, !isPreparingModel, !hasOwnedProbe, let root = workspace?.url else { return nil }
        return .init(worker: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker"), workspace: root, settings: settings, priority: .interactive)
    }
    private var onboarding = SpeechSetupOnboarding()
    var needsSpeechSetup: Bool { onboarding.needsSetup }
    func claimSpeechSetup() -> Bool { onboarding.claimPresentation() }
    var describeImages = UserDefaults.standard.object(forKey: "LibroDescribeImages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(describeImages, forKey: "LibroDescribeImages") }
    }
    var activeBatch: BatchRequest?
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
    var playingDocument: UUID?
    var reopenWindow: (() -> Void)?
    var isGenerating: Bool { activeBatch != nil }
    var activeIDs: Set<UUID> { Set(activeBatch?.documents.map(\.id) ?? []) }
    var candidates: [InputDocument] { documents.filter { !activeIDs.contains($0.id) && (outcomes[$0.id] == nil || retryQueued.contains($0.id)) } }
    var displayedDocuments: [InputDocument] {
        (activeBatch?.documents.map(\.input) ?? []) + documents.filter { !activeIDs.contains($0.id) }
    }
    var hasFinished: Bool { !outcomes.isEmpty }
    var selectedDocument: InputDocument? { selection.count == 1 ? displayedDocuments.first { selection.contains($0.id) } : nil }
    var hasSelectedAudio: Bool { selectedDocument.map { outcomes[$0.id]?.state == .published } ?? false }
    var hasSelectedFailure: Bool { selectedDocument.map { outcomes[$0.id]?.state == .failed || outcomes[$0.id]?.state == .cancelled } ?? false }
    var generationBlocker: GenerationBlocker? {
        .evaluate(isGenerating: isGenerating, isPreparing: isPreparingModel, busy: busy || debugToolsBusy, planning: planning,
                  workspaceAvailable: workspace?.url != nil, outputAvailable: output?.url != nil,
                  checkingAssets: checkingAssets, assetsReady: assetsReady && !setupVerificationFailed, queuedCount: candidates.count,
                  plannedCount: planned.count, hasPlanningError: planningError != nil)
    }
    var canGenerate: Bool { generationBlocker == nil }
    var speechSetupDisabledReason: String? {
        if isGenerating { return "Wait for audio generation to finish before checking or installing a speech model." }
        if isPreparingModel { return "Speech setup is in progress." }
        if checkingAssets { return "Checking local model files." }
        if busy || hasOwnedProbe { return "Wait for the current document or diagnostic operation to finish." }
        if debugToolsBusy { return "Wait for the debug log action to finish." }
        return nil
    }
    var canManageSpeechSetup: Bool { speechSetupDisabledReason == nil }
    var canPrepareModel: Bool { workspace?.url != nil && canManageSpeechSetup }
    var cancellable: Bool { hasCoverWork || pronunciationPreview.hasOwnedWork || scanner != nil || reader != nil || hasOwnedProbe || isGenerating || isPreparingModel }
    var inputCancelLabel: String { scanner != nil ? "Cancel Scan" : (reader != nil ? "Cancel Read" : "Cancel Check") }
    var hasOwnedProbe: Bool { probeProcess != nil }
    var activityStatus: String { scanner != nil ? "Scanning inputs… \(scanCount) entries checked." : status }
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
    private var scanner: Task<IntakeResult, Error>?
    private var reader: Task<(text: String, warnings: [String], document: SemanticDocument), Error>?
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
        output = preferences.load(.output)
        workspace = preferences.load(.workspace)
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
        guard role != .workspace || (!isPreparingModel && !debugToolsBusy) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = role == .output ? "Choose where Libro saves audio." : "Choose the Libro workspace containing models."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let selected = try self.preferences.select(url, role: role)
                if role == .output { self.output = selected } else {
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
        busy = true; scanCount = 0; status = "Scanning inputs…"
        let recipient = self
        let task = Task.detached(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Discovering Libro documents")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            return try InputCollector.collect(selection, excludingOutput: excluded) { count in
                Task { @MainActor in
                    guard recipient.operation == token else { return }
                    recipient.scanCount = count
                }
            }
        }
        scanner = task
        Task {
            do {
                let result = try await task.value
                guard operation == token else { return }
                let existing = Dictionary(uniqueKeysWithValues: documents.map { ($0.source.path, $0) })
                let discovered = result.documents.filter { !removed.contains($0.source.path) }.map {
                    InputDocument(source: $0.source, kind: $0.kind, relativePath: $0.relativePath,
                                  id: existing[$0.source.path]?.id ?? $0.id,
                                  textEncoding: existing[$0.source.path]?.textEncoding ?? .automatic)
                }
                let discoveredPaths = Set(discovered.map { $0.source.path })
                let retainedActive = activeBatch?.documents.map(\.input).filter { !discoveredPaths.contains($0.source.path) } ?? []
                documents = discovered + retainedActive
                issues = result.issues
                let excluded = result.excludedOutput ? " Selected output subtree excluded." : ""
                status = "\(documents.count) documents; \(result.ignoredCount) unsupported or linked items ignored; \(result.issues.count) input errors.\(excluded)"
                importSummary = status
                replan()
            } catch is CancellationError {
                if operation == token { status = "Input scan cancelled." }
            } catch { if operation == token { status = error.localizedDescription } }
            if operation == token { busy = false; scanner = nil }
        }
    }

    func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Self.logger.info("Receiving file drop: \(providers.count) items")
        dropError = nil
        status = "Receiving dropped files and folders…"
        Task {
            let result = await FileDrop.load(providers)
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
        selection.removeAll(); replan()
    }

    func clear() {
        guard !busy, !isGenerating else { return }
        documents = []; roots = []; scopes = [:]; removed = []; names = [:]; states = [:]
        outcomes = [:]; retryQueued = []; batchSummary = nil; notificationSummary = nil
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

    func cancelIntake() {
        coverTask?.cancel()
        scanner?.cancel(); reader?.cancel()
        if let process = probeProcess, process.isRunning { probeCancelled = true; process.terminate() }
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
        let token = UUID(); operation = token; busy = true
        status = "Reading document text…"
        states[document.id] = "Reading…"
        let imageDescriptions = describeImages, selectedSettings = settings, options = narrationOptions
        let task = Task.detached(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Reading a Libro document")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let semantic = try await InferenceLease.withPriority(.interactive) {
                try await DocumentReader.readSemantic(document, describeImages: imageDescriptions)
            }
            let plan = try NarrationPlanner.prepare(semantic, settings: selectedSettings, pronunciations: PronunciationStore().load().dictionary, options: options)
            return (text: plan.chunks.map(\.text).joined(separator: "\n\n"), warnings: Array(Set(semantic.warnings + plan.notices)).sorted(), document: semantic)
        }
        reader = task
        Task {
            do {
                let content = try await task.value
                guard operation == token else { return }
                preview = Preview(id: document.id, title: document.source.lastPathComponent, text: content.text, isPDF: document.kind == .pdf, warnings: content.warnings, document: content.document)
                states[document.id] = "Text ready"
                status = "Text preview ready."
            } catch is CancellationError {
                if operation == token { states[document.id] = "Reading cancelled"; status = "Reading cancelled." }
            } catch {
                if operation == token { states[document.id] = error.localizedDescription; status = "Document text could not be read." }
            }
            if operation == token { busy = false; reader = nil }
        }
    }

    func setTextEncoding(_ encoding: TextFileEncoding, for document: InputDocument) {
        guard !busy, !activeIDs.contains(document.id), [.text, .markdown].contains(document.kind),
              outcomes[document.id]?.state != .published || retryQueued.contains(document.id),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].textEncoding = encoding
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
        do {
            if workspace?.url == nil {
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Libro/SpeechRuntime", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                workspace = try preferences.select(root, role: .workspace)
            }
            prepareModel()
        } catch { preparationStatus = error.localizedDescription }
    }

    func playVoiceSample() {
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
        preparationTask?.cancel()
        await preparationTask?.value
    }

    func generate() {
        guard canGenerate else { return }
        let inputs = planned.map(\.input), references = coverDigests, store = coverStore
        let supportsArt = outputFormat.supportsCoverArtwork
        busy = true
        coverTask = Task {
            defer { coverTask = nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    supportsArt ? try DocumentCoverPreferences.snapshot(inputs, references: references, store: store) : [:]
                }
                let covers = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                busy = false
                beginGeneration(covers: covers)
            } catch { busy = false; planningError = error.localizedDescription }
        }
    }

    private func beginGeneration(covers: [UUID: CoverArtwork]) {
        guard canGenerate, let destination = output?.url, let root = workspace?.url else { return }
        let plans = planned
        let replacements = plans.filter(\.replacesExisting)
        var approved = false
        if !replacements.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace existing audio?"
            alert.informativeText = replacements.map(\.relativeOutput).joined(separator: "\n")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Replace and Generate")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            approved = true
        }
        let request = BatchRequest(documents: plans, outputDirectory: destination, workspace: root,
                                   settings: settings, describeImages: describeImages, replaceExisting: approved, outputFormat: outputFormat, coverArtwork: covers, narrationOptions: narrationOptions)
        let log = makeDebugLog(root)
        log?.record("batch=\(request.id) started documents=\(plans.count) model=\(settings.model.rawValue) voice=\(settings.voice) speed=\(settings.speed) format=\(request.outputFormat.rawValue) app=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        activityProgress = .init(batch: request.id, jobs: request.documents.map(\.id))
        activeBatch = request; speechProgress = nil; batchSummary = nil; notificationSummary = nil
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
                let summary = try await coordinator.run(request, debugLog: log) { [weak self] event in
                    if case .speech(let value) = event, value.phase == .chunkWritten { updates.store(value) }
                    else if case .textPreparation(let value) = event { updates.storeText(value) }
                    else { Task { @MainActor in self?.receive(event) } }
                }
                for outcome in summary.documents {
                    outcomes[outcome.id] = outcome
                    if outcome.state == .published {
                        outputScopes[outcome.id] = outputScope
                        savedNames[outcome.id] = request.documents.first { $0.id == outcome.id }?.relativeOutput
                    }
                }
                batchSummary = summary
                generationStatus = summary.cancelled ? "Batch cancelled: \(summary.successfulCount) saved; \(summary.failedCount) failed." :
                    "Batch complete: \(summary.successfulCount) saved; \(summary.failedCount) failed."
                announce(generationStatus)
                Self.logger.info("Settled batch \(summary.id.uuidString, privacy: .public), saved \(summary.successfulCount), failed \(summary.failedCount), cancelled \(summary.cancelled)")
                Task { await notify(summary) }
            } catch is CancellationError {
                generationStatus = "Batch cancelled before generation."
                for document in request.documents {
                    outcomes[document.id] = DocumentOutcome(id: document.id, state: .cancelled, destination: document.destination)
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
            activeBatch = nil; activityProgress = nil; speechProgress = nil; batchScopes = []
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            generationTask = nil; status = generationStatus
            replan()
        }
        replan()
    }

    private func receive(_ event: BatchEvent) {
        guard let batch = activeBatch, generationTask?.isCancelled != true else { return }
        switch event {
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
        if retryQueued.contains(document.id) { return isGenerating ? "Queued for next batch" : "Queued for retry" }
        if let outcome = outcomes[document.id] {
            switch outcome.state {
            case .published: return "Saved"
            case .failed: return "Failed: " + (outcome.message ?? "Unknown failure. Open Details.")
            case .cancelled: return "Cancelled"
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
        retryQueued.insert(document.id); states[document.id] = "Queued for retry"; replan()
    }

    func previewSelected() { if let document = selectedDocument { showPreview(document) } }
    func playSelected() { if let document = selectedDocument { play(document) } }
    func revealSelected() {
        if let document = selectedDocument, let outcome = outcomes[document.id], outcome.state == .published {
            NSWorkspace.shared.activateFileViewerSelecting([outcome.destination])
        }
    }
    func retrySelected() { if let document = selectedDocument, hasSelectedFailure { retry(document) } }

    func clearFinished() {
        guard !busy, !isGenerating else { return }
        selection = Set(outcomes.keys).subtracting(retryQueued)
        removeSelected()
    }

    func retryUnfinished() {
        for document in documents where outcomes[document.id]?.state == .failed || outcomes[document.id]?.state == .cancelled {
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

