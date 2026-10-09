import Foundation
import SwiftSoup

public enum ArticleArchive: String, Codable, Sendable, CaseIterable {
    case archiveToday, wayback
    public var label: String { self == .archiveToday ? "Archive.ph" : "Wayback Machine" }
    var hosts: Set<String> {
        self == .archiveToday
            ? ["archive.ph", "archive.today", "archive.is", "archive.li", "archive.md", "archive.vn", "archive.fo"]
            : ["archive.org", "web.archive.org"]
    }
}

/// Private snapshot provenance; never added to RSS or diagnostic URLs.
public struct ArchivedArticleCopy: Codable, Sendable, Equatable {
    public let provider: ArticleArchive
    public let snapshotURL: URL
    public let capturedAt: Date
}

public enum ArticleRecoveryError: Error, LocalizedError, Sendable {
    case unavailable(SourceFetchError)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let original): "\(original.localizedDescription) No readable archived copy was found."
        }
    }
}

/// Original first, then existing public captures. No capture submission, browser
/// session, JavaScript execution or CAPTCHA handling. Off unless explicitly enabled.
public struct ArticleSourceLoader: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> FetchedPage
    public typealias ArchiveFetch = @Sendable (URL, FetchLimits, Set<String>, Set<String>) async throws -> FetchedPage
    public let limits: FetchLimits
    public let useArchives: Bool
    private let fetch: Fetch?
    private let archiveFetch: ArchiveFetch?
    private let debugLog: DeliveryDebugLog?
    public init(limits: FetchLimits, useArchives: Bool = false, fetch: Fetch? = nil, archiveFetch: ArchiveFetch? = nil,
                debugLog: DeliveryDebugLog? = nil) {
        self.limits = limits; self.useArchives = useArchives; self.fetch = fetch; self.archiveFetch = archiveFetch
        self.debugLog = debugLog
    }
    public func load(_ url: URL, savedAt: Date? = nil, chunkLimit: Int) async throws -> ReviewedSource {
        try ArticleURL.validate(url); try Task.checkCancellation()
        var original: ReviewedSource?
        var failure: SourceFetchError?
        do {
            let page: FetchedPage
            if let fetch { page = try await fetch(url) }
            else { page = try await PageFetcher(limits: limits).fetch(url) }
            guard page.originalURL == url, page.bytes.count <= limits.maximumBytes else {
                throw RelayError.setup("The fetched article does not match the selected Reading List entry or exceeds its size limit.")
            }
            original = try await review(page, chunkLimit: chunkLimit)
            if let original, original.issue == nil { return original }
        } catch {
            try Task.checkCancellation()
            guard let error = error as? SourceFetchError, Self.recoverable(error) else { throw error }
            failure = error
        }
        guard useArchives, let lookup = Self.lookupURL(url) else {
            if useArchives { debugLog?.record(.articleArchiveSkipped) }
            if let original { return original }
            throw failure ?? .network
        }
        // At most one lookup + one HTML fetch per provider, each <= 10 seconds.
        for provider in ArticleArchive.allCases {
            try Task.checkCancellation()
            debugLog?.record(.articleArchive(provider, .lookup))
            do {
                let indexLimits = try FetchLimits(maximumBytes: min(limits.maximumBytes, 512_000), timeout: min(limits.timeout, 10), maximumRedirects: 3)
                let indexURL = try Self.indexURL(lookup, provider: provider, savedAt: savedAt)
                let types: Set<String> = provider == .archiveToday ? ["application/link-format", "text/plain"] : ["application/json"]
                let index = try await request(indexURL, limits: indexLimits, types: types, hosts: provider.hosts)
                let copy = try Self.capture(index.html, provider: provider, original: lookup, savedAt: savedAt)
                guard let copy else { debugLog?.record(.articleArchive(provider, .unavailable)); continue }
                let pageLimits = try FetchLimits(maximumBytes: limits.maximumBytes, timeout: min(limits.timeout, 10), maximumRedirects: 3)
                let response = try await request(copy.snapshotURL, limits: pageLimits, types: ["text/html", "application/xhtml+xml"], hosts: provider.hosts)
                guard Self.snapshotURL(response.finalURL, provider: provider, original: lookup) != nil else {
                    debugLog?.record(.articleArchive(provider, .unavailable)); continue
                }
                let page = FetchedPage(originalURL: url, finalURL: response.finalURL, bytes: response.bytes,
                    html: try Self.articleHTML(response.html, provider: provider), contentType: response.contentType,
                    encoding: response.encoding, fetchedAt: response.fetchedAt, archivedCopy: copy)
                let recovered = try await review(page, chunkLimit: chunkLimit)
                if recovered.issue == nil { debugLog?.record(.articleArchive(provider, .recovered)); return recovered }
                debugLog?.record(.articleArchive(provider, .unavailable))
            } catch {
                try Task.checkCancellation() // cancellation never starts another provider
                if error is CancellationError { throw error }
                debugLog?.record(.articleArchive(provider, .unavailable))
            }
        }
        if let original {
            return ReviewedSource(page: original.page, document: original.document, narration: original.narration,
                                  issue: original.issue, archiveRecoveryFailed: true)
        }
        throw ArticleRecoveryError.unavailable(failure ?? .network)
    }
    private func review(_ page: FetchedPage, chunkLimit: Int) async throws -> ReviewedSource {
        let work = Task.detached { try Task.checkCancellation(); return try ReviewedSource.prepare(page, chunkLimit: chunkLimit) }
        let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return result
    }
    private func request(_ url: URL, limits: FetchLimits, types: Set<String>, hosts: Set<String>) async throws -> FetchedPage {
        let page: FetchedPage
        if let archiveFetch { page = try await archiveFetch(url, limits, types, hosts) }
        else { page = try await PageFetcher(limits: limits).fetch(url, configuration: .ephemeral, acceptedTypes: types, allowedHosts: hosts) }
        guard page.bytes.count <= limits.maximumBytes, types.contains(page.contentType),
              page.finalURL.scheme == "https", page.finalURL.user == nil, page.finalURL.password == nil,
              page.finalURL.port == nil || page.finalURL.port == 443,
              hosts.contains(page.finalURL.host?.lowercased() ?? "") else { throw SourceFetchError.invalidURL }
        return page
    }
    private static func recoverable(_ error: SourceFetchError) -> Bool {
        switch error {
        case .status(let status): (400...599).contains(status)
        case .authentication, .empty, .network, .timeout, .unsupportedEncoding, .redirectLimit, .insecureRedirect, .transportPolicy: true
        default: false
        }
    }
    /// Remove known tracking parameters; never disclose other queries or local URLs.
    static func lookupURL(_ url: URL) -> URL? {
        guard (try? ArticleURL.validate(url)) != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), host.contains("."),
              !host.contains(":"), host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
              !["localhost", "local", "internal", "lan", "ts.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              parts.port == nil || parts.port == (parts.scheme == "https" ? 443 : 80),
              url.absoluteString.utf8.count <= 4096 else { return nil }
        if parts.query != nil {
            guard let items = parts.queryItems, items.allSatisfy({
                let key = $0.name.lowercased()
                return key.hasPrefix("utm_") || ["fbclid", "gclid", "mc_cid", "mc_eid"].contains(key)
            }) else { return nil }
            parts.query = nil
        }
        parts.fragment = nil
        return parts.url
    }
    static func indexURL(_ url: URL, provider: ArticleArchive, savedAt: Date?) throws -> URL {
        if provider == .archiveToday {
            return try requireURL("https://archive.ph/timemap/" + url.absoluteString)
        }
        var parts = URLComponents(string: "https://archive.org/wayback/available")!
        parts.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let savedAt { parts.queryItems?.append(URLQueryItem(name: "timestamp", value: dateFormatter("yyyyMMddHHmmss").string(from: savedAt))) }
        guard let result = parts.url else { throw SourceFetchError.invalidURL }
        return result
    }
    static func capture(_ body: String, provider: ArticleArchive, original: URL, savedAt: Date?) throws -> ArchivedArticleCopy? {
        if provider == .wayback {
            struct Response: Decodable {
                struct Snapshot: Decodable { let available: Bool; let status: String; let url: URL; let timestamp: String }
                struct Snapshots: Decodable { let closest: Snapshot? }
                let archived_snapshots: Snapshots
            }
            let result = try JSONDecoder().decode(Response.self, from: Data(body.utf8)).archived_snapshots.closest
            guard let result, result.available, result.status == "200", result.timestamp.count == 14,
                  let date = dateFormatter("yyyyMMddHHmmss").date(from: result.timestamp),
                  let url = snapshotURL(result.url, provider: provider, original: original) else { return nil }
            // Raw replay omits the archive toolbar and rewritten media URLs.
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            guard parts.path.hasPrefix("/web/" + result.timestamp + "/") || parts.path.hasPrefix("/web/" + result.timestamp + "id_/") else { return nil }
            parts.percentEncodedPath = parts.percentEncodedPath.replacingOccurrences(of: "/web/" + result.timestamp + "/", with: "/web/" + result.timestamp + "id_/")
            guard let replay = parts.url else { return nil }
            return ArchivedArticleCopy(provider: provider, snapshotURL: replay, capturedAt: date)
        }
        // RFC 7089 TimeMaps use Link format; dates contain commas, so split at
        // bracketed links rather than naively splitting on every comma.
        let pattern = try NSRegularExpression(pattern: "<([^<>]+)>((?:[^<>])*)")
        let ns = body as NSString
        let links = pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).prefix(2000).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
        func attribute(_ name: String, _ value: String) -> String? {
            let regex = try? NSRegularExpression(pattern: ";\\s*" + name + "\\s*=\\s*\"([^\"]*)\"", options: .caseInsensitive)
            guard let match = regex?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
        let originals = links.filter { attribute("rel", $0.1)?.split(separator: " ").contains("original") == true }
        guard originals.count == 1, let address = URL(string: originals[0].0), sameArticle(address, original) else { return nil }
        let copies = links.compactMap { address, attributes -> ArchivedArticleCopy? in
            guard attribute("rel", attributes)?.split(separator: " ").contains("memento") == true,
                  let raw = URL(string: address), let url = snapshotURL(raw, provider: provider, original: original),
                  let value = attribute("datetime", attributes), let date = dateFormatter("EEE, dd MMM yyyy HH:mm:ss zzz").date(from: value) else { return nil }
            return ArchivedArticleCopy(provider: provider, snapshotURL: url, capturedAt: date)
        }
        return copies.sorted {
            if let savedAt {
                let a = abs($0.capturedAt.timeIntervalSince(savedAt)), b = abs($1.capturedAt.timeIntervalSince(savedAt))
                if a != b { return a < b }
            }
            return $0.capturedAt > $1.capturedAt
        }.first
    }
    static func snapshotURL(_ url: URL, provider: ArticleArchive, original: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme ?? ""), let host = parts.host?.lowercased(), provider.hosts.contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 80 || parts.port == 443 else { return nil }
        if provider == .archiveToday {
            if parts.path.range(of: "^/[A-Za-z0-9]{5}$", options: .regularExpression) == nil {
                let path = String(parts.path.dropFirst())
                guard let slash = path.firstIndex(of: "/"), String(path[..<slash]).range(of: "^[0-9]{14}$", options: .regularExpression) != nil,
                      let embedded = URL(string: String(path[path.index(after: slash)...])), sameArticle(embedded, original) else { return nil }
            }
        } else {
            guard host == "web.archive.org", parts.path.hasPrefix("/web/") else { return nil }
            let path = String(parts.path.dropFirst(5))
            guard let slash = path.firstIndex(of: "/"), String(path[..<slash]).range(of: "^[0-9]{14}(id_)?$", options: .regularExpression) != nil,
                  let embedded = URL(string: String(path[path.index(after: slash)...])), sameArticle(embedded, original) else { return nil }
        }
        parts.scheme = "https"; parts.port = nil
        return parts.url
    }
    private static func sameArticle(_ lhs: URL, _ rhs: URL) -> Bool {
        guard (try? ArticleURL.validate(lhs)) != nil else { return false }
        func host(_ url: URL) -> String { let h = url.host?.lowercased() ?? ""; return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        return host(lhs) == host(rhs) && (lhs.path.isEmpty ? "/" : lhs.path) == (rhs.path.isEmpty ? "/" : rhs.path) && lhs.query == rhs.query
            && (lhs.port == nil || lhs.port == 80 || lhs.port == 443)
    }
    private static func articleHTML(_ html: String, provider: ArticleArchive) throws -> String {
        guard provider == .archiveToday else { return html }
        let dom = try SwiftSoup.parse(html)
        if try dom.select("#CONTENT").first() != nil { try dom.select("#HEADER, #FOOTER").remove() }
        return try dom.outerHtml()
    }
    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format; formatter.isLenient = false
        return formatter
    }
    private static func requireURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw SourceFetchError.invalidURL }; return url
    }
}
