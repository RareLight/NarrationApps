import XCTest
import UniformTypeIdentifiers
@testable import LibroCore

@MainActor
final class FileDropTests: XCTestCase {
    func testUnpackedEPUBDropKeepsTheBookTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let book = root.appendingPathComponent("Unpacked Book.epub")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("application/epub+zip".utf8).write(to: book.appendingPathComponent("mimetype"))
        try Data("chapter content".utf8).write(to: book.appendingPathComponent("chapter.txt"))
        let result = await FileDrop.load([NSItemProvider(object: book as NSURL), NSItemProvider(object: root as NSURL)])
        XCTAssertEqual(result.unavailableItems, 0)
        let collected = try InputCollector.collect(result.urls)
        XCTAssertEqual(collected.documents.count, 1)
        XCTAssertEqual(collected.documents.first?.source, book.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(collected.documents.first?.kind, .epub)
    }
    func testNativeURLAndFileReferenceGroupsMatchDirectIntakeAndDeduplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Libro file drop \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("A paragraph.md")
        let pdf = root.appendingPathComponent("Chapter.pdf")
        for url in [markdown, pdf] { try Data("Public fixture".utf8).write(to: url) }
        let reference = try XCTUnwrap((markdown as NSURL).fileReferenceURL())
        let urls = [pdf, root, markdown, markdown]
        let providers = [NSItemProvider(object: pdf as NSURL), NSItemProvider(object: root as NSURL),
                         NSItemProvider(object: reference as NSURL), NSItemProvider(object: markdown as NSURL)]
        let result = await FileDrop.load(providers)
        XCTAssertEqual(result.unavailableItems, 0)
        XCTAssertEqual(result.urls.count, 4)
        XCTAssertFalse(result.urls.contains { $0.path.hasPrefix("/.file/") })
        XCTAssertEqual(try InputCollector.collect(result.urls).documents.map(\.source), try InputCollector.collect(urls).documents.map(\.source))
        XCTAssertEqual(try InputCollector.collect(result.urls).documents.count, 2)
    }
    func testDataFileURLRepresentationAndUnavailableItemsAreReported() async throws {
        let url = URL(fileURLWithPath: "/private/tmp/public sample.md")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil); return nil
        }
        let result = await FileDrop.load([provider, NSItemProvider(object: NSURL(string: "https://example.invalid")!)])
        XCTAssertEqual(result.urls, [url])
        XCTAssertEqual(result.unavailableItems, 1)
    }
}

private final class GatedFileURL: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Data?, (any Error)?) -> Void)?
    let progress = Progress(totalUnitCount: 1)
    var requested: Bool { lock.withLock { completion != nil } }
    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { [self] completion in
            lock.withLock { self.completion = completion }
            return progress
        }
        return provider
    }
    func finish(_ url: URL) {
        let callback = lock.withLock { completion }
        callback?(url.dataRepresentation, nil)
    }
}

extension FileDropTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for synthetic file provider")
    }

    func testCancelledProviderThatNeverCompletesDoesNotBlockShutdownOrImportLate() async throws {
        let gated = GatedFileURL(), imports = FileDropImport()
        var delivered: [URL] = []
        imports.start([gated.provider()]) { delivered += $0.urls }
        try await waitUntil { gated.requested }
        XCTAssertTrue(imports.hasOwnedWork)
        let clock = ContinuousClock.now
        imports.cancel() // The same invalidation used by Clear and Cancel.
        await imports.stop() // Quit joins the owned task even if the provider ignores cancel.
        XCTAssertLessThan(clock.duration(to: .now), .seconds(1))
        XCTAssertFalse(imports.hasOwnedWork)
        gated.finish(URL(fileURLWithPath: "/private/tmp/late.md"))
        await Task.yield()
        XCTAssertTrue(delivered.isEmpty)
    }

    func testReplacementDropsJoinAndDiscardPreviousResolution() async throws {
        let gated = GatedFileURL(), imports = FileDropImport()
        var delivered: [URL] = []
        imports.start([gated.provider()]) { delivered += $0.urls }
        try await waitUntil { gated.requested }
        let replacement = URL(fileURLWithPath: "/private/tmp/replacement.md")
        imports.start([NSItemProvider(object: replacement as NSURL)]) { delivered += $0.urls }
        try await waitUntil { !imports.hasOwnedWork }
        gated.finish(URL(fileURLWithPath: "/private/tmp/stale.md"))
        await Task.yield()
        XCTAssertEqual(delivered, [replacement])
    }

    func testContinuationIgnoresDuplicateAndLateCallbacksAndPrestartCancellation() async {
        let request = DropURLRequest()
        let expected = URL(fileURLWithPath: "/private/tmp/first.md")
        let value: URL? = await withCheckedContinuation { continuation in
            XCTAssertTrue(request.begin(continuation))
            request.finish(expected)
            request.finish(URL(fileURLWithPath: "/private/tmp/second.md"))
            request.cancel()
        }
        XCTAssertEqual(value, expected)
        let cancelled = DropURLRequest()
        cancelled.cancel()
        let missing: URL? = await withCheckedContinuation { continuation in
            XCTAssertFalse(cancelled.begin(continuation))
            cancelled.finish(expected)
        }
        XCTAssertNil(missing)
        let progress = Progress(totalUnitCount: 1)
        cancelled.setProgress(progress)
        XCTAssertTrue(progress.isCancelled)
    }
}
