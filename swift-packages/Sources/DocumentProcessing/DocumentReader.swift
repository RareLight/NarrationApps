import NarrationCore
import Foundation
import AppKit
import PDFKit

public enum DocumentReader {
    public static func readSemantic(_ document: InputDocument, describeImages: Bool = false,
                                    recognize: PDFDocumentExtractor.Recognition? = nil,
                                    progress: @escaping @Sendable (DocumentPreparationProgress) -> Void = { _ in }) async throws -> SemanticDocument {
        try Task.checkCancellation()
        progress(.init(stage: .readingFile))
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: document.source, options: [], error: &coordinationError) { url in
            result = Result {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 512_000_000 else { throw DocumentProcessingError.extraction("This file exceeds the document byte budget.") }
                return try Data(contentsOf: url)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DocumentReadError.malformed }
        let data = try result.get()
        let title = document.source.deletingPathExtension().lastPathComponent
        let semantic: SemanticDocument
        switch document.kind {
        case .pdf:
            semantic = try await PDFDocumentExtractor.extract(data: data, title: title, recognize: recognize, progress: progress)
        case .epub:
            return try await EPUBDocumentExtractor.extract(data: data, title: title, describeImages: describeImages, progress: progress)
        case .text:
            let decoded = try DocumentTextDecoder.decode(data, choice: document.textEncoding)
            semantic = .init(title: title, blocks: try plainTextBlocks(decoded.text), warnings: decoded.warnings, extractorVersion: "Foundation-text-3/encoding-1/paragraphs-1")
        case .markdown:
            let decoded = try DocumentTextDecoder.decode(data, choice: document.textEncoding)
            let text = decoded.text
            let parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .throwError),
                                              baseURL: document.source.deletingLastPathComponent())
            semantic = .init(title: title, blocks: markdownBlocks(parsed), warnings: decoded.warnings, extractorVersion: "Foundation-Markdown-semantic-2/encoding-1/inline-code-1")
        case .rtf:
            guard data.starts(with: Data(#"{\rtf"#.utf8)) else { throw DocumentReadError.malformed }
            let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            semantic = .init(title: title, blocks: [.init(kind: .paragraph, text: attributed.string.replacingOccurrences(of: "\u{fffc}", with: ""), origin: .authored)], extractorVersion: "Foundation-RTF-1")
        }
        guard semantic.blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw DocumentReadError.emptyText }
        let parent = document.source.deletingLastPathComponent().resolvingSymlinksInPath()
        return try await DocumentImages.enrich(semantic, pdfData: document.kind == .pdf ? data : nil, enabled: describeImages, progress: progress,
            fetch: { url in
                guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(parent.path + "/"),
                      url.resolvingSymlinksInPath() == url.standardizedFileURL,
                      (try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).isRegularFile == true,
                      (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 2_000_000 else { throw DocumentReadError.malformed }
                return try Data(contentsOf: url)
            })
    }

