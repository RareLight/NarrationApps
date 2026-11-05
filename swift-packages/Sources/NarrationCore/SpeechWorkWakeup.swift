import Foundation
import CryptoKit
import notify

/// Advisory, payload-free cross-process wakeups. Kernel tickets and the final
/// registration gate remain authoritative. A bounded timer survives missed,
/// coalesced or unavailable notifications; queued events use one buffer slot.
public final class SpeechWorkWakeup: @unchecked Sendable {
    public enum Event: Equatable, Sendable { case changed, fallback }
    public let events: AsyncStream<Event>
    public let notificationsAvailable: Bool
    private let sink: AsyncStream<Event>.Continuation
    private let timer: DispatchSourceTimer
    private let token: Int32?
    private let lock = NSLock()
    private var finished = false

    public init(root: URL, fallbackMilliseconds: Int = 50, notifications: Bool = true) {
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream; sink = pair.continuation
        let sink = pair.continuation
        var registered: Int32 = 0
        if notifications, notify_register_dispatch(Self.name(root), &registered, DispatchQueue.global(qos: .utility), { _ in
            sink.yield(.changed)
        }) == NOTIFY_STATUS_OK {
            token = registered; notificationsAvailable = true
        } else { token = nil; notificationsAvailable = false }
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = max(10, min(fallbackMilliseconds, 30_000))
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { sink.yield(.fallback) }
        timer.resume()
    }
    static func name(_ root: URL) -> String {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "org.narration.work-admission.v1." + hash
    }
    static func post(root: URL) { _ = notify_post(name(root)) }
    public func finish() {
        let finish = lock.withLock { if finished { return false }; finished = true; return true }
        guard finish else { return }
        if let token { _ = notify_cancel(token) }
        timer.cancel(); sink.finish()
    }
    deinit { finish() }
}
