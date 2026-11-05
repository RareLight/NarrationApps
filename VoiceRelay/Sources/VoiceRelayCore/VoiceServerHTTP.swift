import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// One explicit address per listener. Wildcards and host-name resolution are
/// deliberately excluded; discovery must supply an existing local IP address.
public struct VoiceServerBinding: Sendable, Equatable, Hashable {
    public let address: String
    public let port: Int
    public init(address: String, port: Int) throws {
        guard (1...65_535).contains(port), address != "0.0.0.0", address != "::",
              (try? SocketAddress(ipAddress: address, port: port)) != nil else { throw VoiceServerError.failed }
        self.address = address; self.port = port
    }
    public var baseURL: URL? {
        var parts = URLComponents(); parts.scheme = "http"; parts.host = address.contains(":") ? "[\(address)]" : address; parts.port = port; parts.path = "/v1"
        return parts.url
    }
}

/// Listener ownership ends only after child sockets close and service work joins.
/// No live listener is created by construction or by fixture tests.
public actor VoiceServerHTTP {
    private let service: VoiceServerService
    private let group: MultiThreadedEventLoopGroup
    private let connections: VoiceServerConnections
    private var listeners: [VoiceServerBinding: any Channel] = [:]
    private var stopped = false
    private var stopFinished = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    public init(service: VoiceServerService) {
        self.service = service; group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        connections = VoiceServerConnections(maximum: service.limits.maximumConnections)
    }
    public func start(_ bindings: [VoiceServerBinding]) async throws {
        guard !stopped, listeners.isEmpty, !bindings.isEmpty, Set(bindings).count == bindings.count else { throw VoiceServerError.failed }
        do {
            for binding in bindings {
                let service = service, connections = connections
                let channel = try await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 16_384, high: 65_536))
                    .childChannelInitializer { channel in
                        guard connections.insert(channel) else { return channel.close() }
                        channel.closeFuture.whenComplete { _ in connections.remove(channel) }
                        return channel.pipeline.addHandler(VoiceServerWireBound(maximum: service.limits.maximumBodyBytes))
                            .flatMap { channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: false) }
                            .flatMap { channel.pipeline.addHandler(VoiceServerHTTPHandler(service: service)) }
                    }.bind(to: SocketAddress(ipAddress: binding.address, port: binding.port)).get()
                guard !stopped else { try? await channel.close().get(); throw CancellationError() }
                listeners[binding] = channel
            }
        } catch { await stop(); throw VoiceServerError(503, code: "listener_unavailable", message: "VoiceServer could not bind the selected address and port.") }
    }
    public func stop() async {
        if stopped {
            if !stopFinished { await withCheckedContinuation { stopWaiters.append($0) } }
            return
        }
        stopped = true
        let servers = Array(listeners.values); listeners.removeAll()
        for channel in servers { try? await channel.close().get() }
        for channel in connections.snapshot { try? await channel.close().get() }
        await service.stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully(queue: .global(qos: .utility)) { _ in continuation.resume() }
        }
        stopFinished = true
        let waiters = stopWaiters; stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class VoiceServerConnections: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var channels: [ObjectIdentifier: any Channel] = [:]
    init(maximum: Int) { self.maximum = maximum }
    func insert(_ channel: any Channel) -> Bool {
        lock.withLock {
            guard channels.count < maximum else { return false }
            channels[ObjectIdentifier(channel)] = channel; return true
        }
    }
    func remove(_ channel: any Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    var snapshot: [any Channel] { lock.withLock { Array(channels.values) } }
}

/// Bounds bytes before HTTPDecoder can accumulate headers. This server accepts
/// one request per connection, so the total byte cap also bounds pipelined input.
final class VoiceServerWireBound: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private var header: [UInt8] = []
    private var headerDone = false
    private var received = 0
    private var rejected = false
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        let buffer = unwrapInboundIn(data)
        received += buffer.readableBytes
        var valid = received <= maximum + 8_192
        if !headerDone {
            for byte in buffer.readableBytesView {
                header.append(byte)
                if header.count > 8_192 { valid = false; break }
                if header.count >= 4, header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    headerDone = true; header.removeAll(keepingCapacity: false); break
                }
            }
        }
        guard valid else {
            rejected = true
            let body = VoiceServerError(413, code: "request_too_large", message: "The HTTP request exceeds the supported size.").json
            var response = context.channel.allocator.buffer(capacity: body.count + 180)
            response.writeString("HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n")
            response.writeBytes(body)
            let channel = context.channel
            context.writeAndFlush(NIOAny(response)).whenComplete { _ in channel.close(promise: nil) }
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }
}

