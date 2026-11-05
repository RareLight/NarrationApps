import Foundation
import NarrationCore
import NativeSpeech
import Pronunciation

public enum VoiceServerFormat: String, Codable, Sendable, CaseIterable {
    case mp3, wav, pcm
    public var contentType: String {
        switch self { case .mp3: "audio/mpeg"; case .wav: "audio/wav"; case .pcm: "audio/pcm" }
    }
}

public struct VoiceServerLimits: Sendable {
    public var maximumBodyBytes = 65_536
    public var maximumInputBytes = 16_384
    public var maximumQueuedRequests = 4
    public var maximumAggregateInputBytes = 65_536
    public var maximumConnections = 8
    public var maximumOutputBytes: UInt64 = 64 * 1_024 * 1_024
    public var headerBodySeconds: TimeInterval = 10
    public var queueSeconds: TimeInterval = 30
    public var requestSeconds: TimeInterval = 600
    public var writeSeconds: TimeInterval = 15
    public init() {}
}

/// Captured on admission. Neither remote fields nor later Settings changes can
/// choose another model, reference path, pronunciation dictionary or language.
public struct VoiceServerSelection: Sendable {
    public let settings: SpeechSettings
    public let workspace: URL
    public let pronunciations: PronunciationDictionary
    public let modelReady: Bool
    public let narrationOptions: NarrationOptions
    public init(settings: SpeechSettings, workspace: URL, pronunciations: PronunciationDictionary = .empty,
                modelReady: Bool, narrationOptions: NarrationOptions = .init()) {
        var captured = settings; captured.savedChoices = nil
        self.settings = captured; self.workspace = workspace
        self.pronunciations = pronunciations; self.modelReady = modelReady
        self.narrationOptions = narrationOptions
    }
}

public struct VoiceServerResponseModes: Codable, Equatable, Sendable {
    public var streaming: Bool
    public var completeFiles: Bool
    public init(streaming: Bool = true, completeFiles: Bool = true) {
        self.streaming = streaming; self.completeFiles = completeFiles
    }
    public var isValid: Bool { streaming || completeFiles }
}

/// Controlled errors only: never wrap worker stderr, request text, key material
/// or file/URL errors in an HTTP response or a persisted diagnostic.
public struct VoiceServerError: Error, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public let parameter: String?
    public init(_ status: Int, code: String, message: String, parameter: String? = nil) {
        self.status = status; self.code = code; self.message = message; self.parameter = parameter
    }
    public var json: Data {
        struct Envelope: Encodable {
            struct Detail: Encodable { let message: String; let type: String; let param: String?; let code: String }
            let error: Detail
        }
        let type = status == 401 ? "authentication_error" : status < 500 ? "invalid_request_error" : "server_error"
        return (try? JSONEncoder().encode(Envelope(error: .init(message: message, type: type, param: parameter, code: code)))) ?? Data()
    }
    public static let unauthorized = Self(401, code: "invalid_api_key", message: "A valid VoiceServer bearer key is required.")
    public static let unavailable = Self(503, code: "model_unavailable", message: "The selected speech model is unavailable. Check Voice Model settings in VoiceRelay.")
    public static let overloaded = Self(429, code: "queue_full", message: "VoiceServer is at capacity. Retry after an active request finishes.")
    public static let cancelled = Self(503, code: "request_cancelled", message: "The speech request was cancelled.")
    public static let deadline = Self(504, code: "request_timeout", message: "The speech request exceeded its deadline.")
    public static let failed = Self(503, code: "speech_failed", message: "Speech generation could not finish. Check Voice Model settings and retry.")
}

public struct VoiceServerSpeechRequest: Sendable {
    public static let modelAlias = "voicerelay"
    public static let voiceAlias = "default"
    public let input: String
    public let format: VoiceServerFormat
    public let streaming: Bool
    public var inputBytes: Int { input.utf8.count }
    public var delivery: SpeechWorkDelivery { streaming ? .streaming : .file }

    public static func decode(_ data: Data, selection: VoiceServerSelection,
                              modes: VoiceServerResponseModes = .init(), limits: VoiceServerLimits = .init()) throws -> Self {
        guard data.count <= limits.maximumBodyBytes else {
            throw VoiceServerError(413, code: "body_too_large", message: "The request body exceeds the supported size.")
        }
        struct Body: Decodable {
            let input: String
            let model: String?
            let voice: String?
            let speed: Double?
            let response_format: String?
            let stream: Bool?
            let stream_format: String?
        }
        let body: Body
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceServerError.failed }
            let supported: Set<String> = ["input", "model", "voice", "speed", "response_format", "stream", "stream_format"]
            guard Set(object.keys).isSubset(of: supported) else {
                throw VoiceServerError(400, code: "unsupported_parameter", message: "The request contains an unsupported speech parameter.")
            }
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch let error as VoiceServerError where error.status == 400 { throw error }
        catch { throw VoiceServerError(400, code: "invalid_json", message: "Provide a JSON speech request with a string input.") }
        guard !body.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceServerError(400, code: "empty_input", message: "Speech input must contain text.", parameter: "input")
        }
        guard body.input.utf8.count <= limits.maximumInputBytes else {
            throw VoiceServerError(413, code: "input_too_large", message: "Speech input exceeds the supported size.", parameter: "input")
        }
        guard body.model == nil || body.model == modelAlias else {
            throw VoiceServerError(400, code: "model_mismatch", message: "Use model voicerelay; select the speech model in VoiceRelay.", parameter: "model")
        }
        guard body.voice == nil || body.voice == voiceAlias || body.voice == selection.settings.voice else {
            throw VoiceServerError(400, code: "voice_mismatch", message: "Use voice default or the currently selected voice identifier.", parameter: "voice")
        }
        if let speed = body.speed, !speed.isFinite || Float(speed) != selection.settings.speed {
            throw VoiceServerError(400, code: "speed_mismatch", message: "Explicit speed must match the speed selected in VoiceRelay.", parameter: "speed")
        }
        guard let format = VoiceServerFormat(rawValue: body.response_format ?? "mp3") else {
            throw VoiceServerError(400, code: "unsupported_format", message: "Choose mp3, wav or pcm.", parameter: "response_format")
        }
        guard body.stream_format == nil || body.stream_format == "audio" else {
            throw VoiceServerError(400, code: "unsupported_stream_format", message: "Only binary audio streaming is supported.", parameter: "stream_format")
        }
        let streaming = body.stream ?? (format != .wav)
        guard !streaming || format != .wav else {
            throw VoiceServerError(400, code: "unsupported_streaming_wav", message: "WAV requires complete-file output; omit stream or set it to false.", parameter: "stream")
        }
        guard modes.isValid, streaming ? modes.streaming : modes.completeFiles else {
            throw VoiceServerError(503, code: "response_mode_disabled", message: "This response mode is disabled in VoiceServer settings.")
        }
        guard selection.settings.isValid, selection.modelReady, selection.settings.model != .soprano else { throw VoiceServerError.unavailable }
        guard !(streaming && selection.settings.model == .orpheus) else {
            throw VoiceServerError(503, code: "streaming_unavailable", message: "Orpheus currently supports complete files only. Set stream to false or choose another model.")
        }
        return .init(input: body.input, format: format, streaming: streaming)
    }
}
