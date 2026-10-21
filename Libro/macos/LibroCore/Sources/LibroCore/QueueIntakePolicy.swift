import Foundation
import DocumentProcessing
import ProcessingPipeline

public enum ExistingOutputChoice: Sendable { case overwrite, skip, cancel }

/// Decide at batch start, after destinations have been checked again. Approval
/// covers only outputs present in that snapshot; late arrivals remain protected.
public struct QueueProcessingSelection: Sendable {
    public let documents: [PlannedDocument]
    public let skipped: Set<UUID>
    public let replaceExisting: Bool

    public init?(plans: [PlannedDocument], choice: ExistingOutputChoice) {
        guard choice != .cancel else { return nil }
        replaceExisting = choice == .overwrite
        let skippedIDs = choice == .skip ? Set(plans.filter(\.replacesExisting).map(\.id)) : []
        skipped = skippedIDs
        documents = plans.filter { !skippedIDs.contains($0.id) }
    }
}

public enum QueueIntakePolicy {
    /// Re-adding a finished source queues it again without duplicating its row or
    /// changing an active batch. Re-scanning older roots must not requeue them.
    public static func requeuedIDs(documents: [InputDocument], selected: [URL], active: Set<UUID>) -> Set<UUID> {
        let paths = selected.map { source in
            let isAlias = (try? source.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
            let target = isAlias ? ((try? URL(resolvingAliasFileAt: source, options: [.withoutUI, .withoutMounting])) ?? source) : source
            return target.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return Set(documents.filter { document in
            !active.contains(document.id) && paths.contains {
                document.source.path == $0 || document.source.path.hasPrefix($0 + "/")
            }
        }.map(\.id))
    }
}
