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
        case .text:
            semantic = .init(title: title, blocks: [.init(kind: .paragraph, text: try decodeText(data), origin: .authored)], extractorVersion: "Foundation-text-1")
        case .markdown:
            let text = try decodeText(data)
            let parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .throwError),
                                              baseURL: document.source.deletingLastPathComponent())
            semantic = .init(title: title, blocks: markdownBlocks(parsed), extractorVersion: "Foundation-Markdown-semantic-1")
        case .rtf:
            guard data.starts(with: Data("{\rtf".utf8)) else { throw DocumentReadError.malformed }
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

    public static func decodeText(_ data: Data) throws -> String {
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard var value = text else { throw DocumentReadError.invalidUTF8 }
        if value.hasPrefix("\u{feff}") { value.removeFirst() }
        return value
    }

    public static func markdownBlocks(_ parsed: AttributedString) -> [ContentBlock] {
        var blocks: [ContentBlock] = [], current = "", identity: Int?, kind: ContentBlock.Kind = .paragraph, level: Int?
        func flush() {
            if !current.isEmpty { blocks.append(.init(kind: kind, text: current, headingLevel: level, origin: .authored)) }
            current = ""
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
