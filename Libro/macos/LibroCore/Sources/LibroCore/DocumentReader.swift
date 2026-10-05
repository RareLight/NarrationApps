import Foundation
import AppKit
import PDFKit

public enum DocumentReadError: Error, LocalizedError {
    case invalidUTF8, malformed, encryptedPDF, emptyPDF, emptyText
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "Text must be encoded as UTF-8. Save a UTF-8 copy and try again."
        case .malformed: "This document could not be read in its declared format."
        case .encryptedPDF: "This PDF is password protected. Save an unlocked copy first."
        case .emptyPDF: "No extractable PDF text. Scanned-PDF OCR is not supported."
        case .emptyText: "This document contains no narration text after cleanup."
        }
    }
}

public enum DocumentReader {
    /// A coordinated read makes File Provider failures explicit; bytes are never
    /// interpreted as an empty document after a read/coordination failure.
    public static func read(_ document: InputDocument) throws -> String {
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: document.source, options: [], error: &coordinationError) { url in
            result = Result { try extract(url, kind: document.kind) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DocumentReadError.malformed }
        let text = NarrationText.clean(try result.get())
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentReadError.emptyText }
        return text
    }

    private static func extract(_ url: URL, kind: DocumentKind) throws -> String {
        switch kind {
        case .text, .markdown:
            let data = try Data(contentsOf: url)
            guard var text = String(data: data, encoding: .utf8) else { throw DocumentReadError.invalidUTF8 }
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
            if kind == .text { return text }
            let parsed = try AttributedString(markdown: text,
                options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
            return projectMarkdown(parsed)
        case .rtf:
            let data = try Data(contentsOf: url)
            guard data.starts(with: Data("{\\rtf".utf8)) else { throw DocumentReadError.malformed }
            let parsed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return parsed.string.replacingOccurrences(of: "\u{fffc}", with: "")
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { throw DocumentReadError.malformed }
            guard !pdf.isLocked else { throw DocumentReadError.encryptedPDF }
            var pages: [String] = []
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { throw DocumentReadError.malformed }
                pages.append(page.string ?? "")
            }
            let text = pages.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentReadError.emptyPDF }
            return text
        }
    }

    /// Foundation strips block separators from `.characters`. Presentation
    /// intent identities preserve paragraphs/headings/list items without a parser.
    public static func projectMarkdown(_ parsed: AttributedString) -> String {
        var text = ""
        var previousBlock: Int?
        for run in parsed.runs {
            let block = run.presentationIntent?.components.first?.identity
            if !text.isEmpty, let block, let previousBlock, block != previousBlock { text += "\n\n" }
            text += String(parsed[run.range].characters).replacingOccurrences(of: "\u{fffc}", with: "")
            if let block { previousBlock = block }
        }
        return text
    }
}
