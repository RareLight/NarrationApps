import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum RSS {
    static func escaped(_ text: String) -> String {
        let valid = text.unicodeScalars.filter { s in
            let v = s.value
            return v == 9 || v == 10 || v == 13 || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
        }
        return String(String.UnicodeScalarView(valid)).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func render(_ episodes: [Episode], settings: PrototypeProfile) throws -> Data {
        try settings.validate()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\" xmlns:atom=\"http://www.w3.org/2005/Atom\"><channel>"
        xml += "<title>\(escaped(settings.channelTitle))</title><link>\(escaped(settings.feedURL.absoluteString))</link><description>\(escaped(settings.channelDescription))</description><language>\(escaped(settings.language))</language><itunes:block>yes</itunes:block>"
        xml += "<atom:link href=\"\(escaped(settings.feedURL.absoluteString))\" rel=\"self\" type=\"application/rss+xml\"/>"
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for e in episodes.sorted(by: { ($0.publicationDate ?? .distantPast, $0.id) > ($1.publicationDate ?? .distantPast, $1.id) }) {
            guard e.stage == .published, let when = e.publicationDate, let info = e.info, let hash = e.audioHash,
                  UUID(uuidString: e.id) != nil else { throw RelayError.artifact("Feed requires committed episode metadata.") }
            try e.settings.validate()
            guard e.settings.audio.isFileURL else { throw RelayError.artifact("Saved audio storage must be local.") }
            let path = e.settings.audio.appendingPathComponent(e.id + ".m4a")
            guard !Files.hasSymlink(path, below: e.settings.audio) else { throw RelayError.artifact("Saved audio path contains an unexpected link.") }
            guard try Files.hash(path, description: "saved audio referenced by the local feed") == hash, (try path.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(info.byteLength) else {
                throw RelayError.artifact("Published media is missing or changed; previous feed is preserved.")
            }
            let enclosure = e.settings.audioBaseURL.appendingPathComponent(e.id + ".m4a").absoluteString
            xml += "<item><title>\(escaped(e.title))</title><guid isPermaLink=\"false\">\(e.guid)</guid><pubDate>\(date.string(from: when))</pubDate><enclosure url=\"\(escaped(enclosure))\" length=\"\(info.byteLength)\" type=\"audio/mp4\"/><itunes:duration>\(Int(info.duration.rounded()))</itunes:duration></item>"
        }
        xml += "</channel></rss>\n"
        let data = Data(xml.utf8)
        guard XMLParser(data: data).parse() else { throw RelayError.artifact("Generated RSS is not valid XML.") }
        return data
    }
}
