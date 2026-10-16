import Foundation
import CoreGraphics
import Vision
import NarrationCore

public struct OCRParagraph: Sendable {
    public let text: String
    public let bounds: CGRect
    public init(text: String, bounds: CGRect) { self.text = text; self.bounds = bounds }
}
public struct OCRStructure: Sendable {
    public let blocks: [ContentBlock]
    public let bounds: CGRect
    public init(blocks: [ContentBlock], bounds: CGRect) { self.blocks = blocks; self.bounds = bounds }
}

public enum StructuredDocumentOCR {
    /// Preserve Vision's paragraph order and replace child text with its owning
    /// list/table exactly once. Aggregate document text is fallback only.
    public static func project(paragraphs: [OCRParagraph], structures: [OCRStructure], fallback: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = [], emitted = Set<Int>()
        for paragraph in paragraphs {
            if let owner = structures.indices.first(where: {
                structures[$0].bounds.contains(CGPoint(x: paragraph.bounds.midX, y: paragraph.bounds.midY))
            }) {
                if emitted.insert(owner).inserted { blocks += structures[owner].blocks }
            } else if !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rect = paragraph.bounds
                let bounds = PDFTextBounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                let layout: PDFTextLayout? = bounds.isValid ? .init(basis: .image, lines: [.init(location: 0, length: paragraph.text.utf16.count, bounds: bounds)]) : nil
                blocks.append(.init(kind: .paragraph, text: paragraph.text, origin: .ocr, pdfLayout: layout))
            }
        }
        for index in structures.indices where emitted.insert(index).inserted { blocks += structures[index].blocks }
        if blocks.isEmpty, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.init(kind: .paragraph, text: fallback, origin: .ocr))
        }
        return blocks
    }

    public static func recognize(_ image: CGImage) async throws -> [ContentBlock] {
        try await recognize(image, onInferenceAcquired: {})
    }

    public static func recognize(_ image: CGImage, onInferenceAcquired: @Sendable () -> Void) async throws -> [ContentBlock] {
        let lease = try await InferenceLease.acquire()
        defer { withExtendedLifetime(lease) {} }
        onInferenceAcquired()
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = false
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return observations.flatMap { observation in
            let document = observation.document
            let paragraphs = document.paragraphs.map { OCRParagraph(text: $0.transcript, bounds: $0.boundingRegion.boundingBox.cgRect) }
            var structures = document.tables.map { table in
                let rows = table.rows.map { row in row.map { $0.content.text.transcript }.joined(separator: " | ") }.joined(separator: "\n")
                return OCRStructure(blocks: [.init(kind: .table, text: rows, origin: .ocr)], bounds: table.boundingRegion.boundingBox.cgRect)
            }
            structures += document.lists.map { list in
                OCRStructure(blocks: list.items.map { .init(kind: .listItem, text: $0.itemString, origin: .ocr) },
                             bounds: list.boundingRegion.boundingBox.cgRect)
            }
            return project(paragraphs: paragraphs, structures: structures, fallback: document.text.transcript)
        }
    }
}