    /// Blank lines are authored paragraph boundaries. Keep their exact separators in
    /// the preceding block so concatenating retained blocks reconstructs the text.
    /// A single newline remains inside its paragraph (including verse/list lines).
    static func plainTextBlocks(_ text: String) throws -> [ContentBlock] {
        let expression = try NSRegularExpression(pattern: #"(?>\r\n|[\r\n])(?:[ \t]*(?>\r\n|[\r\n]))+"#)
        let ns = text as NSString
        var ends: [Int] = [], exceeded = false
        expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            if let match {
                if ends.count >= 100_000 { exceeded = true; stop.pointee = true; return }
                ends.append(NSMaxRange(match.range))
            }
        }
        try Task.checkCancellation()
        guard !exceeded else { throw DocumentProcessingError.extraction("The text exceeds the paragraph budget. No text was truncated.") }
        var blocks: [ContentBlock] = [], start = 0, cursor = 0
        for end in ends + [ns.length] where end > cursor {
            try Task.checkCancellation()
            let part = ns.substring(with: NSRange(location: cursor, length: end - cursor))
            cursor = end
            if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.init(kind: .paragraph, text: ns.substring(with: NSRange(location: start, length: end - start)), origin: .authored)); start = end
            }
        }
        // A trailing whitespace-only remainder still belongs to the last block.
        if start < ns.length, let last = blocks.popLast() {
            blocks.append(.init(kind: .paragraph, text: last.text + ns.substring(from: start), origin: .authored))
        }
        return blocks
    }

    public static func bookCover(_ document: InputDocument) throws -> Data? {
        guard document.kind == .epub || document.kind == .pdf else { return nil }
        try Task.checkCancellation()
        var error: NSError?, result: Result<Data?, Error>?
        NSFileCoordinator().coordinate(readingItemAt: document.source, options: [], error: &error) { url in
            result = Result {
                guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 512_000_000 else { throw DocumentReadError.malformed }
                if document.kind == .pdf { return try PDFCoverImage.read(url) }
                return try EPUBDocumentExtractor.coverImage(data: Data(contentsOf: url))
            }
        }
        if let error { throw error }
        guard let result else { throw DocumentReadError.malformed }
        return try result.get()
    }

    public static func decodeText(_ data: Data, encoding: TextFileEncoding = .automatic) throws -> String {
        try DocumentTextDecoder.decode(data, choice: encoding).text
    }

    public static func markdownBlocks(_ parsed: AttributedString) -> [ContentBlock] {
        var blocks: [ContentBlock] = [], current = "", identity: Int?, kind: ContentBlock.Kind = .paragraph, level: Int?, containsInlineCode = false
        func flush() {
            if !current.isEmpty { blocks.append(.init(kind: kind, text: current, headingLevel: level, origin: .authored, containsInlineCode: containsInlineCode)) }
            current = ""; containsInlineCode = false
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters).replacingOccurrences(of: "\u{fffc}", with: "")
            if let image = run.imageURL {
                flush()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.init(kind: .caption, text: text, narrationText: "Image description: " + text, imageURL: image, origin: .authored))
                }
                continue
            }
            let component = run.presentationIntent?.components.first
            if component?.identity != identity { flush(); identity = component?.identity }
            containsInlineCode = containsInlineCode || run.inlinePresentationIntent?.contains(.code) == true
            kind = .paragraph; level = nil
            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let value): kind = .heading; level = value
                    case .listItem: kind = .listItem
                    case .codeBlock: kind = .code
                    case .blockQuote: kind = .quote
                    case .table: kind = .table
                    default: break
                    }
                }
            }
            current += text
        }
        flush()
        return blocks
    }

    /// A coordinated read makes File Provider failures explicit; bytes are never
    /// interpreted as an empty document after a read/coordination failure.
    public static func read(_ document: InputDocument) throws -> String {
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: document.source, options: [], error: &coordinationError) { url in
            result = Result { try extract(url, kind: document.kind, encoding: document.textEncoding) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DocumentReadError.malformed }
        let text = NarrationText.clean(try result.get())
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentReadError.emptyText }
        return text
    }

    private static func extract(_ url: URL, kind: DocumentKind, encoding: TextFileEncoding) throws -> String {
        switch kind {
        case .text, .markdown:
            let data = try Data(contentsOf: url)
            let text = try decodeText(data, encoding: encoding)
            if kind == .text { return text }
            let parsed = try AttributedString(markdown: text,
                options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
            return projectMarkdown(parsed)
        case .rtf:
            let data = try Data(contentsOf: url)
            guard data.starts(with: Data("{\\rtf".utf8)) else { throw DocumentReadError.malformed }
            let parsed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return parsed.string.replacingOccurrences(of: "\u{fffc}", with: "")
        case .epub:
            return try EPUBDocumentExtractor.read(data: Data(contentsOf: url), title: url.deletingPathExtension().lastPathComponent)
                .document.blocks.map(\.text).joined(separator: "\n\n")
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
