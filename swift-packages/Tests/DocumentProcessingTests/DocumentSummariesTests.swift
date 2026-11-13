import Foundation
import XCTest
@testable import DocumentProcessing
@testable import NarrationCore

final class DocumentSummariesTests: XCTestCase {
    /// Tiny thread-safe box for counting fake-provider invocations.
    final class Locked<Value>: @unchecked Sendable {
        private var value: Value; private let lock = NSLock()
        init(_ v: Value) { value = v }
        func withLock(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let eligible = "A short document explaining seed germination for gardeners."

    func testProviderSuccessValidates() async throws {
        let result = try await DocumentSummaryGenerator.generate(sourceText: eligible) { _ in
            "The document explains seed germination simply."
        }
        XCTAssertEqual(result, "The document explains seed germination simply.")
    }

    func testNilProviderAndOversizedNeverCalled() async throws {
        let called = Locked(0)
        let nilResult = try await DocumentSummaryGenerator.generate(sourceText: eligible, using: nil)
        XCTAssertNil(nilResult)
        let big = String(repeating: "x", count: DocumentSummaries.maximumSourceBytes + 1)
        let result = try await DocumentSummaryGenerator.generate(sourceText: big) { _ in
            called.withLock { $0 += 1 }; return "x."
        }
        XCTAssertNil(result)
        XCTAssertEqual(called.get(), 0, "provider must not run above the source cutoff")
    }

    func testProviderThrowRefusalInvalidAllNil() async throws {
        let cases: [DocumentSummaryGenerator.Generate] = [
            { _ in struct E: Error { }; throw E() },
            { _ in "I cannot summarize this document." },
            { _ in (1...51).map { "w\($0)" }.joined(separator: " ") + "." },
            { _ in "One. Two. Three. Four sentences is too many." },
            { _ in "See https://x.example/y for details." },
        ]
        for generator in cases {
            let value = try await DocumentSummaryGenerator.generate(sourceText: eligible, using: generator)
            XCTAssertNil(value)
        }
    }

    func testCancellationPropagatesAndProducerJoined() async throws {
        let ended = Locked(false), started = Locked(false)
        let text = eligible
        let task = Task {
            try await DocumentSummaryGenerator.generate(sourceText: text) { _ in
                defer { ended.withLock { $0 = true } }
                started.withLock { $0 = true }
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
        }
        // Wait for the producer to start so cancellation hits the sleep, not the entry guard.
        while !started.get() { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        var threw = false
        do { _ = try await task.value } catch is CancellationError { threw = true }
        XCTAssertTrue(threw, "cancellation must propagate")
        XCTAssertTrue(ended.get(), "producer is joined before returning")
    }

    func testDeadlineImmediateCancellationNoWait() async throws {
        let ended = Locked(false)
        let started = ContinuousClock.now
        let task = Task {
            try await DocumentSummaryGenerator.withDeadline {
                defer { ended.withLock { $0 = true } }
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
        }
        task.cancel()
        var threw = false
        do { _ = try await task.value } catch is CancellationError { threw = true }
        XCTAssertTrue(threw)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "no 20-second wait on cancellation")
        XCTAssertTrue(ended.get(), "cancelled producer is joined")
    }
}