final class VoiceServerHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let service: VoiceServerService
    private let control = VoiceServerRequestControl()
    private var sink: VoiceServerHTTPSink?
    private var route: String?
    private var grant: UUID?
    private var body = Data()
    private var receiving = false
    private var responded = false
    private var task: Task<Void, Never>?
    private var readDeadline: Scheduled<Void>?
    init(service: VoiceServerService) { self.service = service }
    func channelActive(context: ChannelHandlerContext) {
        sink = VoiceServerHTTPSink(channel: context.channel, control: control, seconds: service.limits.writeSeconds)
        let channel = context.channel, control = control
        readDeadline = context.eventLoop.scheduleTask(in: .nanoseconds(Int64(service.limits.headerBodySeconds * 1_000_000_000))) {
            control.cancel(); channel.close(promise: nil)
        }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard !receiving, !responded else { reject(.init(400, code: "one_request_required", message: "Use one request per connection.")); return }
            guard let authorized = service.authentication.authorize(head.headers["authorization"].count == 1 ? head.headers.first(name: "authorization") : nil) else {
                reject(.unauthorized); return
            }
            guard head.version == .http1_1, head.uri.utf8.count <= 128 else { reject(.init(400, code: "invalid_request", message: "Use an HTTP/1.1 API request.")); return }
            let expectedMethod: HTTPMethod
            switch head.uri {
            case "/v1/models", "/v1/audio/voices": expectedMethod = .GET
            case "/v1/audio/speech": expectedMethod = .POST
            default: reject(.init(404, code: "not_found", message: "The API route does not exist.")); return
            }
            guard head.method == expectedMethod else { reject(.init(405, code: "method_not_allowed", message: "The method is not supported for this route.")); return }
            if head.method == .POST {
                let types = head.headers["content-type"]
                guard types.count == 1, Self.validContentType(types[0]) else { reject(.init(415, code: "unsupported_media_type", message: "Use Content-Type application/json with UTF-8 encoding.")); return }
            }
            if let length = head.headers.first(name: "content-length"), Int(length).map({ $0 > service.limits.maximumBodyBytes }) ?? true {
                reject(.init(413, code: "body_too_large", message: "The request body exceeds the supported size.")); return
            }
            guard head.headers["content-encoding"].isEmpty else { reject(.init(415, code: "unsupported_encoding", message: "Compressed request bodies are not supported.")); return }
            if !head.headers["expect"].isEmpty {
                guard head.headers["expect"].count == 1, head.headers.first(name: "expect")?.lowercased() == "100-continue" else {
                    reject(.init(417, code: "unsupported_expectation", message: "The request expectation is not supported.")); return
                }
                context.writeAndFlush(wrapOutboundOut(.head(.init(version: .http1_1, status: .continue))), promise: nil)
            }
            receiving = true; route = head.uri; grant = authorized
        case .body(let buffer):
            guard receiving, !responded else { return }
            guard body.count + buffer.readableBytes <= service.limits.maximumBodyBytes else { reject(.init(413, code: "body_too_large", message: "The request body exceeds the supported size.")); return }
            body.append(contentsOf: buffer.readableBytesView)
        case .end(let trailers):
            guard receiving, !responded, let route, let grant, let sink else { return }
            guard trailers == nil else { reject(.init(400, code: "unsupported_trailers", message: "Request trailers are not supported.")); return }
            readDeadline?.cancel(); readDeadline = nil; responded = true; receiving = false
            let payload = body; body.removeAll(keepingCapacity: false)
            let service = service, control = control
            task = Task {
                if route == "/v1/audio/speech" { await service.speech(body: payload, grant: grant, control: control, sink: sink) }
                else {
                    do {
                        guard payload.isEmpty else { throw VoiceServerError(400, code: "unexpected_body", message: "Metadata requests must not have a body.") }
                        let bytes = try await service.metadata(voices: route == "/v1/audio/voices", grant: grant)
                        sink.metadata(bytes)
                    } catch let error as VoiceServerError { sink.fail(error) }
                    catch { sink.fail(.failed) }
                }
            }
        }
    }
    static func validContentType(_ value: String) -> Bool {
        let fields = value.lowercased().split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return fields == ["application/json"] || fields == ["application/json", "charset=utf-8"] || fields == ["application/json", "charset=\"utf-8\""]
    }
    private func reject(_ error: VoiceServerError) { responded = true; receiving = false; body.removeAll(); readDeadline?.cancel(); sink?.fail(error) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { reject(.init(400, code: "invalid_http", message: "The HTTP request could not be parsed.")) }
    func channelInactive(context: ChannelHandlerContext) {
        readDeadline?.cancel(); control.cancel(); task?.cancel(); body.removeAll()
        context.fireChannelInactive()
    }
}

