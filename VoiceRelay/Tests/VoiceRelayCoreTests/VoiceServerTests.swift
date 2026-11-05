import Foundation
import Testing
import Security
import LocalAuthentication
import NativeSpeech
import NarrationCore
import ProcessingPipeline
import AudioOutput
@testable import VoiceRelayCore

private func serverSelection(_ model: SpeechModel = .kokoro, ready: Bool = true) -> VoiceServerSelection {
    .init(settings: .init(model: model, voice: model.defaultVoice), workspace: URL(fileURLWithPath: "/synthetic/server-models"), modelReady: ready)
}
private func speechBody(_ extra: [String: Any] = [:], input: String = "Exact authored text.") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["input": input].merging(extra) { _, value in value })
}

@Test func voiceServerDefaultsMatchSDKBinaryStreamingAndPreserveInput() throws {
    let source = "  Exact source — including\nparagraphs and spelling.  "
    let request = try VoiceServerSpeechRequest.decode(speechBody(["model": "voicerelay", "voice": "default", "stream_format": "audio"], input: source), selection: serverSelection())
    #expect(request.streaming && request.format == .mp3 && request.input == source)
    #expect(request.delivery == .streaming)
    let pcm = try VoiceServerSpeechRequest.decode(speechBody(["response_format": "pcm"]), selection: serverSelection())
    #expect(pcm.streaming && pcm.format == .pcm)
    let wav = try VoiceServerSpeechRequest.decode(speechBody(["response_format": "wav"]), selection: serverSelection())
    #expect(!wav.streaming && wav.delivery == .file)
    let buffered = try VoiceServerSpeechRequest.decode(speechBody(["stream": false]), selection: serverSelection())
    #expect(!buffered.streaming && buffered.format == .mp3)
}

@Test func voiceServerRejectsUnsupportedOrMismatchedOptionsBeforeWork() throws {
    let selection = serverSelection()
    for fields: [String: Any] in [
        ["model": "remote-model"], ["voice": "other"], ["speed": 2],
        ["stream_format": "sse"], ["response_format": "aac"],
        ["response_format": "wav", "stream": true], ["instructions": "private instruction"],
        ["reference_audio": "/private/reference.wav"], ["stream": "true"]
    ] {
        #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(fields), selection: selection) }
    }
    let exact = try VoiceServerSpeechRequest.decode(speechBody(["voice": selection.settings.voice, "speed": 1]), selection: selection)
    #expect(exact.streaming)
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(input: "  \n"), selection: selection) }
    var limits = VoiceServerLimits(); limits.maximumInputBytes = 4
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(input: "ééé"), selection: selection, limits: limits) }
    limits.maximumBodyBytes = 1
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(), selection: selection, limits: limits) }
}

@Test func voiceServerCapabilityFailuresNeverSilentlyChangeResponseModeOrModel() throws {
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(), selection: serverSelection(.orpheus)) }
    let orpheus = try VoiceServerSpeechRequest.decode(speechBody(["stream": false]), selection: serverSelection(.orpheus))
    #expect(!orpheus.streaming)
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(), selection: serverSelection(ready: false)) }
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(), selection: serverSelection(.soprano)) }
    let files = VoiceServerResponseModes(streaming: false, completeFiles: true)
    #expect(throws: VoiceServerError.self) { try VoiceServerSpeechRequest.decode(speechBody(), selection: serverSelection(), modes: files) }
    let explicit = try VoiceServerSpeechRequest.decode(speechBody(["stream": false]), selection: serverSelection(), modes: files)
    #expect(!explicit.streaming)
    #expect(!VoiceServerResponseModes(streaming: false, completeFiles: false).isValid)
}

@Test func voiceServerBearerRotationRevokesEarlierGrantsAndRejectsMalformedHeaders() throws {
    let auth = VoiceServerAuthentication(), old = Data(repeating: 0x31, count: 32), new = Data(repeating: 0x32, count: 32)
    #expect(auth.authorize(nil) == nil && !auth.isConfigured)
    try auth.install(old)
    let token = try VoiceServerAuthentication.presentation(old)
    let grant = try #require(auth.authorize("bEaReR " + token))
    #expect(auth.isCurrent(grant))
    for header in [token, "Bearer wrong", "Bearer  " + token, "Bearer " + token + " ", String(repeating: "x", count: 129)] {
        #expect(auth.authorize(header) == nil)
    }
    try auth.install(new)
    #expect(!auth.isCurrent(grant) && auth.authorize("Bearer " + token) == nil)
    #expect(auth.authorize("Bearer " + (try VoiceServerAuthentication.presentation(new))) != nil)
    try auth.install(nil)
    #expect(!auth.isConfigured)
    #expect(throws: VoiceServerCredentialFailure.self) { try auth.install(Data([1])) }
    #expect(try VoiceServerAuthentication.generate().count == 32)
}

