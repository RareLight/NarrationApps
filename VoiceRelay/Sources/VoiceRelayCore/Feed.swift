import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum RSS {
    static func renderReconciledRemote(_ episodes: [Episode], channel: RemoteChannel, preserved: [String]) throws -> Data {
        let normal = try renderRemote(episodes, channel: channel)
        guard !preserved.isEmpty else { return normal }
        let suffix = "</channel></rss>\n"
        var text = String(decoding: normal, as: UTF8.self)
        guard text.hasSuffix(suffix) else { throw ServerFeedParser.failure }
        text.removeLast(suffix.count)
        let result = Data((text + preserved.joined() + suffix).utf8)
        guard result.count <= 4 * 1024 * 1024, XMLParser(data: result).parse() else { throw ServerFeedParser.failure }
        return result
    }
    static func escaped(_ text: String) -> String {
        let valid = text.unicodeScalars.filter { s in
            let v = s.value
            return v == 9 || v == 10 || v == 13 || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
        }
        return String(String.UnicodeScalarView(valid)).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private static func artwork(_ url: URL?) -> String {
        guard let url, url.scheme?.lowercased() == "https", (try? ArticleURL.validate(url)) != nil else { return "" }
        return "<itunes:image href=\"\(escaped(url.absoluteString))\"/>"
    }
    static func render(_ episodes: [Episode], settings: PrototypeProfile) throws -> Data {
        try settings.validate()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\" xmlns:atom=\"http://www.w3.org/2005/Atom\"><channel>"
        xml += "<title>\(escaped(settings.channelTitle))</title><link>\(escaped(settings.feedURL.absoluteString))</link><description>\(escaped(settings.channelDescription))</description><language>\(escaped(settings.language))</language><itunes:block>yes</itunes:block>"
        xml += "<atom:link href=\"\(escaped(settings.feedURL.absoluteString))\" rel=\"self\" type=\"application/rss+xml\"/>"
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for e in episodes.sorted(by: { ($0.podcastDate ?? .distantPast, $0.id) > ($1.podcastDate ?? .distantPast, $1.id) }) {
            guard e.stage == .published, e.publicationDate != nil, let when = e.podcastDate, let info = e.info, let hash = e.audioHash,
                  UUID(uuidString: e.id) != nil else { throw RelayError.artifact("Feed requires committed episode metadata.") }
            try e.settings.validate()
            guard e.settings.audio.isFileURL else { throw RelayError.artifact("Saved audio storage must be local.") }
            let path = e.settings.audio.appendingPathComponent(e.id + ".m4a")
            // App feeds are metadata inventories, never a locally hosted audio service.
            // Temporary copies may be released after upload or evicted by macOS.
            if e.settings.temporaryAudio != true && e.localAudioReleased != true {
                guard !Files.hasSymlink(path, below: e.settings.audio) else { throw RelayError.artifact("Saved audio path contains an unexpected link.") }
                guard try Files.hash(path, description: "saved audio referenced by the local feed") == hash, (try path.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(info.byteLength) else {
                    throw RelayError.artifact("Published media is missing or changed; previous feed is preserved.")
                }
            }
            let enclosure = e.settings.audioBaseURL.appendingPathComponent(e.id + ".m4a").absoluteString
            xml += "<item><title>\(escaped(e.title))</title><guid isPermaLink=\"false\">\(e.guid)</guid><pubDate>\(date.string(from: when))</pubDate><enclosure url=\"\(escaped(enclosure))\" length=\"\(info.byteLength)\" type=\"audio/mp4\"/><itunes:duration>\(Int(info.duration.rounded()))</itunes:duration>\(artwork(e.artworkURL))</item>"
        }
        xml += "</channel></rss>\n"
        let data = Data(xml.utf8)
        guard XMLParser(data: data).parse() else { throw RelayError.artifact("Generated RSS is not valid XML.") }
        return data
    }
    /// Remote feed lists byte-confirmed uploads only: published items still pending or
    /// failed are absent until their remote copy is confirmed, so one stuck item never
    /// blocks feed updates. An uploaded record that is internally inconsistent
    /// indicates corruption and fails the render instead.
    static func renderRemote(_ episodes: [Episode], channel: RemoteChannel) throws -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\" xmlns:atom=\"http://www.w3.org/2005/Atom\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:vr=\"\(ServerRecoveryIdentity.namespace)\"><channel>"
        xml += "<title>\(escaped(channel.title))</title><link>\(escaped(channel.feedURL.absoluteString))</link><description>\(escaped(channel.description))</description><language>\(escaped(channel.language))</language><itunes:block>yes</itunes:block>"
        xml += "<atom:link href=\"\(escaped(channel.feedURL.absoluteString))\" rel=\"self\" type=\"application/rss+xml\"/>"
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        xml += artwork(channel.coverArtworkURL)
        if let url = channel.rssArtworkURL {
            xml += "<image><url>\(escaped(url.absoluteString))</url><title>\(escaped(channel.title))</title><link>\(escaped(channel.feedURL.absoluteString))</link><width>144</width><height>144</height></image>"
        }
        for e in episodes.sorted(by: { ($0.podcastDate ?? .distantPast, $0.id) > ($1.podcastDate ?? .distantPast, $1.id) }) {
            guard e.stage == .published, let delivery = e.delivery, delivery.status == .uploaded else { continue }
            guard e.publicationDate != nil, let when = e.podcastDate, let info = e.info, e.audioHash != nil,
                  UUID(uuidString: e.id) != nil, !delivery.remotePath.isEmpty,
                  delivery.uploadedByteLength == info.byteLength else {
                throw RelayError.artifact("A remotely confirmed item has an inconsistent upload record; the previous remote feed is preserved.")
            }
            let enclosure = channel.audioBaseURL.appendingPathComponent(e.id + ".m4a").absoluteString
            var item = "<item><title>\(escaped(e.title))</title><guid isPermaLink=\"false\">\(e.guid)</guid>"
            if let source = e.sourceURL { item += "<link>\(escaped(source.absoluteString))</link>" }
            if let creator = e.author ?? e.sourceHost { item += "<dc:creator>\(escaped(creator))</dc:creator>" }
            item += "<pubDate>\(date.string(from: when))</pubDate><enclosure url=\"\(escaped(enclosure))\" length=\"\(info.byteLength)\" type=\"audio/mp4\"/><itunes:duration>\(Int(info.duration.rounded()))</itunes:duration>\(artwork(e.artworkURL))</item>"
            if let hash = e.audioHash, ServerRecoveryIdentity.validHash(hash) {
                var identity = "<vr:identity sha256=\"\(hash)\""
                if let voice = e.settings.voice { identity += " voice=\"\(escaped(voice))\"" }
                identity += " speed=\"\(e.settings.backendSettings["speed"]?.numericValue ?? 1)\""
                if let key = e.originalSourceIdentity, ServerRecoveryIdentity.validSource(key) { identity += " source=\"\(key)\"" }
                if let published = e.publicationDate { identity += " publishedAt=\"\(published.formatted(.iso8601))\"" }
                if let saved = e.readingListSavedAt { identity += " savedAt=\"\(saved.formatted(.iso8601))\"" }
                if let origin = e.originalSourceHost { identity += " origin=\"\(escaped(origin))\"" }
                item = item.replacingOccurrences(of: "</item>", with: identity + "/></item>")
            }
            xml += item
        }
        xml += "</channel></rss>\n"
        let data = Data(xml.utf8)
        guard XMLParser(data: data).parse() else { throw RelayError.artifact("Generated RSS is not valid XML.") }
        return data
    }
}

/// Channel identity for the remote feed; endpoints come from validated delivery settings.
struct RemoteChannel: Sendable, Equatable {
    let title: String
    let description: String
    let language: String
    let feedURL: URL
    let audioBaseURL: URL
    let coverArtworkURL: URL?
    let rssArtworkURL: URL?
    init(settings: DeliverySettings, previousFeed: Data? = nil) throws {
        guard let feedURL = settings.publicFeedURL, let audioBaseURL = settings.publicAudioBaseURL else {
            throw RelayError.setup("Remote feed requires configured public URLs.")
        }
        if let digest = settings.podcastCoverDigest {
            _ = try AudioCoverReference.validate(digest)
            self.coverArtworkURL = settings.publicFolderURL?.appendingPathComponent("artwork-" + digest + ".jpg")
            self.rssArtworkURL = settings.publicFolderURL?.appendingPathComponent("artwork-" + digest + "-rss.jpg")
        } else if settings.podcastCoverConfigured != true, let previousFeed {
            self.coverArtworkURL = try ServerFeedSnapshot.channelArtwork(in: previousFeed); self.rssArtworkURL = nil
        } else { self.coverArtworkURL = nil; self.rssArtworkURL = nil }
        self.title = settings.channelTitle; self.description = settings.channelDescription
        self.language = settings.language; self.feedURL = feedURL; self.audioBaseURL = audioBaseURL
    }
    init(title: String, description: String, language: String, feedURL: URL, audioBaseURL: URL) {
        self.coverArtworkURL = nil; self.rssArtworkURL = nil
        self.title = title; self.description = description; self.language = language
        self.feedURL = feedURL; self.audioBaseURL = audioBaseURL
    }
}

private enum AudioCoverReference {
    static func validate(_ digest: String) throws {
        guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RelayError.setup("The podcast cover reference is invalid. Replace or remove it.") }
    }
}
