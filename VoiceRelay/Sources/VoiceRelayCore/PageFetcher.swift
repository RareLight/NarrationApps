import Foundation
import CoreFoundation
import SwiftSoup

public enum SourceFetchError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL, invalidLimits, status(Int), unsupportedType, unsupportedEncoding, tooLarge, empty
    case redirectLimit, insecureRedirect, authentication, transportPolicy, timeout, network
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Choose an HTTP or HTTPS article URL without embedded credentials."
        case .invalidLimits: "Article fetch limits must be positive, at most 50 MB and 300 seconds, with at most 10 redirects."
        case .status(let code): "HTTP \(code): the server did not return an article. Review the source manually."
        case .unsupportedType: "This response is not HTML. PDF and other document types require separate support."
        case .unsupportedEncoding: "The HTML encoding is unsupported or invalid; source review is required."
        case .tooLarge: "Article response exceeds the configured byte limit."
        case .empty: "The server returned an empty article response."
        case .redirectLimit: "Article redirect limit exceeded."
        case .insecureRedirect: "An HTTPS article redirected to HTTP; the request was stopped."
        case .authentication: "The article requires authentication. This prototype does not use browser sessions."
        case .transportPolicy: "macOS transport security refused this source. Choose its HTTPS URL; the app keeps the system's transport protections."
        case .timeout: "Article fetch exceeded its deadline; retry the selected article."
        case .network: "Article fetch failed. Check connectivity and review the selected source."
        }
    }
}

public enum ArticleURL {
    @discardableResult public static func validate(_ url: URL) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.port == nil || (1...65535).contains(c.port!) else {
            throw SourceFetchError.invalidURL
        }
        return url
    }
}

public struct FetchLimits: Sendable {
    public let maximumBytes: Int
    public let timeout: TimeInterval
    public let maximumRedirects: Int
    public init(maximumBytes: Int = 10_000_000, timeout: TimeInterval = 30, maximumRedirects: Int = 5) throws {
        guard (1...50_000_000).contains(maximumBytes), timeout.isFinite, timeout > 0, timeout <= 300,
              (0...10).contains(maximumRedirects) else { throw SourceFetchError.invalidLimits }
        self.maximumBytes = maximumBytes; self.timeout = timeout; self.maximumRedirects = maximumRedirects
    }
}

public struct FetchedPage: Sendable {
    public let originalURL: URL
    public let finalURL: URL
    public let bytes: Data
    public let html: String
    public let contentType: String
    public let encoding: String
    public let fetchedAt: Date
    public let archivedCopy: ArchivedArticleCopy?
    public init(originalURL: URL, finalURL: URL, bytes: Data, html: String, contentType: String, encoding: String, fetchedAt: Date,
                archivedCopy: ArchivedArticleCopy? = nil) {
        self.originalURL = originalURL; self.finalURL = finalURL; self.bytes = bytes; self.html = html
        self.contentType = contentType; self.encoding = encoding; self.fetchedAt = fetchedAt
        self.archivedCopy = archivedCopy
    }
}

