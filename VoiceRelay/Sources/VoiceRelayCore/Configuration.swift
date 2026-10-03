import Foundation
import TOMLDecoder

public enum SettingValue: Codable, Sendable, Equatable {
    case string(String), integer(Int), number(Double), bool(Bool), array([SettingValue]), object([String: SettingValue])
    /// JSON checkpoints can decode an integral Double as an integer; both are numeric settings.
    public var numericValue: Double? {
        switch self { case .integer(let value): Double(value); case .number(let value): value; default: nil }
    }
    public init(from decoder: any Decoder) throws {
        // TOML's scalar decoder can still expose its parent keyed container.
        // Try actual scalar values before asking for structural containers.
        if let c = try? decoder.singleValueContainer() {
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Int.self) { self = .integer(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
        }
        if let c = try? decoder.container(keyedBy: SettingKey.self) {
            var values: [String: SettingValue] = [:]
            for key in c.allKeys { values[key.stringValue] = try c.decode(SettingValue.self, forKey: key) }
            self = .object(values); return
        }
        if var c = try? decoder.unkeyedContainer() {
            var values: [SettingValue] = []
            while !c.isAtEnd { values.append(try c.decode(SettingValue.self)) }
            self = .array(values); return
        }
        throw DecodingError.typeMismatch(SettingValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported setting value."))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

private struct SettingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public enum SpeechVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case heart = "af_heart", bella = "af_bella", emma = "bf_emma"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .heart: "Heart · American English"; case .bella: "Bella · American English"; case .emma: "Emma · British English" }
    }
}

/// User-facing choices; technical pipeline defaults remain internal.
public struct SpeechPreferences: Codable, Sendable, Equatable {
    public var voice: SpeechVoice
    public var speed: Double
    public init(voice: SpeechVoice = .heart, speed: Double = 1) { self.voice = voice; self.speed = speed }
    public func validate() throws {
        guard speed.isFinite, (0.75...1.5).contains(speed) else {
            throw RelayError.setup("Choose a speech speed between 0.75 and 1.5.")
        }
    }
}

public enum AppStorage {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceRelayPrototype", isDirectory: true)
    }
    public static var articleLibrary: URL { root.appendingPathComponent("Articles", isDirectory: true) }
    public static var speechFixture: URL { root.appendingPathComponent("SpeechFixture", isDirectory: true) }
}

public struct PrototypeProfile: Codable, Sendable, Equatable {
    public var configurationURL: URL?
    public var safariPlist: URL
    public var database: URL
    public var work: URL
    public var audio: URL
    public var feed: URL
    public var audioBaseURL: URL
    public var feedURL: URL
    public var channelTitle = "VoiceRelay Speech Fixture"
    public var channelDescription = "Isolated pipeline demonstration"
    public var language = "en"
    public var backendSelector = "speech-fixture"
    public var voice: String?
    public var backendSettings: [String: SettingValue] = [:]
    public var chunkMaxCharacters = 1800
    public var bitrate = "64k"
    public var sampleRate = 24000
    public var loudnessLUFS = -16.0
    public var gapSeconds = 0.15
    public var ffmpeg = "ffmpeg"
    public var ffprobe = "ffprobe"
    public var toolTimeoutSeconds = 1800
    public var httpTimeoutSeconds = 30
    public var maxArticleBytes = 10_000_000
    public var minimumFreeBytes = 268_435_456
    public var webdavURL: URL?
    public var webdavUsername: String?
    public var passwordEnvironment = "TTS_PODCAST_WEBDAV_PASSWORD"
    public var compatibilityNotices: [String] = []

