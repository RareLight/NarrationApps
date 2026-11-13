import CryptoKit
import Foundation
import Testing
import AudioOutput
import NarrationCore
@testable import VoiceRelayCore

private func plan(showNotes: DocumentShowNotes?, documentTitle: String? = "Article") -> NarrationPlan {
    // Chunk 0 is the generated intro: no source block association.
    NarrationPlan(version: "v", chunks: [
        NarrationChunk(index: 0, text: "Title. Source: site.", blockIndices: []),
        NarrationChunk(index: 1, text: "First section text.", blockIndices: [0]),
        NarrationChunk(index: 2, text: "Second section text.", blockIndices: [1]),
    ], notices: [], documentTitle: documentTitle, showNotes: showNotes)
}

private func timeline(starts: [Double], seconds: Double = 0.5) -> [AudioSegmentTiming] {
    let rate = 24_000
    return starts.map { .init(startFrame: UInt64($0 * Double(rate)), endFrame: UInt64(($0 + seconds) * Double(rate)), sampleRate: rate) }
}

@Test func chaptersMapToMeasuredArtifactStartsNotIntro() throws {
    let notes = DocumentShowNotes(chapters: [
        DocumentChapter(title: "One", blockIndex: 0), DocumentChapter(title: "Two", blockIndex: 1),
    ])
    // Chunk 1 emits two artifacts; chunk 2 one. Chunk 0 (intro) is one artifact.
    let (chapters, chapterNotice) = try EpisodeChapters.make(plan: plan(showNotes: notes), artifactCounts: [1, 2, 1], timeline: [
        .init(startFrame: 0, endFrame: 12_000, sampleRate: 24_000),
        .init(startFrame: 14_400, endFrame: 24_000, sampleRate: 24_000),
        .init(startFrame: 30_000, endFrame: 48_000, sampleRate: 24_000),
        .init(startFrame: 52_800, endFrame: 72_000, sampleRate: 24_000),
    ])
    // Intro narrates first but owns no source block: first real target is block 0
    // at chunk 1's measured artifact start 14_400 frames = 0.6 s, so an opening
    // marker is inserted at 0; no marker is absorbed by the intro.
    #expect(chapters.map { $0.title } == ["Article", "One", "Two"])
    #expect(chapters.map { $0.startTime } == [0, 0.6, 2.2])
    #expect(chapters.last?.endTime == 3.0)
    #expect(chapterNotice == nil)
}

@Test func chaptersRequireCompleteMeasuredTimeline() {
    let notes = DocumentShowNotes(chapters: [DocumentChapter(title: "One", blockIndex: 0)])
    #expect(throws: RelayError.self) {
        try EpisodeChapters.make(plan: plan(showNotes: notes), artifactCounts: [1, 2, 1],
            timeline: [.init(startFrame: 0, endFrame: 1, sampleRate: 24_000)])
    }
}

/// Real committed episode: the feed verifies hash/size of the saved audio file.
private func episode(title: String, notesHash: String? = nil,
                     notes: DocumentShowNotes? = nil, chapters: [AudioChapter]? = nil) throws -> (Episode, String) {
    let settings = PrototypeProfile.fixture(at: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true))
    try FileManager.default.createDirectory(at: settings.audio, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let audio = Data("synthetic-audio-\(title)".utf8)
    try audio.write(to: settings.audio.appendingPathComponent(id + ".m4a"))
    let hash = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
    var e = Episode(id: id, title: title, stage: .published,
                    publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
                    encodedHash: hash, audioHash: hash,
                    info: AudioInfo(duration: 4, byteLength: Int64(audio.count), sampleRate: 24_000, channels: 1, codec: "aac"),
                    synthesisFingerprint: nil, settings: settings)
    e.sourceURL = URL(string: "https://site.example/post")
    e.sourceName = "site.example"
    e.showNotesAudioHash = notesHash
    e.showNotes = notes; e.chapters = chapters
    return (e, hash)
}

