import XCTest
import AudioOutput
import ImageIO
import UniformTypeIdentifiers
@testable import LibroCore

final class DocumentCoverTests: XCTestCase {
    private func artworkBytes() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testPersistentPerDocumentSelectionSnapshotAndMissingCoverFailure() throws {
        let suite = "LibroCoverTests-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CoverArtworkStore(root: root), preferences = DocumentCoverPreferences(defaults: defaults)
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let cover = try CoverArtwork(data: data as Data), digest = try store.save(cover)
        let first = InputDocument(source: root.appendingPathComponent("first.txt"), kind: .text, relativePath: "first.txt")
        let second = InputDocument(source: root.appendingPathComponent("second.txt"), kind: .text, relativePath: "second.txt")
        preferences.save([DocumentCoverPreferences.key(first.source): digest])
        let snapshot = try DocumentCoverPreferences.snapshot([first, second], references: preferences.load(), store: store)
        XCTAssertEqual(snapshot[first.id], cover); XCTAssertNil(snapshot[second.id])
        preferences.save([:])
        XCTAssertEqual(snapshot[first.id], cover)
        XCTAssertTrue(preferences.load().isEmpty)
        try FileManager.default.removeItem(at: store.url(for: digest))
        XCTAssertThrowsError(try DocumentCoverPreferences.snapshot([first], references: [DocumentCoverPreferences.key(first.source): digest], store: store))
    }

    func testAutomaticDetectionPreservesExplicitSelectionsAndPersistedOptOuts() throws {
        let suite = "LibroAutomaticCoverTests-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CoverArtworkStore(root: root), preferences = DocumentCoverPreferences(defaults: defaults)
        let image = try artworkBytes(), explicitDigest = try store.save(CoverArtwork(data: image))
        let manual = InputDocument(source: root.appendingPathComponent("manual.pdf"), kind: .pdf, relativePath: "manual.pdf")
        let removed = InputDocument(source: root.appendingPathComponent("removed.epub"), kind: .epub, relativePath: "removed.epub")
        let automatic = InputDocument(source: root.appendingPathComponent("automatic.pdf"), kind: .pdf, relativePath: "automatic.pdf")
        let text = InputDocument(source: root.appendingPathComponent("text.txt"), kind: .text, relativePath: "text.txt")
        preferences.save([DocumentCoverPreferences.key(manual.source): explicitDigest])
        XCTAssertTrue(preferences.loadAutomaticExclusions().isEmpty)
        preferences.saveAutomaticExclusions([DocumentCoverPreferences.key(removed.source)])
        let reloaded = DocumentCoverPreferences(defaults: defaults)
        let detected = try DocumentCoverPreferences.automaticCovers(
            [manual, removed, automatic, text], references: reloaded.load(),
            excluding: reloaded.loadAutomaticExclusions(), store: store,
            readCover: { document in
                XCTAssertEqual(document.id, automatic.id)
                return image
            })
        XCTAssertEqual(Set(detected.keys), [DocumentCoverPreferences.key(automatic.source)])
        let digest = try XCTUnwrap(detected[DocumentCoverPreferences.key(automatic.source)])
        let cover = try store.load(digest)
        XCTAssertEqual(cover.width * 3, cover.height * 2)
        XCTAssertEqual(reloaded.load()[DocumentCoverPreferences.key(manual.source)], explicitDigest)
        XCTAssertEqual(reloaded.loadAutomaticExclusions(), [DocumentCoverPreferences.key(removed.source)])
        var references = reloaded.load()
        references.merge(detected) { original, _ in original }
        let snapshot = try DocumentCoverPreferences.snapshot([manual, automatic, removed], references: references, store: store)
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertNil(snapshot[removed.id])
    }

    func testBadAutomaticArtworkIsOptionalAndDoesNotStopOtherDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = ["missing", "malformed", "healthy"].map {
            InputDocument(source: root.appendingPathComponent("\($0).epub"), kind: .epub, relativePath: "\($0).epub")
        }
        let image = try artworkBytes()
        let detected = try DocumentCoverPreferences.automaticCovers(inputs, references: [:], excluding: [],
            store: .init(root: root), readCover: { document in
                if document.id == inputs[0].id { throw CocoaError(.fileReadNoSuchFile) }
                return document.id == inputs[1].id ? Data([1, 2, 3]) : image
            })
        XCTAssertEqual(Set(detected.keys), [DocumentCoverPreferences.key(inputs[2].source)])
    }

    func testAutomaticCancellationIsNotSwallowedAndNoAssetIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = InputDocument(source: root.appendingPathComponent("book.pdf"), kind: .pdf, relativePath: "book.pdf")
        XCTAssertThrowsError(try DocumentCoverPreferences.automaticCovers([input], references: [:], excluding: [],
            store: .init(root: root), readCover: { _ in throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
