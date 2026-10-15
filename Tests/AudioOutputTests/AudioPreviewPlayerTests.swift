import Foundation
import XCTest
@testable import AudioOutput

@MainActor private final class FakePreviewPlayback: PreviewPlayback {
    var isPlaying = false
    var plays = 0
    var stops = 0
    var acceptsPlay = true
    func play() -> Bool { plays += 1; isPlaying = acceptsPlay; return acceptsPlay }
    func stop() { stops += 1; isPlaying = false }
}
final class AudioPreviewPlayerTests: XCTestCase {
    @MainActor func testPlaybackReplacesPreviousSampleAndSameButtonStops() {
        let first = FakePreviewPlayback(), second = FakePreviewPlayback()
        let player = AudioPreviewPlayer { url in url.lastPathComponent == "first.m4a" ? first : second }
        player.toggle(url: URL(fileURLWithPath: "/synthetic/first.m4a"), id: "first")
        XCTAssertEqual(player.playingID, "first")
        player.toggle(url: URL(fileURLWithPath: "/synthetic/second.m4a"), id: "second")
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(player.playingID, "second")
        player.toggle(url: URL(fileURLWithPath: "/synthetic/second.m4a"), id: "second")
        XCTAssertEqual(second.plays, 1)
        XCTAssertEqual(second.stops, 1)
        XCTAssertNil(player.playingID)
    }
    @MainActor func testMissingAndFailedPlaybackRecoverWithoutInference() {
        let audio = FakePreviewPlayback()
        audio.acceptsPlay = false
        let player = AudioPreviewPlayer { _ in audio }
        player.toggle(url: nil, id: "missing")
        XCTAssertNotNil(player.error); XCTAssertEqual(audio.plays, 0)
        player.toggle(url: URL(fileURLWithPath: "/synthetic/sample.m4a"), id: "sample")
        XCTAssertNotNil(player.error); XCTAssertNil(player.playingID)
        audio.acceptsPlay = true
        player.toggle(url: URL(fileURLWithPath: "/synthetic/sample.m4a"), id: "sample")
        XCTAssertNil(player.error); XCTAssertEqual(player.playingID, "sample")
        player.stop()
    }
    @MainActor func testNaturalCompletionClearsState() async throws {
        let audio = FakePreviewPlayback()
        let player = AudioPreviewPlayer { _ in audio }
        player.toggle(url: URL(fileURLWithPath: "/synthetic/sample.m4a"), id: "sample")
        audio.isPlaying = false
        await Task.yield()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(player.playingID)
    }
}
