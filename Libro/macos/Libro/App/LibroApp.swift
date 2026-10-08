import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LibroCore
import Darwin
import AVFoundation
import OSLog
@preconcurrency import UserNotifications

@main
struct LibroApp: App {
    @NSApplicationDelegateAdaptor(LibroDelegate.self) private var delegate
    @State private var model = IntakeModel.shared

    var body: some Scene {
        Window("Libro", id: "main") {
            IntakeView(model: model)
                .frame(minWidth: 780, minHeight: 580)
                .background(WindowAutosave())
                .onOpenURL { model.add([$0]) }
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files and Folders…") { model.openInputs() }.keyboardShortcut("o")
                Button("Add Folder…") { model.openInputs(foldersOnly: true) }
                Divider()
                Button("Remove Selected") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy || model.isGenerating)
                Button("Clear Finished") { model.clearFinished() }.disabled(!model.hasFinished || model.busy || model.isGenerating)
                Button("Clear Queue") { model.clear() }.disabled(model.documents.isEmpty || model.busy || model.isGenerating)
                Divider()
                Button("Preview Selected Document") { model.previewSelected() }.keyboardShortcut("y")
                    .disabled(model.selectedDocument == nil || model.busy)
                Button("Play or Stop Selected Audio") { model.playSelected() }.disabled(!model.hasSelectedAudio)
                Button("Reveal Selected Audio") { model.revealSelected() }.disabled(!model.hasSelectedAudio)
                Button("Queue Selected Unfinished Document") { model.retrySelected() }.disabled(!model.hasSelectedFailure)
                Divider()
                Button("Generate Audio") { model.generate() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!model.canGenerate)
                Button("Cancel Processing") { model.cancel() }.keyboardShortcut(".").disabled(!model.cancellable)
            }
        }
        Settings {
            Form {
                Toggle("Enable debug logging", isOn: $model.debugLogging)
                    .disabled(model.isGenerating || model.isPreparingModel)
                Text("Records local worker diagnostics for generation and model preparation. Library messages may include document text or paths. Nothing is uploaded. Up to two 1 MB log files are retained in the selected Libro workspace.")
                    .font(.callout).foregroundStyle(.secondary)
                if let url = model.debugLogURL {
                    Text(url.path).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Open Debug Log") { NSWorkspace.shared.open(url) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                if let message = model.debugLogStatus { Text(message).textSelection(.enabled) }
                Text("Enable logging before retrying a failed document. Logging is off by default and its preference is remembered.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().frame(width: 520)
        }
    }
}

@MainActor
private final class LibroDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        IntakeModel.shared.add(urls)
        showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Preserve a visible chooser/preview's key-window focus. Recreate the
        // main window only when every window has been closed.
        if !flag { showWindow() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = IntakeModel.shared
        if model.isGenerating || model.isPreparingModel {
            let alert = NSAlert()
            alert.messageText = model.isPreparingModel ? "Libro is preparing model assets." : "Libro is processing audio."
            alert.informativeText = model.isPreparingModel ? "Keep preparing, or cancel preparation and quit. Completed asset files can be reused when you prepare again." : "Keep processing, or cancel this batch and quit. Complete audio already saved will be preserved."
            alert.addButton(withTitle: "Keep Processing")
            alert.addButton(withTitle: "Cancel Processing and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model.cancel()
        model.stopPlayback()
        guard model.hasOwnedProbe || model.isGenerating || model.isPreparingModel else { return .terminateNow }
        Task {
            await model.stopGeneration()
            await model.stopPreparation()
            await model.stopProbe()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func showWindow() {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            IntakeModel.shared.reopenWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
        let visibleKey = NSApp.keyWindow.flatMap { $0.isVisible ? $0 : nil }
        (visibleKey ?? NSApp.windows.first(where: { $0.canBecomeMain }))?.makeKeyAndOrderFront(nil)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let saved = response.notification.request.content.userInfo["saved"] as? Int
        let failed = response.notification.request.content.userInfo["failed"] as? Int
        Task { @MainActor in
            if let saved, let failed, saved >= 0, failed >= 0 {
                IntakeModel.shared.notificationSummary = "Libro processing complete: \(saved) saved; \(failed) failed."
            }
            self.showWindow()
        }
        completionHandler()
    }
}

@MainActor
@Observable
private final class IntakeModel {
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
    var settings = SpeechSettings()
    var serial = false
    var readiness = "Checking prepared model assets…"
    var assetsReady = false
    var checkingAssets = false
    var isPreparingModel = false
    var preparationStatus = ""
    var preparationProgress: ModelPreparationProgress?
    var voices = ["af_aoede"]
    var activeBatch: BatchRequest?
    var speechProgress: SpeechProgress?
    var generationStatus = ""
    var batchSummary: BatchSummary?
    var notificationSummary: String?
    var notificationStatus: String?
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
    var canGenerate: Bool {
        !isGenerating && !isPreparingModel && !busy && !planning && assetsReady && output?.url != nil && workspace?.url != nil &&
        planningError == nil && !candidates.isEmpty && planned.count == candidates.count
    }
    var canPrepareModel: Bool { workspace?.url != nil && !isGenerating && !isPreparingModel && !busy && !checkingAssets && !hasOwnedProbe }
    var cancellable: Bool { scanner != nil || reader != nil || hasOwnedProbe || isGenerating || isPreparingModel }
    var inputCancelLabel: String { scanner != nil ? "Cancel Scan" : (reader != nil ? "Cancel Read" : "Cancel Probe") }
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
    private var reader: Task<String, Error>?
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
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker")))
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
        guard role != .workspace || !isPreparingModel else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = role == .output ? "Choose where Libro saves audio." : "Choose the Libro workspace containing models."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let selected = try self.preferences.select(url, role: role)
                if role == .output { self.output = selected } else { self.workspace = selected }
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
                let existing = Dictionary(uniqueKeysWithValues: documents.map { ($0.source.path, $0.id) })
                let discovered = result.documents.filter { !removed.contains($0.source.path) }.map {
                    InputDocument(source: $0.source, kind: $0.kind, relativePath: $0.relativePath,
                                  id: existing[$0.source.path] ?? $0.id)
                }
                let discoveredPaths = Set(discovered.map { $0.source.path })
                let retainedActive = activeBatch?.documents.map(\.input).filter { !discoveredPaths.contains($0.source.path) } ?? []
                documents = discovered + retainedActive
                issues = result.issues
                let excluded = result.excludedOutput ? " Selected output subtree excluded." : ""
                status = "\(documents.count) documents; \(result.ignoredCount) unsupported or linked items ignored; \(result.issues.count) input errors.\(excluded)"
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
        planningError = nil
        let task = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: .milliseconds(150))
            let scope = DirectoryAccess(url)
            defer { withExtendedLifetime(scope) {} }
            return try BatchPlanner.plan(inputs, output: url, names: overrides)
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
        issues = []; selection = []; status = "Add documents or drop files and folders here."; replan()
    }

    func cancel() {
        cancelIntake()
        if isPreparingModel { preparationStatus = "Cancelling preparation… waiting for the helper to stop."; preparationTask?.cancel() }
        if isGenerating { generationStatus = "Cancelling… waiting for native workers to stop."; generationTask?.cancel() }
    }

    func cancelIntake() {
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
        let task = Task.detached(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Reading a Libro document")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            return try DocumentReader.read(document)
        }
        reader = task
        Task {
            do {
                let text = try await task.value
                guard operation == token else { return }
                preview = Preview(id: document.id, title: document.source.lastPathComponent, text: text)
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

    func probe() {
        guard !busy, !isGenerating, !isPreparingModel, probeProcess == nil else { return }
        let token = UUID(); operation = token
        busy = true; probeCancelled = false; status = "Checking embedded Metal runtime…"
        do {
            // Spawn on the owning actor before any quit event can arrive.
            let (process, output, ended) = try startProbe()
            probeProcess = process
            Task {
                let result = await Task.detached { finishProbe(process, output: output, ended: ended) }.value
                if probeProcess === process { probeProcess = nil }
                if operation == token { status = probeCancelled ? "Worker probe cancelled." : result; busy = false }
            }
        } catch {
            status = "Unable to launch the embedded worker: \(error.localizedDescription)"; busy = false
        }
    }

    func refreshReadiness() {
        guard !isPreparingModel else { return }
        readinessTask?.cancel(); readinessTask = nil
        let token = UUID(); readinessOperation = token
        assetsReady = false; checkingAssets = false; readinessScopes = []
        guard let root = workspace?.url else {
            readiness = workspace?.error ?? "Choose the Libro workspace containing models."
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
            return ("\(selected.model.rawValue.capitalized) ready for local generation.", voices)
        }
        readinessTask = task
        Task {
            do {
                let (message, available) = try await task.value
                guard readinessOperation == token else { return }
                readiness = message; assetsReady = true
                if selected.model == .kokoro { voices = available }
            } catch is CancellationError {}
            catch { if readinessOperation == token { readiness = error.localizedDescription } }
            if readinessOperation == token { checkingAssets = false; readinessTask = nil; readinessScopes = [] }
        }
    }

    func prepareModel() {
        guard canPrepareModel, let root = workspace?.url else { return }
        let selected = settings
        let token = UUID(); preparationOperation = token
        isPreparingModel = true; assetsReady = false; preparationProgress = nil
        preparationStatus = "Checking \(selected.model.rawValue.capitalized) assets in \(root.path)."
        preparationScopes = [DirectoryAccess(root)]
        let log = makeDebugLog(root)
        log?.record("preparation started model=\(selected.model.rawValue) revision=\(NativePrimaryCatalog.specification(for: selected.model).revision)")
        let configuration = WorkerConfiguration(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker"), requestTimeout: .seconds(1_800), debugLog: log)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Preparing user-requested Libro models")
        preparationTask = Task { [self] in
            do {
                try await ModelPreparation.run(configuration: configuration, workspace: root, settings: selected) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isPreparingModel, self.preparationOperation == token else { return }
                        self.preparationProgress = value
                        let scope = value.scope == .primary ? selected.model.rawValue.capitalized : "English pronunciation assets"
                        self.preparationStatus = "\(value.phase.rawValue.capitalized) \(scope)…"
                    }
                }
                preparationStatus = "\(selected.model.rawValue.capitalized) preparation complete. Generation uses local assets."
            } catch is CancellationError {
                preparationStatus = "Preparation cancelled. Completed asset files remain available for reuse."
            } catch { preparationStatus = error.localizedDescription }
            log?.record("preparation settled: \(preparationStatus)")
            if log?.writeFailed == true { debugLogStatus = "Debug logging stopped because its file could not be written. Processing was unaffected." }
            ProcessInfo.processInfo.endActivity(activity)
            preparationOperation = UUID(); isPreparingModel = false; preparationTask = nil; preparationScopes = []
            preparationProgress = nil
            announce(preparationStatus)
            refreshReadiness()
        }
    }

    func stopPreparation() async {
        preparationTask?.cancel()
        await preparationTask?.value
    }

    func generate() {
        guard canGenerate, let destination = output?.url, let root = workspace?.url else { return }
        let plans = planned
        let replacements = plans.filter(\.replacesExisting)
        var approved = false
        if !replacements.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace \(replacements.count) existing WAV outputs?"
            alert.informativeText = "These destinations already contain audio. Libro will replace them only after complete recordings are ready. Failed or cancelled documents preserve their previous outputs."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Replace and Generate")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            approved = true
        }
        let request = BatchRequest(documents: plans, outputDirectory: destination, workspace: root,
                                   settings: settings, serial: serial, replaceExisting: approved)
        let log = makeDebugLog(root)
        log?.record("batch=\(request.id) started documents=\(plans.count) model=\(settings.model.rawValue) voice=\(settings.voice) speed=\(settings.speed) serial=\(serial) app=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        activeBatch = request; speechProgress = nil; batchSummary = nil; notificationSummary = nil
        retryQueued.subtract(request.documents.map(\.id))
        for document in request.documents { outcomes[document.id] = nil; states[document.id] = "Waiting" }
        let outputScope = DirectoryAccess(destination)
        batchScopes = Array(scopes.values) + [outputScope, DirectoryAccess(root)]
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Generating user-requested Libro audio")
        generationStatus = "Preparing batch. Closing the window keeps processing; quitting offers cancellation."
        Self.logger.info("Starting batch \(request.id.uuidString, privacy: .public), documents \(request.documents.count)")
        let updates = LatestSpeechProgress()
        progressTask = Task {
            while !Task.isCancelled {
                if let value = updates.take() { receive(.speech(value)) }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        requestNotificationAuthorization()
        generationTask = Task { [self] in
            do {
                let summary = try await coordinator.run(request, debugLog: log) { [weak self] event in
                    if case .speech(let value) = event, value.phase == .chunkWritten { updates.store(value) }
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
            activeBatch = nil; speechProgress = nil; batchScopes = []
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            generationTask = nil; status = generationStatus
            replan()
        }
        replan()
    }

    private func receive(_ event: BatchEvent) {
        guard let batch = activeBatch else { return }
        switch event {
        case .preparing(let id, let job) where id == batch.id:
            states[job] = "Preparing text…"
            speechProgress = nil
            generationStatus = "Preparing \(batch.documents.first { $0.id == job }?.input.source.lastPathComponent ?? "document")…"
        case .speech(let value) where value.identity.batch == batch.id:
            guard outcomes[value.identity.job] == nil else { return }
            if let current = speechProgress, current.identity.job == value.identity.job {
                guard value.attemptNumber >= current.attemptNumber else { return }
                if value.attemptNumber == current.attemptNumber, value.completedChunks < current.completedChunks { return }
            }
            speechProgress = value
            let name = batch.documents.first { $0.id == value.identity.job }?.input.source.lastPathComponent ?? "document"
            if value.phase == .publishing {
                states[value.identity.job] = "Saving…"; generationStatus = "Saving \(name)…"
            } else {
                let attempt = value.attemptNumber == 2 ? "Serial retry" : (value.workerCount == 2 ? "Automatic" : "Serial")
                states[value.identity.job] = "\(attempt): \(value.completedChunks)/\(value.totalChunks) chunks"
                generationStatus = "\(name) — \(attempt), \(value.completedChunks) of \(value.totalChunks) chunks."
                if value.phase == .attemptStarted, value.attemptNumber == 2 { announce("Retrying the current document serially.") }
            }
        case .document(let id, let outcome) where id == batch.id:
            outcomes[outcome.id] = outcome
            if outcome.state == .published { savedNames[outcome.id] = batch.documents.first { $0.id == outcome.id }?.relativeOutput }
            if outcome.state == .failed { announce("A document failed. See its queue row for details.") }
        default: break // Completion notifications come only after run() returns.
        }
    }

    func stopGeneration() async {
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
        return activeBatch?.documents.first { $0.id == document.id }?.relativeOutput ?? names[document.id] ?? BatchPlanner.defaultOutput(document)
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

    func stopPlayback() { playbackTask?.cancel(); playbackTask = nil; player?.stop(); player = nil; playingDocument = nil }

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

private final class LatestSpeechProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpeechProgress?
    func store(_ value: SpeechProgress) { lock.withLock { self.value = value } }
    func take() -> SpeechProgress? { lock.withLock { let result = value; value = nil; return result } }
}

private struct Preview: Identifiable { let id: UUID; let title: String; let text: String }

private struct IntakeView: View {
    @Bindable var model: IntakeModel
    @State private var dropTarget = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isGenerating { Text("Next batch settings").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Picker("Model", selection: $model.settings.model) {
                    Text("Kokoro").tag(SpeechModel.kokoro)
                    Text("Soprano").tag(SpeechModel.soprano)
                }.frame(maxWidth: 180)
                if model.settings.model == .kokoro {
                    Picker("Voice", selection: $model.settings.voice) {
                        ForEach(model.voices, id: \.self) { voice in Text(voice).tag(voice) }
                    }.frame(maxWidth: 220)
                    Stepper(value: $model.settings.speed, in: 0.5...2, step: 0.1) {
                        Text("Speed \(model.settings.speed, format: .number.precision(.fractionLength(1)))×")
                    }.fixedSize()
                }
                Spacer(minLength: 8)
                Picker("Generation", selection: $model.serial) {
                    Text("Automatic").tag(false)
                    Text("Serial").tag(true)
                }.frame(maxWidth: 180)
            }.disabled(model.isPreparingModel)
            HStack {
                Button("Prepare Model") { model.prepareModel() }.disabled(!model.canPrepareModel)
                    .help("Explicitly verify/reuse or download the selected model and required pronunciation assets into this Libro workspace")
                if model.isPreparingModel { Button("Cancel Preparation") { model.cancel() } }
                Text(model.preparationStatus).font(.callout).textSelection(.enabled)
            }
            let primary = NativePrimaryCatalog.specification(for: model.settings.model)
            Text("\(primary.repository) · revision \(primary.revision)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let value = model.preparationProgress {
                ProgressView(value: Double(value.completedBytes), total: Double(value.totalBytes)) {
                    Text("\(ByteCountFormatter.string(fromByteCount: value.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: value.totalBytes, countStyle: .file))")
                }.accessibilityLabel(model.preparationStatus)
            }
            directoryRow("Libro workspace:", selection: model.workspace, role: .workspace)
            directoryRow(model.isGenerating ? "Next batch saves to:" : "Save audio to:", selection: model.output, role: .output)
            if let batch = model.activeBatch {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current batch saves to: \(batch.outputDirectory.path)").textSelection(.enabled)
                    Text("\(batch.settings.model.rawValue.capitalized) · \(batch.serial ? "Serial" : "Automatic") · \(batch.documents.count) documents. Closing this window keeps processing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if model.checkingAssets { ProgressView().controlSize(.small) }
                Label(model.readiness, systemImage: model.assetsReady ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.assetsReady ? Color.primary : Color.secondary).font(.callout)
            }
            if model.displayedDocuments.isEmpty {
                ContentUnavailableView("Add documents", systemImage: "doc.badge.plus", description: Text("Drop TXT, Markdown, RTF, PDF files, or folders. Subfolders are included."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.displayedDocuments, selection: $model.selection) {
                    TableColumn("Document") { document in
                        VStack(alignment: .leading) {
                            Text(document.source.lastPathComponent)
                            Text((document.relativePath as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }.help(document.source.path)
                    }
                    TableColumn("Type") { Text($0.kind.rawValue.uppercased()) }.width(70)
                    TableColumn("Output name") { document in
                        TextField("Relative WAV name", text: Binding(get: { model.outputName(document) }, set: { model.names[document.id] = $0; model.replan() }))
                            .accessibilityLabel("Output name for \(document.source.lastPathComponent)")
                            .disabled(model.activeIDs.contains(document.id) || (model.outcomes[document.id]?.state == .published && !model.retryQueued.contains(document.id)))
                            .help(model.outputDestinationHint(document))
                    }
                    TableColumn("Status") { document in Text(model.rowStatus(document)).lineLimit(3).help(model.rowStatus(document)) }
                        .width(min: 110, ideal: 160, max: 220)
                    TableColumn("Preview") { document in
                        Button("Read Text") { model.showPreview(document) }.disabled(model.busy)
                            .accessibilityLabel("Preview text of \(document.source.lastPathComponent)")
                    }.width(90)
                    TableColumn("Audio") { document in
                        if let outcome = model.outcomes[document.id] {
                            if outcome.state == .published {
                                HStack {
                                    Button(model.playingDocument == document.id ? "Stop" : "Play", systemImage: model.playingDocument == document.id ? "stop.fill" : "play.fill") { model.play(document) }
                                        .labelStyle(.iconOnly).help("Play or stop saved audio")
                                        .accessibilityLabel("\(model.playingDocument == document.id ? "Stop" : "Play") audio for \(document.source.lastPathComponent)")
                                    Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([outcome.destination]) }
                                        .labelStyle(.iconOnly).help(outcome.destination.path).accessibilityLabel("Reveal audio for \(document.source.lastPathComponent)")
                                }.accessibilityElement(children: .contain)
                            } else {
                                VStack {
                                    if outcome.state == .failed { Button("Details") { model.showFailure(document) } }
                                    Button("Retry") { model.retry(document) }.disabled(model.retryQueued.contains(document.id))
                                        .help("Queue this document for the next batch")
                                }
                            }
                        }
                    }.width(90)
                }
            }
            if let error = model.planningError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if let error = model.dropError { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            if let message = model.debugLogStatus { Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            if model.planning { ProgressView("Checking output destinations…").controlSize(.small) }
            if model.planned.contains(where: \.replacesExisting) {
                Label("\(model.planned.filter(\.replacesExisting).count) existing WAVs share these destinations. Replacement confirmation will be required before generation.", systemImage: "doc.on.doc")
            }
            if !model.issues.isEmpty {
                DisclosureGroup("Input errors (\(model.issues.count))") {
                    ScrollView { ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.source.lastPathComponent): \(issue.message)").frame(maxWidth: .infinity, alignment: .leading)
                    } }.frame(maxHeight: 100)
                }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel(model.activityStatus); Button(model.inputCancelLabel) { model.cancelIntake() } }
                Text(model.activityStatus).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Verify Embedded Worker") { model.probe() }.disabled(model.busy || model.hasOwnedProbe || model.isGenerating || model.isPreparingModel)
            }
            if model.isGenerating {
                Text(model.generationStatus).textSelection(.enabled)
                if let progress = model.speechProgress {
                    ProgressView(value: Double(progress.completedChunks), total: Double(progress.totalChunks))
                        .accessibilityLabel("Current document chunks").accessibilityValue("\(progress.completedChunks) of \(progress.totalChunks)")
                } else { ProgressView("Preparing current document…").controlSize(.small) }
            }
            if let summary = model.batchSummary {
                Label("\(summary.cancelled ? "Cancelled" : "Complete"): \(summary.successfulCount) saved; \(summary.failedCount) failed.",
                      systemImage: summary.cancelled ? "stop.circle" : (summary.failedCount > 0 ? "exclamationmark.circle" : "checkmark.circle"))
            }
            if let summary = model.notificationSummary { Text(summary).font(.callout) }
            if let notificationStatus = model.notificationStatus { Text(notificationStatus).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(model.isGenerating ? "\(model.candidates.count) documents waiting for the next batch." : "\(model.candidates.count) documents queued for generation.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.outcomes.values.contains(where: { $0.state != .published }) {
                    Button("Queue Unfinished") { model.retryUnfinished() }.help("Queue failed or cancelled documents for the next batch")
                }
                if model.isGenerating { Button("Cancel Processing") { model.cancel() } }
                Button("Generate Audio") { model.generate() }.buttonStyle(.borderedProminent).disabled(!model.canGenerate)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in model.importDrop(providers) }
        .toolbar {
            Button("Add Files…", systemImage: "doc.badge.plus") { model.openInputs() }
            Button("Add Folder…", systemImage: "folder.badge.plus") { model.openInputs(foldersOnly: true) }
            Button("Remove Selected", systemImage: "minus") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy || model.isGenerating)
            Button("Clear Finished") { model.clearFinished() }.disabled(!model.hasFinished || model.busy || model.isGenerating)
        }
        .onAppear { model.reopenWindow = { openWindow(id: "main") }; model.replan() }
        .onChange(of: model.settings.model) { model.refreshReadiness() }
        .onChange(of: model.settings.voice) { model.refreshReadiness() }
        .sheet(item: $model.failureDetails) { details in
            VStack(alignment: .leading, spacing: 16) {
                Text("Generation failed: \(details.name)").font(.headline)
                Text(details.message).textSelection(.enabled)
                Text("Job: \(details.id.uuidString)").font(.caption).textSelection(.enabled)
                if let url = model.debugLogURL {
                    Button("Open Debug Log") { NSWorkspace.shared.open(url) }
                }
                Text("For more detail, enable debug logging in Libro Settings before retrying. The log stays in the selected workspace.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Done") { model.failureDetails = nil }.keyboardShortcut(.defaultAction)
            }.padding().frame(width: 560)
        }
        .sheet(item: $model.preview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.title).font(.headline)
                Text("PDF reading order and repeated headers may need review.").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(preview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Done") { model.preview = nil }.keyboardShortcut(.defaultAction)
            }.padding().frame(minWidth: 560, minHeight: 420)
                .onExitCommand { model.preview = nil }
        }
    }

    private func directoryRow(_ label: String, selection: DirectorySelection?, role: DirectoryRole) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 150, alignment: .leading)
            VStack(alignment: .leading) {
                Text(selection?.displayPath ?? "Choose a folder…").textSelection(.enabled)
                    .lineLimit(2).help(selection?.displayPath ?? label)
                    .accessibilityLabel("\(label) \(selection?.displayPath ?? "No folder selected")")
                if let error = selection?.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let url = selection?.url { Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) } }
            Button("Browse…") { model.browse(role) }.disabled(model.busy || (role == .workspace && model.isPreparingModel)).accessibilityLabel("Browse for \(role.rawValue) folder")
        }
    }
}

private struct WindowAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AutosaveView() }
    func updateNSView(_ view: NSView, context: Context) { }
    private final class AutosaveView: NSView {
        private var restored = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, !restored {
                restored = true
                window.setFrameUsingName("Libro.main")
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
                }
                window.setFrameAutosaveName("Libro.main")
            }
        }
    }
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