@Test func feedEmbedsEscapedShowNotesForCurrentAudio() throws {
    let notes = DocumentShowNotes(summary: "A <summary> & short.",
        links: [DocumentSourceLink(label: "Ref", url: URL(string: "https://ref.example/one")!)],
        chapters: [DocumentChapter(title: "Sec", blockIndex: 0)])
    let chapters = [AudioChapter(title: "Sec", startTime: 0, endTime: 2)]
    let (ep, hash) = try episode(title: "T", notesHash: nil, notes: notes, chapters: chapters)
    var withNotes = ep; withNotes.showNotesAudioHash = hash
    let xml = String(decoding: try RSS.render([withNotes], settings: withNotes.settings), as: UTF8.self)
    #expect(xml.contains("<content:encoded>"))
    // Description is XML-escaped over the already-HTML-escaped notes.
    #expect(xml.contains("A &amp;lt;summary&amp;gt; &amp;amp; short."))
    #expect(xml.contains("ref.example/one"))
    #expect(xml.contains("&lt;ul&gt;"), "link list arrives as escaped HTML")
    #expect(xml.contains("&lt;a href=&quot;https://ref.example/one&quot;"))
    #expect(xml.contains("0:00 Sec"))
    #expect(!xml.contains("<script"))
}

@Test func feedSuppressesStaleNotesWhenAudioHashChanges() throws {
    let notes = DocumentShowNotes(summary: "Old summary.", links: [], chapters: [])
    var old = try episode(title: "O", notes: notes,
                          chapters: [AudioChapter(title: "Stale", startTime: 0, endTime: 1)]).0
    old.showNotesAudioHash = String(repeating: "9", count: 64) // stale hash vs real audio
    let xml = String(decoding: try RSS.render([old], settings: old.settings), as: UTF8.self)
    #expect(!xml.contains("Old summary."), "mismatched audio must not carry stale notes")
    #expect(!xml.contains("content:encoded"))
}

@Test func feedSanitizeKeepsSafeMarkupDropsUnsafe() throws {
    // Recovery path: retained description HTML is re-sanitized without fetching.
    let out = RecoveredShowNotes.sanitize("<p>ok</p><script>alert(1)</script><ul><li><a href=\"https://ok.example/x\">L</a> <a href=\"javascript:x()\">bad</a></li></ul>")
    #expect(out?.contains("ok") == true)
    #expect(out?.contains("script") != true)
    #expect(out?.contains("https://ok.example/x") == true)
    #expect(out?.contains("javascript") != true)
    #expect(RecoveredShowNotes.sanitize("<p>" + String(repeating: "x", count: 40 * 1024) + "</p>") == nil,
           "oversized retained notes are dropped")
}

@Test func storeSavePreservesShowNotesAcrossStaleSameAudioUpdate() throws {
    let db = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    let store = try NativeStore(url: db)
    let hash = String(repeating: "b", count: 64)
    let notes = DocumentShowNotes(summary: "S", links: [], chapters: [DocumentChapter(title: "C", blockIndex: 0)])
    var current = try store.episode(sourceKey: "src-k", settings: PrototypeProfile.fixture(
        at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)))
    current.audioHash = hash; current.showNotesAudioHash = hash
    current.showNotes = notes; current.chapters = [AudioChapter(title: "C", startTime: 0, endTime: 1)]
    try store.save(current)
    // A stale worker record missing notes must not erase the captured ones.
    var stale = current; stale.showNotes = nil; stale.chapters = nil; stale.showNotesAudioHash = nil
    try store.save(stale)
    let after = try #require(store.episodes().first { $0.id == current.id })
    #expect(after.showNotes?.summary == "S")
    #expect(after.chapters?.map { $0.title } == ["C"])
    // Different audio hash does not resurrect the old notes either.
    var regen = current; regen.showNotes = nil; regen.chapters = nil; regen.showNotesAudioHash = nil
    regen.audioHash = String(repeating: "c", count: 64)
    try store.save(regen)
    let changed = try #require(store.episodes().first { $0.id == current.id })
    #expect(changed.showNotes == nil)
}

private let remoteChannel = RemoteChannel(title: "Feed", description: "d", language: "en",
    feedURL: URL(string: "https://pod.example/feed.xml")!,
    audioBaseURL: URL(string: "https://pod.example/audio/")!)

/// Source-free recovery shape: locally captured notes/chapters gone, server
/// item's notes + encoded flag retained, bound to the current audio hash.
private func recoveredEpisode(from ep: Episode, item: ServerFeedItem) -> Episode {
    var r = ep
    r.showNotes = nil; r.chapters = nil; r.sourceName = nil
    r.sourceURL = item.source
    r.recoveredShowNotesHTML = item.showNotesHTML
    r.recoveredShowNotesHasEncoded = item.showNotesHasEncoded
    r.showNotesAudioHash = r.audioHash
    return r
}

