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
    /// Keep body paragraphs intact. Tables stay near their visual band; lower
    /// quarter insets follow the page body, with their identified captions.
    public static func project(paragraphs: [OCRParagraph], structures: [OCRStructure], fallback: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        func normalized(_ rect: CGRect) -> Bool {
            PDFTextBounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height).isValid
        }
        func isTable(_ index: Int) -> Bool {
            !structures[index].blocks.isEmpty && structures[index].blocks.allSatisfy { $0.kind == .table } && normalized(structures[index].bounds)
        }
        func sameColumn(_ a: CGRect, _ b: CGRect) -> Bool {
            min(a.maxX, b.maxX) - max(a.minX, b.minX) >= min(a.width, b.width) * 0.5
        }
        var owners = paragraphs.map { paragraph in
            structures.indices.first { !structures[$0].blocks.isEmpty && structures[$0].bounds.contains(CGPoint(x: paragraph.bounds.midX, y: paragraph.bounds.midY)) }
        }
        var captions: [Int: [Int]] = [:]
        for index in paragraphs.indices where owners[index] == nil {
            let paragraph = paragraphs[index]
            guard normalized(paragraph.bounds), paragraph.text.utf16.count <= 500,
                  paragraph.text.range(of: #"^\s*(?:Table|Box|Exhibit)\s+(?:[0-9]+|[IVXLCDM]+)\s*[:.|–—]"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let nearby = structures.indices.filter { table in
                guard isTable(table), sameColumn(paragraph.bounds, structures[table].bounds) else { return false }
                let gap = max(paragraph.bounds.minY - structures[table].bounds.maxY, structures[table].bounds.minY - paragraph.bounds.maxY)
                return gap >= 0 && gap <= 0.035
            }
            // Ambiguous associations retain their original paragraph position.
            if nearby.count == 1 {
                owners[index] = nearby[0]; captions[nearby[0], default: []].append(index)
            }
        }
        var events: [Int: [Int]] = [:]
        for index in structures.indices {
            var anchor = owners.firstIndex { $0 == index } ?? paragraphs.count
            if isTable(index) {
                let rect = structures[index].bounds
                if rect.maxY <= 0.25 { anchor = paragraphs.count }
                else if anchor == paragraphs.count {
                    anchor = paragraphs.firstIndex { normalized($0.bounds) && sameColumn(rect, $0.bounds) && $0.bounds.maxY <= rect.minY } ?? paragraphs.count
                }
            }
            events[anchor, default: []].append(index)
        }
        func paragraphBlock(_ index: Int) -> ContentBlock {
            let paragraph = paragraphs[index], rect = paragraph.bounds
            let bounds = PDFTextBounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            let layout: PDFTextLayout? = bounds.isValid ? .init(basis: .image, lines: [.init(location: 0, length: paragraph.text.utf16.count, bounds: bounds)]) : nil
            return .init(kind: .paragraph, text: paragraph.text, origin: .ocr, pdfLayout: layout)
        }
        for position in 0...paragraphs.count {
            let scheduled = (events[position] ?? []).sorted { a, b in
                let lowA = isTable(a) && structures[a].bounds.maxY <= 0.25
                let lowB = isTable(b) && structures[b].bounds.maxY <= 0.25
                if lowA != lowB { return !lowA }
                if lowA && structures[a].bounds.maxY != structures[b].bounds.maxY { return structures[a].bounds.maxY > structures[b].bounds.maxY }
                return a < b
            }
            for index in scheduled {
                let labels = captions[index] ?? []
                blocks += labels.filter { paragraphs[$0].bounds.midY >= structures[index].bounds.midY }.map(paragraphBlock)
                blocks += structures[index].blocks
                blocks += labels.filter { paragraphs[$0].bounds.midY < structures[index].bounds.midY }.map(paragraphBlock)
            }
            if position < paragraphs.count, owners[position] == nil,
               !paragraphs[position].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(paragraphBlock(position))
            }
        }
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
                let cells = table.rows.map { row in row.map { $0.content.text.transcript } }
                let simple = table.rows.flatMap { $0 }.allSatisfy { $0.rowRange.count == 1 && $0.columnRange.count == 1 }
                let rows = cells.map { $0.joined(separator: " | ") }.joined(separator: "\n")
                return OCRStructure(blocks: [.init(kind: .table, text: rows,
                    narrationText: TableNarration.render(rows: cells, hasHeader: false, relationshipsReliable: simple),
                    origin: .ocr)], bounds: table.boundingRegion.boundingBox.cgRect)
            }
            structures += document.lists.map { list in
                OCRStructure(blocks: list.items.map { .init(kind: .listItem, text: $0.itemString, origin: .ocr) },
                             bounds: list.boundingRegion.boundingBox.cgRect)
            }
            return project(paragraphs: paragraphs, structures: structures, fallback: document.text.transcript)
        }
    }
}
