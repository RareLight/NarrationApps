import Foundation
import XCTest
import NarrationCore
@testable import DocumentProcessing

private enum CPUUnitState { @TaskLocal static var inside = false }
private final class PreparationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
private final class PreparationExecutor: NarrationCPUExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var delay = false
    let clock: PreparationClock
    init(_ clock: PreparationClock) { self.clock = clock }
    func queueLongWait() { lock.withLock { delay = true } }
    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let delayed = lock.withLock { let pending = delay; delay = false; return pending }
        if delayed { clock.advance(100) } // Admission wait, outside the CPU unit.
        let work = Task.detached { try CPUUnitState.$inside.withValue(true, operation: operation) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
private final class PreparationCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

final class PreparationAdmissionTests: XCTestCase, @unchecked Sendable {
    func testIntakeYieldsDuringEnumerationWithoutReturningPartialInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intake-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<120 { try Data("Disposable text".utf8).write(to: root.appendingPathComponent("\(index).txt")) }
        let visited = PreparationCalls()
        XCTAssertThrowsError(try NarrationWorkCheckpoint.$current.withValue({
            if visited.value > 0 { throw CancellationError() }
        }) {
            try InputCollector.collect([root]) { count in if count == 100 { _ = visited.next() } }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(visited.value, 1)
        XCTAssertEqual(try InputCollector.collect([root]).documents.count, 120)
    }
    func testBookCoverChecksAdmissionBeforeOpeningItsSource() throws {
        let input = InputDocument(source: URL(fileURLWithPath: "/unopened-synthetic-cover.pdf"), kind: .pdf, relativePath: "synthetic.pdf")
        XCTAssertThrowsError(try NarrationWorkCheckpoint.$current.withValue({ throw CancellationError() }) {
            try DocumentReader.bookCover(input)
        }) { XCTAssertTrue($0 is CancellationError) }
    }
    func testPDFCPUWaitDoesNotConsumeOCRBudgetAndRecognitionStaysOutsideCPU() async throws {
        let clock = PreparationClock(), executor = PreparationExecutor(clock), calls = PreparationCalls()
        let data = try PDFLayoutTests.fixture(pages: 2)
        let document = try await NarrationPreparationWork.$executor.withValue(executor) {
            try await PDFDocumentExtractor.extract(data: data, limits: .init(ocrSeconds: 1), forceOCR: true, recognize: { _ in
                XCTAssertFalse(CPUUnitState.inside)
                let page = calls.next()
                if page == 1 { executor.queueLongWait() }
                return [.init(kind: .paragraph, text: "Recognized synthetic page \(page).")]
            }, monotonicTime: { clock.now })
        }
        XCTAssertEqual(calls.value, 2); XCTAssertEqual(clock.now, 100)
        XCTAssertEqual(document.blocks.map(\.pdfPageIndex), [0, 1])
        XCTAssertEqual(document.blocks.map(\.text), ["Recognized synthetic page 1.", "Recognized synthetic page 2."])
    }
    func testActualOCRWorkStillExhaustsItsBudget() async throws {
        let clock = PreparationClock(), executor = PreparationExecutor(clock), calls = PreparationCalls()
        let data = try PDFLayoutTests.fixture(pages: 2)
        do {
            _ = try await NarrationPreparationWork.$executor.withValue(executor) {
                try await PDFDocumentExtractor.extract(data: data, limits: .init(ocrSeconds: 1), forceOCR: true, recognize: { _ in
                    _ = calls.next(); clock.advance(2)
                    return [.init(kind: .paragraph, text: "Slow synthetic recognition.")]
                }, monotonicTime: { clock.now })
            }
            XCTFail("Active recognition exceeded its budget")
        } catch PDFExtractionError.ocrLimit {}
        XCTAssertEqual(calls.value, 1)
    }
    private func document(images: Int) -> SemanticDocument {
        .init(blocks: [.init(kind: .paragraph, text: "Original authored prose remains unchanged.", origin: .authored)] +
            (0..<images).map { .init(kind: .caption, text: "Image \($0)", narrationText: "", imageURL: URL(string: "https://images.example/\($0).png"), origin: .authored) },
            extractorVersion: "synthetic-images")
    }
    func testImageCPUWaitDoesNotConsumeDescriptionBudgetOrRunCaptionInsideCPU() async throws {
        let clock = PreparationClock(), executor = PreparationExecutor(clock), calls = PreparationCalls()
        let source = document(images: 2)
        let enriched = try await NarrationPreparationWork.$executor.withValue(executor) {
            try await DocumentImages.enrich(source, enabled: true, monotonicTime: { clock.now }, fetch: { url in
                Data(url.lastPathComponent.utf8)
            }, caption: { _ in
                XCTAssertFalse(CPUUnitState.inside)
                let image = calls.next()
                if image == 1 { executor.queueLongWait() }
                return "Synthetic image \(image)."
            })
        }
        XCTAssertEqual(clock.now, 100); XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(enriched.blocks.filter { $0.imageDescriptionGenerated == true }.count, 2)
        XCTAssertEqual(enriched.blocks[0], source.blocks[0])
    }
    func testActiveImageTimeRemainsBoundedPerImageAndAcrossDocument() async throws {
        let clock = PreparationClock(), executor = PreparationExecutor(clock), calls = PreparationCalls()
        let source = document(images: 6)
        let enriched = try await NarrationPreparationWork.$executor.withValue(executor) {
            try await DocumentImages.enrich(source, enabled: true, monotonicTime: { clock.now }, fetch: { url in
                Data(url.lastPathComponent.utf8)
            }, caption: { _ in
                _ = calls.next(); clock.advance(14)
                return "A bounded synthetic description."
            })
        }
        XCTAssertEqual(calls.value, 5)
        XCTAssertEqual(enriched.blocks.filter { $0.imageDescriptionGenerated == true }.count, 4)
        XCTAssertTrue(enriched.warnings.contains { $0.contains("could not be described") })
        XCTAssertEqual(enriched.blocks[0], source.blocks[0])
        let singleClock = PreparationClock()
        let timedOut = try await DocumentImages.enrich(document(images: 1), enabled: true,
            monotonicTime: { singleClock.now }, fetch: { _ in Data([1]) }, caption: { _ in
                singleClock.advance(16); return "This description is too late."
            })
        XCTAssertFalse(timedOut.blocks.contains { $0.imageDescriptionGenerated == true })
    }
    func testTitleBudgetStartsAtAcquisitionAndGeneratorStaysOutsideCPU() async throws {
        let executor = PreparationExecutor(PreparationClock())
        let blocks = [ContentBlock(kind: .paragraph, text: String(repeating: "An authored opening paragraph offers factual context. ", count: 4))]
        let title = try await NarrationPreparationWork.$executor.withValue(executor) {
            try await DocumentTitles.resolve(title: nil, blocks: blocks, urls: [], generationSeconds: 0.02,
                admittedGenerate: { _, acquired in
                    XCTAssertFalse(CPUUnitState.inside)
                    // This admission wait exceeds the entire active generation allowance.
                    try await Task.sleep(for: .milliseconds(80))
                    acquired()
                    return "A factual synthetic title"
                })
        }
        XCTAssertEqual(title.origin, .generated)
        XCTAssertEqual(title.text, "A factual synthetic title")
        let timedOut = try await DocumentTitles.resolve(title: nil, blocks: blocks, urls: [], generationSeconds: 0.02,
            admittedGenerate: { _, acquired in
                acquired(); try await Task.sleep(for: .seconds(5)); return "Too late to use"
            })
        XCTAssertEqual(timedOut.origin, .fallback)
    }
    func testTitleCancellationWhileWaitingForAdmissionJoinsGenerator() async throws {
        let started = PreparationCalls(), ended = PreparationCalls()
        let work = Task {
            try await DocumentTitles.resolve(title: nil,
                blocks: [.init(kind: .paragraph, text: String(repeating: "Original authored context. ", count: 6))], urls: [],
                admittedGenerate: { _, _ in
                    _ = started.next(); defer { _ = ended.next() }
                    try await Task.sleep(for: .seconds(60)); return nil
                })
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while started.value == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled title generation completed") } catch is CancellationError {}
        XCTAssertEqual(started.value, 1); XCTAssertEqual(ended.value, 1)
    }

}