@Test func voiceServerKeychainUsesPrivateNoPromptQueriesAndOwnService() throws {
    let secret = Data(repeating: 0x31, count: 32)
    let operations = KeychainCredentialStore.Operations(read: { query in
        #expect(query[kSecAttrService as String] as? String == VoiceServerKeychain.service)
        #expect(query[kSecAttrService as String] as? String != KeychainCredentialStore.service)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        return (errSecSuccess, secret as CFData)
    }, add: { attributes in
        #expect(attributes[kSecValueData as String] as? Data == secret)
        #expect(attributes[kSecAttrAccessControl as String] != nil)
        return errSecDuplicateItem
    }, update: { query, values in
        #expect(query[kSecAttrService as String] as? String == VoiceServerKeychain.service)
        #expect(values[kSecValueData as String] as? Data == secret && values[kSecAttrAccessControl as String] != nil)
        return errSecSuccess
    }, delete: { _ in Issue.record("Key rotation must not delete existing credentials"); return errSecSuccess })
    let store = VoiceServerKeychain(operations: operations)
    #expect(try store.read() == secret)
    try store.save(secret)
    #expect(throws: VoiceServerCredentialFailure.self) { try store.save(Data([1])) }
}

@Test func voiceServerErrorsContainOnlyControlledFields() throws {
    let error = VoiceServerError.failed
    let object = try #require(JSONSerialization.jsonObject(with: error.json) as? [String: Any])
    let detail = try #require(object["error"] as? [String: Any])
    #expect(detail["code"] as? String == "speech_failed" && detail["type"] as? String == "server_error")
    #expect(Set(detail.keys).isSubset(of: ["message", "type", "param", "code"]))
}

private final class ServerSink: VoiceServerAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data(), completed = false, starts = 0
    private var length: UInt64?
    var result: (Data, Bool, Int, UInt64?) { lock.withLock { (bytes, completed, starts, length) } }
    func begin(format: VoiceServerFormat, contentLength: UInt64?) throws { lock.withLock { starts += 1; length = contentLength } }
    func write(_ data: Data) throws {
        #expect(data.count <= 16_384)
        lock.withLock { bytes.append(data) }
    }
    func finish() throws { lock.withLock { completed = true } }
    func fail(_ error: VoiceServerError) { Issue.record("Unexpected controlled error \(error.code)") }
    func abort() {}
}

@Test func voiceServerResponseWriterBoundsLargePCMChunksWithoutGainAndCleansOnLimit() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("api-pcm-bounds-\(UUID())")
    try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
    let request = try VoiceServerSpeechRequest.decode(speechBody(["response_format": "pcm"]), selection: serverSelection())
    let sink = ServerSink(), control = VoiceServerRequestControl()
    let output = try VoiceServerResponseAudio(request: request, sampleRate: 24_000, limits: .init(), mp3Library: nil,
        parent: root, control: control, sink: sink)
    try output.append([Float](repeating: 0.25, count: 20_000), gap: 0); try output.finish()
    let bytes = sink.result.0
    #expect(bytes.count == 40_000 && sink.result.1 && sink.result.2 == 1)
    #expect(stride(from: 0, to: bytes.count, by: 2).allSatisfy { bytes[$0] == 0 && bytes[$0 + 1] == 0x20 })
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    var limits = VoiceServerLimits(); limits.maximumOutputBytes = 65_537
    let limited = try VoiceServerResponseAudio(request: request, sampleRate: 24_000, limits: limits, mp3Library: nil,
        parent: root, control: .init(), sink: ServerSink())
    #expect(throws: AudioStreamFailure.self) { try limited.append([Float](repeating: 0.25, count: 40_000), gap: 0) }
    limited.abort()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func voiceServerNativeRendererUsesOneHelperAndCleansPrivateResponseFiles() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("api-render-\(UUID())")
    try Files.directory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try #require(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
    let c = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: .init(executable: URL(fileURLWithPath: executable),
        arguments: ["--handoff-probe"], environment: ["NARRATION_FIXTURE_SYNTHETIC_PCM": "1"],
        inferenceLeaseFile: root.appendingPathComponent("inference.lock")), root: root.appendingPathComponent("admission"))
    let output = root.appendingPathComponent("responses"); try Files.directory(output)
    let codec = ProcessInfo.processInfo.environment["NARRATION_MP3_LIBRARY"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("swift-packages/.build/codecs/lame/lib/libmp3lame.0.dylib")
    let renderer = NativeVoiceServerRenderer(coordinator: c, mp3Library: codec, responseRoot: output)
    let selection = VoiceServerSelection(settings: .init(), workspace: root, modelReady: true)
    do {
        for format in ["pcm", "wav", "mp3"] {
            let request = try VoiceServerSpeechRequest.decode(speechBody(["response_format": format], input: "First complete sentence.\n\nSecond complete paragraph."), selection: selection)
            let control = VoiceServerRequestControl(), sink = ServerSink()
            let job = try await c.openJob(identity: .init(batch: UUID(), job: UUID()), settings: selection.settings,
                workspace: root, rank: .api, delivery: request.delivery, cancelled: { control.isCancelled })
            try await renderer.render(request, selection: selection, job: job, control: control, sink: sink)
            let result = sink.result
            #expect(!result.0.isEmpty && result.1 && result.2 == 1)
            #expect(format == "wav" ? result.3 == UInt64(result.0.count) : result.3 == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            await c.closeJob(job)
        }
        await c.close()
    } catch { await c.close(); throw error }
}
