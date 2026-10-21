import Foundation

/// Transient progress is separate from durable upload/publication confirmations.
public struct UploadProgress: Sendable {
    public let episode: Episode
    public let phase: UploadPhase
    public let sentBytes: Int64?
    public let totalBytes: Int64?
    public init(episode: Episode, phase: UploadPhase, sentBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.episode = episode; self.phase = phase; self.sentBytes = sentBytes; self.totalBytes = totalBytes
    }
    public var fraction: Double? {
        guard phase == .transferring, let sentBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(sentBytes) / Double(totalBytes)))
    }
}
public enum UploadPhase: String, Sendable, CaseIterable {
    case waiting, verifyingLocal, transferring, verifyingServer, publishing
    case failed, verificationFailed, localConflict, discarded, published, removing, removalFailed
    public var title: String {
        switch self {
        case .waiting: "Awaiting upload"
        case .verifyingLocal: "Verifying local audio"
        case .transferring: "Uploading audio"
        case .verifyingServer: "Verifying server audio"
        case .publishing: "Awaiting feed publication"
        case .failed: "Publishing needs retry"
        case .verificationFailed: "Verification failed"
        case .localConflict: "Local file verification needs attention"
        case .discarded: "Local upload removed"
        case .published: "Published · verified"
        case .removing: "Server removal pending"
        case .removalFailed: "Server removal needs retry"
        }
    }
    public var needsAttention: Bool { [.failed, .verificationFailed, .localConflict, .removalFailed].contains(self) }
    public var active: Bool { [.verifyingLocal, .transferring, .verifyingServer].contains(self) }
}
public struct UploadItem: Identifiable, Sendable {
    public let episode: Episode
    public let phase: UploadPhase
    public let detail: String?
    public let progress: UploadProgress?
    public var id: String { episode.id }
    public init(episode: Episode, publication: DeliveryPublicationStatus, blocked: Bool = false,
                feedError: String? = nil, progress: UploadProgress? = nil) {
        self.episode = episode; self.progress = progress
        if episode.stage == .expired || episode.manualAudioDeletionRequested == true {
            if let notice = episode.localCleanupNotice { phase = .localConflict; detail = notice }
            else if let error = episode.delivery?.lastError ?? feedError { phase = .removalFailed; detail = error }
            else { phase = .removing; detail = nil }
        } else if let notice = episode.localCleanupNotice, episode.localAudioDiscarded == true || publication == .published {
            phase = .localConflict; detail = notice
        } else if episode.localAudioDiscarded == true && publication != .published && publication != .uploaded {
            phase = .discarded; detail = "The local copy was removed. Saved article text and any server copy are kept."
        } else if let progress, progress.phase.active || progress.phase == .publishing {
            phase = progress.phase; detail = nil
        } else if blocked || (publication != .notUploaded && episode.delivery?.verificationFailed == true) {
            phase = .verificationFailed; detail = episode.delivery?.lastError ?? "Server verification will retry; other items continue."
        } else if let progress {
            phase = progress.phase; detail = nil
        } else if let error = episode.delivery?.lastError, publication != .published && publication != .notUploaded {
            phase = .failed; detail = error
        } else {
            switch publication {
            case .notUploaded, .awaitingUpload: phase = .waiting; detail = nil
            case .uploaded: phase = feedError == nil ? .publishing : .failed; detail = feedError
            case .published: phase = .published; detail = nil
            case .failed: phase = .failed; detail = episode.delivery?.lastError
            }
        }
    }
    public var isInOutbox: Bool { episode.stage == .published && episode.manualAudioDeletionRequested != true && phase != .published && (episode.localAudioDiscarded != true || episode.localCleanupNotice != nil) }
}