    public static func load(_ url: URL) throws -> Self {
        let url = url.standardizedFileURL
        guard url.isFileURL, let bytes = try? Data(contentsOf: url), bytes.count <= 1_048_576,
              let values = try? TOMLDecoder().decode([String: SettingValue].self, from: bytes) else {
            throw RelayError.setup("Cannot load configuration; check file access, TOML syntax, and value types.")
        }
        func string(_ key: String, _ fallback: String) throws -> String {
            guard let v = values[key] else { return fallback }
            guard case .string(let s) = v else { throw RelayError.setup("Configuration value has an incorrect type.") }
            return s
        }
        func integer(_ key: String, _ fallback: Int) throws -> Int {
            guard let v = values[key] else { return fallback }
            guard case .integer(let n) = v else { throw RelayError.setup("Configuration value has an incorrect type.") }
            return n
        }
        func number(_ key: String, _ fallback: Double) throws -> Double {
            guard let v = values[key] else { return fallback }
            switch v {
            case .integer(let n): return Double(n)
            case .number(let n): return n
            default: throw RelayError.setup("Configuration value has an incorrect type.")
            }
        }
        func path(_ key: String, _ fallback: String) throws -> URL {
            let text = (try string(key, fallback) as NSString).expandingTildeInPath
            return URL(fileURLWithPath: text, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        var p = Self(configurationURL: url,
                     safariPlist: try path("safari_plist", "~/Library/Safari/Bookmarks.plist"),
                     database: try path("database_path", "var/state.sqlite3"),
                     work: try path("working_directory", "var/work"),
                     audio: try path("audio_output_directory", "var/podcast"),
                     feed: try path("feed_path", "var/feed.xml"),
                     audioBaseURL: try https(try string("public_audio_base_url", ""), directory: true),
                     feedURL: try https(try string("feed_url", "")))
        p.channelTitle = try string("channel_title", "Private Reading List")
        p.channelDescription = try string("channel_description", "Personal narrated articles")
        p.language = try string("language", "en")
        p.backendSelector = try string("default_tts_backend", "kokoro-mlx-audio")
        p.voice = try string("voice", ""); if p.voice == "" { p.voice = nil }
        if let setting = values["tts_config"] {
            guard case .object(let v) = setting else { throw RelayError.setup("tts_config must be a TOML table.") }
            p.backendSettings = v
        }
        p.chunkMaxCharacters = try integer("chunk_max_chars", 1800)
        p.bitrate = try string("aac_bitrate", "64k")
        p.sampleRate = try integer("sample_rate", 24000)
        p.loudnessLUFS = try number("loudness_lufs", -16)
        p.gapSeconds = try number("segment_gap_seconds", 0.15)
        p.ffmpeg = try string("ffmpeg", "ffmpeg"); p.ffprobe = try string("ffprobe", "ffprobe")
        p.toolTimeoutSeconds = try integer("tool_timeout_seconds", 1800)
        p.httpTimeoutSeconds = try integer("http_timeout_seconds", 30)
        p.maxArticleBytes = try integer("max_article_bytes", 10_000_000)
        p.minimumFreeBytes = try integer("minimum_free_space_bytes", 268_435_456)
        let webdav = try string("webdav_url", "")
        p.webdavURL = webdav.isEmpty ? nil : try https(webdav)
        let user = try string("webdav_username", "")
        p.webdavUsername = user.isEmpty ? nil : user
        p.passwordEnvironment = try string("webdav_password_env", "TTS_PODCAST_WEBDAV_PASSWORD")
        let used: Set<String> = ["safari_plist", "database_path", "working_directory", "audio_output_directory", "feed_path", "public_audio_base_url", "feed_url", "channel_title", "channel_description", "language", "default_tts_backend", "voice", "tts_config", "chunk_max_chars", "aac_bitrate", "sample_rate", "loudness_lufs", "segment_gap_seconds", "ffmpeg", "ffprobe", "tool_timeout_seconds", "http_timeout_seconds", "max_article_bytes", "minimum_free_space_bytes", "webdav_url", "webdav_username", "webdav_password_env"]
        if !Set(values.keys).subtracting(used).isEmpty {
            p.compatibilityNotices.append("Additional legacy settings remain in the source file; native scheduling and backend deadlines are deferred.")
        }
        if p.backendSelector != "kokoro-mlx-audio" {
            p.compatibilityNotices.append("Legacy backend selection is preserved for import diagnostics. Native speech uses the configured project-local Kokoro runtime.")
        }
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("TTS_PODCAST_") }) {
            p.compatibilityNotices.append("Python environment overrides are not applied to native profiles. Secret references are preserved; delivery is disabled.")
        }
        try p.validate(); return p
    }

