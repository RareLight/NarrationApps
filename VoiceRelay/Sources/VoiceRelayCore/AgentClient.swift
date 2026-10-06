import Foundation
import Security
import Darwin

public enum AgentClientFailure: Error, Sendable, Equatable {
    case untrustedIdentity
    case unavailable
    case interrupted
    case invalidated
    case timedOut
    case requestInProgress
    case invalidRequest
    case invalidResponse
    public var message: String {
        switch self {
        case .untrustedIdentity: "The agent connection could not verify trusted app or agent signing."
        case .unavailable: "The agent is unavailable; it may not be enrolled yet."
        case .interrupted: "The agent connection was interrupted."
        case .invalidated: "The agent connection ended before replying."
        case .timedOut: "The agent did not reply in time."
        case .requestInProgress: "An agent request is already in progress."
        case .invalidRequest: "The agent request could not be sent."
        case .invalidResponse: "The agent reply could not be used."
        }
    }
}

@MainActor public protocol AgentTransport: AnyObject {
    func activate(onFailure: @escaping @Sendable (AgentClientFailure) -> Void) throws
    func send(_ data: Data, reply: @escaping @Sendable (Result<Data, AgentClientFailure>) -> Void)
    func invalidate()
}

@MainActor public final class AgentClient {
    public static let maximumTimeout: Duration = .seconds(30)
    private let transportFactory: @MainActor () throws -> any AgentTransport
    private var pending: Pending?

    private struct Pending {
        let session: UUID
        let transport: any AgentTransport
        let continuation: CheckedContinuation<AgentSnapshot, any Error>
        let deadline: Task<Void, Never>
    }

    public init() {
        transportFactory = { AgentXPCTransport() }
    }
    public init(transportFactory: @escaping @MainActor () throws -> any AgentTransport) {
        self.transportFactory = transportFactory
    }

    public func snapshot(timeout: Duration = .seconds(5)) async throws -> AgentSnapshot {
        guard timeout > .zero && timeout <= Self.maximumTimeout else { throw AgentClientFailure.invalidRequest }
        guard pending == nil else { throw AgentClientFailure.requestInProgress }
        try Task.checkCancellation()
        let session = UUID()
        guard let data = try? AgentWire.encode(AgentRequest(command: .snapshot, requestID: session)) else {
            throw AgentClientFailure.invalidRequest
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AgentSnapshot, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let transport: any AgentTransport
                do { transport = try transportFactory() }
                catch let failure as AgentClientFailure {
                    continuation.resume(throwing: failure)
                    return
                } catch {
                    continuation.resume(throwing: AgentClientFailure.unavailable)
                    return
                }
                let deadline = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.finish(session: session, outcome: .failure(AgentClientFailure.timedOut))
                }
                pending = Pending(session: session, transport: transport, continuation: continuation, deadline: deadline)
                do {
                    try transport.activate { [weak self] failure in
                        Task { @MainActor in self?.finish(session: session, outcome: .failure(failure)) }
                    }
                } catch let failure as AgentClientFailure {
                    finish(session: session, outcome: .failure(failure))
                } catch {
                    finish(session: session, outcome: .failure(AgentClientFailure.unavailable))
                }
                guard pending != nil else { return }
                transport.send(data) { [weak self] result in
                    Task { @MainActor in self?.handleReply(session: session, result: result) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(session: session, outcome: .failure(CancellationError())) }
        }
    }

    public func cancel() {
        guard let session = pending?.session else { return }
        finish(session: session, outcome: .failure(CancellationError()))
    }

    private func handleReply(session: UUID, result: Result<Data, AgentClientFailure>) {
        switch result {
        case .failure(let failure):
            finish(session: session, outcome: .failure(failure))
        case .success(let data):
            do {
                finish(session: session, outcome: .success(try Self.snapshot(from: data, requestID: session)))
            } catch {
                finish(session: session, outcome: .failure(error))
            }
        }
    }

    private func finish(session: UUID, outcome: Result<AgentSnapshot, any Error>) {
        guard let pending, pending.session == session else { return }
        self.pending = nil
        pending.deadline.cancel()
        pending.transport.invalidate()
        switch outcome {
        case .success(let snapshot): pending.continuation.resume(returning: snapshot)
        case .failure(let error): pending.continuation.resume(throwing: error)
        }
    }

    private static func snapshot(from data: Data, requestID: UUID) throws -> AgentSnapshot {
        let response: AgentResponse
        do { response = try AgentWire.decodeResponse(data, requestID: requestID) }
        catch { throw AgentClientFailure.invalidResponse }
        guard response.requestID == requestID else { throw AgentClientFailure.invalidResponse }
        if let failure = response.failure { throw failure }
        guard let snapshot = response.snapshot,
              snapshot.mode == "readOnlyFoundation",
              snapshot.supportedCommands == ["snapshot"],
              snapshot.progress == nil,
              snapshot.articles >= 0, snapshot.waiting >= 0, snapshot.processing >= 0,
              snapshot.paused >= 0, snapshot.failed >= 0, snapshot.completed >= 0
        else { throw AgentClientFailure.invalidResponse }
        return snapshot
    }
}

@MainActor
private final class AgentXPCTransport: AgentTransport {
    private var connection: NSXPCConnection?

    func activate(onFailure: @escaping @Sendable (AgentClientFailure) -> Void) throws {
        let flags = SecCSFlags(rawValue: 0)
        var current: SecCode?, code: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf(flags, &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, flags, &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw AgentClientFailure.untrustedIdentity
        }
        var parsed: SecRequirement?
        guard let own = try? AgentIdentity.peerRequirement(team: team),
              SecRequirementCreateWithString(own as CFString, flags, &parsed) == errSecSuccess,
              SecCodeCheckValidity(current, flags, parsed) == errSecSuccess,
              let agent = try? AgentIdentity.peerRequirement(team: team, agent: true),
              SecRequirementCreateWithString(agent as CFString, flags, &parsed) == errSecSuccess else {
            throw AgentClientFailure.untrustedIdentity
        }
        let connection = NSXPCConnection(machServiceName: AgentIdentity.machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentXPCProtocol.self)
        connection.setCodeSigningRequirement(agent)
        connection.interruptionHandler = { onFailure(.interrupted) }
        connection.invalidationHandler = { onFailure(.invalidated) }
        self.connection = connection
        connection.activate()
    }

    func send(_ data: Data, reply: @escaping @Sendable (Result<Data, AgentClientFailure>) -> Void) {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in
            reply(.failure(.unavailable))
        }) as? AgentXPCProtocol else {
            reply(.failure(.unavailable))
            return
        }
        proxy.handle(data) { response in
            Task { @MainActor in
                guard let connection = self.connection else {
                    reply(.failure(.invalidated))
                    return
                }
                guard connection.effectiveUserIdentifier == geteuid() else {
                    reply(.failure(.untrustedIdentity))
                    return
                }
                reply(.success(response))
            }
        }
    }

    func invalidate() {
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
    }
}
