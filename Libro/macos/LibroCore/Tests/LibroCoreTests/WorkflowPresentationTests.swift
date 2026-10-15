import XCTest
@testable import LibroCore

final class WorkflowPresentationTests: XCTestCase {
    func testArrowSelectionRangesBoundariesAndRemovedRows() {
        let rows = (0..<4).map { _ in UUID() }
        var navigation = QueueKeyboardSelection()
        var selection = navigation.move(rows: rows, selection: [], forward: true, extending: false)
        XCTAssertEqual(selection, [rows[0]])
        selection = navigation.move(rows: rows, selection: selection, forward: true, extending: true)
        XCTAssertEqual(selection, Set(rows[0...1]))
        selection = navigation.move(rows: rows, selection: selection, forward: true, extending: true)
        XCTAssertEqual(selection, Set(rows[0...2]))
        selection = navigation.move(rows: rows, selection: selection, forward: false, extending: true)
        XCTAssertEqual(selection, Set(rows[0...1]))
        selection = navigation.move(rows: rows, selection: [rows[3]], forward: true, extending: false)
        XCTAssertEqual(selection, [rows[3]])
        selection = navigation.move(rows: Array(rows.dropLast()), selection: selection, forward: false, extending: false)
        XCTAssertEqual(selection, [rows[2]])
        XCTAssertEqual(navigation.move(rows: [], selection: selection, forward: true, extending: true), [])
    }

    func testFriendlyLabelsKeepUnknownIdentifiersAndCatalogDefaults() {
        for voice in NativePrimaryCatalog.specification(for: .kokoro).voices {
            XCTAssertFalse(VoicePresentation.name(voice).contains("_"))
        }
        XCTAssertEqual(VoicePresentation.name("af_aoede"), "Aoede")
        XCTAssertEqual(VoicePresentation.name("bm_george"), "George")
        XCTAssertEqual(VoicePresentation.name("future_voice"), "future_voice")
        XCTAssertEqual(SpeechSettings().voice, "af_heart")
        XCTAssertEqual(SpeechSettings().speed, 1.0)
    }

    func testRecoverySequenceAndImmutableActiveBatchGate() {
        func blocker(generating: Bool = false, preparing: Bool = false, busy: Bool = false,
                     planning: Bool = false, workspace: Bool = true, output: Bool = true,
                     checking: Bool = false, ready: Bool = true, queued: Int = 2, planned: Int = 2,
                     error: Bool = false) -> GenerationBlocker? {
            .evaluate(isGenerating: generating, isPreparing: preparing, busy: busy, planning: planning,
                      workspaceAvailable: workspace, outputAvailable: output, checkingAssets: checking,
                      assetsReady: ready, queuedCount: queued, plannedCount: planned, hasPlanningError: error)
        }
        XCTAssertEqual(blocker(workspace: false, output: false, ready: false, queued: 0), .workspace)
        XCTAssertEqual(blocker(output: false, ready: false), .output)
        XCTAssertEqual(blocker(checking: true, ready: false), .checkingModel)
        XCTAssertEqual(blocker(ready: false), .model)
        XCTAssertEqual(blocker(queued: 0, planned: 0), .documents)
        XCTAssertEqual(blocker(planning: true, planned: 0), .planning)
        XCTAssertEqual(blocker(planned: 1), .destinations)
        XCTAssertEqual(blocker(error: true), .destinations)
        XCTAssertNil(blocker())
        XCTAssertEqual(blocker(generating: true, workspace: false, output: false), .activeBatch)
        XCTAssertEqual(blocker(preparing: true), .preparation)
        XCTAssertEqual(blocker(busy: true), .intake)
    }
}
