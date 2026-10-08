import XCTest
import Darwin
@testable import LibroCore

@MainActor
final class DebugLogTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Libro debug \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBoundedRotationPrivatePermissionsAndLatestRecord() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try DebugLog(workspace: root)
        XCTAssertEqual(DebugLog.existingURL(workspace: root), log.url)
        for index in 0..<180 { log.record("record=\(index) " + String(repeating: "x", count: 16_000)) }
        log.record("latest public marker")
        XCTAssertFalse(log.writeFailed)
        let previous = log.url.deletingLastPathComponent().appendingPathComponent("debug.previous.log")
        for url in [log.url, previous] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertLessThanOrEqual((attributes[.size] as! NSNumber).intValue, DebugLog.maximumBytes)
            XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o600)
        }
        XCTAssertTrue(try String(contentsOf: log.url, encoding: .utf8).contains("latest public marker"))
    }

    func testAliasAndHardlinkCannotRedirectLogsAndRotationFailureIsNonfatal() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("preserve.txt")
        try Data("preserve".utf8).write(to: external)
        let directory = root.appendingPathComponent("models/.native/diagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("debug.log")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: external)
        XCTAssertThrowsError(try DebugLog(workspace: root))
        try FileManager.default.removeItem(at: current)
        try FileManager.default.linkItem(at: external, to: current)
        XCTAssertThrowsError(try DebugLog(workspace: root))
        try FileManager.default.removeItem(at: current)
        let previous = directory.appendingPathComponent("debug.previous.log")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let marker = previous.appendingPathComponent("preserve")
        try Data([42]).write(to: marker)
        let log = try DebugLog(workspace: root)
        for _ in 0..<70 { log.record(String(repeating: "x", count: 16_000)) }
        XCTAssertTrue(log.writeFailed)
        XCTAssertEqual(try Data(contentsOf: marker), Data([42]))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "preserve")
    }

    func testCrashTailIsRetainedAfterReapingWithoutLoggingNarration() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRO_FIXTURE_WORKER"] else { throw XCTSkip("Run check.sh") }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try DebugLog(workspace: root)
        let identity = AttemptIdentity(batch: UUID(), job: UUID())
        let worker = try SpeechWorkerProcess(configuration: .init(executable: URL(fileURLWithPath: path),
            environment: ["LIBRO_FIXTURE_MODE": "diagnosticCrash", "LIBRO_FIXTURE_TRACE": root.path], debugLog: log), identity: identity)
        do {
            _ = try await worker.request(.init(kind: .generate, identity: identity, chunk: 0, text: "Private narration sentinel"))
            XCTFail("Crashed helper succeeded")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .workerExited) }
        await worker.stop()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains("Public diagnostic crash tail."))
        XCTAssertTrue(text.contains("request=generate chunk=0"))
        XCTAssertTrue(text.contains("reason=exit status=7"))
        XCTAssertFalse(text.contains("Private narration sentinel"))
        XCTAssertLessThan(text.utf8.count, 12_000)
    }

    func testDisabledLoggingCreatesNoLogAndFailureHasInitializationContext() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRO_FIXTURE_WORKER"] else { throw XCTSkip("Run check.sh") }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = AttemptIdentity(batch: UUID(), job: UUID())
        let worker = try SpeechWorkerProcess(configuration: .init(executable: URL(fileURLWithPath: path),
            environment: ["LIBRO_FIXTURE_MODE": "initializeFailureAndStall", "LIBRO_FIXTURE_TRACE": root.path],
            shutdownGrace: 0.05, terminationGrace: 0.05), identity: identity)
        do {
            _ = try await worker.request(.init(kind: .initialize, identity: identity))
            XCTFail("Invalid initialization succeeded")
        } catch let failure as SpeechFailure {
            XCTAssertEqual(failure.code, .invalidInput)
            XCTAssertTrue(failure.localizedDescription.contains("model initialization"))
        }
        await worker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/.native/diagnostics").path))
    }
}
