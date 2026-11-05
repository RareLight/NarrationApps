import XCTest
import Foundation
@testable import NarrationCore

final class SpeechWorkWakeupTests: XCTestCase, @unchecked Sendable {
    private func next(_ wakeup: SpeechWorkWakeup) async throws -> SpeechWorkWakeup.Event {
        try await withThrowingTaskGroup(of: SpeechWorkWakeup.Event?.self) { group in
            group.addTask { var iterator = wakeup.events.makeAsyncIterator(); return await iterator.next() }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw SpeechFailure(.timeout) }
            defer { group.cancelAll() }
            guard let result = try await group.next() ?? nil else { throw SpeechFailure(.workerExited) }
            return result
        }
    }
    func testBoundedFallbackWorksWithNotificationsUnavailableAndFinishJoinsStream() async throws {
        let wakeup = SpeechWorkWakeup(root: URL(fileURLWithPath: "/synthetic/\(UUID())"), fallbackMilliseconds: 20, notifications: false)
        defer { wakeup.finish() }
        XCTAssertFalse(wakeup.notificationsAvailable)
        let event = try await next(wakeup); XCTAssertEqual(event, .fallback)
        wakeup.finish(); wakeup.finish()
        var iterator = wakeup.events.makeAsyncIterator()
        while await iterator.next() != nil {} // At most the one coalesced event remains.
    }
    func testAdvisoryNotificationsCannotGrantOrInventDemand() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("wakeup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try SpeechWorkAdmission(root: root)
        let wakeup = SpeechWorkWakeup(root: root, fallbackMilliseconds: 30_000)
        defer { wakeup.finish() }
        guard wakeup.notificationsAvailable else { throw XCTSkip("System notifications unavailable; fallback is tested separately") }
        SpeechWorkWakeup.post(root: root)
        let advisory = try await next(wakeup); XCTAssertEqual(advisory, .changed)
        XCTAssertNil(try registry.highest())
        let ticket = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming)
        let accepted = try await next(wakeup); XCTAssertEqual(accepted, .changed)
        XCTAssertEqual(try registry.highest(), ticket.demand)
        try ticket.withdraw()
        let withdrawn = try await next(wakeup); XCTAssertEqual(withdrawn, .changed)
        XCTAssertNil(try registry.highest())
    }
    func testNamespaceContainsNoRootPathAndSeparatesIsolatedRegistries() {
        let root = URL(fileURLWithPath: "/synthetic/private-input-\(UUID())")
        let name = SpeechWorkWakeup.name(root)
        XCTAssertFalse(name.contains(root.lastPathComponent)); XCTAssertFalse(name.contains("/"))
        XCTAssertNotEqual(name, SpeechWorkWakeup.name(root.appendingPathComponent("other")))
        XCTAssertEqual(name, SpeechWorkWakeup.name(root.appendingPathComponent("../" + root.lastPathComponent)))
    }
}
