import Foundation
import VoiceRelayCore

@MainActor
extension AppModel {
    var progressHandler: @Sendable (PipelineProgress) -> Void {
        let token = progressID
        return { [weak self] update in Task { @MainActor in
            guard let self, self.progressID == token else { return }
            self.progress = update
        } }
    }
    var queueHandler: @Sendable (SpeechQueueItem) -> Void {
        let token = progressID
        return { [weak self] item in
            Task { @MainActor in
                guard let self, self.progressID == token else { return }
                if item.state == .completed {
                    self.completedQueueIDs.insert(item.id)
                    self.queueItems.removeAll { $0.id == item.id }
                    self.queueSelection.remove(.episode(item.id)); return
                }
                guard !self.completedQueueIDs.contains(item.id) else { return }
                if item.state == .running {
                    self.queueItems.removeAll { $0.id == item.id }
                    self.queueItems.insert(item, at: 0)
                } else if let index = self.queueItems.firstIndex(where: { $0.id == item.id }) { self.queueItems[index] = item }
                else { self.queueItems.append(item) }
            }
        }
    }
    /// Progress snapshots may predate captured metadata; they must not erase it in the UI.
    func recordUploadProgress(_ event: UploadProgress) {
        uploadProgress[event.episode.id] = event
        var episode = event.episode
        if let index = savedEpisodes.firstIndex(where: { $0.id == episode.id }) {
            let previous = savedEpisodes[index]
            episode.readingListSavedAt = episode.readingListSavedAt ?? previous.readingListSavedAt
            episode.originalSourceHost = episode.originalSourceHost ?? previous.originalSourceHost
            episode.originalSourceIdentity = episode.originalSourceIdentity ?? previous.originalSourceIdentity
            savedEpisodes[index] = episode
        } else { savedEpisodes.append(episode) }
    }
    func recordDeliveryPublication(_ summary: DeliverySummary) {
        deliveryPublicationStates = summary.publicationStates
        deliveryPublicationAudioHashes = summary.publicationAudioHashes
        deliveryPublicationSettingsHash = summary.publicationSettingsHash
        deliveryVerificationFailedIDs = summary.verificationFailedIDs
        deliveryFeedError = summary.feedError
    }
}
