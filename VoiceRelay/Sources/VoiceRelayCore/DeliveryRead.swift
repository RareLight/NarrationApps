import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

public struct RemoteAudioDigest: Sendable {
    public let status: Int
    public let byteLength: Int64
    public let sha256: String
    public var etag: String? = nil
}

public struct VerifiedRemoteAudio: Sendable {
    public let digest: RemoteAudioDigest
    public let info: AudioInfo?
}

struct ServerAudioProof: Codable, Sendable, Equatable {
    let hash: String
    let info: AudioInfo
    let etag: String?
    let checkedAt: Date
}

extension DeliveryTransport {
    /// Default implementations keep injected transports independently testable.
    public func read(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> DeliveryResponse {
        let response = try await request("GET", url: url, body: nil, file: nil, headers: headers)
        guard response.body.count <= maximumBytes,
              response.status != 200 || response.contentLength == nil || response.contentLength == Int64(response.body.count) else {
            throw DeliveryError.fatal("The server response exceeded the recovery limit or was incomplete.")
        }
        return response
    }
    public func digest(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> RemoteAudioDigest {
        let response = try await read(url, headers: headers, maximumBytes: maximumBytes)
        return RemoteAudioDigest(status: response.status, byteLength: Int64(response.body.count), sha256: Files.hash(response.body), etag: response.header("etag"))
    }
    public func verifiedAudio(_ url: URL, headers: [String: String], maximumBytes: Int64, settings: PrototypeProfile) async throws -> VerifiedRemoteAudio {
        let response = try await read(url, headers: headers, maximumBytes: maximumBytes)
        let digest = RemoteAudioDigest(status: response.status, byteLength: Int64(response.body.count), sha256: Files.hash(response.body), etag: response.header("etag"))
        guard response.status == 200 else { return VerifiedRemoteAudio(digest: digest, info: nil) }
        return try await ServerAudioValidation.inspect(settings: settings) { file in
            try Files.write(response.body, to: file)
            return digest
        }
    }
}

struct InvalidServerAudio: Error {}

private enum ServerAudioValidation {
    static func inspect(settings: PrototypeProfile, download: (URL) async throws -> RemoteAudioDigest) async throws -> VerifiedRemoteAudio {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceRelayPrototype/ServerVerification/\(UUID().uuidString)")
        try Files.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("verification.m4a")
        let digest = try await download(file)
        guard digest.status == 200 else { return VerifiedRemoteAudio(digest: digest, info: nil) }
        let inspection = Task.detached {
            let audio = AudioProcessor(settings: settings, toolDirectory: root)
            do {
                let info = try audio.probe(file, final: true)
                try audio.decode(file); return info
            } catch is CancellationError { throw CancellationError() }
            catch let error as RelayError {
                switch error { case .artifact: throw InvalidServerAudio(); default: throw error }
            }
        }
        let info = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        return VerifiedRemoteAudio(digest: digest, info: info)
    }
}

extension URLSessionDeliveryTransport {
    public func verifiedAudio(_ url: URL, headers: [String: String], maximumBytes: Int64, settings: PrototypeProfile) async throws -> VerifiedRemoteAudio {
        try await ServerAudioValidation.inspect(settings: settings) { file in
            try await receive(url, headers: headers, maximumBytes: maximumBytes, retainBody: false, destination: file).0
        }
    }
    public func read(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> DeliveryResponse {
        let value = try await receive(url, headers: headers, maximumBytes: maximumBytes, retainBody: true)
        return DeliveryResponse(status: value.0.status, headers: value.1, body: value.2)
    }
    public func digest(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> RemoteAudioDigest {
        try await receive(url, headers: headers, maximumBytes: maximumBytes, retainBody: false).0
    }
    /// Stream through a bounded SHA-256 buffer: recovery does not keep another
    /// local audio copy or load an entire episode into memory.
    private func receive(_ url: URL, headers: [String: String], maximumBytes: Int64,
                         retainBody: Bool, destination: URL? = nil) async throws -> (RemoteAudioDigest, [String: String], Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 300)
        let session = URLSession(configuration: configuration, delegate: DeliverySessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                var request = URLRequest(url: url); request.httpMethod = "GET"
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw DeliveryError.retryable("The server did not answer over HTTP.") }
                var normalized: [String: String] = [:]
                for (key, value) in http.allHeaderFields { normalized[String(describing: key).lowercased()] = String(describing: value) }
                guard http.statusCode == 200 else { return (RemoteAudioDigest(status: http.statusCode, byteLength: 0, sha256: ""), normalized, Data()) }
                let output: FileHandle?
                if let destination { try Files.write(Data(), to: destination); output = try FileHandle(forWritingTo: destination) }
                else { output = nil }
                defer { try? output?.close() }
                let reported = DeliveryResponse(status: 200, headers: normalized).contentLength
                guard maximumBytes > 0, reported == nil || reported! <= maximumBytes else {
                    throw DeliveryError.fatal("The server response exceeded the recovery limit.")
                }
                var hash = SHA256(), buffer = Data(), body = Data(), count: Int64 = 0
                buffer.reserveCapacity(65_536)
                for try await byte in bytes {
                    count += 1
                    guard count <= maximumBytes else { throw DeliveryError.fatal("The server response exceeded the recovery limit.") }
                    buffer.append(byte)
                    if buffer.count == 65_536 {
                        try Task.checkCancellation(); hash.update(data: buffer)
                        if retainBody { body.append(buffer) }; try output?.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                guard reported == nil || count == reported else { throw DeliveryError.fatal("The server response was incomplete.") }
                hash.update(data: buffer); if retainBody { body.append(buffer) }; try output?.write(contentsOf: buffer)
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                return (RemoteAudioDigest(status: 200, byteLength: count, sha256: digest, etag: normalized["etag"]), normalized, body)
            } onCancel: { session.invalidateAndCancel() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is CancellationError { throw error }
            if let error = error as? DeliveryError { throw error }
            throw Self.classifyTransport(error)
        }
    }
}

extension LoggingDeliveryTransport {
    public func verifiedAudio(_ url: URL, headers: [String: String], maximumBytes: Int64, settings: PrototypeProfile) async throws -> VerifiedRemoteAudio {
        log.record(.request(.get))
        do { let result = try await base.verifiedAudio(url, headers: headers, maximumBytes: maximumBytes, settings: settings); log.record(.response(.get, result.digest.status)); return result }
        catch { log.recordFailure(error); throw error }
    }
    public func read(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> DeliveryResponse {
        log.record(.request(.get))
        do { let result = try await base.read(url, headers: headers, maximumBytes: maximumBytes); log.record(.response(.get, result.status)); return result }
        catch { log.recordFailure(error); throw error }
    }
    public func digest(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> RemoteAudioDigest {
        log.record(.request(.get))
        do { let result = try await base.digest(url, headers: headers, maximumBytes: maximumBytes); log.record(.response(.get, result.status)); return result }
        catch { log.recordFailure(error); throw error }
    }
}

extension WebDAVClient {
    func recoveryHeaders(_ url: URL) throws -> [String: String] {
        try headers(for: url, extra: ["Accept-Encoding": "identity", "Cache-Control": "no-cache"])
    }
    func readRecoveryFeed() async throws -> Data? {
        let target = try remoteURL(settings.remoteFeedPath)
        let response = try await transport.read(target, headers: recoveryHeaders(target), maximumBytes: 4 * 1024 * 1024)
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw DeliveryError.classify(response.status) }
        return response.body
    }
    func publishFeed(_ feed: Data, ifMatch: String? = nil, onlyIfMissing: Bool = false) async throws {
        guard feed.count <= 4 * 1024 * 1024 else {
            throw DeliveryError.fatal("The podcast feed is too large to verify safely. Remove finished episodes before publishing again.")
        }
        try await uploadData(feed, remotePath: settings.remoteFeedPath, ifMatch: ifMatch, onlyIfMissing: onlyIfMissing)
        try await confirmPublishedFeed(feed)
    }
    /// Size alone cannot confirm RSS membership. Verify the exact authenticated
    /// representation before dependent cleanup or server removals are authorized.
    func confirmPublishedFeed(_ expected: Data) async throws {
        try Task.checkCancellation()
        guard expected.count <= 4 * 1024 * 1024,
              let actual = try await readRecoveryFeed(), actual.count == expected.count,
              Files.hash(actual) == Files.hash(expected) else {
            throw DeliveryError.retryable("The uploaded feed contents could not be confirmed; publication remains pending.")
        }
        try Task.checkCancellation()
    }
    func readFeed(ifNoneMatch: String? = nil) async throws -> DeliveryResponse {
        let target = try remoteURL(settings.remoteFeedPath)
        var headers = try recoveryHeaders(target)
        if let ifNoneMatch { headers["If-None-Match"] = ifNoneMatch }
        let response = try await transport.read(target, headers: headers, maximumBytes: 4 * 1024 * 1024)
        guard [200, 304, 404].contains(response.status) else { throw DeliveryError.classify(response.status) }
        return response
    }
    func audioMetadata(id: String) async throws -> DeliveryResponse {
        let target = try remoteURL(settings.remoteMediaPath(id))
        let response = try await transport.request("HEAD", url: target, body: nil, file: nil, headers: recoveryHeaders(target))
        guard [200, 404, 405, 501].contains(response.status) else { throw DeliveryError.classify(response.status) }
        return response
    }
    func verifyAudio(id: String, settings profile: PrototypeProfile) async throws -> VerifiedRemoteAudio? {
        let target = try remoteURL(settings.remoteMediaPath(id))
        let audio = try await transport.verifiedAudio(target, headers: recoveryHeaders(target), maximumBytes: 512 * 1024 * 1024, settings: profile)
        if audio.digest.status == 404 { return nil }
        guard audio.digest.status == 200 else { throw DeliveryError.classify(audio.digest.status) }
        return audio
    }
    func recoveryDigest(id: String, maximumBytes: Int64) async throws -> RemoteAudioDigest? {
        guard UUID(uuidString: id) != nil, maximumBytes > 0, maximumBytes <= 512 * 1024 * 1024 else { throw ServerFeedParser.failure }
        let target = try remoteURL(settings.remoteMediaPath(id))
        let digest = try await transport.digest(target, headers: recoveryHeaders(target), maximumBytes: maximumBytes)
        if digest.status == 404 { return nil }
        guard digest.status == 200 else { throw DeliveryError.classify(digest.status) }
        return digest
    }
}
