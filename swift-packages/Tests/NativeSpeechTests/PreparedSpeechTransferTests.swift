import XCTest
import NarrationCore
@testable import NativeSpeech

final class PreparedSpeechTransferTests: XCTestCase {
    private func fixture(_ body: (URL, PreparedUtterance) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let utterance = PreparedUtterance(text: "hello", phonemes: "h", tokenCount: 1,
            source: .init(blockIndices: [0], location: 0, length: 5), boundaryAfter: .paragraph, acousticIdentity: "test")
        try body(root, utterance)
    }
    func testBoundedPrivateArtifactRoundTripAndExclusiveCreation() throws {
        try fixture { root, utterance in
            let values = Array(repeating: utterance, count: 300)
            let reference = try PreparedSpeechTransfer.write(values, index: 0, spool: root)
            let event = WorkerEvent(kind: .textPrepared, identity: .init(batch: UUID(), job: UUID()), chunk: 0, preparedFile: reference)
            XCTAssertLessThan(try SpeechIPC.encode(event).count, 2_000)
            XCTAssertEqual(try PreparedSpeechTransfer.read(reference, index: 0, spool: root), values)
            XCTAssertThrowsError(try PreparedSpeechTransfer.write(values, index: 0, spool: root))
        }
    }
    func testRejectsOutsidePathDigestChangesSymlinksHardlinksAndOversize() throws {
        try fixture { root, utterance in
            let reference = try PreparedSpeechTransfer.write([utterance], index: 0, spool: root)
            let file = SpeechIPC.preparationFile(in: root, index: 0)
            XCTAssertThrowsError(try PreparedSpeechTransfer.read(.init(path: root.appendingPathComponent("other").path, sha256: reference.sha256, count: 1), index: 0, spool: root))
            XCTAssertThrowsError(try PreparedSpeechTransfer.read(.init(path: reference.path, sha256: String(repeating: "0", count: 64), count: 1), index: 0, spool: root))
            let link = root.appendingPathComponent("hardlink")
            try FileManager.default.linkItem(at: file, to: link)
            XCTAssertThrowsError(try PreparedSpeechTransfer.read(reference, index: 0, spool: root))
            try FileManager.default.removeItem(at: link)
            let payload = root.appendingPathComponent("payload")
            try FileManager.default.moveItem(at: file, to: payload)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: payload)
            XCTAssertThrowsError(try PreparedSpeechTransfer.read(reference, index: 0, spool: root))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: payload, to: file)
            let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(PreparedSpeechTransfer.maximumBytes + 1)); try handle.close()
            XCTAssertThrowsError(try PreparedSpeechTransfer.read(reference, index: 0, spool: root))
        }
    }
}