/// Fresh ephemeral session per selected fetch; stream bounds apply to decoded response bytes.
public struct PageFetcher: Sendable {
    public let limits: FetchLimits
    public init(limits: FetchLimits) { self.limits = limits }
    public func fetch(_ url: URL) async throws -> FetchedPage {
        try await fetch(url, configuration: .ephemeral)
    }
    func fetch(_ url: URL, configuration: URLSessionConfiguration,
               acceptedTypes: Set<String> = ["text/html", "application/xhtml+xml"],
               allowedHosts: Set<String>? = nil) async throws -> FetchedPage {
        try ArticleURL.validate(url); try Task.checkCancellation()
        if let allowedHosts, !allowedHosts.contains(url.host?.lowercased() ?? "") || url.scheme != "https" || (url.port != nil && url.port != 443) {
            throw SourceFetchError.invalidURL
        }
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = limits.timeout; configuration.timeoutIntervalForResource = limits.timeout
        let redirects = FetchRedirects(maximum: limits.maximumRedirects, allowedHosts: allowedHosts)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: FetchedPage.self) { group in
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.setValue(acceptedTypes.sorted().joined(separator: ", "), forHTTPHeaderField: "Accept")
                        request.setValue("VoiceRelayPrototype/1.0", forHTTPHeaderField: "User-Agent")
                        let (stream, response) = try await session.bytes(for: request, delegate: redirects)
                        if let failure = redirects.failure { throw failure }
                        guard let response = response as? HTTPURLResponse, let final = response.url else { throw SourceFetchError.network }
                        try ArticleURL.validate(final)
                        if let allowedHosts, !allowedHosts.contains(final.host?.lowercased() ?? "") { throw SourceFetchError.invalidURL }
                        guard (200...299).contains(response.statusCode) else { throw SourceFetchError.status(response.statusCode) }
                        let type = response.mimeType?.lowercased() ?? ""
                        guard acceptedTypes.contains(type) else { throw SourceFetchError.unsupportedType }
                        guard response.expectedContentLength <= Int64(limits.maximumBytes) else { throw SourceFetchError.tooLarge }
                        var bytes = Data(); bytes.reserveCapacity(min(limits.maximumBytes, 65_536))
                        for try await byte in stream {
                            guard bytes.count < limits.maximumBytes else { throw SourceFetchError.tooLarge }
                            bytes.append(byte)
                            if bytes.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
                        }
                        try Task.checkCancellation()
                        guard !bytes.isEmpty else { throw SourceFetchError.empty }
                        let decoded = try Self.decode(bytes, declared: response.textEncodingName)
                        return FetchedPage(originalURL: url, finalURL: final, bytes: bytes, html: decoded.text,
                                           contentType: type, encoding: decoded.encoding, fetchedAt: Date())
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(limits.timeout))
                        redirects.recordFailure(.timeout)
                        session.invalidateAndCancel()
                        throw SourceFetchError.timeout
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { session.invalidateAndCancel() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure = redirects.failure { throw failure }
            if let error = error as? SourceFetchError { throw error }
            if (error as? URLError)?.code == .timedOut { throw SourceFetchError.timeout }
            if (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection { throw SourceFetchError.transportPolicy }
            throw SourceFetchError.network
        }
    }
    static func decode(_ data: Data, declared: String?) throws -> (text: String, encoding: String) {
        for (bom, encoding, label): ([UInt8], String.Encoding, String) in [
            ([0xEF, 0xBB, 0xBF], .utf8, "utf-8"), ([0xFF, 0xFE], .utf16LittleEndian, "utf-16le"), ([0xFE, 0xFF], .utf16BigEndian, "utf-16be")
        ] where data.starts(with: bom) {
            guard let text = String(data: data.dropFirst(bom.count), encoding: encoding) else { throw SourceFetchError.unsupportedEncoding }
            return (text, label)
        }
        var name = declared
        if name == nil, let prefix = String(data: data.prefix(8192), encoding: .isoLatin1) {
            let document = try SwiftSoup.parse(prefix)
            name = try document.select("meta[charset]").first()?.attr("charset")
            if name == nil, let content = try document.select("meta[http-equiv]").first(where: { (try? $0.attr("http-equiv").lowercased()) == "content-type" })?.attr("content"),
               let range = content.range(of: "charset=", options: .caseInsensitive) {
                name = String(content[range.upperBound...]).split(separator: ";").first.map(String.init)
            }
        }
        let label = name?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() ?? "utf-8"
        let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard cf != kCFStringEncodingInvalidId,
              let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) else {
            throw SourceFetchError.unsupportedEncoding
        }
        return (text, label)
    }
}

final class FetchRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private let allowedHosts: Set<String>?
    private var count = 0
    private var storedFailure: SourceFetchError?
    var failure: SourceFetchError? { lock.withLock { storedFailure } }
    init(maximum: Int, allowedHosts: Set<String>? = nil) { self.maximum = maximum; self.allowedHosts = allowedHosts }
    func recordFailure(_ error: SourceFetchError) { lock.withLock { storedFailure = error } }
    func redirected(from: URL, to: URL) -> SourceFetchError? {
        lock.withLock {
            count += 1
            let error: SourceFetchError?
            if (try? ArticleURL.validate(to)) == nil { error = .invalidURL }
            else if let allowedHosts, !allowedHosts.contains(to.host?.lowercased() ?? "") || to.scheme != "https" || (to.port != nil && to.port != 443) { error = .invalidURL }
            else if from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "http" { error = .insecureRedirect }
            else if count > maximum { error = .redirectLimit }
            else { error = nil }
            if let error { storedFailure = error }
            return error
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url, redirected(from: from, to: to) == nil else {
            completionHandler(nil); return
        }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            lock.withLock { storedFailure = .authentication }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
