import Foundation

/// Time actually spent in an admitted platform call. Queue/admission waits and
/// unrelated CPU preparation must not exhaust an optional analysis budget.
final class PreparationInterval: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var start: TimeInterval?
    private var duration: TimeInterval = 0
    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    func begin() { lock.withLock { if start == nil { start = now() } } }
    func end() { lock.withLock { if let start { duration += max(0, now() - start); self.start = nil } } }
    var elapsed: TimeInterval { lock.withLock { duration } }
}
