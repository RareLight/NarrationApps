import Foundation

public enum DocumentReadError: Error, LocalizedError {
    case invalidUTF8, malformed, encryptedPDF, emptyPDF, emptyText
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "Text must be encoded as UTF-8 or UTF-16 with a byte-order mark."
        case .malformed: "This document could not be read in its declared format."
        case .encryptedPDF: "This PDF is password protected. Save an unlocked copy first."
        case .emptyPDF: "No readable PDF text could be extracted or recognized."
        case .emptyText: "This document contains no narration text after cleanup."
        }
    }
}
