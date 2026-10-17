import Foundation
import VoiceRelayCore

@MainActor
extension AppModel {
    var canSyncNow: Bool {
        !preview && !stopping && !syncBusy && !cancelling && !libraryReviewRequired
            && !libraryMaintenanceBusy && !sourcePruningBusy && !audioMutationBusy && !runtimeBusy && !deliveryCredentialBusy
    }
    /// One manual round trip, without changing persisted automation preferences.
    func syncNow() {
        guard canSyncNow else { return }
        syncBusy = true; syncPreparing = true; syncPhase = .readingList
        syncTask = Task {
            defer { syncTask = nil; syncBusy = false; syncPreparing = false; syncPhase = nil }
            do {
                guard await sourceReview.refreshSource() else { return }
                try Task.checkCancellation()
                await waitForSourcePruning()
                refreshLibrary(allowDelivery: false); await waitForLibraryRefresh()
                try Task.checkCancellation()
                // Manual Sync retries credential access and the current feed check,
                // while retaining valid media proofs and ordinary upload backoff.
                syncPhase = .reconciling
                triggerDelivery(reconcileNow: true); await waitForDelivery()
                try Task.checkCancellation()
                syncPhase = .preparing
                await autoAdmitNewEntries(explicit: true)
                await waitForEnqueue()
                syncPhase = .generating
                await waitForProcessing()
                await waitForAudioMutation()
                await waitForLibraryRefresh()
                try Task.checkCancellation()
                if runtimeTestResult != .success && canManageSpeechRuntime {
                    syncPhase = .speechCheck
                    checkSpeechRuntime(); await waitForRuntimeSetup()
                }
                try Task.checkCancellation()
                syncPreparing = false
                syncPhase = .generating
                if canGenerateAudio { runQueue(); await waitForProcessing() }
                try Task.checkCancellation()
                syncPhase = .publishing
                triggerDelivery(); await waitForDelivery()
                await waitForLibraryRefresh()
            } catch is CancellationError {
            } catch { self.error = "Sync could not finish; saved progress is retained." }
        }
    }
    var syncProgressLabel: String {
        if syncPhase == .reconciling || syncPhase == .publishing,
           let transfer = uploadProgress.values.first(where: { $0.phase.active }) { return transfer.phase.title }
        return syncPhase?.rawValue ?? "Syncing…"
    }
    /// Measured generation or current-file transfer progress, never an overall estimate.
    var syncProgressFraction: Double? {
        guard syncBusy else { return nil }
        if syncPhase == .generating { return processingFraction }
        if syncPhase == .reconciling || syncPhase == .publishing {
            return uploadProgress.values.first(where: { $0.phase == .transferring })?.fraction
        }
        return nil
    }
}
