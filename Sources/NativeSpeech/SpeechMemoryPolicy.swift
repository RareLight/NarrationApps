import NarrationCore
import Foundation

/// Per-process budgets: two native workers must not each inherit MLX's
/// machine-sized buffer pool. The MLX working limit is a scheduling/GC
/// threshold, not a hard allocation limit; the host also watches footprint.
public enum SpeechMemoryPolicy {
    public static let cacheLimitBytes = 64 * 1_024 * 1_024
    public static let workingLimitBytes = 1_024 * 1_024 * 1_024
    public static var workerFootprintLimitBytes: UInt64 {
        min(3 * 1_024 * 1_024 * 1_024, ProcessInfo.processInfo.physicalMemory / 4)
    }
}
