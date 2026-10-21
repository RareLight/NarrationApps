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
