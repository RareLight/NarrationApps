import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum VoiceServerCredentialFailure: Error, LocalizedError, Sendable {
    case unavailable, invalid, random
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The VoiceServer API key is unavailable in Keychain. Use the normally signed VoiceRelay app and retry."
        case .invalid: "The saved VoiceServer API key is invalid. Generate a new key in VoiceServer settings."
        case .random: "A secure API key could not be generated. Retry."
        }
    }
}

public protocol VoiceServerKeyStore: Sendable {
    func read() throws -> Data?
    func save(_ secret: Data) throws
}

public struct VoiceServerKeychain: VoiceServerKeyStore {
    static let service = "VoiceRelay VoiceServer API"
    private let operations: KeychainCredentialStore.Operations
    public init() { operations = .system }
    init(operations: KeychainCredentialStore.Operations) { self.operations = operations }
    private func query() -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "bearer-v1",
            kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context]
    }
    public func read() throws -> Data? {
        var query = query()
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = operations.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw VoiceServerCredentialFailure.unavailable }
        guard data.count == VoiceServerAuthentication.secretBytes else { throw VoiceServerCredentialFailure.invalid }
        return data
    }
    public func save(_ secret: Data) throws {
        guard secret.count == VoiceServerAuthentication.secretBytes else { throw VoiceServerCredentialFailure.invalid }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [], nil) else {
            throw VoiceServerCredentialFailure.unavailable
        }
        var attributes = query()
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessControl as String] = access
        let status = operations.add(attributes)
        if status == errSecDuplicateItem {
            guard operations.update(query(), [kSecValueData as String: secret, kSecAttrAccessControl as String: access]) == errSecSuccess else {
                throw VoiceServerCredentialFailure.unavailable
            }
        } else if status != errSecSuccess { throw VoiceServerCredentialFailure.unavailable }
    }
}

/// Shared across HTTP event loops. The key itself never enters configuration,
/// diagnostics or the request queue. A generation identifies revocable grants.
public final class VoiceServerAuthentication: @unchecked Sendable {
    public static let secretBytes = 32
    private let lock = NSLock()
    private var digest: [UInt8]?
    private var generation = UUID()
    public init() {}
    public static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: secretBytes)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, secretBytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VoiceServerCredentialFailure.random }
        return Data(bytes)
    }
    /// Call only for an explicit Copy action or to install an in-memory verifier.
    public static func presentation(_ secret: Data) throws -> String {
        guard secret.count == secretBytes else { throw VoiceServerCredentialFailure.invalid }
        return "vs_" + secret.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    @discardableResult public func install(_ secret: Data?) throws -> UUID {
        let digest = try secret.map { Array(SHA256.hash(data: Data(try Self.presentation($0).utf8))) }
        return lock.withLock {
            self.digest = digest; generation = UUID(); return generation
        }
    }
    public var isConfigured: Bool { lock.withLock { digest != nil } }
    public func isCurrent(_ grant: UUID) -> Bool { lock.withLock { digest != nil && generation == grant } }
    public func authorize(_ header: String?) -> UUID? {
        guard let header, header.utf8.count <= 128 else { return nil }
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, String(fields[0]).caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let supplied = Array(SHA256.hash(data: Data(fields[1].utf8)))
        return lock.withLock {
            guard let digest else { return nil }
            var difference: UInt8 = 0
            for index in 0..<digest.count { difference |= digest[index] ^ supplied[index] }
            return difference == 0 ? generation : nil
        }
    }
}

/// Cancellation wakes synchronous bounded writes without blocking a UI or HTTP
/// event loop. Hooks run outside the lock and must not retain request bodies.
public final class VoiceServerRequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var hooks: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func check() throws { if isCancelled { throw CancellationError() } }
    public func cancel() {
        let pending = lock.withLock { cancelled = true; return Array(hooks.values) }
        for hook in pending { hook() }
    }
    @discardableResult public func onCancel(_ hook: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let stopped = lock.withLock { hooks[id] = hook; return cancelled }
        if stopped { hook() }
        return id
    }
    public func removeHook(_ id: UUID) { _ = lock.withLock { hooks.removeValue(forKey: id) } }
}
