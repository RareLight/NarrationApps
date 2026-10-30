import NarrationUI
import NarrationCore
import VoiceRelayCore
import Foundation
import NativeSpeech
import ProcessingPipeline
import AppKit

@MainActor
extension AppModel {
    var speechSetupValidation: SpeechSetupValidation {
        if let existing = speechSetupValidationStorage { return existing }
        let created = SpeechSetupValidation(inspect: { [weak self] target in
                if let installed = self?.runtimeInstalledOverride { return installed(target.root) }
                return try await SpeechSetupValidation.defaultInspect(target)
            }, check: { [weak self] target in
                let perform = self?.runtimeSetupOverride
                let worker = Task.detached(priority: .utility) {
                    if let perform { try perform(false, target.root, target.settings, { _ in }) }
                    else { try NativeSpeechSetup.check(at: target.root, settings: target.settings) }
                }
                do {
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as RelayError {
                    throw error
                } catch {
                    throw RelayError.setup("Speech setup could not be verified offline. Check that the speech model is installed, or repair the local model.")
                }
            })
        speechSetupValidationStorage = created
        return created
    }
    var speechSetupStatus: SpeechSetupStatus {
        switch runtimeTestResult {
        case .untested: speechRuntimeInstalled ? .notChecked : .notInstalled
        case .success: .ready
        case .cancelled: .cancelled
        case .failure(let message): .failure(message)
        }
    }
    var pronunciationUnavailableReason: String? {
        guard pronunciationConfiguration == nil else { return nil }
        if running || runtimeBusy || stopping { return NarrationSettingsHelp.previewBusy }
        if runtimeVerificationFailed { return NarrationSettingsHelp.previewCheckNeeded }
        return speechRuntimeAvailable ? NarrationSettingsHelp.previewBusy : NarrationSettingsHelp.previewModelMissing
    }

    var speechRuntimeInstalled: Bool {
        if let runtimeInstalledOverride { return runtimeInstalledOverride(runtimeProject) }
        return storageOverride != nil || backendOverride != nil || NativeSpeechSetup.isInstalled(at: runtimeProject, settings: preferences.modelSelection)
    }
    var speechRuntimeAvailable: Bool {
        if speechValidationStarted { return speechSetupValidation.result == .ready }
        return !runtimeVerificationFailed && speechRuntimeInstalled
    }
    var speechSetupValidating: Bool { speechValidationStarted && speechSetupValidation.hasOwnedWork }
    var speechSetupHeaderPresented: Bool {
        !preview && (runtimeBusy || (speechValidationStarted ? speechSetupValidation.result == .notInstalled : !speechRuntimeAvailable))
    }
    var speechSetupFailureDetail: String? {
        guard !runtimeBusy, case .failure(let message) = runtimeTestResult else { return nil }
        return message
    }
    var canManageLibrary: Bool {
        !modelStorage.isBusy && !syncBusy && !sourcePruningBusy && !preview && !stopping && !running && !runtimeBusy && !libraryMaintenanceBusy && pendingAdds.isEmpty
            && !queueMutationBusy && !audioMutationBusy && !deliveryBusy && !deliveryTesting
            && !deliveryCredentialBusy && !sourceReview.busy && !sourceReview.maintenanceSuspended && libraryTask == nil
    }
    /// Speech setup is independent of server operations and short library metadata writes.
    var runtimeControlDisabledReason: String? {
        if preview || (storageOverride != nil && runtimeSetupOverride == nil) { return "Unavailable in this isolated model." }
        if modelStorage.isBusy { return "Deleting a model." }
        if stopping { return "VoiceRelay is quitting." }
        if runtimeBusy { return "Speech setup is in progress." }
        if speechValidationStarted && speechSetupValidation.hasOwnedWork { return "Speech setup validation is running." }
        if running || processingSpeech || cancelling { return "Stop audio generation before checking speech setup or installing a model." }
        if libraryMaintenanceBusy { return "Wait for library maintenance to finish." }
        return nil
    }
    var canManageSpeechRuntime: Bool { runtimeControlDisabledReason == nil }
    func startSpeechSetupValidation() {
        guard !preview, !stopping else { return }
        speechValidationStarted = true
        if speechSetupActivationObserver == nil {
            speechSetupActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.speechSetupDidBecomeActive() }
            }
        }
        applySpeechSetupObservation()
    }
    func checkSpeechRuntime() {
        guard !preview else { return }
        if !speechValidationStarted { startSpeechSetupValidation(); return }
        if case .ready = speechSetupValidation.result {} else { speechCheckEpoch += 1 }
        applySpeechSetupObservation()
    }
    private func speechSetupTarget() -> SpeechSetupValidation.Target? {
        .init(root: runtimeProject, settings: preferences.modelSelection,
              revision: modelStorageRevision + modelStorage.revision + speechCheckEpoch)
    }
    private func speechSetupPermitted() -> Bool {
        !preview && !stopping && !runtimeBusy && !running && !processingSpeech && !cancelling
            && !pronunciationPreview.hasOwnedWork && !libraryMaintenanceBusy && !modelStorage.isBusy
    }
    func speechSetupDidBecomeActive() {
        guard !preview, !stopping else { return }
        if !speechValidationStarted { startSpeechSetupValidation(); return }
        if !speechSetupValidation.hasOwnedWork { speechCheckEpoch += 1 }
        applySpeechSetupObservation()
    }
    func applySpeechSetupObservation() {
        guard speechValidationStarted, !stopping else { return }
        speechSetupObserverGeneration += 1
        let generation = speechSetupObserverGeneration
        var target: SpeechSetupValidation.Target?
        var permitted = false
        withObservationTracking {
            target = self.speechSetupTarget()
            permitted = self.speechSetupPermitted()
            _ = (self.speechSetupValidation.result, self.speechSetupValidation.target,
                 self.speechSetupValidation.hasOwnedWork)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.speechSetupObserverGeneration == generation else { return }
                self.applySpeechSetupObservation()
            }
        }
        speechSetupValidation.update(target: target, permitted: permitted)
        propagateSpeechSetupResult()
    }
    private func propagateSpeechSetupResult() {
        guard !runtimeBusy else { return }
        switch speechSetupValidation.result {
        case .ready:
            runtimeTestResult = .success; runtimeVerificationFailed = false
            maybeAutoProcess()
        case .failure(let message):
            runtimeTestResult = .failure(message); runtimeVerificationFailed = true
        case .notInstalled, .idle, .checking:
            runtimeTestResult = .untested; runtimeVerificationFailed = false
        }
    }
    func installSpeechRuntime() {
        beginRuntimeSetup(install: true)
    }
    private func beginRuntimeSetup(install: Bool) {
        guard canManageSpeechRuntime else { return }
        let root = runtimeProject
        pronunciationPreview.stop()
        runtimeBusy = true; runtimeInstalling = install; runtimeTestResult = .untested
        runtimeSetupProgress = nil
        let token = UUID(); runtimeSetupOperation = token
        let operation: DeliveryDebugLog.Event.RuntimeOperation = install ? .installation : .check
        deliveryDebugLog.record(.speechRuntime(operation, .started))
        let selected = preferences.modelSelection
        let perform = runtimeSetupOverride
        runtimeTask = Task { [weak self] in
            guard let self else { return }
            var outcome: SpeechSetupValidation.Result?
            defer {
                runtimeTask = nil; runtimeBusy = false
                runtimeSetupProgress = nil; runtimeSetupOperation = UUID()
                modelStorageRevision += 1
                if let outcome, let target = self.speechSetupTarget() {
                    speechSetupValidation.update(target: target, permitted: false)
                    speechSetupValidation.record(outcome, for: target)
                }
                applySpeechSetupObservation()
                maybeAutoProcess()
            }
            await pronunciationPreview.stopAndWait()
            speechSetupValidation.update(target: nil, permitted: false)
            await speechSetupValidation.waitForIdle()
            let report: @Sendable (ModelPreparationProgress) -> Void = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.runtimeBusy, self.runtimeInstalling,
                          self.runtimeSetupOperation == token else { return }
                    self.runtimeSetupProgress = value
                }
            }
            let worker = Task.detached {
                if let perform { try perform(install, root, selected, report) }
                else { try NativeSpeechSetup.install(at: root, settings: selected, progress: report) }
            }
            let stampCurrent = { [weak self] in
                guard let self, self.runtimeSetupOperation == token else { return false }
                return self.preferences.modelSelection.model == selected.model
                    && self.preferences.modelSelection.voice == selected.voice
                    && self.preferences.modelSelection.effectiveLanguage == selected.effectiveLanguage
                    && self.runtimeProject.standardizedFileURL == root.standardizedFileURL
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard !stopping, stampCurrent() else { return }
                if install {
                    if root.resolvingSymlinksInPath().path == NativeModelStorage.defaultRoot.path { defaults.removeObject(forKey: "runtimeProject") }
                    else { defaults.set(root.path, forKey: "runtimeProject") }
                }
                runtimeVerificationFailed = false
                runtimeTestResult = .success
                deliveryDebugLog.record(.speechRuntime(operation, .verified))
                outcome = .ready
            } catch is CancellationError {
                guard !stopping else { return }
                runtimeTestResult = .cancelled
                deliveryDebugLog.record(.speechRuntime(operation, .cancelled))
            } catch {
                guard !stopping, stampCurrent() else { return }
                runtimeVerificationFailed = true
                let guidance = install
                    ? "The speech model could not be installed. Check your internet connection and available disk space, then retry."
                    : "Speech setup could not be verified offline. Check that the speech model is installed, or install it again."
                let message = (error as? RelayError)?.localizedDescription ?? guidance
                runtimeTestResult = .failure(message)
                deliveryDebugLog.record(.speechRuntime(operation, .failed))
                outcome = .failure(message)
            }
        }
    }
    func chooseModelStorage() {
        guard canManageSpeechRuntime else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a model storage folder."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url, self.canManageSpeechRuntime else { return }
            do {
                try NativeModelStorage.prepareRoot(url)
                self.runtimeProject = url
                if url.resolvingSymlinksInPath().path == NativeModelStorage.defaultRoot.path { self.defaults.removeObject(forKey: "runtimeProject") }
                else { self.defaults.set(url.path, forKey: "runtimeProject") }
                self.runtimeVerificationFailed = false; self.runtimeTestResult = .untested
                self.modelStorageRevision += 1
                self.applySpeechSetupObservation()
            } catch { self.runtimeTestResult = .failure(error.localizedDescription) }
        }
    }
    func useDefaultModelStorage() {
        guard canManageSpeechRuntime else { return }
        runtimeProject = NativeModelStorage.defaultRoot; defaults.removeObject(forKey: "runtimeProject")
        runtimeVerificationFailed = false; runtimeTestResult = .untested; modelStorageRevision += 1
    }
    func cancelRuntimeSetup() { runtimeTask?.cancel() }
}
