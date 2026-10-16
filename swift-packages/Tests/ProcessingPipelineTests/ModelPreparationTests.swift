import XCTest
import Darwin
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

private final class PreparationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ModelPreparationProgress] = []
    func append(_ value: ModelPreparationProgress) { lock.withLock { updates.append(value) } }
    var count: Int { lock.withLock { updates.count } }
}

@MainActor
final class ModelPreparationTests: XCTestCase {
    private func fixture(_ mode: String, timeout: Duration = .seconds(2)) throws -> (URL, WorkerConfiguration) {
        guard let path = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Run macos/scripts/check.sh to build the fixture helper") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Libro preparation \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, WorkerConfiguration(executable: URL(fileURLWithPath: path),
            environment: ["NARRATION_FIXTURE_MODE": mode, "NARRATION_FIXTURE_TRACE": root.path], requestTimeout: timeout,
            shutdownGrace: 0.05, terminationGrace: 0.05))
    }
    private func assertReaped(_ root: URL) throws {
        let traces = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(traces.count, 1)
        for trace in traces {
            let pid = try XCTUnwrap(Int32(trace.deletingPathExtension().lastPathComponent))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
    func testValidatedProgressIgnoresOtherAttemptAndReapsSuccessfulHelper() async throws {
        let (root, configuration) = try fixture("success"); defer { try? FileManager.default.removeItem(at: root) }
        let log = PreparationLog()
        try await ModelPreparation.run(configuration: configuration, workspace: root, settings: .init(), progress: log.append)
        XCTAssertEqual(log.count, 1)
        try assertReaped(root)
    }
    func testInvalidProgressCannotCompletePreparation() async throws {
        let (root, configuration) = try fixture("assetInvalid"); defer { try? FileManager.default.removeItem(at: root) }
        let log = PreparationLog()
        do {
            try await ModelPreparation.run(configuration: configuration, workspace: root, settings: .init(), progress: log.append)
            XCTFail("Invalid counts were accepted")
        } catch let error as SpeechFailure { XCTAssertEqual(error.code, .protocolViolation) }
        XCTAssertEqual(log.count, 0)
        try assertReaped(root)
    }
    func testCancellationAndTimeoutReapUncooperativePreparationHelper() async throws {
        for cancelled in [false, true] {
            let (root, configuration) = try fixture("assetStall", timeout: cancelled ? .seconds(2) : .seconds(1))
            defer { try? FileManager.default.removeItem(at: root) }
            let task = Task { try await ModelPreparation.run(configuration: configuration, workspace: root, settings: .init()) }
            if cancelled {
                let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(2))
                while try !FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasSuffix(".jsonl") }), clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                task.cancel()
            }
            do { try await task.value; XCTFail("Stalled preparation succeeded") }
            catch is CancellationError { XCTAssertTrue(cancelled) }
            catch let error as SpeechFailure { XCTAssertFalse(cancelled); XCTAssertEqual(error.code, .timeout) }
            try assertReaped(root)
        }
    }
    func testProgressIsBoundToSelectedScopeAndPinnedBytes() {
        let total = NativePrimaryCatalog.specification(for: .soprano).files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        XCTAssertTrue(ModelPreparationProgress(scope: .primary, phase: .checking, totalBytes: total).isValid(for: .soprano))
        XCTAssertFalse(ModelPreparationProgress(scope: .primary, phase: .checking, totalBytes: total + 1).isValid(for: .soprano))
        XCTAssertFalse(ModelPreparationProgress(scope: .primary, phase: .downloading, completedBytes: total + 1, totalBytes: total).isValid(for: .soprano))
        XCTAssertFalse(ModelPreparationProgress(scope: .g2p, phase: .checking, totalBytes: 9_119_497).isValid(for: .soprano))
    }
}
