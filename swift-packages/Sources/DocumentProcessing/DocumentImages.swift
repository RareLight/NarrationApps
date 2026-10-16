import Foundation
import PDFKit
import AppKit
import CryptoKit
import NarrationCore

public enum DocumentImages {
    /// Transport is supplied by the app's authorized source adapter. Ordinary
    /// extraction never fetches images, nor requires Apple Intelligence.
    public static func enrich(_ document: SemanticDocument, pdfData: Data? = nil, enabled: Bool,
                              progress: @escaping @Sendable (DocumentPreparationProgress) -> Void = { _ in },
                              fetch: ImageDescriptions.Fetch? = nil, caption: ImageDescriptions.Caption? = nil) async throws -> SemanticDocument {
        guard enabled else { return document }
        var blocks = document.blocks, warnings = document.warnings
        var outline = document.outline
        guard caption != nil || ImageDescriptions.available else {
            return .init(title: document.title, author: document.author, blocks: blocks, warnings: warnings + ["On-device image descriptions are unavailable; authored text is retained."], extractorVersion: document.extractorVersion, outline: outline)
        }
        var seenURLs = Set<URL>(), seenBytes = Set<SHA256.Digest>()
        var attempts = 0, bytesUsed = 0, added = 0, failed = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        func generate(_ bytes: Data, context: DocumentPreparationProgress) async throws -> String? {
            try Task.checkCancellation()
            guard bytes.count <= 2_000_000, bytesUsed + bytes.count <= 16_000_000,
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            bytesUsed += bytes.count
            guard seenBytes.insert(SHA256.hash(data: bytes)).inserted else { return nil }
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    if let caption {
                        progress(context.with(stage: .describingImage))
                        return try await caption(bytes)
                    }
                    progress(context.with(stage: .waitingForImageDescription))
                    return try await ImageDescriptions.generate(bytes, onInferenceAcquired: {
                        progress(context.with(stage: .describingImage))
                    })
                }

                group.addTask { try await Task.sleep(for: .seconds(15)); throw DocumentProcessingError.extraction("Image description timed out.") }
                defer { group.cancelAll() }
                guard let text = try await group.next() ?? nil else { return nil }
                return ImageDescriptions.clean(text)
            }
        }
        let imageIndices = blocks.indices.filter { blocks[$0].imageURL != nil && blocks[$0].narrationText == "" }
        for (position, index) in imageIndices.enumerated() {
            try Task.checkCancellation()
            let context = DocumentPreparationProgress(stage: .reviewingImages, completed: position, total: imageIndices.count, unit: .images)
            progress(context)
            let block = blocks[index], url = block.imageURL!
            if let fetch, seenURLs.insert(url).inserted, attempts < 20,
               ProcessInfo.processInfo.systemUptime < deadline {
                attempts += 1
                do {
                    if let text = try await generate(fetch(url), context: context) {
                        blocks[index] = .init(kind: block.kind, text: block.text, headingLevel: block.headingLevel,
                                              narrationText: "Image description: " + text, footnoteReferences: block.footnoteReferences,
                                              footnoteID: block.footnoteID, imageURL: url, imageDescriptionGenerated: true,
                                              pdfPageIndex: block.pdfPageIndex, origin: .generated, resourcePath: block.resourcePath, containsInlineCode: block.containsInlineCode, pdfLayout: block.pdfLayout, sourceID: block.sourceID, sourceAnchors: block.sourceAnchors, role: block.role)
                        added += 1
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
            }
            progress(.init(stage: .reviewingImages, completed: position + 1, total: imageIndices.count, unit: .images))
        }
        if let pdfData, let pdf = PDFDocument(data: pdfData) {
            let pageCount = pdf.pageCount
            for index in 0..<pageCount {
                try Task.checkCancellation()
                let context = DocumentPreparationProgress(stage: .reviewingImages, completed: index, total: pageCount, currentPage: index + 1)
                progress(context)
                if attempts < 20, ProcessInfo.processInfo.systemUptime < deadline,
                   let page = pdf.page(at: index), PDFImageMetadata.hasImage(page),
                   !blocks.contains(where: { $0.kind == .caption && $0.pdfPageIndex == index && !($0.narrationText ?? $0.text).isEmpty }) {
                    attempts += 1
                    do {
                        let bytes = try autoreleasepool { () throws -> Data in
                            let image = try PDFDocumentExtractor.render(page, maximumDimension: 1024)
                            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw DocumentReadError.malformed }
                            return data
                        }
                        if let text = try await generate(bytes, context: context) {
                            let insertion = blocks.lastIndex(where: { $0.pdfPageIndex == index }).map { $0 + 1 } ?? blocks.count
                            outline = outline?.map { $0.shiftedForInsertion(at: insertion) }
                            blocks.insert(.init(kind: .caption, text: "Page imagery without a description",
                                                narrationText: "Page imagery description: " + text, imageDescriptionGenerated: true,
                                                pdfPageIndex: index, origin: .generated), at: insertion)
                            added += 1
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failed += 1 }
                }
                progress(.init(stage: .reviewingImages, completed: index + 1, total: pageCount))
            }
        }
        if added > 0 { warnings.append("Generated image descriptions may contain mistakes; review before narration.") }
        if failed > 0 { warnings.append("Some images could not be described; source text is retained.") }
        return .init(title: document.title, author: document.author, blocks: blocks, warnings: warnings, extractorVersion: document.extractorVersion, outline: outline)
    }
}
