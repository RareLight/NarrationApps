import Foundation
import XCTest
import HuggingFace

private struct Reply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var error: URLError.Code?
    var stall = false
}

private final class Responses: @unchecked Sendable {
    let lock = NSLock()
    var replies: [Reply]
    var ranges: [String?] = []
    let count: Int
    let metadata: Bool
    init(_ replies: [Reply], count: Int, metadata: Bool) {
        self.replies = replies; self.count = count; self.metadata = metadata
    }
    func next(_ request: URLRequest) -> Reply {
        lock.withLock {
            if request.httpMethod == "HEAD" {
                if !metadata { return Reply(headers: ["Content-Length": String(count)]) }
                return Reply(headers: ["ETag": CacheDownloadTests.etag, "X-Repo-Commit": CacheDownloadTests.revision,
                                       "Content-Length": String(count)])
            }
            ranges.append(request.value(forHTTPHeaderField: "Range"))
            return replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
        }
    }
    var requestedRanges: [String?] { lock.withLock { ranges } }
}

private final class ResponseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Responses] = [:]
    func register(_ values: Responses, host: String) { lock.withLock { self.values[host] = values } }
    func remove(_ host: String) { _ = lock.withLock { values.removeValue(forKey: host) } }
    func get(_ host: String) -> Responses? { lock.withLock { values[host] } }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ResponseRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let responses = Self.registry.get(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        let reply = responses.next(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        if let error = reply.error {
            // Let URLSession deliver the preceding buffer before simulating
            // connection loss; immediate URLProtocol failure discards queued
            // data and does not represent an interrupted received transfer.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(error))
            }
        }
        else if !reply.stall { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class CacheDownloadTests: XCTestCase {
    fileprivate static let revision = String(repeating: "a", count: 40)
    fileprivate static let etag = String(repeating: "b", count: 64)
    private let bytes = Data((0..<131_072).map { UInt8($0 % 251) })
    private let repo = Repo.ID(rawValue: "fixture/model")!

    private struct Fixture: Sendable {
        let client: HubClient
        let cache: HubCache
        let root: URL
        let host: String
        let responses: Responses
        let destination: URL
        let partial: URL
        func cleanup() {
            FixtureProtocol.registry.remove(host)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(_ replies: [Reply], partial: Data? = nil, metadata: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Libro Hub \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = "\(UUID().uuidString.lowercased()).invalid"
        let responses = Responses(replies, count: bytes.count, metadata: metadata)
        FixtureProtocol.registry.register(responses, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]; configuration.urlCache = nil
        let cache = HubCache(cacheDirectory: root.appendingPathComponent("hub"))
        let partialURL = try cache.incompleteBlobPath(repo: repo, kind: .model, etag: Self.etag)
        if let partial {
            try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try partial.write(to: partialURL)
        }
        let client = HubClient(session: URLSession(configuration: configuration), host: URL(string: "https://\(host)")!, cache: cache)
        return Fixture(client: client, cache: cache, root: root, host: host, responses: responses,
                       destination: root.appendingPathComponent("stage/weight.bin"), partial: partialURL)
    }

    private func download(_ fixture: Fixture, progress: Progress? = nil) async throws -> URL {
        try await fixture.client.downloadFile(at: "weight.bin", from: repo, to: fixture.destination,
            revision: Self.revision, progress: progress, transport: .lfs, downloadInCache: true)
    }
    private func full() -> Reply { Reply(headers: ["Content-Length": String(bytes.count)], body: bytes) }
    private func resumed(at offset: Int) -> Reply {
        Reply(status: 206, headers: ["Content-Range": "bytes \(offset)-\(bytes.count - 1)/\(bytes.count)",
                                    "Content-Length": String(bytes.count - offset)], body: bytes.dropFirst(offset))
    }

    func testInterruptedTransferPersistsPrefixThenResumesExactBytes() async throws {
        let offset = 32_768
        let fixture = try fixture([
            Reply(headers: ["Content-Length": String(bytes.count)], body: bytes.prefix(offset), error: .networkConnectionLost),
            resumed(at: offset)
        ]); defer { fixture.cleanup() }
        do { _ = try await download(fixture); XCTFail("Interrupted transfer succeeded") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.partial), bytes.prefix(offset))
        XCTAssertNil(fixture.cache.cachedFilePath(repo: repo, kind: .model, revision: Self.revision, filename: "weight.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let progress = Progress(totalUnitCount: Int64(bytes.count))
        let destination = try await download(fixture, progress: progress)
        XCTAssertEqual(destination, fixture.destination)
        XCTAssertEqual(progress.userInfo[ProgressUserInfoKey("cacheDownloadResumeOffset")] as? Int64, Int64(offset))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), bytes)
        XCTAssertEqual(fixture.responses.requestedRanges, [nil, "bytes=\(offset)-"])
        XCTAssertEqual(progress.completedUnitCount, Int64(bytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        // Offline SDK reuse does not issue another request.
        _ = try await fixture.client.downloadFile(at: "weight.bin", from: repo, revision: Self.revision, localFilesOnly: true)
        XCTAssertEqual(fixture.responses.requestedRanges.count, 2)
    }

    func testIgnoredRangeReplacesPrefixInsteadOfAppendingFullResponse() async throws {
        let fixture = try fixture([full()], partial: Data(repeating: 99, count: 100)); defer { fixture.cleanup() }
        let progress = Progress(totalUnitCount: Int64(bytes.count))
        _ = try await download(fixture, progress: progress)
        XCTAssertEqual(progress.userInfo[ProgressUserInfoKey("cacheDownloadResumeOffset")] as? Int64, 0)
        XCTAssertEqual(fixture.responses.requestedRanges, ["bytes=100-"])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), bytes)
    }

    func testRangeNotSatisfiableResetsOversizedPartialAndRestarts() async throws {
        let fixture = try fixture([Reply(status: 416), full()], partial: Data(repeating: 99, count: bytes.count + 1))
        defer { fixture.cleanup() }
        _ = try await download(fixture)
        XCTAssertEqual(fixture.responses.requestedRanges, ["bytes=\(bytes.count + 1)-", nil])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), bytes)
    }

    func testMalformedRangeAndHTTPFailurePreserveExistingPrefix() async throws {
        let prefix = Data(bytes.prefix(100))
        for reply in [
            Reply(status: 206, headers: ["Content-Range": "bytes 0-131071/131072"], body: bytes),
            Reply(status: 206, body: bytes),
            Reply(status: 503, body: Data("server error".utf8))
        ] {
            let fixture = try fixture([reply], partial: prefix); defer { fixture.cleanup() }
            do { _ = try await download(fixture); XCTFail("Invalid response succeeded") } catch {}
            XCTAssertEqual(try Data(contentsOf: fixture.partial), prefix)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertNil(fixture.cache.cachedFilePath(repo: repo, kind: .model, revision: Self.revision, filename: "weight.bin"))
        }
    }

    func testShortResponseCannotPublishAndRemainsResumable() async throws {
        let fixture = try fixture([Reply(headers: ["Content-Length": String(bytes.count)], body: bytes.prefix(100))])
        defer { fixture.cleanup() }
        do { _ = try await download(fixture); XCTFail("Short response succeeded") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.partial), bytes.prefix(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testCancellationPreservesReceivedBytesForNextAttempt() async throws {
        let offset = 32_768
        let fixture = try fixture([Reply(headers: ["Content-Length": String(bytes.count)], body: bytes.prefix(offset), stall: true)])
        defer { fixture.cleanup() }
        let client = fixture.client, repo = repo
        let task = Task {
            try await client.downloadFile(at: "weight.bin", from: repo, to: fixture.destination,
                revision: Self.revision, transport: .lfs, downloadInCache: true)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (try? fixture.partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) != offset, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was ignored") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: fixture.partial), bytes.prefix(offset))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testMissingMetadataCannotFallBackToOSDownloadScratch() async throws {
        let fixture = try fixture([full()], metadata: false); defer { fixture.cleanup() }
        do { _ = try await download(fixture); XCTFail("Metadata-free transfer succeeded") } catch {}
        XCTAssertTrue(fixture.responses.requestedRanges.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testPartialSymlinkAndStorageObstructionCannotModifyPriorDataOrPublish() async throws {
        for symlink in [false, true] {
            let fixture = try fixture([full()], partial: Data([1, 2, 3])); defer { fixture.cleanup() }
            try FileManager.default.removeItem(at: fixture.partial)
            let prior = fixture.root.appendingPathComponent("prior.bin")
            let original = Data([4, 5, 6]); try original.write(to: prior)
            if symlink { try FileManager.default.createSymbolicLink(at: fixture.partial, withDestinationURL: prior) }
            else { try FileManager.default.createDirectory(at: fixture.partial, withIntermediateDirectories: false) }
            do { _ = try await download(fixture); XCTFail("Unsafe destination succeeded") } catch {}
            XCTAssertEqual(try Data(contentsOf: prior), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertNil(fixture.cache.cachedFilePath(repo: repo, kind: .model, revision: Self.revision, filename: "weight.bin"))
        }
    }

    func testSimultaneousSDKRequestsShareOneCompletedTransfer() async throws {
        let fixture = try fixture([full()]); defer { fixture.cleanup() }
        let client = fixture.client, repo = repo
        let first = fixture.root.appendingPathComponent("first.bin")
        let second = fixture.root.appendingPathComponent("second.bin")
        async let firstURL = client.downloadFile(at: "weight.bin", from: repo, to: first,
            revision: Self.revision, transport: .lfs, downloadInCache: true)
        async let secondURL = client.downloadFile(at: "weight.bin", from: repo, to: second,
            revision: Self.revision, transport: .lfs, downloadInCache: true)
        _ = try await (firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        XCTAssertEqual(fixture.responses.requestedRanges.count, 1)
    }
}
