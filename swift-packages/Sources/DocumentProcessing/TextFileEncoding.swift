import Foundation
import CoreFoundation
import NarrationCore

/// A per-input choice captured with the batch; original file bytes are never rewritten.
public enum TextFileEncoding: String, CaseIterable, Sendable, Codable {
    case automatic, utf8, utf16LittleEndian, utf16BigEndian, windows1252, macRoman, isoLatin1, dos437, shiftJIS, windows1251
    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .utf8: "Unicode (UTF-8)"
        case .utf16LittleEndian: "Unicode (UTF-16 Little Endian)"
        case .utf16BigEndian: "Unicode (UTF-16 Big Endian)"
        case .windows1252: "Western (Windows-1252)"
        case .macRoman: "Western (Mac Roman)"
        case .isoLatin1: "Western (ISO Latin 1)"
        case .dos437: "Western (DOS 437)"
        case .shiftJIS: "Japanese (Shift JIS)"
        case .windows1251: "Cyrillic (Windows-1251)"
        }
    }
    var encoding: String.Encoding? {
        switch self {
        case .automatic: nil
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .windows1252: .windowsCP1252
        case .macRoman: .macOSRoman
        case .isoLatin1: .isoLatin1
        case .dos437: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        case .shiftJIS: .shiftJIS
        case .windows1251: .windowsCP1251
        }
    }
}

struct DecodedDocumentText {
    let text: String
    let encoding: String.Encoding
    let inferred: Bool
    var warnings: [String] {
        inferred ? ["Text encoding was inferred as \(NSString.localizedName(of: encoding.rawValue)). Review accents and punctuation; use Text Encoding if they look incorrect."] : []
    }
}

/// Foundation performs character conversion. Detection is a best effort, never
/// lossy substitution; ambiguous historical code pages have an explicit override.
enum DocumentTextDecoder {
    static func decode(_ bytes: Data, choice: TextFileEncoding = .automatic) throws -> DecodedDocumentText {
        let value: String
        let encoding: String.Encoding
        var inferred = false
        if let selected = choice.encoding {
            encoding = selected
            guard let decoded = strictString(bytes, encoding: selected) else { throw DocumentReadError.invalidUTF8 }
            value = decoded
        } else if let marked = bomEncoding(bytes) {
            encoding = marked
            guard let decoded = strictString(bytes, encoding: marked) else { throw DocumentReadError.invalidUTF8 }
            value = decoded
        } else if let wide = unmarkedUTF16(bytes) {
            encoding = wide
            guard let decoded = strictString(bytes, encoding: wide) else { throw DocumentReadError.invalidUTF8 }
            value = decoded
        } else if let decoded = String(data: bytes, encoding: .utf8) {
            encoding = .utf8; value = decoded
        } else {
            var converted: NSString?, lossy = ObjCBool(false)
            let detected = NSString.stringEncoding(for: bytes, encodingOptions: [
                .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.macOSRoman.rawValue,
                    String.Encoding.isoLatin1.rawValue, String.Encoding.shiftJIS.rawValue, String.Encoding.windowsCP1251.rawValue],
                .useOnlySuggestedEncodingsKey: true, .allowLossyKey: false
            ], convertedString: &converted, usedLossyConversion: &lossy)
            guard detected != 0, !lossy.boolValue, let converted else { throw DocumentReadError.invalidUTF8 }
            encoding = .init(rawValue: detected); value = converted as String; inferred = true
        }
        var text = value
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        // DOS text commonly ends in an explicit EOF marker, not spoken prose.
        if text.last == "\u{001a}" { text.removeLast() }
        guard !text.unicodeScalars.contains(where: {
            $0.value == 0 || (CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value < 0xa0)
        }) else { throw DocumentReadError.invalidUTF8 }
        return .init(text: text, encoding: encoding, inferred: inferred)
    }

    private static func strictString(_ bytes: Data, encoding: String.Encoding) -> String? {
        // Foundation accepts an incomplete final UTF-16 code unit on this SDK.
        // Reject it rather than silently dropping a source byte during ingress.
        if [.utf16, .utf16LittleEndian, .utf16BigEndian].contains(encoding), !bytes.count.isMultiple(of: 2) { return nil }
        if [.utf32, .utf32LittleEndian, .utf32BigEndian].contains(encoding), !bytes.count.isMultiple(of: 4) { return nil }
        return String(data: bytes, encoding: encoding)
    }

    private static func bomEncoding(_ bytes: Data) -> String.Encoding? {
        if bytes.starts(with: [0xff, 0xfe, 0, 0]) { return .utf32LittleEndian }
        if bytes.starts(with: [0, 0, 0xfe, 0xff]) { return .utf32BigEndian }
        if bytes.starts(with: [0xff, 0xfe]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xfe, 0xff]) { return .utf16BigEndian }
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { return .utf8 }
        return nil
    }

    private static func unmarkedUTF16(_ bytes: Data) -> String.Encoding? {
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) else { return nil }
        let sample = Array(bytes.prefix(4096)), pairs = sample.count / 2
        let even = stride(from: 0, to: pairs * 2, by: 2).filter { sample[$0] == 0 }.count
        let odd = stride(from: 1, to: pairs * 2, by: 2).filter { sample[$0] == 0 }.count
        // ASCII-heavy UTF-16 has a clear empty high-byte lane. Arbitrary binary
        // still has to decode strictly and pass the printable-text check.
        if odd * 4 > pairs && even * 10 < pairs { return .utf16LittleEndian }
        if even * 4 > pairs && odd * 10 < pairs { return .utf16BigEndian }
        return nil
    }
}
