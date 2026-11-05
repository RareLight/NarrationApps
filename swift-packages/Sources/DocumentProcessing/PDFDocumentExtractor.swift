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
    public static let version = "PDFKit/RecognizeDocuments-2/layout-1/image-tables-1/table-flow-2"
    public typealias Recognition = @Sendable (CGImage) async throws -> [ContentBlock]
    public typealias Preview = @Sendable (PDFExtractionPreview) async throws -> Void

    public static func extract(data: Data, title: String? = nil, limits: PDFExtractionLimits = .init(),
                               forceOCR: Bool = false, recognize: Recognition? = nil,
                               preview: Preview? = nil,
                               monotonicTime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                               progress: @escaping @Sendable (DocumentPreparationProgress) -> Void = { _ in }) async throws -> SemanticDocument {
        try Task.checkCancellation()
        guard limits.maximumPages > 0, limits.maximumOCRPages >= 0, limits.maximumTextBytes > 0,
              limits.ocrSeconds.isFinite, limits.ocrSeconds > 0,
              data.starts(with: Data("%PDF-".utf8)) else { throw DocumentReadError.malformed }
        let (owned, pageCount, metadataTitle, author, alternatives) = try await NarrationPreparationWork.run {
            guard let pdf = PDFDocument(data: data) else { throw DocumentReadError.malformed }
            guard !pdf.isLocked else { throw DocumentReadError.encryptedPDF }
            guard pdf.allowsCopying || pdf.allowsContentAccessibility else { throw PDFExtractionError.restricted }
            guard pdf.pageCount <= limits.maximumPages else { throw PDFExtractionError.pageLimit }
            return (OwnedPDFDocument(pdf), pdf.pageCount, pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                    pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, PDFImageMetadata.alternatives(pdf))
        }
        progress(.init(stage: .readingPDFStructure))
        var blocks: [ContentBlock] = [], totalBytes = 0, ocrPages = 0, geometryLines = 0
        var geometrySkipped = Set<Int>(), tablePages = 0, tableRecognitionIncomplete = false
        // A small first prefix, then doubling prefixes: less than 3 full-document
        // equivalents of provisional planning, with backpressure from the reader.
        var nextPreviewPage = min(5, max(1, (pageCount + 19) / 20))
        func snapshot(outline: [DocumentOutlineEntry]? = nil, warnings: [String] = []) -> SemanticDocument {
            .init(title: metadataTitle ?? title, author: author, blocks: blocks,
                warnings: warnings + ["Complex PDF reading order should be reviewed."] +
                    (ocrPages > 0 ? ["Includes OCR text; review recognition accuracy."] : []) +
                    (tableRecognitionIncomplete ? ["Some image-table content could not be recognized within the analysis limits; narration identifies the original table."] : []) +
                    (geometrySkipped.isEmpty ? [] : ["Layout evidence unavailable for \(geometrySkipped.count) PDF pages; uncertain text is preserved."]),
                extractorVersion: version, outline: outline)
        }
        var ocrElapsed: TimeInterval = 0
        func recognizeImage(_ image: CGImage, context: DocumentPreparationProgress) async throws -> [ContentBlock] {
            let interval = PreparationInterval(now: monotonicTime)
            defer { interval.end(); ocrElapsed += interval.elapsed }
            if let recognize {
                progress(context.with(stage: .recognizingText)); interval.begin()
                return try await recognize(image)
            }
            progress(context.with(stage: .waitingForOCR))
            return try await StructuredDocumentOCR.recognize(image, onInferenceFinished: { interval.end() }, onInferenceAcquired: {
                interval.begin(); progress(context.with(stage: .recognizingText))
            })
        }
        for index in 0..<pageCount {
            try Task.checkCancellation()
            progress(.init(stage: .extractingText, completed: index, total: pageCount, currentPage: index + 1))
            let (page, text, needsOCR, hasImage, tableGeometry) = try await NarrationPreparationWork.run {
                guard let page = owned.document.page(at: index) else { throw DocumentReadError.malformed }
                var text = (page.string ?? "").replacingOccurrences(of: "\u{fffc}", with: "")
                let authored = alternatives[index] ?? []
                let authoredKeys = Set(authored.map(NarrationText.normalizeWhitespace))
                text = text.components(separatedBy: .newlines).filter { !authoredKeys.contains(NarrationText.normalizeWhitespace($0)) }.joined(separator: "\n")
                let scalars = text.unicodeScalars
                let usable = scalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                let broken = scalars.filter { $0.value == 0xfffd || ($0.value < 32 && !CharacterSet.whitespacesAndNewlines.contains($0)) }.count
                let image = PDFImageMetadata.hasImage(page)
                let needsOCR = forceOCR || usable == 0 || (image && usable < 80) || broken * 20 > max(scalars.count, 1)
                return (OwnedPDFPage(page), text, needsOCR, image,
                        page.rotation == 0 && page.bounds(for: .cropBox) == page.bounds(for: .mediaBox))
            }
            let authored = alternatives[index] ?? []
            var pageBlocks: [ContentBlock]
            if needsOCR {
                guard ocrPages < limits.maximumOCRPages, ocrElapsed < limits.ocrSeconds else {
                    throw PDFExtractionError.ocrLimit
                }
                progress(.init(stage: .renderingOCR, completed: index, total: pageCount, currentPage: index + 1))
                let image = try await NarrationPreparationWork.run { try autoreleasepool { try render(page.page) } }
                pageBlocks = try await recognizeImage(image, context: .init(stage: .waitingForOCR, completed: index, total: pageCount, currentPage: index + 1))

                try Task.checkCancellation()
                ocrPages += 1
                guard ocrElapsed < limits.ocrSeconds else { throw PDFExtractionError.ocrLimit }
            } else {
                progress(.init(stage: .reviewingPDFLayout, completed: index, total: pageCount, currentPage: index + 1))
                let remaining = PDFTextGeometry.maximumLines - geometryLines
                let capturedBytes = totalBytes
                let (mappedBlocks, geometryMissing) = try await NarrationPreparationWork.run {
                    let raw = try DocumentReader.plainTextBlocks(text)
                    let layouts = try autoreleasepool { try PDFTextGeometry.capture(page: page.page, text: text, blocks: raw, remaining: remaining) }
                    let mapped = raw.enumerated().map { position, block in
                        ContentBlock(kind: block.kind, text: block.text, origin: .authored, pdfLayout: layouts?[position])
                    }
                    guard mapped.reduce(capturedBytes, { $0 + $1.text.utf8.count }) <= limits.maximumTextBytes else { throw PDFExtractionError.textLimit }
                    return (mapped, layouts == nil)
                }
                if geometryMissing { geometrySkipped.insert(index) }
                pageBlocks = mappedBlocks
                let capturedPageBlocks = pageBlocks
                let candidate: PDFImageTable.Candidate?
                if hasImage, tableGeometry { candidate = try await NarrationPreparationWork.run { PDFImageTable.candidate(capturedPageBlocks) } }
                else { candidate = nil }
                if let table = candidate {
                    // Count targeted image-table recognition against the same OCR
                    // page/time budget. Native prose and geometry remain untouched.
                    var recognized: [ContentBlock] = []
                    if tablePages < 20, ocrPages < limits.maximumOCRPages, ocrElapsed < limits.ocrSeconds {
                        tablePages += 1; ocrPages += 1
                        do {
                            progress(.init(stage: .renderingOCR, completed: index, total: pageCount, currentPage: index + 1))
                            let crop = try await NarrationPreparationWork.run {
                                try autoreleasepool { PDFImageTable.crop(try render(page.page, maximumDimension: 4096), to: table.bounds) }
                            }
                            if let crop {
                                progress(.init(stage: .waitingForOCR, completed: index, total: pageCount, currentPage: index + 1))
                                recognized = try await recognizeImage(crop, context: .init(stage: .waitingForOCR, completed: index, total: pageCount, currentPage: index + 1))
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch { tableRecognitionIncomplete = true }
                        try Task.checkCancellation()
                        if ocrElapsed >= limits.ocrSeconds { recognized = [] }
                    }
                    if !recognized.contains(where: { $0.kind == .table }) { tableRecognitionIncomplete = true }
                    let capturedRecognition = recognized
                    pageBlocks += try await NarrationPreparationWork.run { PDFImageTable.recovered(capturedRecognition, caption: table.label) }
                }
            }
            let capturedPageBlocks = pageBlocks, startingBytes = totalBytes, startingGeometry = geometryLines
            let appended = try await NarrationPreparationWork.run {
                var totalBytes = startingBytes, geometryLines = startingGeometry, result: [ContentBlock] = [], geometryMissing = false
                let pageGeometryCount = capturedPageBlocks.reduce(0) { $0 + ($1.pdfLayout?.lines.count ?? 0) }
                let retainPageGeometry = pageGeometryCount <= PDFTextGeometry.maximumLinesPerPage && pageGeometryCount <= PDFTextGeometry.maximumLines - geometryLines
                if !retainPageGeometry { geometryMissing = true }
                for block in capturedPageBlocks {
                    try NarrationWorkCheckpoint.check()
                    totalBytes += block.text.utf8.count
                    guard totalBytes <= limits.maximumTextBytes else { throw PDFExtractionError.textLimit }
                    let layout: PDFTextLayout?
                    if retainPageGeometry, let candidate = block.pdfLayout, candidate.lines.count <= PDFTextGeometry.maximumLinesPerPage,
                       candidate.lines.count <= PDFTextGeometry.maximumLines - geometryLines {
                        layout = candidate; geometryLines += candidate.lines.count
                    } else { layout = nil; if block.kind == .paragraph { geometryMissing = true } }
                    result.append(.init(kind: block.kind, text: block.text, headingLevel: block.headingLevel, narrationText: block.narrationText,
                                        footnoteReferences: block.footnoteReferences, footnoteID: block.footnoteID, pdfPageIndex: index,
                                        origin: block.origin ?? (needsOCR ? .ocr : .authored), pdfLayout: layout))
                }
                for caption in authored {
                    result.append(.init(kind: .caption, text: caption, narrationText: "Image description: " + caption,
                                        pdfPageIndex: index, origin: .authored))
                }
                return (result, totalBytes, geometryLines, geometryMissing)
            }
            blocks.append(contentsOf: appended.0); totalBytes = appended.1; geometryLines = appended.2
            if appended.3 { geometrySkipped.insert(index) }
            progress(.init(stage: .extractingText, completed: index + 1, total: pageCount))
            if let preview, index + 1 >= nextPreviewPage,
               blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                try Task.checkCancellation()
                try await preview(.init(document: snapshot(), completedPages: index + 1, totalPages: pageCount))
                try Task.checkCancellation()
                nextPreviewPage = min(pageCount, (index + 1) * 2)
            }
        }
        guard blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw DocumentReadError.emptyPDF }
        var outline: [DocumentOutlineEntry]?, outlineWarnings: [String] = []
        let capturedBlocks = blocks
        do { outline = try await NarrationPreparationWork.run { try PDFNavigation.entries(owned.document, blocks: capturedBlocks) } }
        catch is CancellationError { throw CancellationError() }
        catch { outlineWarnings.append("The PDF outline exceeded its navigation budget; source text is retained.") }
        return snapshot(outline: outline, warnings: outlineWarnings)
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

/// Provisional prefix for interactive previews only. The full extraction still
/// enforces cumulative budgets and produces the canonical generation document.
public struct PDFExtractionPreview: Sendable {
    public let document: SemanticDocument
    public let completedPages: Int
    public let totalPages: Int
}
