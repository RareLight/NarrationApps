import Foundation
import XCTest
@testable import NarrationCore

final class SpeechScratchLeaseTests: XCTestCase {
    private func directory(_ parent: URL, _ name: String) throws -> URL {
        let result = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return result
    }
    func testCleanupRequiresBothHostAndHelperToReleaseTheirActualLocks() throws {
        let root = try directory(FileManager.default.temporaryDirectory.resolvingSymlinksInPath(), UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = try directory(root, "attempt-\(UUID())")
        let host = try SpeechScratchLease(directory: stage, create: true)
        let helper = try SpeechScratchLease(directory: stage, create: false)
        let pcm = stage.appendingPathComponent("owned.f32"); try Data([1, 2, 3]).write(to: pcm)
        XCTAssertFalse(try SpeechScratchLease.removeIfUnowned(stage))
        host.close()
        XCTAssertFalse(try SpeechScratchLease.removeIfUnowned(stage))
        XCTAssertEqual(try Data(contentsOf: pcm), Data([1, 2, 3]))
        helper.close()
        XCTAssertTrue(try SpeechScratchLease.removeIfUnowned(stage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testSweepRetainsUnmarkedLegacyWorkAndOnlyRemovesOwnedNamespace() throws {
        let root = try directory(FileManager.default.temporaryDirectory.resolvingSymlinksInPath(), UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try directory(root, "attempt-\(UUID())")
        let orphan = try directory(root, "attempt-\(UUID())")
        let other = try directory(root, "unrelated-\(UUID())")
        let lease = try SpeechScratchLease(directory: orphan, create: true); lease.close()
        let unrelated = try SpeechScratchLease(directory: other, create: true); unrelated.close()
        XCTAssertEqual(try SpeechScratchLease.sweep(root, prefix: "attempt-"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
    func testMarkerSymlinkCannotAuthorizeCleanupOfOtherFiles() throws {
        let root = try directory(FileManager.default.temporaryDirectory.resolvingSymlinksInPath(), UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = try directory(root, "attempt-\(UUID())")
        let lease = try SpeechScratchLease(directory: stage, create: true); lease.close()
        let marker = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).first)
        let original = root.appendingPathComponent("original.txt"); try Data("Original bytes".utf8).write(to: original)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: original)
        XCTAssertThrowsError(try SpeechScratchLease.removeIfUnowned(stage))
        XCTAssertEqual(try Data(contentsOf: original), Data("Original bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
    }
}