@Test func recoveredGeneratedFeedRendersByteIdentical() throws {
    let notes = DocumentShowNotes(summary: "A gardener's <best> & \"finest\" notes.",
        links: [DocumentSourceLink(label: "Farmer's guide", url: URL(string: "https://ref.example/a?one=1&two=two#sec")!)],
        chapters: [DocumentChapter(title: "Section's One", blockIndex: 0)])
    var ep = try episode(title: "T", notes: notes,
                         chapters: [AudioChapter(title: "Section's One", startTime: 0, endTime: 2)]).0
    ep.showNotesAudioHash = ep.audioHash
    ep.delivery = DeliveryState(status: .uploaded, remotePath: "dav/files/user/Feed/audio/\(ep.id).m4a",
                               uploadedByteLength: ep.info?.byteLength)
    let first = try RSS.renderRemote([ep], channel: remoteChannel)
    let item = try #require(try ServerFeedParser.parse(first).first)
    #expect(item.showNotesHasEncoded)
    let second = try RSS.renderRemote([recoveredEpisode(from: ep, item: item)], channel: remoteChannel)
    #expect(second == first, "recovered rich feed must round-trip byte-identically")
}

@Test func recoveredLegacyDescriptionOnlyFeedStaysDescriptionOnly() throws {
    var ep = try episode(title: "T").0
    ep.recoveredShowNotesHTML = "<p>legacy notes &amp; stuff</p>"
    ep.recoveredShowNotesHasEncoded = false
    ep.showNotesAudioHash = ep.audioHash
    ep.delivery = DeliveryState(status: .uploaded, remotePath: "dav/files/user/Feed/audio/\(ep.id).m4a",
                               uploadedByteLength: ep.info?.byteLength)
    let first = try RSS.renderRemote([ep], channel: remoteChannel)
    let xml = String(decoding: first, as: UTF8.self)
    #expect(xml.contains("<description>"))
    #expect(!xml.contains("content:encoded"), "description-only legacy feed must not gain encoded")
    let item = try #require(try ServerFeedParser.parse(first).first)
    #expect(!item.showNotesHasEncoded)
    let second = try RSS.renderRemote([recoveredEpisode(from: ep, item: item)], channel: remoteChannel)
    #expect(second == first, "restart recovery must not rewrite a legacy feed")
}

@Test func namespaceImpostorEncodedIgnoredValidCDATAHonored() throws {
    let id = UUID().uuidString.lowercased()
    let make = { (body: String) -> Data in Data("""
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
    <item><guid>\(id)</guid><title>Ep</title>
    <enclosure url="https://pod.example/audio/\(id).m4a" type="audio/mp4" length="100"/>
    <pubDate>Tue, 01 Jan 2030 00:00:00 GMT</pubDate>
    <description>legacy notes</description>\(body)
    </item></channel></rss>
    """.utf8) }
    var items = try ServerFeedParser.parse(make("<encoded xmlns=\"http://impostor.example/\">FAKE</encoded>"))
    let impostor = try #require(items.first)
    #expect(!impostor.showNotesHasEncoded && impostor.showNotesHTML == "legacy notes",
            "impostor-namespaced encoded must be ignored")
    items = try ServerFeedParser.parse(make("<content:encoded><![CDATA[<p>rich notes</p>]]></content:encoded>"))
    let rich = try #require(items.first)
    #expect(rich.showNotesHasEncoded && rich.showNotesHTML == "<p>rich notes</p>",
            "valid content:encoded CDATA is retained")
}

@Test func unsafeOrMissingSourceKeepsRichNotesWithoutLink() throws {
    var ep = try episode(title: "T").0
    ep.recoveredShowNotesHTML = "<p>safe summary</p><ul><li><a href=\"https://ok.example/ref\">Ref</a></li></ul>"
    ep.recoveredShowNotesHasEncoded = true
    ep.showNotesAudioHash = ep.audioHash
    ep.delivery = DeliveryState(status: .uploaded, remotePath: "dav/files/user/Feed/audio/\(ep.id).m4a",
                               uploadedByteLength: ep.info?.byteLength)
    for unsafe in ["https://user:password@bad.example/x", "javascript:alert(1)", "file:///tmp/x"] {
        ep.sourceURL = URL(string: unsafe)
        let xml = String(decoding: try RSS.renderRemote([ep], channel: remoteChannel), as: UTF8.self)
        #expect(xml.contains("safe summary") && xml.contains("ok.example/ref"), "rich notes persist")
        #expect(!xml.contains("password") && !xml.contains("javascript") && !xml.contains("file://"),
                "unsafe source never reaches the feed")
        #expect(!xml.contains("<link>\(unsafe)"), "no source link for unsafe URL")
    }
    ep.sourceURL = nil
    let xml = String(decoding: try RSS.renderRemote([ep], channel: remoteChannel), as: UTF8.self)
    #expect(xml.contains("safe summary"))
}
