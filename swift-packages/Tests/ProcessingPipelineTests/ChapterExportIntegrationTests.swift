import AVFoundation
import AudioOutput
import DocumentProcessing
import Foundation
import NarrationCore
import NativeSpeech
import XCTest
@testable import ProcessingPipeline

final class ChapterExportIntegrationTests: XCTestCase, @unchecked Sendable {
    private actor Calls {
        var sources: [String] = []
        func record(_ text: String) { sources.append(text) }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("chapter-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func configuration(_ root: URL, executable: URL? = nil, failPreparation: Bool = false) throws -> WorkerConfiguration {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let worker = executable ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] ??
            package.appendingPathComponent(".build/debug/NarrationFixtureWorker").path)
        if executable == nil, !FileManager.default.isExecutableFile(atPath: worker.path) {
            throw XCTSkip("Build NarrationFixtureWorker before running chapter export fixtures.")
        }
        var configuration = WorkerConfiguration(executable: worker, arguments: ["--handoff-probe"],
            environment: ["NARRATION_FIXTURE_SYNTHETIC_PCM": "1", "NARRATION_FIXTURE_FAIL_PREPARATION": failPreparation ? "1" : "0"],
            inferenceLeaseFile: root.appendingPathComponent("inference.lock"), inferencePriority: .interactive)
        configuration.workCoordinator = try SpeechWorkCoordinator(owner: .libro, configuration: configuration,
            root: root.appendingPathComponent("admission"))
        return configuration
    }

    private func chapterGroups(_ output: URL) async throws -> [AVTimedMetadataGroup] {
        let asset = AVURLAsset(url: output)
        let locales = try await asset.load(.availableChapterLocales)
        let locale = try XCTUnwrap(locales.first)
        return try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
    }

    func testLibroCapturesSummaryAndBookChaptersAcrossInterruptedExport() async throws {
        let root = try root(), output = root.appendingPathComponent("output"), workspace = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("book.md")
        let text = """
        # Chapter One

        A gardener prepares the soil for seeds. [Reference](https://reference.example/soil)

        ## A small subsection

        Seeds need water and light.

        # Chapter Two

        The gardener watches the plants grow.
        """
        try Data(text.utf8).write(to: source)
        let inputs = [InputDocument(source: source, kind: .markdown, relativePath: "book.md")]
        let documents = try BatchPlanner.plan(inputs, output: output, format: .m4a)
        let request = BatchRequest(documents: documents, outputDirectory: output, workspace: workspace,
            settings: .init(model: .soprano), describeImages: false, outputFormat: .m4a)
        let configuration = try configuration(root), engine = try XCTUnwrap(configuration.workCoordinator)
        let calls = Calls()
        let coordinator = QueueCoordinator(configuration: configuration, summaryGenerator: { text in
            await calls.record(text)
            return "A gardener prepares soil and helps seeds grow."
        })
        var recovery: LibroBatchRecovery? = try .init(directory: root.appendingPathComponent("recovery"), request: request)
        let control = BatchQueueControl(batch: request.id, jobs: documents.map(\.id))
        let task = Task { [owned = recovery!] in
            try await coordinator.run(request, control: control, recovery: owned) { event in
                if case .speech(let value) = event, value.phase == .chunkWritten, value.completedChunks == 1 {
                    control.setPaused(true)
                }
            }
        }
        do {
            let deadline = ContinuousClock.now + .seconds(10)
            while control.state.phase != .paused {
                guard ContinuousClock.now < deadline else { throw SpeechFailure(.timeout) }
                try await Task.sleep(for: .milliseconds(5))
            }
            await coordinator.cancelAndWait()
            let interrupted = try await task.value
            XCTAssertTrue(interrupted.cancelled)
        } catch {
            task.cancel(); await coordinator.cancelAndWait(); _ = await task.result
            await engine.close(); throw error
        }
        await engine.close()
        var journal = try recovery!.journal(document: documents[0].id)
        let captured = try XCTUnwrap(journal?.request.plan.showNotes)
        XCTAssertEqual(captured.summary, "A gardener prepares soil and helps seeds grow.")
        XCTAssertEqual(captured.links.map(\.url.absoluteString), ["https://reference.example/soil"])
        XCTAssertEqual(captured.chapters.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents[0].destination.path))
        journal = nil; recovery = nil

