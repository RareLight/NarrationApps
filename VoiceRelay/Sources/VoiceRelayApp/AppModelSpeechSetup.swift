import NarrationUI
import VoiceRelayCore
import Foundation
import NativeSpeech
import AppKit

@MainActor
extension AppModel {
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
    var speechRuntimeAvailable: Bool { !runtimeVerificationFailed && speechRuntimeInstalled }
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
        if running || processingSpeech || cancelling { return "Stop audio generation before checking speech setup or installing a model." }
        if libraryMaintenanceBusy { return "Wait for library maintenance to finish." }
        return nil
    }
    var canManageSpeechRuntime: Bool { runtimeControlDisabledReason == nil }
    func checkSpeechRuntime() {
        beginRuntimeSetup(install: false)
    }
    func installSpeechRuntime() {
        beginRuntimeSetup(install: true)
    }
    private func beginRuntimeSetup(install: Bool) {
        guard canManageSpeechRuntime else { return }
        let root = runtimeProject
        pronunciationPreview.stop()
        runtimeBusy = true; runtimeInstalling = install; runtimeTestResult = .untested
        let operation: DeliveryDebugLog.Event.RuntimeOperation = install ? .installation : .check
        deliveryDebugLog.record(.speechRuntime(operation, .started))
        let selected = preferences.modelSelection
        let perform = runtimeSetupOverride
        runtimeTask = Task { [weak self] in
            guard let self else { return }
            defer { runtimeTask = nil; runtimeBusy = false; modelStorageRevision += 1; maybeAutoProcess() }
            await pronunciationPreview.stopAndWait()
            let worker = Task.detached {
                if let perform { try perform(install, root) }
                else if install { try NativeSpeechSetup.install(at: root, settings: selected) }
                else { try NativeSpeechSetup.check(at: root, settings: selected) }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard !stopping else { return }
                if install {
                    runtimeProject = root
                    if root.resolvingSymlinksInPath().path == NativeModelStorage.defaultRoot.path { defaults.removeObject(forKey: "runtimeProject") }
                    else { defaults.set(root.path, forKey: "runtimeProject") }
                }
                runtimeVerificationFailed = false
                runtimeTestResult = .success
                deliveryDebugLog.record(.speechRuntime(operation, .verified))
            } catch is CancellationError {
                guard !stopping else { return }
                runtimeTestResult = .cancelled
                deliveryDebugLog.record(.speechRuntime(operation, .cancelled))
            } catch {
                guard !stopping else { return }
                if root.standardizedFileURL == runtimeProject.standardizedFileURL { runtimeVerificationFailed = true }
                let guidance = install
                    ? "The speech model could not be installed. Check your internet connection and available disk space, then retry."
                    : "Speech setup could not be verified offline. Check that the speech model is installed, or install it again."
                runtimeTestResult = .failure((error as? RelayError)?.localizedDescription ?? guidance)
                deliveryDebugLog.record(.speechRuntime(operation, .failed))
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
