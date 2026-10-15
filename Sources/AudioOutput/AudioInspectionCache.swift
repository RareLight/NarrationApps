import Foundation

/// Per-job, bounded reuse keyed by caller-verified content digests. Decoded
/// copies can be reused without retaining sample buffers or unbounded metadata.
public final class AudioInspectionCache: @unchecked Sendable {
    private struct Entry { var info: NativeAudioInfo?; var decoded = false }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    public init(capacity: Int = 128) { self.capacity = max(1, capacity) }
    public func info(_ hash: String) -> NativeAudioInfo? { lock.withLock { entries[hash]?.info } }
    public func save(_ info: NativeAudioInfo, hash: String) { lock.withLock { admit(hash); entries[hash]?.info = info } }
    public func isDecoded(_ hash: String) -> Bool { lock.withLock { entries[hash]?.decoded == true } }
    public func markDecoded(_ hash: String) { lock.withLock { admit(hash); entries[hash]?.decoded = true } }
    private func admit(_ hash: String) {
        guard entries[hash] == nil else { return }
        while order.count >= capacity { entries.removeValue(forKey: order.removeFirst()) }
        order.append(hash); entries[hash] = Entry()
    }
}
