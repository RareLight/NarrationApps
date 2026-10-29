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
    public static func workingLimit(for model: SpeechModel) -> Int {
        model.isLarge ? (model == .orpheus ? 12 : 6) * 1_024 * 1_024 * 1_024 : workingLimitBytes
    }
    public static func footprintLimit(for model: SpeechModel) -> UInt64 {
        model.isLarge ? min(UInt64(model == .orpheus ? 16 : 8) * 1_024 * 1_024 * 1_024, ProcessInfo.processInfo.physicalMemory / 2) : workerFootprintLimitBytes
    }
    public static func canLoad(_ model: SpeechModel, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        !model.isLarge || physicalMemory >= UInt64(model == .orpheus ? 24 : 16) * 1_024 * 1_024 * 1_024
    }

}
