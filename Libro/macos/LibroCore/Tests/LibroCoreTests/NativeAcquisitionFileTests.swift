import XCTest
import CryptoKit
@testable import LibroCore

final class NativeAcquisitionFileTests: XCTestCase {
    private let bytes = Data("fixture asset".utf8)
    private var file: NativeAcquisitionFile {
        .init(path: "config.json", bytes: bytes.count,
              hash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), gitOID: nil)
    }
    private func workspace() throws -> NativeWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Native repair \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try NativeWorkspace(root: root)
    }

    func testOrphanBlobIsQuarantinedWithoutSnapshotMapping() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let blob = workspace.hubCache.appendingPathComponent("models--fixture--model/blobs/fixture")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data(repeating: 88, count: bytes.count)
        try corrupt.write(to: blob)
        XCTAssertFalse(try file.quarantineInvalidCopy(at: blob, workspace: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        let quarantine = try FileManager.default.contentsOfDirectory(at: blob.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(quarantine.count, 1)
        XCTAssertTrue(quarantine[0].lastPathComponent.hasPrefix("fixture.invalid-"))
        XCTAssertEqual(try Data(contentsOf: quarantine[0]), corrupt)
        try bytes.write(to: blob)
        XCTAssertTrue(try file.quarantineInvalidCopy(at: blob, workspace: workspace))
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
    }

    func testCompletedCopiesRemainUnchangedAndMissingCopiesStayMissing() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let stage = workspace.nativeRoot.appendingPathComponent("staging/config.json")
        try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertFalse(try file.quarantineInvalidCopy(at: stage, workspace: workspace))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stage.deletingLastPathComponent().path).isEmpty)
        try bytes.write(to: stage)
        XCTAssertTrue(try file.quarantineInvalidCopy(at: stage, workspace: workspace))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.deletingLastPathComponent().path), ["config.json"])
        try Data([1]).write(to: stage)
        XCTAssertFalse(try file.quarantineInvalidCopy(at: stage, workspace: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    func testRepairRejectsPythonCopiesAndPrivateAliasesWithoutModifyingThem() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let shared = workspace.root.appendingPathComponent("models/shared/config.json")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data([1, 2, 3]); try corrupt.write(to: shared)
        XCTAssertThrowsError(try file.quarantineInvalidCopy(at: shared, workspace: workspace))
        let alias = workspace.hubCache.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        XCTAssertThrowsError(try file.quarantineInvalidCopy(at: alias, workspace: workspace))
        XCTAssertEqual(try Data(contentsOf: shared), corrupt)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), shared.path)
    }

    func testCancellationDoesNotQuarantineExistingCopy() async throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let copy = workspace.nativeRoot.appendingPathComponent("staging/config.json")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: copy)
        let file = file
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try file.quarantineInvalidCopy(at: copy, workspace: workspace)
        }
        do { _ = try await task.value; XCTFail("Cancellation was ignored") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: copy), Data([1]))
    }

    func testChildTransferByteProgressAdvancesBeforeCompletion() {
        let parent = NativeAcquisitionProgress(total: 1_000)
        parent.value.completedUnitCount = 100
        let first = NativeAcquisitionProgress(total: 400)
        let second = NativeAcquisitionProgress(total: 500)
        parent.value.addChild(first.value, withPendingUnitCount: 400)
        parent.value.addChild(second.value, withPendingUnitCount: 500)
        first.value.completedUnitCount = 200
        second.value.completedUnitCount = 125
        XCTAssertEqual(parent.value.completedUnitCount, 100)
        XCTAssertEqual(parent.completedBytes, 425)
        first.value.completedUnitCount = 400
        second.value.completedUnitCount = 500
        XCTAssertEqual(parent.completedBytes, 1_000)
    }
}
