import Foundation
import CryptoKit
import CoreFoundation

/// Version 1 structural JSON digest. Object order is immaterial; array order,
/// types and exact string bytes are retained. Length prefixes prevent ambiguity.
/// Foundation's sortedKeys uses collation ties for some vocabulary keys, so its
/// serialized byte order cannot identify freshly generated tokenizers reliably.
package enum NativeJSONDigest {
    package static func sha256(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16_777_216 else { throw NativeAssetError.invalid("generated JSON size") }
        return try sha256(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }
    package static func sha256(_ value: Any) throws -> String {
        var digest = SHA256()
        func append(_ text: String) { digest.update(data: Data(text.utf8)) }
        func scalar(_ tag: String, _ text: String) { append(tag + String(text.utf8.count) + ":"); append(text) }
        func visit(_ value: Any, depth: Int) throws {
            guard depth <= 64 else { throw NativeAssetError.invalid("generated JSON depth") }
            if value is NSNull { append("z") }
            else if let string = value as? String { scalar("s", string) }
            else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { append(number.boolValue ? "t" : "f") }
                else {
                    guard number.doubleValue.isFinite else { throw NativeAssetError.invalid("generated JSON number") }
                    scalar("n", number.stringValue)
                }
            } else if let object = value as? [String: Any] {
                append("o" + String(object.count) + ":")
                for key in object.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    scalar("s", key); try visit(object[key]!, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                append("a" + String(array.count) + ":")
                for item in array { try visit(item, depth: depth + 1) }
            } else { throw NativeAssetError.invalid("generated JSON value") }
        }
        append("generated-json-structure-1:")
        try visit(value, depth: 0)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
