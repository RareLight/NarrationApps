import Foundation
import AppKit
import PDFKit
import NarrationCore

public struct PDFExtractionLimits: Sendable {
    public var maximumPages: Int
    public var maximumOCRPages: Int
    public var maximumTextBytes: Int
    public var ocrSeconds: Double
    public init(maximumPages: Int = 10_000, maximumOCRPages: Int = 1_000, maximumTextBytes: Int = 32_000_000, ocrSeconds: Double = 1_200) {
        self.maximumPages = maximumPages; self.maximumOCRPages = maximumOCRPages
        self.maximumTextBytes = maximumTextBytes; self.ocrSeconds = ocrSeconds
    }
    public static let article = PDFExtractionLimits(maximumPages: 500, maximumOCRPages: 50, maximumTextBytes: 2_000_000, ocrSeconds: 120)
}

public enum PDFExtractionError: Error, LocalizedError, Sendable {
    case restricted, pageLimit, ocrLimit, textLimit
    public var errorDescription: String? {
        switch self {
        case .restricted: "The PDF does not allow text access."
        case .pageLimit: "The PDF exceeds the selected document page budget."
        case .ocrLimit: "The PDF exceeds the selected OCR budget. No partial recording was published."
        case .textLimit: "The document exceeds the text budget."
        }
    }
}

public enum PDFDocumentExtractor {
    public static let version = "PDFKit/RecognizeDocuments-1"
    public typealias Recognition = @Sendable (CGImage) async throws -> [ContentBlock]

    public static func extract(data: Data, title: String? = nil, limits: PDFExtractionLimits = .init(),
                               forceOCR: Bool = false, recognize: Recognition? = nil,
                               progress: @escaping @Sendable (DocumentPreparationProgress) -> Void = { _ in }) async throws -> SemanticDocument {
        try Task.checkCancellation()
        guard limits.maximumPages > 0, limits.maximumOCRPages >= 0, limits.maximumTextBytes > 0,
              limits.ocrSeconds.isFinite, limits.ocrSeconds > 0,
              data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data) else { throw DocumentReadError.malformed }
        let pageCount = pdf.pageCount
        guard !pdf.isLocked else { throw DocumentReadError.encryptedPDF }
        guard pdf.allowsCopying || pdf.allowsContentAccessibility else { throw PDFExtractionError.restricted }
        guard pageCount <= limits.maximumPages else { throw PDFExtractionError.pageLimit }
        progress(.init(stage: .readingPDFStructure))
        let alternatives = PDFImageMetadata.alternatives(pdf)
        var blocks: [ContentBlock] = [], totalBytes = 0, ocrPages = 0
        let deadline = ProcessInfo.processInfo.systemUptime + limits.ocrSeconds
        for index in 0..<pageCount {
            try Task.checkCancellation()
            progress(.init(stage: .extractingText, completed: index, total: pageCount, currentPage: index + 1))
            guard let page = pdf.page(at: index) else { throw DocumentReadError.malformed }
            var text = (page.string ?? "").replacingOccurrences(of: "\u{fffc}", with: "")
            let authored = alternatives[index] ?? []
            let authoredKeys = Set(authored.map(NarrationText.normalizeWhitespace))
            text = text.components(separatedBy: .newlines).filter { !authoredKeys.contains(NarrationText.normalizeWhitespace($0)) }.joined(separator: "\n")
            let scalars = text.unicodeScalars
            let usable = scalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            let broken = scalars.filter { $0.value == 0xfffd || ($0.value < 32 && !CharacterSet.whitespacesAndNewlines.contains($0)) }.count
            let needsOCR = forceOCR || usable == 0 || (PDFImageMetadata.hasImage(page) && usable < 80) || broken * 20 > max(scalars.count, 1)
            let pageBlocks: [ContentBlock]
            if needsOCR {
                guard ocrPages < limits.maximumOCRPages, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw PDFExtractionError.ocrLimit
                }
                progress(.init(stage: .renderingOCR, completed: index, total: pageCount, currentPage: index + 1))
                let image = try autoreleasepool { try render(page) }
                if let recognize {
                    progress(.init(stage: .recognizingText, completed: index, total: pageCount, currentPage: index + 1))
                    pageBlocks = try await recognize(image)
                } else {
                    progress(.init(stage: .waitingForOCR, completed: index, total: pageCount, currentPage: index + 1))
                    pageBlocks = try await StructuredDocumentOCR.recognize(image, onInferenceAcquired: {
                        progress(.init(stage: .recognizingText, completed: index, total: pageCount, currentPage: index + 1))
                    })
                }

                try Task.checkCancellation()
                ocrPages += 1
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw PDFExtractionError.ocrLimit }
            } else {
                pageBlocks = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
                    .map(NarrationText.normalizeWhitespace).filter { !$0.isEmpty }.map { .init(kind: .paragraph, text: $0, origin: .authored) }
            }
            for block in pageBlocks {
                totalBytes += block.text.utf8.count
                guard totalBytes <= limits.maximumTextBytes else { throw PDFExtractionError.textLimit }
                blocks.append(.init(kind: block.kind, text: block.text, headingLevel: block.headingLevel, narrationText: block.narrationText,
                                    footnoteReferences: block.footnoteReferences, footnoteID: block.footnoteID, pdfPageIndex: index,
                                    origin: needsOCR ? .ocr : .authored))
            }
            for caption in authored {
                blocks.append(.init(kind: .caption, text: caption, narrationText: "Image description: " + caption,
                                    pdfPageIndex: index, origin: .authored))
            }
            progress(.init(stage: .extractingText, completed: index + 1, total: pageCount))
        }
        guard blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw DocumentReadError.emptyPDF }
        let metadataTitle = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return .init(title: metadataTitle ?? title, author: pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, blocks: blocks,
                     warnings: ["Complex PDF reading order should be reviewed."] + (ocrPages > 0 ? ["Includes OCR text; review recognition accuracy."] : []),
                     extractorVersion: version)
    }

    public static func render(_ page: PDFPage, maximumDimension: CGFloat = 2200) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard maximumDimension.isFinite, (128...4096).contains(maximumDimension), bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { throw DocumentReadError.malformed }
        let scale = maximumDimension / max(bounds.width, bounds.height)
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DocumentReadError.malformed }
        return image
    }
}
