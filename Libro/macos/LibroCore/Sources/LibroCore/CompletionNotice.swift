import Foundation

public struct CompletionNotice: Sendable {
    public let batchID: UUID
    public let title: String
    public let body: String
    public let successfulCount: Int
    public let failedCount: Int
}

/// Session-only deduplication. Call after the coordinator returns its settled
/// summary, never on a synthesis/progress event. Even denied/cancelled batches
/// are settled once, so a late event cannot later announce them as successful.
public struct CompletionNoticeLedger {
    private var settled = Set<UUID>()
    public init() {}
    public mutating func finish(_ summary: BatchSummary, authorized: Bool) -> CompletionNotice? {
        guard settled.insert(summary.id).inserted, authorized, !summary.cancelled,
              !summary.documents.contains(where: { $0.state == .cancelled }) else { return nil }
        return CompletionNotice(batchID: summary.id, title: "Libro processing complete",
            body: "Documents saved: \(summary.successfulCount). Failed: \(summary.failedCount)." + (summary.skippedCount > 0 ? " Skipped: \(summary.skippedCount)." : ""),
            successfulCount: summary.successfulCount, failedCount: summary.failedCount)
    }
}
