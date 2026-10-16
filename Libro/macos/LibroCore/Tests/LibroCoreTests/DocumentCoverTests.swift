import XCTest
import AudioOutput
import ImageIO
import UniformTypeIdentifiers
@testable import LibroCore

final class DocumentCoverTests: XCTestCase {
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
}
