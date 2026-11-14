import Foundation
import VoiceRelayCore

enum AppHealthStatus: Equatable {
    case ready
    case needsSetup(String, SettingsSection)
    case failure(String, SettingsSection)
    var title: String {
        switch self {
        case .ready: "Ready"
        case .needsSetup(let message, _), .failure(let message, _): message
        }
    }
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .needsSetup: "arrow.down.circle"
        case .failure: "xmark.circle.fill"
        }
    }
    var settingsSection: SettingsSection? {
        switch self {
        case .failure(_, let section), .needsSetup(_, let section): return section
        default: return nil
        }
    }
}

@MainActor
extension AppModel {
    /// Actionable issues only: menu Ready means nothing needs the user's
    /// attention, not that every service finished verifying. Transient checks,
    /// in-flight work and unverified states stay quiet; a recorded error stays
    /// visible even while its recheck runs. Reading this never performs checks.
    var appHealth: AppHealthStatus {
        if libraryReviewRequired { return .failure("Library review required", .troubleshooting) }
        if sourceReview.plist == nil { return .failure("Reading List needs setup", .general) }
        if sourceReview.error != nil { return .failure("Reading List unavailable", .general) }
        if runtimeVerificationFailed { return .failure("Speech setup needs attention", .voiceModel) }
        if !runtimeBusy && !preview && !speechRuntimeInstalled { return .needsSetup("Set up speech", .voiceModel) }
        if case .failure = runtimeTestResult { return .failure("Speech setup check failed", .voiceModel) }
        if !deliverySettings.enabled { return .failure("Publishing is off", .delivery) }
        if (try? deliverySettings.validate()) == nil { return .failure("Publishing needs setup", .delivery) }
        if deliveryError != nil { return .failure("Publishing needs attention", .delivery) }
        if case .failure = deliveryTestResult { return .failure("Publishing check failed", .delivery) }
        if deliveryPasswordChecked && !deliveryPasswordStored && !deliveryCredentialBusy { return .failure("Publishing password missing", .delivery) }
        return .ready
    }
    /// Read existing presentation state only. This never queries Keychain or the network.
    var publishingReadiness: PublishingReadiness {
        var required = deliverySettings
        required.enabled = true
        if required.feedFolderURL == nil || required.publicFolderURL == nil || (try? required.validate()) == nil {
            return .needsSetup
        }
        if !deliverySettings.enabled { return .turnedOff }
        if deliveryPreflightBusy { return .checking }
        if deliveryError != nil || uploadsNeedAttention { return .needsAttention }
        if !deliveryPasswordChecked { return .notChecked }
        return deliveryPasswordStored ? .configured : .needsSetup
    }
    /// Publishing failures must retain their Settings route alongside outbox issues.
    var publishingSettingsNotice: PublishingReadiness? {
        if publishingReadiness == .checking { return nil }
        if deliveryError != nil { return .needsAttention }
        if uploadsNeedAttention || publishingReadiness == .configured { return nil }
        return publishingReadiness
    }
    var eligibleGenerationCount: Int { readyQueueCount + pendingAdds.count }
    /// Idle setup and errors have dedicated notices; the footer is only for owned work.
    var showsWorkspaceActivity: Bool { showsProcessingProgress || deliveryBusy || audioMutationBusy || !hiddenServerAudioRemovalIDs.isEmpty }
    var generationDisabledReason: String? {
        if sourcePruningBusy { return "Clearing removed articles from the library." }
        if libraryReviewRequired { return "Review the restored library before processing resumes." }
        if deliveryPreflightBusy { return "Checking the existing server feed before processing resumes." }
        if libraryMaintenanceBusy { return "Wait for library maintenance to finish." }
        if stopping { return "VoiceRelay is quitting; owned work is stopping." }
        if runtimeBusy { return "Wait for speech setup to finish, or cancel it in Voice Model." }
        if !preview && !speechRuntimeAvailable && (readyQueueCount == 0 || !FileManager.default.isExecutableFile(atPath: NativeSpeechSetup.workerExecutable.path)) { return "Speech setup is required before generating audio." }
        if !deliveryServerChecked { return "Set up Publishing and let its server check finish before generating audio." }
        if cancelling { return "Stopping… Wait for owned work to finish." }
        if running { return "Audio work is already running." }
        if audioMutationBusy || sourceReview.maintenanceSuspended { return "Waiting for library changes to finish." }
        if eligibleGenerationCount == 0 { return "No Ready articles. Add articles or retry a failed item." }
        return nil
    }
}

