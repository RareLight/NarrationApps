import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(Security)
import Security
import LocalAuthentication
#endif

/// Folder input policy built on Foundation's URL parser and percent-encoding.
/// This is deliberately restricted to HTTPS delivery folders, not a general URL parser.
public enum DeliveryURL {
    public static func folder(_ input: String, label: String = "Folder URL") throws -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        func invalid(_ reason: String) -> RelayError { .setup("\(label): \(reason)") }
        guard !text.contains("\\"), !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw invalid("remove backslashes or line breaks from the address.")
        }
        if text.hasPrefix("//") { text = "https:" + text }
        else if !text.contains("://") { text = "https://" + text }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = c.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }), c.url != nil else {
            throw invalid("enter a website address such as https://example.com/podcast.")
        }
        guard c.user == nil, c.password == nil else {
            throw invalid("enter the username and password in their separate fields.")
        }
        guard c.query == nil || c.query == "" else {
            throw invalid("use the folder address without a query after ?.")
        }
        guard c.port == nil || (1...65535).contains(c.port!) else {
            throw invalid("use a port between 1 and 65535.")
        }
        c.scheme = "https"; c.host = host.lowercased()
        if c.port == 443 || (scheme == "http" && c.port == 80) { c.port = nil }
        c.query = nil; c.fragment = nil
        var segments: [String] = []
        for raw in c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = String(raw).removingPercentEncoding,
                  !segment.contains("/"), !segment.contains("\\"),
                  !segment.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw invalid("a folder name contains an encoded separator or line break.")
            }
            if segment == "." { continue }
            if segment == ".." { if !segments.isEmpty { segments.removeLast() }; continue }
            segments.append(segment)
        }
        // Accept a pasted subscription URL as well as its containing folder.
        if segments.last?.lowercased() == "feed.xml" { segments.removeLast() }
        c.path = "/" + segments.joined(separator: "/") + (segments.isEmpty ? "" : "/")
        guard let url = c.url else { throw invalid("the address could not be read.") }
        return url
    }
}

/// User-configured private podcast delivery. Secrets never appear here; only the username
/// and HTTPS folders persist. Passwords live behind the injected credential store.
public struct DeliverySettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var feedFolderURL: URL?
    public var publicFolderURL: URL?
    public var username: String?
    public var channelTitle = "VoiceRelay"
    public var channelDescription = "Personal narrated articles"
    public var language = "en"
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, feedFolderURL, publicFolderURL, username, channelTitle, channelDescription, language
        // Read old settings once; independent audio folders are intentionally retired.
        case webdavURL, remoteFolder, publicFeedURL
    }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try v.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        feedFolderURL = try v.decodeIfPresent(URL.self, forKey: .feedFolderURL)
        if feedFolderURL == nil, let base = try v.decodeIfPresent(URL.self, forKey: .webdavURL) {
            let folder = try v.decodeIfPresent(String.self, forKey: .remoteFolder) ?? ""
            let text = folder.contains("://") ? folder : base.absoluteString + (base.absoluteString.hasSuffix("/") ? "" : "/") + folder
            feedFolderURL = try DeliveryURL.folder(text, label: "Feed folder")
        }
        publicFolderURL = try v.decodeIfPresent(URL.self, forKey: .publicFolderURL)
        if publicFolderURL == nil, let feed = try v.decodeIfPresent(URL.self, forKey: .publicFeedURL) {
            publicFolderURL = try DeliveryURL.folder(feed.deletingLastPathComponent().absoluteString, label: "Public folder")
        }
        username = try v.decodeIfPresent(String.self, forKey: .username)
        channelTitle = try v.decodeIfPresent(String.self, forKey: .channelTitle) ?? "VoiceRelay"
        channelDescription = try v.decodeIfPresent(String.self, forKey: .channelDescription) ?? "Personal narrated articles"
        language = try v.decodeIfPresent(String.self, forKey: .language) ?? "en"
    }
    public func encode(to encoder: any Encoder) throws {
        let s = try normalized()
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(s.enabled, forKey: .enabled)
        try v.encodeIfPresent(s.feedFolderURL, forKey: .feedFolderURL)
        try v.encodeIfPresent(s.publicFolderURL, forKey: .publicFolderURL)
        try v.encodeIfPresent(s.username, forKey: .username)
        try v.encode(s.channelTitle, forKey: .channelTitle)
        try v.encode(s.channelDescription, forKey: .channelDescription)
        try v.encode(s.language, forKey: .language)
    }
    public func normalized() throws -> Self {
        var s = self
        s.feedFolderURL = try feedFolderURL.flatMap { try DeliveryURL.folder($0.absoluteString, label: "Feed folder") }
        s.publicFolderURL = try publicFolderURL.flatMap { try DeliveryURL.folder($0.absoluteString, label: "Public folder") }
        return s
    }
    static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }
    /// Internal paths are decoded names relative to the server origin. URLComponents
    /// encodes them once when constructing requests; user input never enters here directly.
    static func pathSegments(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw RelayError.setup("A saved delivery path is invalid. Choose the feed folder again.")
        }
        return segments
    }
    public var credentialUsername: String { username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    public var credentialHost: String { feedFolderURL?.host?.lowercased() ?? "" }
    public var publicFeedURL: URL? { publicFolderURL.flatMap { try? DeliveryURL.folder($0.absoluteString) }?.appendingPathComponent("feed.xml") }
    public var publicAudioBaseURL: URL? { publicFolderURL.flatMap { try? DeliveryURL.folder($0.absoluteString) }?.appendingPathComponent("audio", isDirectory: true) }
    var remoteFolder: String { feedFolderURL.flatMap { try? DeliveryURL.folder($0.absoluteString) }?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "" }
    var mediaFolder: String { Self.join(remoteFolder, "audio") }
    var remoteFeedPath: String { Self.join(remoteFolder, "feed.xml") }
    func remoteMediaPath(_ id: String) -> String { Self.join(mediaFolder, id + ".m4a") }
    public func validate() throws {
        let s = try normalized()
        if let username {
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !credentialUsername.contains(":"), !credentialUsername.contains(where: { $0.isNewline }) else {
                throw RelayError.setup("The delivery username must be nonblank and contain no colons or line breaks; leave it empty for password-only authentication.")
            }
        }
        if enabled, s.feedFolderURL == nil || s.publicFolderURL == nil {
            throw RelayError.setup("Delivery requires a Feed folder URL and a Public folder URL.")
        }
    }
    public func settingsHash() throws -> String { Files.hash(try Files.json(self)) }
    /// Feed identity excludes switches and credentials that do not alter publication.
    public func publicationHash() throws -> String {
        let settings = try normalized(), channel = try RemoteChannel(settings: settings)
        return Files.hash(try Files.json([settings.feedFolderURL?.absoluteString ?? "",
            channel.feedURL.absoluteString, channel.audioBaseURL.absoluteString,
            channel.title, channel.description, channel.language]))
    }
}

/// Errors are grouped by retry posture, never by raw server text.
public enum DeliveryError: Error, LocalizedError, Sendable, Equatable {
    case authFailed(String), permissionDenied(String), credentialUnavailable(String), retryable(String), fatal(String)
    public var errorDescription: String? {
        switch self { case .authFailed(let m), .permissionDenied(let m), .credentialUnavailable(let m), .retryable(let m), .fatal(let m): m }
    }
    static let authNotice = "Delivery credentials need attention."
    static let permissionNotice = "The server denied access (HTTP 403). Check the upload folder and account permissions."
    static let credentialNotice = "The saved delivery password could not be accessed in Keychain. Check Keychain access and try again."
    static let verificationNotice = "The remote copy size could not be confirmed; the upload is treated as unfinished."
    static func classify(_ status: Int) -> DeliveryError {
        switch status {
        case 412: .retryable("The server copy changed during publishing; reconciliation will retry automatically.")
        case 401: .authFailed("Delivery credentials were rejected (HTTP 401).")
        case 403: .permissionDenied(permissionNotice)
        case 500...599: .retryable("The delivery endpoint is unavailable (HTTP \(status)). Upload retries automatically.")
        case 300...399: .fatal("The delivery endpoint answered with a redirect (HTTP \(status)); redirects are refused.")
        default: .fatal("The delivery endpoint refused the request (HTTP \(status)).")
        }
    }
}

