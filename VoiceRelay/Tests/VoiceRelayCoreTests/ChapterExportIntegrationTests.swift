import AVFoundation
import AudioOutput
import Foundation
import NarrationCore
import Testing
@testable import VoiceRelayCore

private actor SummaryCalls {
    var count = 0
    func record() { count += 1 }
}

private final class ChapterAudioBackend: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "chapter-notes-test-1", displayName: "Synthetic chapter fixture", isMock: false)
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func prepare() throws { try Task.checkCancellation() }
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        lock.withLock { calls += 1 }
        var artifacts: [LosslessArtifact] = []
        for index in 0..<2 {
            let file = directory.appendingPathComponent("segment-\(index).wav")
            let writer = try AtomicAudioWriter(destination: file, format: .wav)
            defer { writer.abort() }
            let rate = 24_000, count = index == 0 ? 6_000 : 3_000
            let samples: [Float] = (0..<count).map {
                $0 < 600 || $0 >= count - 600 ? 0 : Float(sin(Double($0) * 0.05) * 0.1)
            }
            try writer.append(samples: samples, sampleRate: rate)
            try writer.publish()
            artifacts.append(.init(url: file, sampleRate: rate, channels: 1, format: "wav"))
        }
        return .init(artifacts: artifacts)
    }
}

@Test func reviewedArticleChaptersSummaryAndLinksSurviveEncodingRetry() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("voicerelay-chapter-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = URL(string: "https://articles.example/gardening")!
    let html = """
    <html><head><title>A garden</title></head><body><article>
    <h1>A garden</h1><h2>First section</h2>
    <p>A gardener prepares the soil with care, choosing seeds for the season.
    The source explains how water and light help the plants grow.
    <a href="https://reference.example/soil">Soil reference</a></p>
    <h3>A nested section</h3><p>The gardener checks the soil regularly.</p>
    <h2>Second section</h2><p>The gardener watches the plants grow and collects the harvest.</p>
    </article></body></html>
    """
    let calls = SummaryCalls()
    let review = try await ArticleSourceLoader(limits: FetchLimits(), fetch: { requested in
        FetchedPage(originalURL: requested, finalURL: requested, bytes: Data(html.utf8), html: html,
            contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    }, describeImages: false, generateSummaries: true, summaryGenerator: { text in
        #expect(text.contains("gardener"))
        await calls.record()
        return "A gardener prepares soil and helps seeds grow."
    }).load(url, chunkLimit: 1800)
    #expect(review.document?.article.summaryAttempted == true)
    #expect(review.narration?.showNotes?.summary == "A gardener prepares soil and helps seeds grow.")
    let snapshot = try StoredExtraction(review: review, chunkLimit: 1800)
    let captured = try JSONDecoder().decode(StoredExtraction.self, from: Files.json(snapshot)).review()
    #expect(captured.narration?.showNotes == review.narration?.showNotes)
    let coordinator = FixtureCoordinator(), backend = ChapterAudioBackend()
    do {
        _ = try await coordinator.runReviewed(root: root, review: captured, backend: backend, interruptAfter: .encoded)
        Issue.record("Expected the synthetic prepublication interruption.")
    } catch { #expect(error as? RelayError == .interrupted) }
    let synthesized = backend.count
    #expect(synthesized > 0)
    let result = try await coordinator.runReviewed(root: root, review: captured, backend: backend)
    #expect(result.synthesizedChunks == 0 && backend.count == synthesized)
    #expect(result.episode.showNotes?.summary == captured.document?.article.summary)
    #expect(result.episode.showNotesAudioHash == result.episode.audioHash)
    let output = result.episode.settings.audio.appendingPathComponent(result.episode.id + ".m4a")
    let asset = AVURLAsset(url: output), locales = try await asset.load(.availableChapterLocales)
    let locale = try #require(locales.first)
    let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
    let measured = try #require(result.episode.chapters)
    #expect(groups.count == measured.count && measured.count > 2)
    for (group, chapter) in zip(groups, measured) {
        let title = try await group.items.first { $0.commonKey == AVMetadataKey.commonKeyTitle }?.load(.stringValue)
        #expect(title == chapter.title)
        #expect(abs(group.timeRange.start.seconds - chapter.startTime) <= 0.001)
    }
    #expect(measured.first?.startTime == 0)
    #expect(measured.contains { $0.title == "A nested section" })
    let metadata = try await asset.load(.commonMetadata)
    let description = try await metadata.first { $0.commonKey == AVMetadataKey.commonKeyDescription }?.load(.stringValue)
    #expect(description?.contains("A gardener prepares soil and helps seeds grow.") == true)
    #expect(description?.contains("https://reference.example/soil") == true)
    let hash = try Files.hash(output)
    let repeated = try await coordinator.runReviewed(root: root, review: captured, backend: backend)
    #expect(repeated.synthesizedChunks == 0 && backend.count == synthesized)
    #expect(try Files.hash(output) == hash)
    #expect(await calls.count == 1)
}
