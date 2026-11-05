import Foundation
import Testing
import NarrationCore
import ProcessingPipeline
@testable import VoiceRelayCore

private actor ServerRenderBarrier: VoiceServerRenderer {
    private var started: [String] = []
    private var permitted: Set<String> = []
    func allow(_ value: String) { permitted.insert(value) }
    var order: [String] { started }
    func render(_ request: VoiceServerSpeechRequest, selection: VoiceServerSelection, job: SpeechWorkJob,
                control: VoiceServerRequestControl, sink: any VoiceServerAudioSink) async throws {
        started.append(request.input)
        while !permitted.contains(request.input) {
            try control.check(); try await Task.sleep(for: .milliseconds(2))
        }
        try control.check()
        try sink.begin(format: .pcm, contentLength: 2); try sink.write(Data([0, 0])); try sink.finish()
    }
}
private final class ServerServiceSink: VoiceServerAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var code: String?, finished = false, aborted = false
    var result: (String?, Bool, Bool) { lock.withLock { (code, finished, aborted) } }
    func begin(format: VoiceServerFormat, contentLength: UInt64?) throws {}
    func write(_ bytes: Data) throws {}
    func finish() throws { lock.withLock { finished = true } }
    func fail(_ error: VoiceServerError) { lock.withLock { code = error.code } }
    func abort() { lock.withLock { aborted = true } }
}
private func awaitServerState(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw VoiceServerError.deadline }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Test func voiceServerServicePreservesFIFORejectsOverloadAndJoinsCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("api-service-\(UUID())")
    try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: .init(executable: URL(fileURLWithPath: "/synthetic/not-launched")), root: root.appendingPathComponent("admission"))
    let auth = VoiceServerAuthentication(), secret = Data(repeating: 0x55, count: 32)
    try auth.install(secret)
    let grant = try #require(auth.authorize("Bearer " + VoiceServerAuthentication.presentation(secret)))
    let renderer = ServerRenderBarrier()
    var limits = VoiceServerLimits(); limits.maximumQueuedRequests = 1
    let service = try VoiceServerService(coordinator: coordinator, authentication: auth, renderer: renderer, limits: limits) {
        .init(settings: .init(), workspace: root, modelReady: true)
    }
    func submit(_ value: String, sink: ServerServiceSink, control: VoiceServerRequestControl = .init()) -> Task<Void, Never> {
        let body = Data("{\"input\":\"\(value)\",\"response_format\":\"pcm\"}".utf8)
        return Task { await service.speech(body: body, grant: grant, control: control, sink: sink) }
    }
    let a = ServerServiceSink(), b = ServerServiceSink(), c = ServerServiceSink()
    let first = submit("A", sink: a)
    try await awaitServerState { await renderer.order == ["A"] }
    let second = submit("B", sink: b)
    try await awaitServerState { await service.status.queued == 1 }
    let third = submit("C", sink: c); await third.value
    #expect(c.result.0 == "queue_full")
    await renderer.allow("A"); await first.value
    try await awaitServerState { await renderer.order == ["A", "B"] }
    #expect(a.result.1 && !b.result.1)
    second.cancel(); await second.value
    #expect(b.result.2)
    #expect(await service.status == .init(active: 0, queued: 0))
    let stopped = submit("D", sink: ServerServiceSink())
    try await awaitServerState { await service.status.active == 1 }
    await service.stop(); await stopped.value
    #expect(await service.status == .init(active: 0, queued: 0))
    let refused = ServerServiceSink(); await submit("E", sink: refused).value
    #expect(refused.result.0 == "invalid_api_key")
    await coordinator.close()
}

@Test func voiceServerDiscoveryUsesOnlySelfStateAndExplicitExistingAddresses() throws {
    let status = try VoiceServerTailscaleStatus.parse(Data(#"{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.4","fd7a:115c:a1e0::4"],"DNSName":"anna.example.ts.net."},"Peer":{"private":"must not be retained"}}"#.utf8))
    #expect(status.connected && status.addresses.count == 2 && status.magicDNS == "anna.example.ts.net")
    #expect(status.baseURL(port: 8080)?.absoluteString == "http://anna.example.ts.net:8080/v1")
    for json in [#"{"BackendState":"Stopped","Self":{"TailscaleIPs":["100.64.0.4"]}}"#,
                 #"{"BackendState":"NeedsLogin"}"#, #"{}"#] {
        #expect(try VoiceServerTailscaleStatus.parse(Data(json.utf8)) == .unavailable)
    }
    let noDNS = try VoiceServerTailscaleStatus.parse(Data(#"{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.4"],"DNSName":""}}"#.utf8))
    #expect(noDNS.connected && noDNS.magicDNS == nil)
    var configuration = VoiceServerConfiguration()
    #expect(!configuration.enabled && configuration.access == nil)
    #expect(throws: VoiceServerError.self) { try configuration.bindings(local: [], tailscale: status) }
    configuration.access = .loopback
    #expect(try configuration.bindings(local: [], tailscale: .unavailable).map(\.address) == ["127.0.0.1", "::1"])
    configuration.access = .tailscale; configuration.addresses = ["100.64.0.4"]
    #expect(try configuration.bindings(local: ["100.64.0.4"], tailscale: status).count == 3)
    #expect(throws: VoiceServerError.self) { try configuration.bindings(local: ["192.168.1.3"], tailscale: status) }
    #expect(throws: VoiceServerError.self) { try configuration.bindings(local: ["100.64.0.4"], tailscale: .unavailable) }
    configuration.access = .otherVPN; configuration.addresses = ["192.168.1.3"]
    #expect(try configuration.bindings(local: ["192.168.1.3"], tailscale: .unavailable).count == 3)
    configuration.addresses = ["0.0.0.0"]
    #expect(throws: VoiceServerError.self) { try configuration.bindings(local: ["0.0.0.0"], tailscale: .unavailable) }
}
