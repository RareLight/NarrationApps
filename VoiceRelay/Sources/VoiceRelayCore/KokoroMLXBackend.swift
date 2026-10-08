import Foundation

public struct KokoroConfiguration: Sendable {
    public let projectRoot: URL
    public let voice: String
    public let speed: Double
    public let prepareTimeout: TimeInterval
    public let synthesisTimeout: TimeInterval
    public init(projectRoot: URL, voice: String = "af_heart", speed: Double = 1,
                prepareTimeout: TimeInterval = 180, synthesisTimeout: TimeInterval = 600) throws {
        guard projectRoot.isFileURL, voice.range(of: "^[ab][fm]_[a-z0-9_]+$", options: .regularExpression) != nil,
              speed.isFinite, (0.25...4).contains(speed), prepareTimeout > 0, synthesisTimeout > 0,
              prepareTimeout.isFinite, synthesisTimeout.isFinite else { throw RelayError.setup("Invalid Kokoro runtime, voice, speed, or deadline.") }
        self.projectRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        self.voice = voice; self.speed = speed; self.prepareTimeout = prepareTimeout; self.synthesisTimeout = synthesisTimeout
    }
}

public final class KokoroMLXBackend: LookaheadTTSBackend, Sendable {
    private let helper: ExecutableSpeechBackend
    public var identity: BackendIdentity { helper.identity }
    public init(configuration: KokoroConfiguration, debugLog: DeliveryDebugLog? = nil) throws {
        let root = configuration.projectRoot
        func confined(_ relative: String) throws -> URL {
            let value = root.appendingPathComponent(relative)
            guard Files.contains(root, value) else { throw RelayError.setup("Speech runtime/model paths must remain project-local.") }
            return value
        }
        let source = try confined("runtime/kokoro/provider.py")
        let pins = try confined("runtime/kokoro/selection.json")
        let setup = try confined("runtime/kokoro/runtime_setup.py")
        let lock = try confined("runtime/kokoro/requirements.lock")
        let downloads = try confined("runtime/kokoro/python-downloads.json")
        guard [source, pins, setup, lock, downloads].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RelayError.setup("Select the VoiceRelay project containing its own Kokoro runtime sources and pins.")
        }
        var env = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"] { env.removeValue(forKey: key) }
        let paths = ["HF_HOME": ".runtime/cache/huggingface", "HF_HUB_CACHE": "models/huggingface/hub",
            "HUGGINGFACE_HUB_CACHE": "models/huggingface/hub", "HF_XET_CACHE": ".runtime/cache/huggingface/xet",
            "HF_ASSETS_CACHE": ".runtime/cache/huggingface/assets", "TRANSFORMERS_CACHE": "models/huggingface/hub",
            "XDG_CACHE_HOME": ".runtime/cache/xdg", "XDG_CONFIG_HOME": ".runtime/config", "XDG_DATA_HOME": ".runtime/data",
            "NLTK_DATA": ".runtime/data/nltk"]
        for (key, path) in paths { env[key] = try confined(path).path }
        env["PYTHONNOUSERSITE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"; env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        let python = try confined(".runtime/kokoro/.venv/bin/python")
        // Fingerprint the adapter, pins, interpreter catalog, full dependency lock, configured settings,
        // and selected voice bytes. Runtime preparation verifies model/package pins.
        let voiceFile = try confined("models/kokoro/a71e4d38b236d968966a2002c4c895dbd12b1c3c/voices/\(configuration.voice).safetensors")
        let parts = try [source, pins, setup, lock, downloads].map { try Files.hash($0, description: "speech runtime sources or dependency pins") }
            + [configuration.voice, String(configuration.speed), (try? Files.hash(voiceFile)) ?? "missing-voice",
               (try? Files.hash(confined("models/kokoro/a71e4d38b236d968966a2002c4c895dbd12b1c3c/asset-manifest.json"))) ?? "missing-voice-manifest"]
        let id = "kokoro-mlx-audio-v1-" + Files.hash(Data(parts.joined(separator: "\n").utf8))
        let helperTemporary = AppStorage.temporaryWork.appendingPathComponent("SpeechHelper", isDirectory: true)
        guard helperTemporary.isFileURL, helperTemporary.path != "/",
              !Files.contains(root, helperTemporary), !Files.contains(helperTemporary, root) else {
            throw RelayError.setup("Unsafe helper temporary storage.")
        }
        helper = ExecutableSpeechBackend(identity: BackendIdentity(id: id, displayName: "Kokoro via mlx-audio — speech", isMock: false),
            executable: python, arguments: ["-I", "-B", source.path], environment: env, voice: configuration.voice, speed: configuration.speed,
            prepareTimeout: configuration.prepareTimeout, synthesisTimeout: configuration.synthesisTimeout,
            temporaryRoot: helperTemporary, debugLog: debugLog)
    }
    public func prepare() throws { try helper.prepare() }
    public func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult { try helper.synthesize(request, directory: directory) }
    public func synthesize(_ request: SynthesisRequest, directory: URL, next: SynthesisRequest?) throws -> SynthesisResult {
        try helper.synthesize(request, directory: directory, next: next)
    }
    public func cancel() { helper.cancel() }
}
