import Foundation

/// Inventory validation around Hub-owned acquisition, including blobs that
/// exist without a snapshot mapping after an interrupted cache publication.
public struct NativeAcquisitionFile: Sendable {
    public let path: String
    public let bytes: Int
    public let hash: String
    public let gitOID: String?

    public init(path: String, bytes: Int, hash: String, gitOID: String?) {
        self.path = path; self.bytes = bytes; self.hash = hash; self.gitOID = gitOID
    }

    public func matches(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == bytes else { return false }
        return try NativeG2P.sha256(url) == hash
    }

    /// Preserve invalid bytes for diagnosis, but remove them from SDK lookup.
    /// Call under the preparation scope lock, only for private native copies.
    @discardableResult
    public func quarantineInvalidCopy(at url: URL, workspace: NativeWorkspace) throws -> Bool {
        _ = try workspace.managed(url)
        try Task.checkCancellation()
        if try matches(url) { return true }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("invalid-\(UUID().uuidString)"))
        }
        return false
    }
}

/// Foundation Progress synchronizes its counters. Child transfers contribute
/// to fractionCompleted continuously, but completedUnitCount advances only
/// when a child finishes. Use the fraction for byte progress in the GUI.
public final class NativeAcquisitionProgress: @unchecked Sendable {
    public let value: Progress
    private let total: Int64
    public init(total: Int64) { self.total = total; value = Progress(totalUnitCount: total) }
    public var completedBytes: Int64 {
        let fraction = value.fractionCompleted
        guard fraction.isFinite, fraction > 0 else { return 0 }
        return min(total, Int64((Double(total) * min(1, fraction)).rounded(.down)))
    }
}
