import Foundation

public enum AgentCommand: Codable, Sendable, Equatable {
    case snapshot
    case reconcile
    case enqueue(entryIDs: [String])
    case generateAudio
    case pause
    case setExcluded(entryID: String, excluded: Bool)
    case retry(articleID: String)
    case removeFromQueue(articleID: String)
}

public struct AgentRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID: UUID
    public let command: AgentCommand
    public init(command: AgentCommand, requestID: UUID = UUID(), version: Int = AgentWire.version) {
        self.version = version; self.requestID = requestID; self.command = command
    }
}

public enum AgentFailure: String, Codable, Sendable, Error {
    case invalidRequest, unsupportedVersion, payloadTooLarge, commandUnavailable, storageUnavailable
    public var message: String {
        switch self {
        case .invalidRequest: "The agent request is invalid."
        case .unsupportedVersion: "The app and agent protocol versions do not match."
        case .payloadTooLarge: "The agent message exceeds its size limit."
        case .commandUnavailable: "This agent foundation is read-only. Processing remains in the app until ownership transfer is implemented."
        case .storageUnavailable: "The private library is unavailable. Existing data is preserved."
        }
    }
}

public struct AgentSnapshot: Codable, Sendable, Equatable {
    public let mode: String
    public let supportedCommands: [String]
    public let articles: Int
    public let waiting: Int
    public let processing: Int
    public let paused: Int
    public let failed: Int
    public let completed: Int
    public let progress: QueueBatchProgress?
    init(catalog: ReadingListCatalog, queue: [SpeechQueueItem]) {
        mode = "readOnlyFoundation"; supportedCommands = ["snapshot"]
        articles = catalog.entries.count
        waiting = queue.filter { $0.state == .queued }.count
        processing = queue.filter { $0.state == .running }.count
        paused = queue.filter { $0.state == .paused }.count
        failed = queue.filter { $0.state == .failed }.count
        completed = queue.filter { $0.state == .completed }.count
        progress = nil // This executable does not yet own processing.
    }
}

public struct AgentResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID: UUID?
    public let snapshot: AgentSnapshot?
    public let failure: AgentFailure?
    init(requestID: UUID?, snapshot: AgentSnapshot? = nil, failure: AgentFailure? = nil) {
        version = AgentWire.version; self.requestID = requestID; self.snapshot = snapshot; self.failure = failure
    }
}

/// JSON carried as Data over NSXPC, with no arbitrary object graph, credentials or source HTML.
public enum AgentWire {
    public static let version = 1
    public static let maximumBytes = 256 * 1024
    public static func encode(_ request: AgentRequest) throws -> Data {
        try validate(request)
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumBytes else { throw AgentFailure.payloadTooLarge }
        return data
    }
    public static func decodeRequest(_ data: Data) throws -> AgentRequest {
        guard data.count <= maximumBytes else { throw AgentFailure.payloadTooLarge }
        let request: AgentRequest
        do { request = try JSONDecoder().decode(AgentRequest.self, from: data) }
        catch { throw AgentFailure.invalidRequest }
        try validate(request); return request
    }
    public static func decodeResponse(_ data: Data, requestID: UUID) throws -> AgentResponse {
        guard data.count <= maximumBytes else { throw AgentFailure.payloadTooLarge }
        let response: AgentResponse
        do { response = try JSONDecoder().decode(AgentResponse.self, from: data) }
        catch { throw AgentFailure.invalidRequest }
        guard response.version == version else { throw AgentFailure.unsupportedVersion }
        guard (response.snapshot == nil) != (response.failure == nil),
              response.requestID == requestID || (response.requestID == nil && response.failure != nil) else {
            throw AgentFailure.invalidRequest
        }
        return response
    }
    private static func validate(_ request: AgentRequest) throws {
        guard request.version == version else { throw AgentFailure.unsupportedVersion }
        func entry(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        switch request.command {
        case .enqueue(let ids):
            guard !ids.isEmpty, ids.count <= 2048, Set(ids).count == ids.count, ids.allSatisfy(entry) else { throw AgentFailure.invalidRequest }
        case .setExcluded(let id, _): guard entry(id) else { throw AgentFailure.invalidRequest }
        case .retry(let id), .removeFromQueue(let id): guard UUID(uuidString: id) != nil else { throw AgentFailure.invalidRequest }
        case .snapshot, .reconcile, .generateAudio, .pause: break
        }
    }
    static func encodeResponse(_ response: AgentResponse) -> Data {
        if let data = try? JSONEncoder().encode(response), data.count <= maximumBytes { return data }
        return (try? JSONEncoder().encode(AgentResponse(requestID: response.requestID, failure: .payloadTooLarge))) ?? Data()
    }
}

/// Read-only foundation: mutation vocabulary is versioned but explicitly unavailable until handoff.
public actor AgentEndpoint {
    private let coordinator = FixtureCoordinator()
    private let stateRoot: URL
    public init(stateRoot: URL = AppStorage.managedLibrary) { self.stateRoot = stateRoot }
    public func handle(_ data: Data) async -> Data {
        let request: AgentRequest
        do { request = try AgentWire.decodeRequest(data) }
        catch { return AgentWire.encodeResponse(AgentResponse(requestID: nil, failure: error as? AgentFailure ?? .invalidRequest)) }
        guard request.command == .snapshot else {
            return AgentWire.encodeResponse(AgentResponse(requestID: request.requestID, failure: .commandUnavailable))
        }
        do {
            let catalog = try await coordinator.catalog(stateRoot: stateRoot)
            let queue = try await coordinator.queue(stateRoot: stateRoot)
            return AgentWire.encodeResponse(AgentResponse(requestID: request.requestID, snapshot: AgentSnapshot(catalog: catalog, queue: queue)))
        } catch { return AgentWire.encodeResponse(AgentResponse(requestID: request.requestID, failure: .storageUnavailable)) }
    }
}

@objc(VoiceRelayAgentXPCProtocol) public protocol AgentXPCProtocol {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public final class AgentXPCService: NSObject, AgentXPCProtocol, Sendable {
    private let endpoint: AgentEndpoint
    public init(endpoint: AgentEndpoint) { self.endpoint = endpoint }
    public func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(await endpoint.handle(request)) }
    }
}

public enum AgentIdentity {
    public static let appIdentifier = "org.voicerelay.prototype"
    public static let agentIdentifier = "org.voicerelay.prototype.agent"
    public static let machService = "org.voicerelay.prototype.agent"
    public static let plistName = "org.voicerelay.prototype.agent.plist"
    public static func peerRequirement(team: String, agent: Bool = false) throws -> String {
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw RelayError.setup("A trusted signing team is required before running the agent listener.")
        }
        return "identifier \"\(agent ? agentIdentifier : appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