        let reopened = try LibroBatchRecovery(reopening: root.appendingPathComponent("recovery"))
        let resumedRequest = try reopened.resumeRequest()
        let resumedConfiguration = try self.configuration(root, failPreparation: true)
        let resumedEngine = try XCTUnwrap(resumedConfiguration.workCoordinator)
        let result = try await QueueCoordinator(configuration: resumedConfiguration, summaryGenerator: { text in
            await calls.record(text); return "This provider must not run again."
        }).run(resumedRequest, recovery: reopened)
        await resumedEngine.close()
        XCTAssertEqual(result.successfulCount, 1, "\(result.documents)")
        let count = await calls.sources.count
        XCTAssertEqual(count, 1, "Resume must use the captured summary and plan.")
        let groups = try await chapterGroups(documents[0].destination)
        XCTAssertEqual(groups.count, 2)
        let titles = try await groups.asyncTitles()
        XCTAssertEqual(titles, ["Chapter One", "Chapter Two"])
        XCTAssertEqual(groups[0].timeRange.start.seconds, 0, accuracy: 0.001)
        XCTAssertGreaterThan(groups[1].timeRange.start.seconds, groups[0].timeRange.start.seconds)
        let metadata = try await AVURLAsset(url: documents[0].destination).load(.commonMetadata)
        let description = try await metadata.first { $0.commonKey == .commonKeyDescription }?.load(.stringValue)
        XCTAssertTrue(description?.contains(captured.summary!) == true)
        XCTAssertTrue(description?.contains("https://reference.example/soil") == true)
        XCTAssertTrue(try reopened.resumeRequest().documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data(text.utf8))
    }

    func testRestoredPCMChaptersUseInsertedFramesNotRequestedGap() async throws {
        let root = try root(), settings = SpeechSettings(model: .soprano), identity = AttemptIdentity(batch: UUID(), job: UUID())
        let acoustic = SpeechAcousticIdentity.make(settings: settings, policy: .nativeText)
        let utterances = (0..<2).map { index in
            PreparedUtterance(text: "Chapter \(index).", phonemes: nil, tokenCount: 0,
                source: .init(blockIndices: [index], location: 0, length: 10),
                boundaryAfter: .heading, acousticIdentity: acoustic)
        }
        let plan = PreparedSpeechPlan(policy: .nativeText, settings: settings, semanticVersion: "fixture",
            acousticIdentity: acoustic, utterances: utterances, notices: [], documentTitle: "Book",
            showNotes: .init(chapters: [.init(title: "One", blockIndex: 0), .init(title: "Two", blockIndex: 1)]))
        let destination = root.appendingPathComponent("book.m4a")
        let journal = try SpeechRenderJournal(directory: root.appendingPathComponent("journal"),
            request: .init(identity: identity, plan: plan, destination: destination, format: .m4a,
                replaceExisting: false, sourceFingerprint: "synthetic-source", documentOrder: [identity.job]))
        let rate = settings.model.capabilities.sampleRate
        let first = [Float](repeating: 0.1, count: rate * 8 / 10) + [Float](repeating: 0, count: rate * 2 / 10)
        let second = [Float](repeating: 0, count: rate / 10) + [Float](repeating: 0.2, count: rate * 9 / 10)
        let token = try SpeechAttemptFence(batch: identity.batch, job: identity.job).begin()
        for (index, samples) in [first, second].enumerated() {
            try journal.commit(journal.stage(index: index, samples: samples, token: token))
        }
        let configuration = try configuration(root, executable: root.appendingPathComponent("must-not-launch"))
        let engine = try XCTUnwrap(configuration.workCoordinator)
        let session = try NativeSpeechSession(configuration: configuration, workspace: root, settings: settings,
            leaseFile: configuration.inferenceLeaseFile)
        do {
            try await session.prepare()
            try await session.render(plan: plan, destination: destination, outputFormat: .m4a, replaceExisting: false,
                identity: identity, recovery: journal)
            await session.close()
        } catch { await session.close(); await engine.close(); throw error }
        let observation = await engine.observation()
        await engine.close()
        XCTAssertNil(observation.pid, "Verified restored PCM must not launch a speech helper.")
        let groups = try await chapterGroups(destination)
        XCTAssertEqual(groups.count, 2)
        // 0.45s target - 0.20s existing tail - 0.10s existing lead = 0.15s inserted.
        XCTAssertEqual(groups[1].timeRange.start.seconds, 1.15, accuracy: 0.001)
        let info = try NativeAudio.inspect(destination)
        // Native AAC container tail: at most one packet beyond the intended PCM.
        let expected = Int64(rate * 215 / 100)
        XCTAssertGreaterThanOrEqual(info.frames, expected)
        XCTAssertLessThan(info.frames - expected, 1_024)
        XCTAssertGreaterThanOrEqual(info.duration, 2.15)
        XCTAssertLessThan(info.duration - 2.15, 1_024.0 / 32_000.0)
    }

    func testLibroExportsWhenSummaryDisabledUnavailableOrOversized() async throws {
        for mode in ["disabled", "unavailable", "oversized"] {
            let root = try root(), output = root.appendingPathComponent("output"), source = root.appendingPathComponent("document.md")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let text = "# One\n\nA short source.\n\n# Two\n\n" +
                (mode == "oversized" ? String(repeating: "A source sentence. ", count: 500) : "Another short source.")
            try Data(text.utf8).write(to: source)
            let documents = try BatchPlanner.plan([.init(source: source, kind: .markdown, relativePath: "document.md")], output: output, format: .m4a)
            let request = BatchRequest(documents: documents, outputDirectory: output, workspace: root,
                settings: .init(model: .soprano), outputFormat: .m4a,
                narrationOptions: .init(generateSummary: mode != "disabled"))
            let configuration = try configuration(root), engine = try XCTUnwrap(configuration.workCoordinator), calls = Calls()
            let provider: DocumentSummaryGenerator.Generate? = mode == "unavailable" ? nil : { @Sendable text in
                await calls.record(text); return "This provider should not run."
            }
            let result = try await QueueCoordinator(configuration: configuration, summaryGenerator: provider).run(request)
            await engine.close()
            XCTAssertEqual(result.successfulCount, 1, "\(mode): \(result.documents)")
            let count = await calls.sources.count
            XCTAssertEqual(count, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: documents[0].destination.path))
            let groups = try await chapterGroups(documents[0].destination)
            XCTAssertEqual(groups.count, 2)
        }
    }
}

private extension Array where Element == AVTimedMetadataGroup {
    func asyncTitles() async throws -> [String] {
        var titles: [String] = []
        for group in self {
            titles.append(try await group.items.first { $0.commonKey == .commonKeyTitle }?.load(.stringValue) ?? "")
        }
        return titles
    }
}
