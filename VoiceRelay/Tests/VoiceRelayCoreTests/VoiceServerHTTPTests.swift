import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NarrationCore
import ProcessingPipeline
@testable import VoiceRelayCore

private struct UnusedServerRenderer: VoiceServerRenderer {
    func render(_ request: VoiceServerSpeechRequest, selection: VoiceServerSelection, job: SpeechWorkJob,
                control: VoiceServerRequestControl, sink: any VoiceServerAudioSink) async throws { throw VoiceServerError.failed }
}

@Test func voiceServerHTTPAuthenticatesRoutesBoundsBodiesAndNeverAddsCORS() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("api-http-\(UUID())")
    try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
    let c = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: .init(executable: URL(fileURLWithPath: "/synthetic/never-launched")), root: root.appendingPathComponent("admission"))
    let auth = VoiceServerAuthentication(), secret = Data(repeating: 0x42, count: 32)
    try auth.install(secret)
    let token = try VoiceServerAuthentication.presentation(secret)
    let service = try VoiceServerService(coordinator: c, authentication: auth, renderer: UnusedServerRenderer()) {
        .init(settings: .init(), workspace: root, modelReady: false)
    }
    func exchange(_ request: String) async throws -> String {
        let loop = NIOAsyncTestingEventLoop()
        let channel = NIOAsyncTestingChannel(loop: loop)
        try await channel.pipeline.addHandler(VoiceServerWireBound(maximum: 65_536)).get()
        try await channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: false).get()
        try await channel.pipeline.addHandler(VoiceServerHTTPHandler(service: service)).get()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8080)).get()
        var bytes = channel.allocator.buffer(capacity: request.utf8.count); bytes.writeString(request)
        _ = try await channel.writeInbound(bytes)
        var output = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            await loop.run()
            while var frame = try await channel.readOutbound(as: ByteBuffer.self) { output += frame.readString(length: frame.readableBytes) ?? "" }
            if !channel.isActive, !output.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try? await channel.finish(acceptAlreadyClosed: true)
        return output
    }
    let unauthorized = try await exchange("GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n")
    #expect(unauthorized.contains("401 Unauthorized") && unauthorized.contains("invalid_api_key"))
    let metadata = try await exchange("GET /v1/models HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n")
    #expect(metadata.contains("200 OK") && metadata.contains("voicerelay") && metadata.contains("no-store"))
    #expect(!metadata.lowercased().contains("access-control"))
    let legacyHTTP = try await exchange("GET /v1/models HTTP/1.0\r\nAuthorization: Bearer \(token)\r\n\r\n")
    #expect(legacyHTTP.contains("400 Bad Request") && legacyHTTP.contains("HTTP/1.1"))
    let voices = try await exchange("GET /v1/audio/voices HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n")
    #expect(voices.contains("selected_voice") && voices.contains("false"))
    let badRoute = try await exchange("GET /private/file HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n")
    #expect(badRoute.contains("404 Not Found"))
    let wrongType = try await exchange("POST /v1/audio/speech HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n")
    #expect(wrongType.contains("415 Unsupported Media Type"))
    let oversized = try await exchange("POST /v1/audio/speech HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: 65537\r\nExpect: 100-continue\r\n\r\n")
    #expect(oversized.contains("413 Payload Too Large") && !oversized.contains("100 Continue"))
    let header = try await exchange("GET /v1/models HTTP/1.1\r\nX-Large: " + String(repeating: "x", count: 8_193))
    #expect(header.contains("413 Payload Too Large"))
    let payload = "{\"input\":\"Private test text\"}"
    let unavailable = try await exchange("POST /v1/audio/speech HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)")
    #expect(unavailable.contains("503 Service Unavailable") && unavailable.contains("model_unavailable"))
    #expect(!unavailable.contains("Private test text"))
    #expect(await service.status == .init(active: 0, queued: 0))
    await service.stop(); await c.close()
}

@Test func voiceServerBindingsRejectWildcardsAndBuildIPv6URLs() throws {
    for address in ["0.0.0.0", "::", "localhost", "https://example.test", ""] {
        #expect(throws: VoiceServerError.self) { try VoiceServerBinding(address: address, port: 8_080) }
    }
    let v6 = try VoiceServerBinding(address: "::1", port: 8_080)
    #expect(v6.baseURL?.absoluteString == "http://[::1]:8080/v1")
    #expect(throws: VoiceServerError.self) { try VoiceServerBinding(address: "127.0.0.1", port: 0) }
}

private final class StalledAudioWrite: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart
    private var pending: EventLoopPromise<Void>?
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .body = unwrapOutboundIn(data) { pending = promise }
        else { context.write(data, promise: promise) }
    }
    func handlerRemoved(context: ChannelHandlerContext) { pending?.fail(ChannelError.ioOnClosedChannel); pending = nil }
}

@Test func voiceServerHTTPStalledWriteHasBoundedDeadlineAndCancellationWakeup() async throws {
    for explicitCancel in [false, true] {
        let channel = await NIOAsyncTestingChannel(handler: StalledAudioWrite())
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8080)).get()
        let control = VoiceServerRequestControl()
        let sink = VoiceServerHTTPSink(channel: channel, control: control, seconds: explicitCancel ? 1 : 0.03)
        let started = ContinuousClock.now
        let writer = Task.detached { () -> Bool in
            do {
                try sink.begin(format: .pcm, contentLength: nil)
                try sink.write(Data(repeating: 0, count: 16_384))
                return false
            } catch { return true }
        }
        if explicitCancel { try await Task.sleep(for: .milliseconds(10)); control.cancel() }
        #expect(await writer.value)
        #expect(control.isCancelled && started.duration(to: .now) < .seconds(1))
        _ = try? await channel.finish(acceptAlreadyClosed: true)
    }
}