public protocol DeliveryCredentialStore: Sendable {
    func readPassword(username: String, host: String) throws -> String?
    func writePassword(_ password: String, username: String, host: String) throws
    func deletePassword(username: String, host: String) throws
    /// Presence check that must not decrypt the item — a decrypting read can trigger a
    /// Keychain consent prompt, so status UI uses this instead of readPassword.
    func hasPassword(username: String, host: String) throws -> Bool
}

public extension DeliveryCredentialStore {
    func hasPassword(username: String, host: String) throws -> Bool {
        try readPassword(username: username, host: host)?.isEmpty == false
    }
}

/// One credential session shared by every app operation. UI presence checks never touch
/// Keychain; reads (including failures) are serialized and remembered until Quit.
public final class SessionDeliveryCredentialStore: DeliveryCredentialStore, @unchecked Sendable {
    public enum Presence: Sendable, Equatable { case unchecked, stored, missing, unavailable }
    private struct Identity: Hashable {
        let username: String, host: String
        init(_ username: String, _ host: String) {
            self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            self.host = host.lowercased()
        }
    }
    private let base: any DeliveryCredentialStore
    private let log: DeliveryDebugLog?
    private let lock = NSLock()
    private let operationLock = NSLock()
    private var passwords: [Identity: Result<String?, DeliveryError>] = [:]
    public init(base: any DeliveryCredentialStore, debugLog: DeliveryDebugLog? = nil) {
        self.base = base; self.log = debugLog
    }
    public func presence(username: String, host: String) -> Presence {
        lock.withLock {
            switch passwords[Identity(username, host)] {
            case .success(let password): password?.isEmpty == false ? .stored : .missing
            case .failure: .unavailable
            case nil: .unchecked
            }
        }
    }
    public func hasPassword(username: String, host: String) throws -> Bool {
        presence(username: username, host: host) == .stored
    }
    public func readPassword(username: String, host: String) throws -> String? {
        try operationLock.withLock {
            let identity = Identity(username, host)
            if let cached = lock.withLock({ passwords[identity] }) {
                log?.record(.credentialCacheHit)
                return try cached.get()
            }
            let result: Result<String?, DeliveryError>
            do {
                result = .success(try base.readPassword(username: identity.username, host: identity.host))
                log?.record(.credentialRead)
            } catch let error as DeliveryError {
                if case .credentialUnavailable = error { result = .failure(error) }
                else { result = .failure(.credentialUnavailable(DeliveryError.credentialNotice)) }
                log?.record(.failure(.keychain))
            } catch {
                result = .failure(.credentialUnavailable(DeliveryError.credentialNotice))
                log?.record(.failure(.keychain))
            }
            lock.withLock { passwords[identity] = result }
            return try result.get()
        }
    }
    /// Explicit Test/Upload may retry a failed or missing read, but never discard a successful grant.
    public func retryFailedAccess(username: String, host: String) {
        lock.withLock {
            let identity = Identity(username, host)
            switch passwords[identity] {
            case .success(let password) where password?.isEmpty == false: break
            default: passwords.removeValue(forKey: identity)
            }
        }
    }
    public func writePassword(_ password: String, username: String, host: String) throws {
        try operationLock.withLock {
            let identity = Identity(username, host)
            // Re-saving the same password need not ask Keychain for modification access.
            if case .success(let saved) = lock.withLock({ passwords[identity] }), saved == password { return }
            try base.writePassword(password, username: identity.username, host: identity.host)
            lock.withLock { passwords[identity] = .success(password) }
        }
    }
    public func deletePassword(username: String, host: String) throws {
        try operationLock.withLock {
            let identity = Identity(username, host)
            try base.deletePassword(username: identity.username, host: identity.host)
            lock.withLock { passwords[identity] = .success(nil) }
        }
    }
    public func cancelAuthentication() { (base as? KeychainCredentialStore)?.cancelAuthentication() }
    public func clearSession() {
        lock.withLock { passwords.removeAll() }
        cancelAuthentication()
    }
}

/// macOS Keychain generic-password items keyed by host:username. No password is logged or returned elsewhere.
public final class KeychainCredentialStore: DeliveryCredentialStore, @unchecked Sendable {
    public static let service = "VoiceRelay Podcast Upload"
    private let contextLock = NSLock()
    private var authenticationContext = LAContext()
    public init() { authenticationContext.localizedReason = "Unlock VoiceRelay delivery for this app session." }
    public func cancelAuthentication() {
        let cancelled = contextLock.withLock {
            let previous = authenticationContext
            authenticationContext = LAContext()
            authenticationContext.localizedReason = "Unlock VoiceRelay delivery for this app session."
            return previous
        }
        cancelled.invalidate()
    }
    func base(_ username: String, _ host: String) -> [String: Any] {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host.lowercased()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                kSecAttrAccount as String: username.isEmpty ? host : host + ":" + username,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: false]
    }
    static func accessControl() throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryAny, .devicePasscode, .companion, .or], nil) else {
            throw DeliveryError.credentialUnavailable("The protected delivery credential could not be configured.")
        }
        return access
    }
    func context() -> LAContext {
        contextLock.withLock { authenticationContext }
    }
    public func hasPassword(username: String, host: String) throws -> Bool {
        var query = base(username, host)
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw DeliveryError.credentialUnavailable(Self.readNotice(status))
        }
        return true
    }
    public func readPassword(username: String, host: String) throws -> String? {
        var query = base(username, host)
        query[kSecUseAuthenticationContext as String] = context()
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw DeliveryError.credentialUnavailable(Self.readNotice(status))
        }
        return password
    }
    private static func readNotice(_ status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled: "Keychain access was cancelled. Allow VoiceRelay to access the saved password and try again."
        case errSecAuthFailed: "Keychain access was denied. Allow VoiceRelay to access the saved password and try again."
        case errSecMissingEntitlement: "Protected Keychain access requires the signed VoiceRelay app and its provisioning profile. Check Xcode signing settings."
        default: DeliveryError.credentialNotice
        }
    }
    public func writePassword(_ password: String, username: String, host: String) throws {
        var attributes = base(username, host)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessControl as String] = try Self.accessControl()
        attributes[kSecUseAuthenticationContext as String] = context()
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let update = [kSecValueData as String: Data(password.utf8)]
            var query = base(username, host)
            query[kSecUseAuthenticationContext as String] = context()
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw DeliveryError.credentialUnavailable(Self.readNotice(status))
            }
        } else {
            guard added == errSecSuccess else { throw DeliveryError.credentialUnavailable(Self.readNotice(added)) }
        }
    }
    public func deletePassword(username: String, host: String) throws {
        var query = base(username, host)
        query[kSecUseAuthenticationContext as String] = context()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeliveryError.credentialUnavailable(Self.readNotice(status))
        }
    }
}

public struct DeliveryResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    public var contentLength: Int64? { header("content-length").flatMap(Self.byteCount) }
    static func byteCount(_ text: String) -> Int64? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(digits)
    }
}

