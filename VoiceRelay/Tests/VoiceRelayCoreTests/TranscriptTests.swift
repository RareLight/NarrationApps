import Foundation
import Testing
import AudioOutput
@testable import VoiceRelayCore

@Test func timedTranscriptUsesMeasuredSegmentsAndEscapesCueSyntax() throws {
    let transcript = try EpisodeTranscript.make(texts: ["First & <name>\n\n00:00:00.000 --> fake", "Second sentence."], artifactCounts: [2, 1], timeline: [
        .init(startFrame: 0, endFrame: 24_000, sampleRate: 24_000),
        .init(startFrame: 27_600, endFrame: 51_600, sampleRate: 24_000),
        .init(startFrame: 55_200, endFrame: 79_200, sampleRate: 24_000)
    ], language: "en-GB", audioHash: String(repeating: "a", count: 64))
    #expect(transcript.vtt == "WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.150\nFirst &amp; &lt;name&gt; 00:00:00.000 --&gt; fake\n\n2\n00:00:02.300 --> 00:00:03.300\nSecond sentence.\n\n")
    #expect(try transcript.data(for: transcript.audioHash) == Data(transcript.vtt.utf8))
    #expect(throws: RelayError.self) { try transcript.data(for: String(repeating: "b", count: 64)) }
    #expect(throws: RelayError.self) {
        try EpisodeTranscript.make(texts: ["Missing"], artifactCounts: [2], timeline: [.init(startFrame: 0, endFrame: 24_000, sampleRate: 24_000)], language: "en", audioHash: transcript.audioHash)
    }
    #expect(throws: RelayError.self) {
        try EpisodeTranscript.make(texts: ["Overlapping", "segments"], artifactCounts: [1, 1], timeline: [
            .init(startFrame: 0, endFrame: 24_000, sampleRate: 24_000), .init(startFrame: 12_000, endFrame: 36_000, sampleRate: 24_000)
        ], language: "en", audioHash: transcript.audioHash)
    }
    #expect(throws: RelayError.self) {
        try EpisodeTranscript.make(texts: ["\0"], artifactCounts: [1], timeline: [.init(startFrame: 0, endFrame: 1, sampleRate: 24_000)], language: "en", audioHash: transcript.audioHash)
    }
}

@Test func timedTranscriptPreferenceIsDefaultOnAndBackwardCompatible() throws {
    var preferences = try JSONDecoder().decode(SpeechPreferences.self, from: Data(#"{"voice":"af_heart","speed":1}"#.utf8))
    #expect(preferences.timedTranscriptsEnabled)
    preferences.timedTranscriptsEnabled = false
    let saved = try JSONDecoder().decode(SpeechPreferences.self, from: Files.json(preferences))
    #expect(!saved.timedTranscriptsEnabled)
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let legacy = PrototypeProfile.fixture(at: root)
    #expect(legacy.publishTranscripts == nil)
    let episode = Episode(id: UUID().uuidString.lowercased(), title: "Legacy", stage: .published, settings: legacy)
    let decoded = try JSONDecoder().decode(Episode.self, from: Files.json(episode))
    #expect(decoded.transcript == nil && decoded.transcriptReferences == nil)
}

@Test func timedTranscriptRSSPreservesNamespacesEscapingAndForeignReferences() throws {
    var settings = DeliverySettings()
    settings.enabled = true; settings.feedFolderURL = URL(string: "https://webdav.example/feed/")
    settings.publicFolderURL = URL(string: "https://podcast.example/feed/"); settings.username = "fixture"
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    var episode = Episode(id: UUID().uuidString.lowercased(), title: "Transcript fixture", stage: .published, publicationDate: Date(), settings: .fixture(at: root))
    episode.audioHash = String(repeating: "a", count: 64)
    episode.info = .init(duration: 2, byteLength: 100, sampleRate: 24_000, channels: 1, codec: "aac")
    episode.delivery = .init(status: .uploaded, remotePath: settings.remoteMediaPath(episode.id), uploadedByteLength: 100)
    episode.delivery?.destinationURL = settings.feedFolderURL
    let reference = PodcastTranscriptReference(url: URL(string: "https://transcripts.example/text.vtt?one=1&two=2")!, type: "text/vtt", language: "en-US", rel: "captions")
    episode.transcriptReferences = [reference]
    let feed = try RSS.renderRemote([episode], channel: RemoteChannel(settings: settings))
    #expect(String(decoding: feed, as: UTF8.self).contains("one=1&amp;two=2"))
    #expect(try ServerFeedParser.parse(feed).first?.transcripts == [reference])
    #expect(episode.ownedTranscriptPaths(settings: settings).isEmpty)
    let impostor = String(decoding: feed, as: UTF8.self)
        .replacingOccurrences(of: "xmlns:podcast=\"\(PodcastTranscriptReference.namespace)\"", with: "xmlns:podcast=\"urn:unrelated\"")
    #expect(try ServerFeedParser.parse(Data(impostor.utf8)).first?.transcripts.isEmpty == true)
    let unsafe = String(decoding: feed, as: UTF8.self).replacingOccurrences(of: "https://transcripts.example", with: "https://user:password@transcripts.example")
    let snapshot = try ServerFeedSnapshot(Data(unsafe.utf8))
    #expect(snapshot.items.isEmpty && snapshot.invalidItems.count == 1)
}
