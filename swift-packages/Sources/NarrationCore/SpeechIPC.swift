import Foundation
import Darwin

public enum SpeechFailureCode: String, Codable, Sendable {
    case incompatibleWorker, textPreparation, regionalAssets, invalidInput, storage, acquisition, generation, protocolViolation, timeout, workerExited, memoryLimit

}

/// Only controlled descriptions cross into the UI. Library diagnostics and
/// narration never become error messages or completion notifications.
public struct SpeechFailure: Error, LocalizedError, Sendable {
    public let code: SpeechFailureCode
    public let operation: WorkerCommand.Kind?
    public let chunk: Int?
    public let source: SpokenSourceRange?
    public init(_ code: SpeechFailureCode, operation: WorkerCommand.Kind? = nil, chunk: Int? = nil, source: SpokenSourceRange? = nil) {
        self.code = code; self.operation = operation; self.chunk = chunk; self.source = source
    }
    public var errorDescription: String? {
        let description = switch code {
        case .incompatibleWorker: "The app and embedded speech helper are incompatible. Rebuild or reinstall the complete app, then retry."
        case .textPreparation: source.map { SpeechPreparationError(source: $0).localizedDescription } ?? "The text cannot be prepared within the model token limit. No content was truncated."
        case .regionalAssets: "British pronunciation assets are missing or invalid. Install or update the speech model for the selected British voice, then retry."
        case .invalidInput: "The speech request or prepared model assets are invalid."
        case .storage: "Could not read, write, or publish audio in the selected folders."
        case .acquisition: "Model preparation failed. Check network access and available workspace storage, then prepare again."
        case .generation: "The speech engine could not generate a valid audio chunk."
        case .protocolViolation: "The speech worker returned an invalid response."
        case .timeout: "The speech worker did not respond within the time limit."
        case .workerExited: "The speech worker stopped before completing its request."
        case .memoryLimit: "This model needs more system memory, or its worker exceeded the supported memory limit."
        }
        let stage = switch operation {
        case .initialize: " During model initialization."
        case .generate: " While generating chunk \((chunk ?? 0) + 1)."
        case .prepare: " During model preparation."
        default: ""
        }
        return description + stage + " Error: \(code.rawValue)."
    }
}

public struct AttemptIdentity: Codable, Equatable, Sendable {
    public let batch: UUID
    public let job: UUID
    public let attempt: UUID
    public init(batch: UUID, job: UUID, attempt: UUID = UUID()) {
        self.batch = batch; self.job = job; self.attempt = attempt
    }
}

public struct WorkerCommand: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case initialize, generate, prepare, prepareText, generatePrepared, cancel, shutdown }
    public var protocolVersion = SpeechIPC.protocolVersion
    public let kind: Kind
    public let identity: AttemptIdentity
    public let chunk: Int?
    public let workspace: URL?
    public let settings: SpeechSettings?
    public let spoolDirectory: URL?
    public let text: String?
    public let policy: SpeechPreparationPolicy?
    public let textWindow: SpeechTextWindow?
    public let utterance: PreparedUtterance?

    public init(kind: Kind, identity: AttemptIdentity, chunk: Int? = nil,
                workspace: URL? = nil, settings: SpeechSettings? = nil,
                spoolDirectory: URL? = nil, text: String? = nil, policy: SpeechPreparationPolicy? = nil,
                textWindow: SpeechTextWindow? = nil, utterance: PreparedUtterance? = nil) {
        self.kind = kind; self.identity = identity; self.chunk = chunk
        self.workspace = workspace; self.settings = settings
        self.spoolDirectory = spoolDirectory; self.text = text
        self.policy = policy; self.textWindow = textWindow; self.utterance = utterance
    }
}

public struct PreparedSpeechFile: Codable, Sendable {
    public let path: String
    public let sha256: String
    public let count: Int
    public init(path: String, sha256: String, count: Int) { self.path = path; self.sha256 = sha256; self.count = count }
}

public struct WorkerEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case ready, chunk, assetProgress, prepared, textPrepared, failure }
    public var protocolVersion = SpeechIPC.protocolVersion
    public let kind: Kind
    public let identity: AttemptIdentity
    public let chunk: Int?
    public let sampleRate: Int?
    public let frames: Int?
    public let channels: Int?
    public let pcmFile: String?
    public let failure: SpeechFailureCode?
    public let preparation: ModelPreparationProgress?
    public let preparedFile: PreparedSpeechFile?
    public let source: SpokenSourceRange?

    public init(kind: Kind, identity: AttemptIdentity, chunk: Int? = nil,
                sampleRate: Int? = nil, frames: Int? = nil, channels: Int? = nil,
                pcmFile: String? = nil, failure: SpeechFailureCode? = nil, preparation: ModelPreparationProgress? = nil, preparedFile: PreparedSpeechFile? = nil, source: SpokenSourceRange? = nil) {
        self.kind = kind; self.identity = identity; self.chunk = chunk
        self.sampleRate = sampleRate; self.frames = frames; self.channels = channels
        self.pcmFile = pcmFile; self.failure = failure
        self.preparedFile = preparedFile; self.preparation = preparation; self.source = source
    }
}

public enum SpeechIPC {
    public static let protocolVersion = 3
    public static let maximumRecordBytes = 65_536

    public static func encode<T: Encodable>(_ record: T) throws -> Data {
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumRecordBytes else { throw SpeechFailure(.invalidInput) }
        return data + Data([10])
    }

    public static func preparationFile(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent("prepared-\(index).json")
    }

    public static func chunkFile(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent("chunk-\(index).f32")
    }

    /// One POSIX read returns the bytes currently delivered by a pipe. Some
    /// Foundation read(upToCount:) implementations wait to fill the requested
    /// count, which deadlocks a small request/response record on an open pipe.
    public static func readPipe(_ handle: FileHandle) throws -> Data? {
        var bytes = Data(count: 4_096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw SpeechFailure(.workerExited)
            }
            bytes.count = count
            return bytes
        }
    }
}

/// A worker's single control reader. The host uses a dedicated pipe reader;
/// synchronous reads here never run in the GUI process or on MainActor.
public final class WorkerCommandReader {
    private var buffer = Data()
    private let input: FileHandle
    public init(input: FileHandle = .standardInput) { self.input = input }
    public func next() throws -> WorkerCommand? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard newline <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                do { return try JSONDecoder().decode(WorkerCommand.self, from: line) }
                catch { throw SpeechFailure(.protocolViolation) }
            }
            guard buffer.count <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
            guard let bytes = try SpeechIPC.readPipe(input) else {
                guard buffer.isEmpty else { throw SpeechFailure(.protocolViolation) }
                return nil
            }
            buffer.append(bytes)
        }
    }
}
