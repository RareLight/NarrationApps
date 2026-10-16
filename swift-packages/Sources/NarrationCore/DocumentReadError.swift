import Foundation

public enum DocumentReadError: Error, LocalizedError {
    case invalidUTF8, malformed, encryptedPDF, emptyPDF, emptyText
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "This file could not be decoded as readable text. Choose its Text Encoding, or export a Unicode copy."
        case .malformed: "This document could not be read in its declared format."
        case .encryptedPDF: "This PDF is password protected. Save an unlocked copy first."
        case .emptyPDF: "No readable PDF text could be extracted or recognized."
        case .emptyText: "This document contains no narration text after cleanup."
        }
    }
}