public protocol DeliveryTransport: Sendable {
    func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse
    func upload(_ url: URL, file: URL, headers: [String: String], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DeliveryResponse
    func read(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> DeliveryResponse
    func digest(_ url: URL, headers: [String: String], maximumBytes: Int64) async throws -> RemoteAudioDigest
    func verifiedAudio(_ url: URL, headers: [String: String], maximumBytes: Int64, settings: PrototypeProfile) async throws -> VerifiedRemoteAudio
}

extension DeliveryTransport {
    /// Injected transports can omit byte reporting; the UI then uses an indeterminate indicator.
    public func upload(_ url: URL, file: URL, headers: [String: String], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DeliveryResponse {
        try await request("PUT", url: url, body: nil, file: file, headers: headers)
    }
}

/// Opt-in, bounded session log. Events cannot carry endpoints, account names, secrets or server bodies.
public final class DeliveryDebugLog: @unchecked Sendable {
    public enum Method: String, Sendable { case get = "GET", propfind = "PROPFIND", mkcol = "MKCOL", put = "PUT", head = "HEAD", delete = "DELETE" }
    public enum Folder: String, Sendable { case root, feed, audio }
    public enum SizeResult: String, Sendable { case matched, unavailable, mismatch, unsupported }
    public enum Failure: String, Sendable { case credentials, keychain, permissions, transport, configuration, cancelled }
    public enum ArchiveResult: String, Sendable { case lookup, recovered, unavailable }
    public enum Reconciliation: String, Sendable { case started, unchanged, deferred, serverPreferred, localPreferred, metadataRepaired, itemFailed, finished }
    public enum Event: Sendable {
        case credentialPresence(Bool), credentialRead, credentialCacheHit, credentialSaved, credentialRemoved
        case connectionStarted, connectionVerified, connectionFoldersPending, deliveryStarted, deliveryFinished
        case request(Method), response(Method, Int), failure(Failure)
        case folderCheck(Folder, Int), folderCreation(Folder, Int)
        case sizeCheck(Method, SizeResult)
        case speechTiming(SpeechTimingStage, Double, Int?)
        case speechEncoding(Double, Double)
        case speechFinalizerWaiting(Int?), speechFinalizerAcquired(Double, Int?)
        case articleArchive(ArticleArchive, ArchiveResult), articleArchiveSkipped
        case reconciliation(Reconciliation)
        case localCleanupFailed
        case articleCacheRemoved, articleCacheRemovalFailed
        case speechRuntime(RuntimeOperation, RuntimeOutcome)
        public enum RuntimeOperation: String, Sendable { case check, installation }
        public enum RuntimeOutcome: String, Sendable { case started, verified, cancelled, failed }
        var message: String {
            switch self {
            case .articleCacheRemoved: "removed article cache: cleared; server history retained"
            case .articleCacheRemovalFailed: "removed article cache: cleanup failed; retry pending"
            case .speechRuntime(let operation, let outcome): "speech runtime \(operation.rawValue): \(outcome.rawValue)"
            case .localCleanupFailed: "local audio cleanup: verification failed; file retained"
            case .reconciliation(let result): "server reconciliation: \(result.rawValue)"
            case .articleArchive(let provider, let result): "article archive: \(provider.rawValue) \(result.rawValue)"
            case .articleArchiveSkipped: "article archive: skipped (URL not eligible)"
            case .credentialPresence(let present): "credential presence: \(present ? "stored" : "missing")"
            case .credentialRead: "credential read: succeeded"
            case .credentialCacheHit: "credential session: reused (no Keychain query)"
            case .credentialSaved: "credential save: succeeded"
            case .credentialRemoved: "credential removal: succeeded"
            case .connectionStarted: "connection test: started"
            case .connectionVerified: "connection test: feed and audio folders verified (write access untested)"
            case .connectionFoldersPending: "connection test: connected; missing folders created on upload (write access untested)"
            case .deliveryStarted: "delivery: started"
            case .deliveryFinished: "delivery: finished"
            case .request(let method): "request: \(method.rawValue)"
            case .response(let method, let status): "response: \(method.rawValue) HTTP \(status)"
            case .failure(let failure): "failure: \(failure.rawValue)"
            case .folderCheck(let folder, let level): "folder check: \(folder.rawValue), level \(level)"
            case .folderCreation(let folder, let level): "folder creation: \(folder.rawValue), level \(level)"
            case .sizeCheck(let method, let result): "upload size check: \(method.rawValue) \(result.rawValue)"
            case .speechTiming(let stage, let milliseconds, let chunk):
                "speech timing: \(stage.rawValue)\(chunk.map { " chunk \(max(0, min($0, 1_000_000)) + 1)" } ?? "") \(milliseconds.isFinite ? max(0, min(milliseconds, 86_400_000)).rounded() : 0) ms"
            case .speechEncoding(let seconds, let duration):
                Self.encodingMessage(seconds: seconds, duration: duration)
            case .speechFinalizerWaiting(let ready):
                "speech finalizer wait: started; ready items \(Self.readyCount(ready))"
            case .speechFinalizerAcquired(let milliseconds, let ready):
                "speech finalizer wait: \(milliseconds.isFinite ? max(0, min(milliseconds, 86_400_000)).rounded() : 0) ms; ready items \(Self.readyCount(ready))"
            }
        }
        private static func readyCount(_ value: Int?) -> String {
            value.map { String(max(0, min($0, 1_000_000))) } ?? "unknown"
        }
        private static func encodingMessage(seconds: Double, duration: Double) -> String {
            let perMinute = seconds / duration * 60
            guard seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0, perMinute.isFinite else {
                return "speech encoding: duration unavailable"
            }
            func number(_ value: Double) -> String {
                String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), min(value, 86_400_000))
            }
            return "speech encoding: audio \(number(duration)) s, encode \(number(seconds)) s, \(number(perMinute)) s per audio minute"
        }
    }
    private let lock = NSLock()
    private var active = false
    private var entries: [String] = []
    public init() {}
    public var enabled: Bool {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }
    public func record(_ event: Event) {
        lock.withLock {
            guard active else { return }
            entries.append(Date().formatted(.iso8601) + " " + event.message)
            if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        }
    }
    public func recordFailure(_ error: any Error) {
        let category: Failure
        if error is CancellationError { category = .cancelled }
        else {
            switch error as? DeliveryError {
            case .authFailed: category = .credentials
            case .credentialUnavailable: category = .keychain
            case .permissionDenied: category = .permissions
            case .retryable: category = .transport
            case .fatal: category = .configuration
            case nil: category = .transport
            }
        }
        record(.failure(category))
    }
    public var text: String { lock.withLock { entries.joined(separator: "\n") } }
    public func clear() { lock.withLock { entries.removeAll() } }
}

/// Logs only fixed method names and HTTP numbers; never interpolates URLRequest or errors.
public struct LoggingDeliveryTransport: DeliveryTransport {
    public let base: any DeliveryTransport
    public let log: DeliveryDebugLog
    public init(base: any DeliveryTransport, log: DeliveryDebugLog) { self.base = base; self.log = log }
    public func upload(_ url: URL, file: URL, headers: [String: String], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DeliveryResponse {
        log.record(.request(.put))
        do {
            let response = try await base.upload(url, file: file, headers: headers, progress: progress)
            log.record(.response(.put, response.status)); return response
        } catch { log.recordFailure(error); throw error }
    }
    public func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        let known = DeliveryDebugLog.Method(rawValue: method)
        if let known { log.record(.request(known)) }
        do {
            let response = try await base.request(method, url: url, body: body, file: file, headers: headers)
            if let known { log.record(.response(known, response.status)) }
            return response
        } catch { log.recordFailure(error); throw error }
    }
}

/// Ephemeral URLSession transport. Every redirect is refused; credentials are already
/// constrained to the configured origin by WebDAVClient before they reach a request.
public final class URLSessionDeliveryTransport: DeliveryTransport, @unchecked Sendable {
    let timeout: TimeInterval
    public init(timeout: TimeInterval = 60) { self.timeout = timeout }
    public func upload(_ url: URL, file: URL, headers: [String: String], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DeliveryResponse {
        try await request("PUT", url: url, body: nil, file: file, headers: headers, progress: progress)
    }
    public func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String]) async throws -> DeliveryResponse {
        try await request(method, url: url, body: body, file: file, headers: headers, progress: nil)
    }
    private func request(_ method: String, url: URL, body: Data?, file: URL?, headers: [String: String],
                         progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DeliveryResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: DeliverySessionDelegate(progress: progress), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let request = try await withTaskCancellationHandler {
                var request = URLRequest(url: url)
                request.httpMethod = method
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                if let file { return try await session.upload(for: request, fromFile: file) }
                if let body { request.httpBody = body }
                return try await session.data(for: request)
            } onCancel: { session.invalidateAndCancel() }
            guard let http = request.1 as? HTTPURLResponse else {
                throw DeliveryError.retryable("The delivery endpoint did not answer over HTTP.")
            }
            var normalized: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                normalized[String(describing: key).lowercased()] = String(describing: value)
            }
            return DeliveryResponse(status: http.statusCode, headers: normalized, body: Data(request.0.prefix(65_536)))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? DeliveryError { throw error }
            throw Self.classifyTransport(error)
        }
    }
    /// Sanitized transport failures: distinguish a certificate/TLS refusal from ordinary
    /// reachability so "server unreachable" does not mask a wrong-hostname endpoint.
    static func classifyTransport(_ error: any Error) -> DeliveryError {
        guard let urlError = error as? URLError else {
            return .retryable("The delivery request failed. Check connectivity and the configured endpoint.")
        }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return .fatal("The endpoint's security certificate could not be verified. Check that the WebDAV URL is correct.")
        case .cannotFindHost, .dnsLookupFailed:
            return .fatal("The delivery endpoint's host could not be found. Check the WebDAV URL.")
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return .retryable("The delivery endpoint is unreachable. Upload retries automatically.")
        default:
            return .retryable("The delivery request failed. Check connectivity and the configured endpoint.")
        }
    }
}