    public static func https(_ text: String, directory: Bool = false) throws -> URL {
        guard let c = URLComponents(string: text), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!),
              !directory || c.path.hasSuffix("/"), let url = c.url else {
            throw RelayError.setup("Delivery URLs must be HTTPS without credentials, query, or fragment; audio base must end in /.")
        }
        return url
    }

    public func validate() throws {
        _ = try Self.https(audioBaseURL.absoluteString, directory: true)
        _ = try Self.https(feedURL.absoluteString)
        if let webdavURL { _ = try Self.https(webdavURL.absoluteString) }
        guard (100...50_000).contains(chunkMaxCharacters), (8000...48000).contains(sampleRate),
              (-30 ... -10).contains(loudnessLUFS), (0...5).contains(gapSeconds),
              bitrate.range(of: "^[1-9][0-9]{0,2}k$", options: .regularExpression) != nil,
              toolTimeoutSeconds > 0, httpTimeoutSeconds > 0, maxArticleBytes > 0, minimumFreeBytes >= 0 else {
            throw RelayError.setup("Invalid audio, chunk, storage reserve, or timeout settings.")
        }
        guard !Files.contains(audio, database), !Files.contains(audio, work), !Files.contains(audio, feed),
              !Files.contains(work, audio), !Files.contains(audio, safariPlist), !Files.contains(work, safariPlist),
              !Files.samePath(database, feed), !Files.samePath(safariPlist, database),
              !Files.samePath(safariPlist, feed) else {
            throw RelayError.setup("Private artifacts and Safari source must be separate from writable media destinations.")
        }
        func hasSecret(_ values: [String: SettingValue]) -> Bool {
            func nestedSecret(_ value: SettingValue) -> Bool {
                switch value {
                case .object(let children): return hasSecret(children)
                case .array(let children): return children.contains(where: nestedSecret)
                default: return false
                }
            }
            return values.contains { key, value in
                if ["password", "secret", "token", "credential"].contains(where: { key.lowercased().contains($0) }) { return true }
                return nestedSecret(value)
            }
        }
        guard !hasSecret(backendSettings) else { throw RelayError.setup("Backend settings must not contain secrets.") }
    }

    public func isolated(at root: URL) -> Self {
        var p = self
        p.configurationURL = nil
        p.safariPlist = root.appendingPathComponent("private/unused-safari.plist")
        p.database = root.appendingPathComponent("private/native.sqlite3")
        p.work = root.appendingPathComponent("private/work")
        p.audio = root.appendingPathComponent("media")
        p.feed = root.appendingPathComponent("private/feed.xml")
        p.audioBaseURL = URL(string: "https://fixture.invalid/podcast/")!
        p.feedURL = URL(string: "https://fixture.invalid/feed.xml")!
        p.channelTitle = "VoiceRelay Speech Fixture"
        p.channelDescription = "Isolated pipeline demonstration"
        p.backendSelector = "speech-fixture"; p.voice = nil; p.backendSettings = [:]
        p.webdavURL = nil; p.webdavUsername = nil
        p.compatibilityNotices = []
        return p
    }

    public static func fixture(at root: URL) -> Self {
        Self(safariPlist: root.appendingPathComponent("unused.plist"),
             database: root.appendingPathComponent("private/native.sqlite3"),
             work: root.appendingPathComponent("private/work"), audio: root.appendingPathComponent("media"),
             feed: root.appendingPathComponent("private/feed.xml"),
             audioBaseURL: URL(string: "https://fixture.invalid/podcast/")!,
             feedURL: URL(string: "https://fixture.invalid/feed.xml")!)
    }
}

public struct SetupDiagnostic: Identifiable, Sendable {
    public let id: String
    public let ready: Bool
    public let message: String
}

public enum Diagnostics {
    public static func inspect(_ p: PrototypeProfile) -> [SetupDiagnostic] {
        let fm = FileManager.default
        return [
            SetupDiagnostic(id: "configuration", ready: true, message: "Profile imported read-only. Live state adoption is deferred."),
            SetupDiagnostic(id: "storage", ready: fm.fileExists(atPath: p.audio.path), message: fm.fileExists(atPath: p.audio.path) ? "Configured media destination exists; write and mount acceptance remain outstanding." : "Media storage is unavailable. Mount the configured volume; native setup does not create it."),
            SetupDiagnostic(id: "tools", ready: ToolRunner.locate(p.ffmpeg) != nil && ToolRunner.locate(p.ffprobe) != nil, message: "ffmpeg and ffprobe must be available to the app's process."),
            SetupDiagnostic(id: "safari", ready: false, message: "Safari access from the future agent is unverified. Full Disk Access may be required."),
            SetupDiagnostic(id: "backend", ready: false, message: "Native speech uses the project-local Kokoro runtime. Installation, listening and final-agent acceptance are separate checks."),
            SetupDiagnostic(id: "delivery", ready: false, message: "Remote delivery and background processing are disabled in Slices 1–2.")
        ]
    }
}
