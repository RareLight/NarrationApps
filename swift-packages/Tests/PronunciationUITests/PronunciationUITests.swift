import XCTest
import Foundation
import Pronunciation
import NarrationCore
import AudioOutput
@testable import PronunciationUI

@MainActor final class PronunciationUITests: XCTestCase {
    func testContextPreviewCapturesSentenceAndDocumentScope() async throws {
        let invoked = expectation(description: "Context captured")
        let preview = PronunciationPreview { text, _, configuration in
            XCTAssertEqual(text, "Mina opened the book."); XCTAssertEqual(configuration.documentTitle, "The station")
            invoked.fulfill(); throw CancellationError()
        }
        let entry = PronunciationEntry(word: "Mina", spelling: "mee nah", documentTitle: "The station")
        preview.play(entry: entry, dictionary: try .init(entries: [entry]), configuration: .init(worker: URL(fileURLWithPath: "/synthetic/worker"), workspace: URL(fileURLWithPath: "/synthetic/workspace"), settings: .init(), priority: .background), sentence: "Mina opened the book.")
        await fulfillment(of: [invoked], timeout: 2)
        await preview.stopAndWait(); XCTAssertFalse(preview.hasOwnedWork)
    }
    func testManualReviewSharesJoinedPreviewOwnership() async throws {
        let began = expectation(description: "Review owns work"), ended = expectation(description: "Review cancelled")
        let preview = PronunciationPreview()
        preview.performReview { began.fulfill(); do { try await Task.sleep(for: .seconds(30)) } catch { ended.fulfill(); throw error } }
        await fulfillment(of: [began], timeout: 2); XCTAssertTrue(preview.hasOwnedWork)
        await preview.stopAndWait(); await fulfillment(of: [ended], timeout: 2); XCTAssertFalse(preview.hasOwnedWork)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for owned operation")
    }
    func testEditorRoundTripAddRemoveAndCrossAppReload() async throws {
        let store = PronunciationStore(file: try root().appendingPathComponent("overrides.json"))
        let first = PronunciationEditor(store: store), second = PronunciationEditor(store: store)
        await first.reload(); await second.reload()
        let id = first.add()
        first.update(.init(id: id, word: "SQLite", spelling: "sequel lite")); first.save()
        try await settle { !first.saving && !first.dirty }
        await second.reload()
        XCTAssertEqual(second.entries.first?.word, "SQLite")
        second.remove(id: id); second.save()
        try await settle { !second.saving && !second.dirty }
        await first.reload()
        XCTAssertTrue(first.entries.isEmpty)
    }
    func testBlankNewRowSurvivesAutomaticRefresh() async throws {
        let store = PronunciationStore(file: try root().appendingPathComponent("overrides.json"))
        let editor = PronunciationEditor(store: store)
        await editor.reload()
        let id = editor.add(); editor.save()
        try await settle { !editor.saving && !editor.dirty }
        await editor.reload()
        XCTAssertEqual(editor.entries.first?.id, id)
    }

    func testInvalidDraftAndConflictingEditsDoNotOverwriteSavedDictionary() async throws {
        let store = PronunciationStore(file: try root().appendingPathComponent("overrides.json"))
        let first = PronunciationEditor(store: store), second = PronunciationEditor(store: store)
        await first.reload(); await second.reload()
        let id = first.add()
        first.update(.init(id: id, word: "SQLite", spelling: "sequel lite")); first.save()
        try await settle { !first.saving && !first.dirty }
        let other = second.add()
        second.update(.init(id: other, word: "Libro", spelling: "lee bro")); second.save()
        try await settle { !second.saving && second.error != nil }
        XCTAssertTrue(second.dirty)
        XCTAssertEqual(try store.load().dictionary.entries.first?.word, "SQLite")
        await second.reload(discardChanges: true)
        second.update(.init(id: id, word: "SQLite", spelling: "sikwəl")); second.save()
        XCTAssertNotNil(second.validationMessage)
        XCTAssertEqual(try store.load().dictionary.entries.first?.spelling, "sequel lite")
    }
    func testPreviewCancellationAndFailureJoinOwnedRenderWithoutPlayback() async throws {
        let started = expectation(description: "Preview render started")
        let cancelled = expectation(description: "Preview render cancelled")
        let preview = PronunciationPreview { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill(); throw error }
            throw CancellationError()
        }
        let entry = PronunciationEntry(word: "SQLite", spelling: "sequel lite")
        let dictionary = try PronunciationDictionary(entries: [entry])
        let config = PronunciationPreviewConfiguration(worker: URL(fileURLWithPath: "/synthetic/worker"),
            workspace: URL(fileURLWithPath: "/synthetic/models"), settings: .init(), priority: .background)
        preview.play(entry: entry, dictionary: dictionary, configuration: config)
        await fulfillment(of: [started], timeout: 3)
        await preview.stopAndWait()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertFalse(preview.hasOwnedWork); XCTAssertNil(preview.renderingID); XCTAssertNil(preview.playingID)
        let failure = PronunciationPreview { _, _, _ in throw PronunciationError.invalidFile }
        failure.play(entry: entry, dictionary: dictionary, configuration: config)
        try await settle { !failure.isRendering }
        XCTAssertNotNil(failure.error); XCTAssertNil(failure.playingID)
    }
    func testNativePronunciationPreviewRendererWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NARRATION_PRONUNCIATION_NATIVE"] == "1" else { throw XCTSkip("Opt-in native pronunciation renders") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workspace = root.deletingLastPathComponent().appendingPathComponent("Libro")
        let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
        for model in SpeechModel.allCases {
            let configuration = PronunciationPreviewConfiguration(worker: root.appendingPathComponent(".build/debug/NarrationSpeechWorker"),
                workspace: workspace, settings: .init(model: model, voice: model == .kokoro ? "af_heart" : "soprano", speed: 1), priority: .background)
            let artifact = try await PronunciationPreview.renderNative(word: "SQLite", dictionary: dictionary, configuration: configuration)
            let info = try NativeAudio.inspect(artifact.audio)
            XCTAssertEqual(info.sampleRate, model.capabilities.sampleRate)
            XCTAssertEqual(info.codec, "pcm_f32le")
            var nonzero = false
            try NativeAudio.decode(artifact.audio) { frames in
                XCTAssertTrue(frames.allSatisfy(\.isFinite)); nonzero = nonzero || frames.contains { $0 != 0 }
            }
            XCTAssertTrue(nonzero)
            await artifact.remove()
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.directory.path))
        }
    }

    func testPreviewArtifactsAreRemovedWhenPlaybackCannotStart() async throws {
        let directory = try root().appendingPathComponent("owned-preview")
        let preview = PronunciationPreview { _, _, _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return .init(directory: directory) // Missing audio fails without playing sound.
        }
        let entry = PronunciationEntry(word: "SQLite", spelling: "sequel lite")
        let config = PronunciationPreviewConfiguration(worker: URL(fileURLWithPath: "/synthetic/worker"),
            workspace: URL(fileURLWithPath: "/synthetic/models"), settings: .init(), priority: .background)
        preview.play(entry: entry, dictionary: try .init(entries: [entry]), configuration: config)
        try await settle { preview.error != nil && !FileManager.default.fileExists(atPath: directory.path) }
        XCTAssertNil(preview.playingID)
    }
}