final class DeliverySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressAt: TimeInterval = 0
    init(progress: (@Sendable (Int64, Int64) -> Void)? = nil) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressAt >= 0.15 || totalBytesSent == totalBytesExpectedToSend else { return }
        lastProgressAt = now
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}

private final class UploadVerificationStage: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var verifying: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// MKCOL/PUT/HEAD/DELETE against the configured WebDAV folder. Basic auth attaches only
/// when the request URL shares scheme, host and port with the configured endpoint.
public struct WebDAVClient: Sendable {
    public let transport: any DeliveryTransport
    public let settings: DeliverySettings
    public let credential: any DeliveryCredentialStore
    /// Read once per client: each decrypting Keychain access can prompt, so requests
    /// must never re-read mid-drain.
    private let password: String
    private let debugLog: DeliveryDebugLog?
    public init(transport: any DeliveryTransport, settings: DeliverySettings, credential: any DeliveryCredentialStore,
                debugLog: DeliveryDebugLog? = nil) throws {
        let settings = try settings.normalized()
        try settings.validate()
        guard settings.feedFolderURL != nil else { throw DeliveryError.fatal("Delivery endpoint is not configured.") }
        self.transport = transport; self.settings = settings; self.credential = credential; self.debugLog = debugLog
        let saved: String?
        do { saved = try credential.readPassword(username: settings.credentialUsername, host: settings.credentialHost) }
        catch let error as DeliveryError {
            if case .credentialUnavailable = error { throw error }
            throw DeliveryError.credentialUnavailable(DeliveryError.credentialNotice)
        } catch { throw DeliveryError.credentialUnavailable(DeliveryError.credentialNotice) }
        guard let saved, !saved.isEmpty else {
            throw DeliveryError.authFailed("No saved password for this host and username.")
        }
        self.password = saved
        // Session stores report actual Keychain reads and cache hits separately.
        if !(credential is SessionDeliveryCredentialStore) { debugLog?.record(.credentialRead) }
    }
    func remoteURL(_ remotePath: String, directory: Bool = false) throws -> URL {
        guard let base = settings.feedFolderURL, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw DeliveryError.fatal("Delivery endpoint is not configured.") }
        let segments: [String]
        do { segments = try DeliverySettings.pathSegments(remotePath) }
        catch { throw DeliveryError.fatal("A remote delivery path is invalid.") }
        components.path = "/" + segments.joined(separator: "/") + (directory && !segments.isEmpty ? "/" : "")
        guard let url = components.url else { throw DeliveryError.fatal("A remote delivery address is invalid.") }
        return url
    }
    private static func sameOrigin(_ url: URL, base: URL) -> Bool {
        func port(_ u: URL) -> Int? { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : u.scheme?.lowercased() == "http" ? 80 : nil) }
        return url.scheme?.lowercased() == base.scheme?.lowercased()
            && url.host?.lowercased() == base.host?.lowercased() && port(url) == port(base)
    }
    func headers(for url: URL, extra: [String: String]) throws -> [String: String] {
        var headers = extra
        guard let base = settings.feedFolderURL else { throw DeliveryError.authFailed(DeliveryError.authNotice) }
        guard Self.sameOrigin(url, base: base) else { return headers }
        let username = settings.credentialUsername
        headers["Authorization"] = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        return headers
    }
    /// Read-only authentication/destination probe. This never creates folders or proves write access.
    @discardableResult
    public func testConnection() async throws -> Bool {
        let segments = try DeliverySettings.pathSegments(settings.remoteFolder)
        if try await collectionExists(remotePath: settings.remoteFolder, role: .feed, level: segments.count) {
            return try await collectionExists(remotePath: settings.mediaFolder, role: .audio, level: segments.count + 1)
        }
        // Authenticate against the nearest existing parent. A test must never write.
        for count in (0..<segments.count).reversed() {
            if try await collectionExists(remotePath: segments.prefix(count).joined(separator: "/"), role: .root, level: count) { return false }
        }
        throw DeliveryError.fatal("The feed folder and its parents could not be found. Check the Feed folder URL.")
    }
    private func requireCollection(remotePath: String, role: DeliveryDebugLog.Folder, level: Int) async throws {
        guard try await collectionExists(remotePath: remotePath, role: role, level: level) else {
            let message = switch role {
            case .root: "The WebDAV root was not found. Check the WebDAV root URL."
            case .feed: "The feed folder was not found. Publishing can create missing folders."
            case .audio: "The audio folder was not found. Publishing can create it."
            }
            throw DeliveryError.fatal(message)
        }
    }
    private func collectionExists(remotePath: String, role: DeliveryDebugLog.Folder, level: Int) async throws -> Bool {
        let target = try remoteURL(remotePath, directory: true)
        debugLog?.record(.folderCheck(role, level))
        let body = Data("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let response = try await transport.request("PROPFIND", url: target, body: body, file: nil,
            headers: try headers(for: target, extra: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"]))
        if response.status == 404 { return false }
        guard response.status == 207 else { throw DeliveryError.classify(response.status) }
        guard DAVResponseParser.confirmsCollection(response.body, target: target) else {
            throw DeliveryError.fatal("The WebDAV response did not confirm a readable folder. Check the WebDAV URL and folder permissions.")
        }
        return true
    }
    @discardableResult
    private func perform(_ method: String, remotePath: String, body: Data? = nil, file: URL? = nil,
                         contentType: String? = nil, directory: Bool = false, progress: (@Sendable (Int64, Int64) -> Void)? = nil, extraHeaders: [String: String] = [:], acceptable: (Int) -> Bool) async throws -> DeliveryResponse {
        let target = try remoteURL(remotePath, directory: directory)
        var extra = extraHeaders
        if method == "HEAD" { extra["Accept-Encoding"] = "identity"; extra["Cache-Control"] = "no-cache"; extra["Want-Repr-Digest"] = "sha-256=10" }
        if let contentType { extra["Content-Type"] = contentType }
        let response: DeliveryResponse
        if let file, let progress {
            response = try await transport.upload(target, file: file, headers: try headers(for: target, extra: extra), progress: progress)
        } else {
            response = try await transport.request(method, url: target, body: body, file: file,
                                                   headers: try headers(for: target, extra: extra))
        }
        guard acceptable(response.status) else { throw DeliveryError.classify(response.status) }
        return response
    }
    /// Probe first: existing account/files ancestors must not be
    /// created. Create only confirmed-missing collections, parent before child.
    public func ensureCollections() async throws {
        try await ensureCollection(settings.remoteFolder, role: .feed, level: try DeliverySettings.pathSegments(settings.remoteFolder).count)
        try await ensureCollection(settings.mediaFolder, role: .audio, level: try DeliverySettings.pathSegments(settings.mediaFolder).count)
    }
    private func ensureCollection(_ path: String, role: DeliveryDebugLog.Folder, level: Int) async throws {
        if try await collectionExists(remotePath: path, role: role, level: level) { return }
        let segments = try DeliverySettings.pathSegments(path)
        guard !segments.isEmpty else { throw DeliveryError.fatal("The server root could not be found. Check the Feed folder URL.") }
        try await ensureCollection(segments.dropLast().joined(separator: "/"), role: .feed, level: level - 1)
        debugLog?.record(.folderCreation(role, level))
        _ = try await perform("MKCOL", remotePath: path, directory: true) { [200, 201, 405].contains($0) }
        // Verify creation, including a 405 from another client creating it concurrently.
        try await requireCollection(remotePath: path, role: role, level: level)
    }
    /// Complete-byte upload; confirm length through HEAD or DAV:getcontentlength.
    @discardableResult
    public func uploadFile(_ local: URL, remotePath: String, onlyIfMissing: Bool = false, progress: (@Sendable (Int64, Int64) -> Void)? = nil,
                           verifying: (@Sendable () -> Void)? = nil) async throws -> DeliveryResponse {
        guard let bytes = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes >= 0 else {
            throw DeliveryError.fatal("The local audio size could not be read; no upload was attempted.")
        }
        let size = Int64(bytes)
        _ = try await perform("PUT", remotePath: remotePath, file: local, contentType: "audio/mp4", progress: progress, extraHeaders: onlyIfMissing ? ["If-None-Match": "*"] : [:]) { (200...299).contains($0) }
        verifying?()
        return try await verify(remotePath: remotePath, expected: size)
    }
    public func uploadData(_ data: Data, remotePath: String, contentType: String = "application/rss+xml", ifMatch: String? = nil, onlyIfMissing: Bool = false) async throws {
        var preconditions: [String: String] = [:]
        if let ifMatch { preconditions["If-Match"] = ifMatch }
        else if onlyIfMissing { preconditions["If-None-Match"] = "*" }
        _ = try await perform("PUT", remotePath: remotePath, body: data, contentType: contentType, extraHeaders: preconditions) { (200...299).contains($0) }
        _ = try await verify(remotePath: remotePath, expected: Int64(data.count))
    }
    private func verify(remotePath: String, expected: Int64) async throws -> DeliveryResponse {
        let head = try await perform("HEAD", remotePath: remotePath) { (200...299).contains($0) || [405, 501].contains($0) }
        let headResult: DeliveryDebugLog.SizeResult = [405, 501].contains(head.status) ? .unsupported
            : head.contentLength == nil ? .unavailable : head.contentLength == expected ? .matched : .mismatch
        debugLog?.record(.sizeCheck(.head, headResult))
        if headResult == .matched { return head }
        // HEAD may omit a length or describe a negotiated representation. Ask the DAV
        // resource itself for its unencoded length, never the XML response body's size.
        let target = try remoteURL(remotePath)
        let body = Data("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>".utf8)
        let response = try await transport.request("PROPFIND", url: target, body: body, file: nil,
            headers: try headers(for: target, extra: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8", "Accept-Encoding": "identity", "Cache-Control": "no-cache"]))
        guard response.status == 207 else { throw DeliveryError.classify(response.status) }
        let length = DAVResponseParser.contentLength(response.body, target: target)
        let result: DeliveryDebugLog.SizeResult = length == nil ? .unavailable : length == expected ? .matched : .mismatch
        debugLog?.record(.sizeCheck(.propfind, result))
        guard result == .matched else {
            throw DeliveryError.fatal(DeliveryError.verificationNotice)
        }
        return response
    }
    /// Remote removal mirrors local retirement; an absent copy is already retired.
    public func delete(remotePath: String) async throws {
        _ = try await perform("DELETE", remotePath: remotePath) { (200...299).contains($0) || $0 == 404 }
    }
}

/// Accept properties only from successful DAV propstats for the exact requested resource.
private final class DAVResponseParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var href = "", status = ""
    private var collection = false, readable = false
    private var confirmed = false
    private var propertyLength: Int64?, lengths: [Int64] = []
    private var propertyLengthCount = 0
    private var ambiguousLength = false
    private var hasResourceType = false, fileTypeConfirmed = false, responseIsCollection = false
    private var matchedResponses = 0, matchedLength: Int64?
    private let target: URL
    private init(target: URL) { self.target = target }
    static func confirmsCollection(_ data: Data, target: URL) -> Bool { parse(data, target: target)?.confirmed == true }
    static func contentLength(_ data: Data, target: URL) -> Int64? {
        guard let result = parse(data, target: target), result.matchedResponses == 1 else { return nil }
        return result.matchedLength
    }
    private static func parse(_ data: Data, target: URL) -> DAVResponseParser? {
        guard !data.isEmpty, data.count <= 65_536 else { return nil }
        let delegate = DAVResponseParser(target: target)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() ? delegate : nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        path.append(namespaceURI == "DAV:" ? elementName : "")
        text = ""
        if path == ["multistatus", "response"] {
            href = ""; readable = false; lengths = []; ambiguousLength = false; fileTypeConfirmed = false; responseIsCollection = false
        }
        if path == ["multistatus", "response", "propstat"] {
            status = ""; collection = false; propertyLength = nil; propertyLengthCount = 0; hasResourceType = false
        }
        if path == ["multistatus", "response", "propstat", "prop", "resourcetype", "collection"] { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if path == ["multistatus", "response", "href"] { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if path == ["multistatus", "response", "propstat", "status"] { status = text }
        if path == ["multistatus", "response", "propstat", "prop", "getcontentlength"] {
            propertyLengthCount += 1
            propertyLength = DeliveryResponse.byteCount(text)
        }
        if path == ["multistatus", "response", "propstat", "prop", "resourcetype"] { hasResourceType = true }
        if path == ["multistatus", "response", "propstat"],
           status.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("HTTP/"),
           let code = status.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.flatMap({ Int($0) }),
           (200...299).contains(code) {
            if collection { readable = true; responseIsCollection = true }
            if hasResourceType && !collection { fileTypeConfirmed = true }
            if propertyLengthCount > 1 { ambiguousLength = true }
            if let propertyLength { lengths.append(propertyLength) }
        }
        if path == ["multistatus", "response"],
           let url = URL(string: href, relativeTo: target)?.absoluteURL,
           url.scheme?.lowercased() == target.scheme?.lowercased(),
           url.host?.lowercased() == target.host?.lowercased(),
           (url.port ?? 443) == (target.port ?? 443), url.query == nil, url.fragment == nil,
           url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            if readable { confirmed = true }
            matchedResponses += 1
            if fileTypeConfirmed && !responseIsCollection && !ambiguousLength && lengths.count == 1,
               url.path == target.path, url.hasDirectoryPath == target.hasDirectoryPath {
                matchedLength = lengths[0]
            }
        }
        path.removeLast(); text = ""
    }
}

/// Durable delivery intent beside the native database. A missing ledger is empty; a
/// corrupt one is preserved under a timestamped name and reported, never silently reset.
public struct DeliveryLedger: Codable, Sendable, Equatable {
    public var remoteFeedPending = false
    public var lastUploadedFeedHash: String?
    public var lastPublishedAudioHashes: [String: String]?
    public var lastPublishedSettingsHash: String?
    public var pendingRemoteDeletes: [String] = []
    public var lastError: String?
    public var feedAttempts = 0
    public var lastAttemptAt: Date?
    public var settingsHash: String?
    public var destinationURL: URL?
    var serverAudioProofs: [String: ServerAudioProof]?
    var reconciledFeed: Data?
    var reconciledFeedETag: String?
    var reconciledAt: Date?
    public var reconciliationAttemptAt: Date?
    var reconciliationError: String?
    var preservedServerItems: [String]?
    var blockedServerIDs: [String]?
    var serverFeedUnsafe: Bool?
    var reconciledQueueIDs: [String]?
    public init() {}
    public static func fileURL(stateRoot: URL) -> URL { stateRoot.appendingPathComponent("private/delivery.json") }
    public static func load(stateRoot: URL, preserveCorrupt: Bool = true) throws -> DeliveryLedger {
        let url = fileURL(stateRoot: stateRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return DeliveryLedger() }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw RelayError.storage("The delivery ledger could not be read; saved state is preserved.")
        }
        do { return try JSONDecoder().decode(DeliveryLedger.self, from: data) } catch {
            let preserved = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            if preserveCorrupt { try? FileManager.default.moveItem(at: url, to: preserved) }
            throw RelayError.storage("The delivery ledger is corrupt; the original was preserved alongside it.")
        }
    }
    public func save(stateRoot: URL) throws {
        try Files.directory(stateRoot.appendingPathComponent("private"))
        try Files.write(try Files.json(self), to: Self.fileURL(stateRoot: stateRoot))
    }
}

public struct DeliveryResult: Sendable, Equatable {
    public var skipped = false
    public var uploadedMedia = 0
    public var feedUploaded = false
    public var remoteDeletes = 0
    public var failed = 0
    public var retrying = 0
    public init() {}
}

public enum DeliveryPublicationStatus: Sendable, Equatable {
    case notUploaded, awaitingUpload, uploaded, published, failed

    /// An audio-copy record alone cannot certify inclusion in the remote feed.
    public static func unconfirmed(_ episode: Episode, settings: DeliverySettings) -> Self {
        guard let copy = episode.delivery,
              copy.remotePath == settings.remoteMediaPath(episode.id),
              copy.destinationURL == nil || copy.destinationURL == settings.feedFolderURL else { return .notUploaded }
        switch copy.status {
        case .pending: return .awaitingUpload
        case .failed: return .failed
        case .uploaded:
            guard copy.destinationURL != nil, episode.audioHash != nil, let length = episode.info?.byteLength,
                  copy.uploadedByteLength == length else { return .notUploaded }
            return .uploaded
        }
    }
}

/// Cheap read-only delivery snapshot for status display and pending-work detection.
public struct DeliverySummary: Sendable, Equatable {
    public var reconciledAt: Date?
    public var pendingMedia = 0
    public var uploadedMedia = 0
    public var failedMedia = 0
    public var remoteFeedPending = false
    public var pendingRemoteDeletes = 0
    public var feedUploaded = false
    public var lastError: String?
    public var publicationStates: [String: DeliveryPublicationStatus] = [:]
    public var publicationAudioHashes: [String: String] = [:]
    public var publicationSettingsHash: String?
    public var verificationFailedIDs: Set<String> = []
    public var feedError: String?
    public init() {}
    public var needsDrain: Bool { pendingMedia > 0 || pendingRemoteDeletes > 0 || remoteFeedPending }
}

extension FixtureCoordinator {
    /// Keep ledger I/O and JSON decoding off the app's main actor. This read-only
    /// readiness probe must not rename corrupt state; the delivery owner handles it.
    public func deliveryPreflightRequired(stateRoot: URL, settings: DeliverySettings, now: Date) -> Bool {
        beforeDeliveryPreflight?()
        let ledger = try? DeliveryLedger.load(stateRoot: stateRoot, preserveCorrupt: false)
        return ledger?.destinationURL != settings.feedFolderURL || ledger?.reconciliationAttemptAt == nil
            || now.timeIntervalSince(ledger?.reconciliationAttemptAt ?? .distantPast) >= 300
    }
    public func invalidateDeliveryFeed(stateRoot: URL, settingsHash: String) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: PrototypeProfile.fixture(at: stateRoot).database.path),
              !activeDeliveryRoots.contains(stateRoot.resolvingSymlinksInPath().standardizedFileURL.path) else { return }
        try ManagedSpeechStorage.validateLibrary(stateRoot: stateRoot)
        var ledger = try DeliveryLedger.load(stateRoot: stateRoot)
        guard ledger.settingsHash != settingsHash, !ledger.remoteFeedPending else { return }
        ledger.remoteFeedPending = true
        try ledger.save(stateRoot: stateRoot)
    }
    /// Durable read used by automation: a library without a database has no pending work.
    public func deliverySummary(stateRoot: URL, settings: DeliverySettings? = nil) throws -> DeliverySummary {
        var summary = DeliverySummary()
        let database = PrototypeProfile.fixture(at: stateRoot).database
        let ledger = try DeliveryLedger.load(stateRoot: stateRoot)
        summary.reconciledAt = ledger.reconciledAt
        summary.remoteFeedPending = ledger.remoteFeedPending
        summary.pendingRemoteDeletes = ledger.pendingRemoteDeletes.count
        summary.feedUploaded = ledger.lastUploadedFeedHash != nil
        summary.lastError = ledger.lastError ?? ledger.reconciliationError
        summary.verificationFailedIDs = Set(ledger.blockedServerIDs ?? [])
        summary.feedError = ledger.remoteFeedPending ? ledger.lastError ?? ledger.reconciliationError : nil
        guard FileManager.default.fileExists(atPath: database.path) else { return summary }
        let store = try NativeStore(url: database, readOnly: true)
        let episodes = try store.episodes().filter { $0.stage == .published }
        if let settings = try settings?.normalized() {
            if ledger.destinationURL != settings.feedFolderURL {
                summary.verificationFailedIDs = []; summary.feedError = nil
            }
            let candidate = (try? RemoteChannel(settings: settings)).flatMap { try? RSS.renderReconciledRemote(episodes, channel: $0, preserved: ledger.preservedServerItems ?? []) }
            if let candidate, ledger.lastUploadedFeedHash != Files.hash(candidate) { summary.remoteFeedPending = true }
            let identity = try? settings.publicationHash()
            summary.publicationSettingsHash = identity
            var published = identity != nil && ledger.lastPublishedSettingsHash == identity
                ? ledger.lastPublishedAudioHashes ?? [:] : [:]
            // Older ledgers have only the exact uploaded XML hash. Infer membership
            // only if today's candidate feed matches that confirmed copy byte-for-byte.
            if ledger.lastPublishedAudioHashes == nil, ledger.destinationURL == settings.feedFolderURL,
               let feed = candidate,
               ledger.lastUploadedFeedHash == Files.hash(feed) {
                published = Dictionary(uniqueKeysWithValues: episodes.compactMap { episode in
                    guard episode.delivery?.status == .uploaded, let hash = episode.audioHash else { return nil }
                    return (episode.id, hash)
                })
            }
            for episode in episodes {
                summary.publicationAudioHashes[episode.id] = episode.audioHash
                let state = DeliveryPublicationStatus.unconfirmed(episode, settings: settings)
                summary.publicationStates[episode.id] = state == .uploaded && published[episode.id] == episode.audioHash
                    ? .published : state
            }
        }
        for episode in episodes {
            if episode.localAudioDiscarded == true && episode.delivery?.status != .uploaded { continue }
            switch episode.delivery?.status {
            case .pending: summary.pendingMedia += 1
            case .uploaded: summary.uploadedMedia += 1
            case .failed: summary.failedMedia += 1
            case nil: break
            }
        }
        if episodes.isEmpty && ledger.reconciledFeed == nil && (ledger.preservedServerItems ?? []).isEmpty && ledger.pendingRemoteDeletes.isEmpty {
            summary.remoteFeedPending = false
        }
        return summary
    }
    /// True when this source URL already produced a recorded episode — admission never
    /// deletes episodes, so presence means the article was admitted (and possibly
    /// deliberately removed) before. Automatic admission must not re-add it.
    public func hasRecordedArticle(url: URL, stateRoot: URL) throws -> Bool {
        let database = PrototypeProfile.fixture(at: stateRoot).database
        guard FileManager.default.fileExists(atPath: database.path) else { return false }
        let store = try NativeStore(url: database, readOnly: true)
        if try store.existingEpisode(sourceKey: "reviewed-url-v1-" + Files.hash(Data(url.absoluteString.utf8))) != nil { return true }
        // An old feed can lack original-source fingerprints. An exact article-link
        // match to recovered remote-only history still prevents automatic duplication.
        return try store.query("SELECT record FROM episodes WHERE source_key LIKE 'remote-episode-v1-%'").contains { row in
            let episode = try JSONDecoder().decode(Episode.self, from: Data(row[0].utf8))
            return episode.stage == .published && episode.originalSourceIdentity == nil && episode.sourceURL == url
        }
    }
    static func deliveryBackoff(_ attempts: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(0, attempts - 1))), 1800)
    }
    private static func deliveryNotice(_ error: any Error) -> String {
        if let failure = error as? DeliveryError { return failure.localizedDescription }
        return (error as? RelayError)?.localizedDescription ?? "Delivery failed; saved progress is retained."
    }
    private static func reconcileRemoteDeletes(_ episodes: [Episode], settings: DeliverySettings,
                                               ledger: inout DeliveryLedger) -> Bool {
        var changed = false
        for episode in episodes {
            guard episode.delivery?.destinationURL == settings.feedFolderURL,
                  let path = episode.delivery?.remotePath, !path.isEmpty else { continue }
            if episode.stage == .expired && !ledger.pendingRemoteDeletes.contains(path) {
                ledger.pendingRemoteDeletes.append(path)
                ledger.remoteFeedPending = true
                changed = true
            } else if episode.stage == .published && ledger.pendingRemoteDeletes.contains(path) {
                ledger.pendingRemoteDeletes.removeAll { $0 == path }
                changed = true
            }
        }
        return changed
    }
    /// Ordered drain: confirmed media uploads → feed.xml → remote deletes. Each episode
    /// transition commits as a short write so a crash resumes without resynthesis.
    @discardableResult
    public func deliverPending(storage: ManagedSpeechStorage, settings: DeliverySettings,
                               credential: any DeliveryCredentialStore, transport: any DeliveryTransport,
                               force: Bool = false, reconcileNow: Bool = false, now: Date = Date(), debugLog: DeliveryDebugLog? = nil,
                               progress: (@Sendable (UploadProgress) -> Void)? = nil) async throws -> DeliveryResult {
        try Task.checkCancellation()
        try storage.validate()
        let settings = try settings.normalized()
        try settings.validate()
        var result = DeliveryResult()
        guard settings.enabled else { result.skipped = true; return result }
        try await reconcileServerAutomatically(storage: storage, settings: settings, credential: credential,
            transport: transport, force: force, reconcileNow: reconcileNow, now: now, debugLog: debugLog)
        let root = storage.stateRoot.resolvingSymlinksInPath().standardizedFileURL
        guard activeDeliveryRoots.insert(root.path).inserted else {
            throw RelayError.setup("A delivery drain is already uploading this library.")
        }
        defer { activeDeliveryRoots.remove(root.path) }
        let database = PrototypeProfile.fixture(at: root).database
        var ledger = try DeliveryLedger.load(stateRoot: root)
        let settingsHash = try settings.settingsHash()
        guard FileManager.default.fileExists(atPath: database.path) else { return result }
        let store = try PipelineStore(databaseURL: database)
        if ledger.destinationURL != settings.feedFolderURL {
            // Preserve copies at the old destination; never delete them on a new host.
            ledger.pendingRemoteDeletes = []
            ledger.destinationURL = settings.feedFolderURL
            ledger.remoteFeedPending = true
        }
        if ledger.settingsHash != settingsHash { ledger.remoteFeedPending = true }
        if ledger.settingsHash != settingsHash || force {
            // Explicit upload retries also recover saved size-verification failures and
            // password changes, which never enter the settings hash.
            for var episode in try store.published()
                where episode.localAudioDiscarded != true && episode.delivery?.status == .failed && ledger.blockedServerIDs?.contains(episode.id) != true
                    && ((force && episode.delivery?.verificationFailed == true)
                        || [DeliveryError.authNotice, DeliveryError.permissionNotice, DeliveryError.verificationNotice].contains(episode.delivery?.lastError ?? "")) {
                episode.delivery?.status = .pending
                episode.delivery?.attempts = 0
                episode.delivery?.lastError = nil
                episode.delivery?.verificationFailed = nil
                episode.delivery?.nextAttemptAt = nil
                try store.save(episode)
            }
            ledger.settingsHash = settingsHash
            ledger.lastError = nil
            ledger.feedAttempts = 0
            try ledger.save(stateRoot: root)
        }
        // Resolve durable intent and metadata-only feed changes locally before
        // touching credentials or the server. Backed-off work is not due yet.
        let episodes = try store.episodes()
        var ledgerChanged = Self.reconcileRemoteDeletes(episodes, settings: settings, ledger: &ledger)
        let published = episodes.filter { $0.stage == .published }
        if !ledger.remoteFeedPending,
           let candidate = try? RSS.renderReconciledRemote(published, channel: RemoteChannel(settings: settings), preserved: ledger.preservedServerItems ?? []),
           ledger.lastUploadedFeedHash != Files.hash(candidate) {
            ledger.remoteFeedPending = true
            ledgerChanged = true
        }
        if ledgerChanged { try ledger.save(stateRoot: root) }
        let mediaDue = published.contains { episode in
            guard episode.localAudioDiscarded != true else { return false }
            guard let delivery = episode.delivery else { return true }
            if delivery.status == .uploaded && (delivery.destinationURL != settings.feedFolderURL
                || delivery.remotePath != settings.remoteMediaPath(episode.id)) { return true }
            return delivery.status == .pending && (force || delivery.nextAttemptAt == nil || delivery.nextAttemptAt! <= now)
        }
        let hasFeedContent = !published.isEmpty || ledger.reconciledFeed != nil
            || !(ledger.preservedServerItems ?? []).isEmpty || !ledger.pendingRemoteDeletes.isEmpty
        let feedPending = hasFeedContent && (ledger.remoteFeedPending || ledger.lastUploadedFeedHash == nil)
        let feedDue = feedPending && (force || ledger.feedAttempts == 0 || ledger.lastAttemptAt == nil
            || now >= ledger.lastAttemptAt! + Self.deliveryBackoff(ledger.feedAttempts))
        let deletesDue = !feedPending && !ledger.pendingRemoteDeletes.isEmpty
        guard force || mediaDue || feedDue || deletesDue else {
            try releaseTemporaryAudio(storage: storage, settings: settings, continueOnFailure: true, debugLog: debugLog)
            return result
        }
        let client: WebDAVClient
        do {
            client = try WebDAVClient(transport: transport, settings: settings, credential: credential, debugLog: debugLog)
            try await client.ensureCollections()
        } catch let error as CancellationError {
            throw error
        } catch {
            debugLog?.recordFailure(error)
            ledger.lastError = Self.deliveryNotice(error)
            ledger.lastAttemptAt = now
            try ledger.save(stateRoot: root)
            let notice: String?
            switch error as? DeliveryError {
            case .authFailed, .credentialUnavailable: notice = DeliveryError.authNotice
            case .permissionDenied: notice = DeliveryError.permissionNotice
            default: notice = nil
            }
            if let notice {
                for var episode in try store.published() where episode.localAudioDiscarded != true && episode.delivery?.status == .pending {
                    episode.delivery?.status = .failed
                    episode.delivery?.lastError = notice
                    episode.delivery?.lastAttemptAt = now
                    try store.save(episode)
                    result.failed += 1
                }
            }
            return result
        }
        // Media uploads first; the remote feed only references confirmed bytes.
        for var episode in try store.published() {
            try Task.checkCancellation()
            if episode.localAudioDiscarded == true {
                if episode.delivery?.status == .uploaded && episode.delivery?.destinationURL != settings.feedFolderURL {
                    episode.delivery?.status = .pending; try store.save(episode)
                }
                continue
            }
            if ledger.blockedServerIDs?.contains(episode.id) == true { result.failed += 1; continue }
            var delivery = episode.delivery ?? DeliveryState(status: .pending, remotePath: settings.remoteMediaPath(episode.id))
            let expectedPath = settings.remoteMediaPath(episode.id)
            if delivery.status == .uploaded && (delivery.destinationURL != settings.feedFolderURL || delivery.remotePath != expectedPath) {
                delivery.status = .pending
                delivery.uploadedByteLength = nil
                delivery.attempts = 0; delivery.nextAttemptAt = nil; delivery.lastError = nil; delivery.verificationFailed = nil
            }
            guard delivery.status == .pending else { continue }
            // A pending copy follows the configured folder and host. Persist provenance
            // before the request, including partially uploaded copies that fail verification.
            delivery.remotePath = expectedPath
            delivery.destinationURL = settings.feedFolderURL
            episode.delivery = delivery
            try store.save(episode)
            guard force || delivery.nextAttemptAt == nil || delivery.nextAttemptAt! <= now else { continue }
            delivery.attempts += 1
            delivery.lastAttemptAt = now
            let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
            let progressEpisode = episode
            let verificationStage = UploadVerificationStage()
            progress?(UploadProgress(episode: episode, phase: .verifyingLocal))
            do {
                // Verify the exact committed bytes before any network write; a
                // substituted file fails the delivery rather than uploading it.
                switch audioAvailability(episode) {
                case .available:
                    guard let hash = episode.audioHash, episode.info != nil,
                          (try? Files.hash(file, description: "audio awaiting upload")) == hash else {
                        throw DeliveryError.fatal("Published media changed before upload; its remote copy was not replaced.")
                    }
                case .missing:
                    throw DeliveryError.fatal("Published media is missing; its remote copy was not replaced.")
                case .unavailable:
                    throw DeliveryError.retryable("The audio folder for this item is unavailable; upload retries when it returns.")
                }
                // A deferred scan must not overwrite an unseen existing copy.
                progress?(UploadProgress(episode: episode, phase: .verifyingServer))
                let head = try await client.audioMetadata(id: episode.id)
                if head.status != 404 {
                    guard let digest = try await client.recoveryDigest(id: episode.id, maximumBytes: 512 * 1024 * 1024),
                          digest.sha256 == episode.audioHash, digest.byteLength == episode.info?.byteLength else {
                        throw DeliveryError.retryable("An existing copy needs reconciliation; other uploads continue.")
                    }
                } else {
                    verificationStage.verifying = false
                    progress?(UploadProgress(episode: episode, phase: .transferring))
                    let receipt = try await client.uploadFile(file, remotePath: delivery.remotePath, onlyIfMissing: true,
                        progress: { sent, total in progress?(UploadProgress(episode: progressEpisode, phase: .transferring, sentBytes: sent, totalBytes: total)) },
                        verifying: { verificationStage.verifying = true; progress?(UploadProgress(episode: progressEpisode, phase: .verifyingServer)) })
                    verificationStage.verifying = true
                    guard let hash = episode.audioHash, let info = episode.info else { throw ServerFeedParser.failure }
                    let digest: RemoteAudioDigest
                    if Self.representationHash(receipt.header("repr-digest")) == hash {
                        digest = RemoteAudioDigest(status: 200, byteLength: info.byteLength, sha256: hash, etag: receipt.header("etag"))
                    } else {
                        guard let checked = try await client.recoveryDigest(id: episode.id, maximumBytes: info.byteLength),
                              checked.sha256 == hash, checked.byteLength == info.byteLength else {
                            throw DeliveryError.retryable("The uploaded media hash could not be confirmed; other uploads continue.")
                        }
                        digest = checked
                    }
                    ledger.serverAudioProofs = ledger.serverAudioProofs ?? [:]
                    ledger.serverAudioProofs?[episode.id] = ServerAudioProof(hash: hash, info: info, etag: digest.etag, checkedAt: now)
                }
                delivery.status = .uploaded
                delivery.verificationFailed = nil
                delivery.destinationURL = settings.feedFolderURL
                delivery.uploadedByteLength = episode.info?.byteLength
                delivery.lastError = nil
                delivery.nextAttemptAt = nil
                episode.delivery = delivery
                try store.save(episode)
                ledger.remoteFeedPending = true
                result.uploadedMedia += 1
                progress?(UploadProgress(episode: episode, phase: .publishing))
            } catch let error as CancellationError {
                throw error
            } catch let failure as DeliveryError {
                delivery.verificationFailed = verificationStage.verifying
                debugLog?.recordFailure(failure)
                switch failure {
                case .authFailed, .credentialUnavailable:
                    delivery.status = .failed
                    delivery.lastError = DeliveryError.authNotice
                    delivery.nextAttemptAt = nil
                    result.failed += 1
                case .permissionDenied(let message):
                    delivery.status = .failed
                    delivery.lastError = message
                    delivery.nextAttemptAt = nil
                    result.failed += 1
                case .retryable(let message):
                    delivery.status = .pending
                    delivery.lastError = message
                    delivery.nextAttemptAt = now + Self.deliveryBackoff(delivery.attempts)
                    result.retrying += 1
                case .fatal(let message):
                    delivery.status = .failed
                    delivery.lastError = message
                    delivery.nextAttemptAt = nil
                    result.failed += 1
                }
                episode.delivery = delivery
                try store.save(episode)
                ledger.remoteFeedPending = true
                ledger.lastError = delivery.lastError
            } catch {
                debugLog?.recordFailure(error)
                delivery.status = .pending
                delivery.lastError = "One media copy could not be synchronized; other items continued."
                delivery.nextAttemptAt = now + Self.deliveryBackoff(delivery.attempts)
                episode.delivery = delivery; try store.save(episode)
                delivery.verificationFailed = verificationStage.verifying
                episode.delivery = delivery; try store.save(episode)
                ledger.lastError = delivery.lastError; result.retrying += 1
            }
            if delivery.lastError != nil { progress?(UploadProgress(episode: episode, phase: delivery.verificationFailed == true ? .verificationFailed : .failed)) }
        }
        try ledger.save(stateRoot: root)
        // Self-heal remote-delete intent from durable episode records: a crash between
        // the retire commit and the ledger write must not strand remote media, and a
        // lost rescind must not delete a copy that is listed again.
        let reconciled = Self.reconcileRemoteDeletes(try store.episodes(), settings: settings, ledger: &ledger)
        if reconciled { try ledger.save(stateRoot: root) }
        // Metadata-only changes (including recovered Reading List dates) need a
        // fresh feed even when every audio copy was already confirmed.
        if let candidate = try? RSS.renderReconciledRemote(store.published(), channel: RemoteChannel(settings: settings), preserved: ledger.preservedServerItems ?? []),
           ledger.lastUploadedFeedHash != Files.hash(candidate), !ledger.remoteFeedPending {
            ledger.remoteFeedPending = true
            try ledger.save(stateRoot: root)
        }
        // Feed update gates remote deletes: a failed upload never strands listed media.
        // feedAttempts backs off retries of a failed upload; fresh pending work is due.
        if hasFeedContent && (ledger.remoteFeedPending || ledger.lastUploadedFeedHash == nil) && ledger.serverFeedUnsafe != true {
            let feedDue = force || ledger.feedAttempts == 0 || ledger.lastAttemptAt == nil
                || now >= ledger.lastAttemptAt! + Self.deliveryBackoff(ledger.feedAttempts)
            if feedDue {
                do {
                    let channel = try RemoteChannel(settings: settings)
                    let published = try store.published()
                    let feed = try RSS.renderReconciledRemote(published, channel: channel, preserved: ledger.preservedServerItems ?? [])
                    let etag = ledger.reconciledFeedETag.flatMap { Self.strongETag($0) ? $0 : nil }
                    if etag == nil {
                        let current = try await client.readRecoveryFeed()
                        guard current == ledger.reconciledFeed else { throw DeliveryError.retryable("The server feed changed; reconciliation will retry before publishing it.") }
                    }
                    try await client.publishFeed(feed, ifMatch: etag, onlyIfMissing: ledger.reconciledFeed == nil)
                    ledger.lastUploadedFeedHash = Files.hash(feed)
                    ledger.lastPublishedAudioHashes = Dictionary(uniqueKeysWithValues: published.compactMap { episode in
                        guard episode.delivery?.status == .uploaded, let hash = episode.audioHash else { return nil }
                        return (episode.id, hash)
                    })
                    ledger.lastPublishedSettingsHash = try settings.publicationHash()
                    ledger.remoteFeedPending = false
                    ledger.feedAttempts = 0
                    ledger.lastError = nil
                    ledger.lastAttemptAt = now
                    ledger.reconciledFeed = feed; ledger.reconciledFeedETag = nil
                    try ledger.save(stateRoot: root)
                    result.feedUploaded = true
                } catch let error as CancellationError {
                    throw error
                } catch {
                    debugLog?.recordFailure(error)
                    ledger.lastError = Self.deliveryNotice(error)
                    ledger.feedAttempts += 1
                    ledger.lastAttemptAt = now
                    try ledger.save(stateRoot: root)
                }
            }
        }
        if !ledger.remoteFeedPending && ledger.serverFeedUnsafe != true && !ledger.pendingRemoteDeletes.isEmpty {
            for path in ledger.pendingRemoteDeletes {
                do {
                    try Task.checkCancellation()
                    try await client.delete(remotePath: path)
                    ledger.pendingRemoteDeletes.removeAll { $0 == path }
                    // Clearing the retired record's path is the durable marker that the
                    // remote copy is gone; reconciliation never re-queues an empty path.
                    if var owner = try store.episodes().first(where: { $0.stage == .expired && $0.delivery?.remotePath == path }) {
                        owner.delivery?.remotePath = ""
                        owner.delivery?.lastError = nil
                        try store.save(owner)
                    }
                    result.remoteDeletes += 1
                } catch let error as CancellationError {
                    try? ledger.save(stateRoot: root)
                    throw error
                } catch {
                    debugLog?.recordFailure(error)
                    ledger.lastError = Self.deliveryNotice(error)
                    for var owner in try store.episodes() where owner.stage == .expired && owner.delivery?.remotePath == path {
                        owner.delivery?.lastError = ledger.lastError
                        try store.save(owner)
                    }
                }
            }
            try ledger.save(stateRoot: root)
        }
        try releaseTemporaryAudio(storage: storage, settings: settings, continueOnFailure: true, debugLog: debugLog)
        ledger.lastError = ledger.lastError ?? ledger.reconciliationError
        try ledger.save(stateRoot: root)
        return result
    }
}
