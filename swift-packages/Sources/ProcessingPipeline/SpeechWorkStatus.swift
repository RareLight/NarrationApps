import Foundation

public struct SpeechWorkStatus: Equatable, Sendable {
    public let source: UUID
    public let sequence: UInt64
    public let reason: SpeechWorkWait?
    public init(source: UUID, sequence: UInt64, reason: SpeechWorkWait?) {
        self.source = source; self.sequence = sequence; self.reason = reason
    }
}

/// Coalesced, sequenced transient events; no durable queue/progress state.
public final class SpeechWorkStatusReporter: @unchecked Sendable {
    private let source = UUID()
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var previous: SpeechWorkWait?
    private let deliver: @Sendable (SpeechWorkStatus) -> Void
    public init(deliver: @escaping @Sendable (SpeechWorkStatus) -> Void) { self.deliver = deliver }
    public func update(_ reason: SpeechWorkWait?) {
        let event: SpeechWorkStatus? = lock.withLock {
            guard sequence == 0 || previous != reason, sequence < UInt64.max else { return nil }
            sequence += 1; previous = reason
            return .init(source: source, sequence: sequence, reason: reason)
        }
        if let event { deliver(event) }
    }
}

/// Reject reordered/late events without changing counters, attempts or consent.
public struct SpeechWorkStatusProjection: Sendable {
    private var sequences: [UUID: UInt64] = [:]
    private var reasons: [UUID: SpeechWorkWait] = [:]
    public init() {}
    @discardableResult public mutating func receive(_ event: SpeechWorkStatus) -> Bool {
        guard event.sequence > (sequences[event.source] ?? 0) else { return false }
        sequences[event.source] = event.sequence; reasons[event.source] = event.reason
        return true
    }
    public var reason: SpeechWorkWait? {
        [.api, .maintenance, .libro, .manualPause].first { reasons.values.contains($0) }
    }
}

public extension SpeechWorkWait {
    var statusLabel: String {
        switch self {
        case .api: "Waiting for VoiceServer"
        case .libro: "Waiting for Libro"
        case .manualPause: "Paused"
        case .maintenance: "Waiting for model maintenance"
        }
    }
}