/// Only the admitted CPU renderer calls blocking writes. One <=16 KiB chunk is
/// outstanding; cancellation wakes the waiter and closes the socket. No event
/// loop, main actor or inference callback waits for network backpressure.
final class VoiceServerHTTPSink: VoiceServerAudioSink, @unchecked Sendable {
    private let channel: any Channel
    private let control: VoiceServerRequestControl
    private let seconds: TimeInterval
    private let lock = NSLock()
    private var began = false
    private var ended = false
    init(channel: any Channel, control: VoiceServerRequestControl, seconds: TimeInterval) {
        self.channel = channel; self.control = control; self.seconds = seconds
    }
    func begin(format: VoiceServerFormat, contentLength: UInt64?) throws {
        try control.check()
        guard lock.withLock({ if began || ended { return false }; began = true; return true }) else { throw CancellationError() }
        try wait(channel.writeAndFlush(HTTPServerResponsePart.head(head(status: .ok, type: format.contentType, length: contentLength))))
    }
    func write(_ bytes: Data) throws {
        try control.check()
        guard !bytes.isEmpty, bytes.count <= 16_384, lock.withLock({ began && !ended }) else { throw VoiceServerError.failed }
        var buffer = channel.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
        try wait(channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))))
    }
    func finish() throws {
        guard lock.withLock({ if !began || ended { return false }; ended = true; return true }) else { throw CancellationError() }
        try wait(channel.writeAndFlush(HTTPServerResponsePart.end(nil)))
        channel.close(promise: nil)
    }
    func metadata(_ bytes: Data) { respond(status: .ok, bytes: bytes) }
    func fail(_ error: VoiceServerError) { respond(status: .init(statusCode: error.status), bytes: error.json) }
    private func respond(status: HTTPResponseStatus, bytes: Data) {
        let canSend = lock.withLock { if ended { return false }; ended = true; if began { return false }; began = true; return true }
        guard canSend else { channel.close(promise: nil); return }
        let channel = channel, response = head(status: status, type: "application/json", length: UInt64(bytes.count))
        channel.eventLoop.execute {
            channel.write(HTTPServerResponsePart.head(response), promise: nil)
            var buffer = channel.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
        }
    }
    func abort() { lock.withLock { ended = true }; channel.close(promise: nil) }
    private func head(status: HTTPResponseStatus, type: String, length: UInt64?) -> HTTPResponseHead {
        var headers = HTTPHeaders([("content-type", type), ("cache-control", "no-store"), ("connection", "close")])
        if let length { headers.add(name: "content-length", value: String(length)) }
        else { headers.add(name: "transfer-encoding", value: "chunked") }
        return .init(version: .http1_1, status: status, headers: headers)
    }
    private func wait(_ future: EventLoopFuture<Void>) throws {
        precondition(!channel.eventLoop.inEventLoop)
        let waiter = VoiceServerWriteWaiter()
        let hook = control.onCancel { waiter.cancel() }
        defer { control.removeHook(hook) }
        future.whenComplete { waiter.complete($0) }
        do { try waiter.wait(seconds: seconds); try control.check() }
        catch { control.cancel(); channel.close(promise: nil); throw error }
    }
}

private final class VoiceServerWriteWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Void, any Error>?
    func complete(_ value: Result<Void, any Error>) { condition.lock(); if result == nil { result = value }; condition.broadcast(); condition.unlock() }
    func cancel() { complete(.failure(CancellationError())) }
    func wait(seconds: TimeInterval) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        condition.lock(); defer { condition.unlock() }
        while result == nil {
            guard ContinuousClock.now < deadline else { throw VoiceServerError.deadline }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(seconds, 0.05)))
        }
        try result?.get()
    }
}
