import Foundation
import Observation
import NarrationCore
import NativeSpeech

/// App-owned automatic model validation: one local inventory plus one offline
/// initialization per selected target, serialized behind any prior task so a
/// superseded check cannot overlap or stamp its result late.
@MainActor @Observable
public final class SpeechSetupValidation {
    public struct Target: Sendable, Equatable {
        public let root: URL
        public let settings: SpeechSettings
        public let revision: Int
        public init(root: URL, settings: SpeechSettings, revision: Int) {
            self.root = root.standardizedFileURL
            self.settings = settings
            self.revision = revision
        }
        public static func == (lhs: Target, rhs: Target) -> Bool {
            lhs.root.standardizedFileURL == rhs.root.standardizedFileURL
                && lhs.settings.model == rhs.settings.model
                && lhs.settings.voice == rhs.settings.voice
                && lhs.settings.effectiveLanguage == rhs.settings.effectiveLanguage
                && lhs.revision == rhs.revision
        }
    }
    public enum Result: Equatable, Sendable {
        case idle, checking, notInstalled, ready, failure(String)
        var isTerminal: Bool {
            switch self {
            case .notInstalled, .ready, .failure: return true
            case .idle, .checking: return false
            }
        }
    }
    public private(set) var result: Result = .idle
    public private(set) var target: Target?
    public private(set) var hasOwnedWork = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID = UUID()
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var desired: Target?
    @ObservationIgnored private var inflight: Target?
    @ObservationIgnored private var settled: Target?
    @ObservationIgnored private var permitted = true
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private let inspect: @Sendable (Target) async throws -> Bool
    @ObservationIgnored private let check: @Sendable (Target) async throws -> Void

    public static func defaultInspect(_ target: Target) async throws -> Bool {
        let root = target.root, model = target.settings.model
        let scan = Task.detached(priority: .utility) {
            try NativeModelStorage.entries(at: root, models: [model]).contains { $0.model == model }
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }

    public init(inspect: @escaping @Sendable (Target) async throws -> Bool = SpeechSetupValidation.defaultInspect,
                check: @escaping @Sendable (Target) async throws -> Void) {
        self.inspect = inspect
        self.check = check
    }

    public func update(target: Target?, permitted: Bool) {
        self.permitted = permitted
        guard !stopped else { return }
        if desired != target {
            desired = target
            settled = nil
            operation = UUID()
            inflight = nil
            task?.cancel()
            self.target = target
            result = .idle
        }
        if !permitted {
            operation = UUID()
            inflight = nil
            task?.cancel()
            if result == .checking { result = .idle }
        }
        schedule()
    }

    public func record(_ outcome: Result, for target: Target) {
        guard !stopped, desired == target else { return }
        operation = UUID()
        inflight = nil
        task?.cancel()
        self.target = target
        settled = outcome.isTerminal ? target : settled
        result = outcome
    }

    public func waitForIdle() async {
        while let task { await task.value }
    }

    public func stopAndWait() async {
        stopped = true
        operation = UUID()
        inflight = nil
        task?.cancel()
        if result == .checking { result = .idle }
        while let pending = task { await pending.value }
    }

    private func schedule() {
        guard !stopped, permitted, let desired, settled != desired, inflight != desired else { return }
        result = .checking
        hasOwnedWork = true
        inflight = desired
        let op = UUID(); operation = op
        let id = UUID(); taskID = id
        let previous = task
        task = Task { [weak self, inspect, check] in
            await previous?.value
            defer {
                if let self, self.taskID == id {
                    self.task = nil; self.inflight = nil; self.hasOwnedWork = false
                }
            }
            guard let self, self.operation == op, !Task.isCancelled else { return }
            do {
                let present = try await inspect(desired)
                guard self.operation == op else { return }
                if !present {
                    self.result = .notInstalled; self.settled = desired
                } else {
                    try await check(desired)
                    guard self.operation == op else { return }
                    self.result = .ready; self.settled = desired
                }
            } catch is CancellationError {
                if self.operation == op {
                    self.result = .idle; self.settled = desired
                }
            } catch {
                guard self.operation == op else { return }
                self.result = .failure(error.localizedDescription); self.settled = desired
            }
        }
    }
}
