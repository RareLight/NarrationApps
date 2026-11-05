import Foundation
import PDFKit
import AppKit
import CryptoKit
import NarrationCore

public enum DocumentImages {
    /// Transport is supplied by the app's authorized source adapter. Ordinary
    /// extraction never fetches images, nor requires Apple Intelligence.
    public static func enrich(_ document: SemanticDocument, pdfData: Data? = nil, enabled: Bool,
                              monotonicTime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
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
        var descriptionElapsed: TimeInterval = 0
        func generate(_ bytes: Data, context: DocumentPreparationProgress) async throws -> String? {
            try Task.checkCancellation()
            guard bytes.count <= 2_000_000, bytesUsed + bytes.count <= 16_000_000,
                  descriptionElapsed < 60 else { return nil }
            bytesUsed += bytes.count
            let digest = try await NarrationPreparationWork.run { SHA256.hash(data: bytes) }
            guard seenBytes.insert(digest).inserted else { return nil }
            let interval = PreparationInterval(now: monotonicTime), timeout = min(15, 60 - descriptionElapsed)
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { started.continuation.finish(); interval.end(); descriptionElapsed += interval.elapsed }
            let generated: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    if let caption {
                        interval.begin(); started.continuation.yield()
                        defer { interval.end() }
                        progress(context.with(stage: .describingImage))
                        return try await caption(bytes)
                    }
                    progress(context.with(stage: .waitingForImageDescription))
                    return try await ImageDescriptions.generateRaw(bytes, onInferenceFinished: { interval.end() }, onInferenceAcquired: {
                        interval.begin(); started.continuation.yield()
                        progress(context.with(stage: .describingImage))
                    })
                }

                group.addTask {
                    for await _ in started.stream {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .seconds(timeout))
                        throw DocumentProcessingError.extraction("Image description timed out.")
                    }
                    try Task.checkCancellation(); return nil
                }
                defer { group.cancelAll() }
                guard let text = try await group.next() ?? nil else { return nil }
                return text
            }
            guard interval.elapsed <= timeout else { throw DocumentProcessingError.extraction("Image description timed out.") }
            return try await NarrationPreparationWork.run { generated.flatMap(ImageDescriptions.clean) }
        }
        let sourceBlocks = blocks
        let imageIndices = try await NarrationPreparationWork.run { sourceBlocks.indices.filter { sourceBlocks[$0].imageURL != nil && sourceBlocks[$0].narrationText == "" } }
        for (position, index) in imageIndices.enumerated() {
            try Task.checkCancellation()
            let context = DocumentPreparationProgress(stage: .reviewingImages, completed: position, total: imageIndices.count, unit: .images)
            progress(context)
            let block = blocks[index], url = block.imageURL!
            if let fetch, seenURLs.insert(url).inserted, attempts < 20,
               descriptionElapsed < 60 {
                attempts += 1
                do {
                    try await NarrationPreparationWork.run {} // A new authorized fetch is a new preparation unit.
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
        let ownedPDF = try await NarrationPreparationWork.run { pdfData.flatMap { PDFDocument(data: $0).map(OwnedPDFDocument.init) } }
        if let ownedPDF {
            let pageCount = try await NarrationPreparationWork.run { ownedPDF.document.pageCount }
            for index in 0..<pageCount {
                try Task.checkCancellation()
                let context = DocumentPreparationProgress(stage: .reviewingImages, completed: index, total: pageCount, currentPage: index + 1)
                progress(context)
                if attempts < 20, descriptionElapsed < 60,
                   !blocks.contains(where: { $0.kind == .caption && $0.pdfPageIndex == index && !($0.narrationText ?? $0.text).isEmpty }) {
                    let selectedPage = try await NarrationPreparationWork.run {
                        guard let page = ownedPDF.document.page(at: index), PDFImageMetadata.hasImage(page) else { return OwnedPDFPage?.none }
                        return OwnedPDFPage(page)
                    }
                    guard let selectedPage else {
                        progress(.init(stage: .reviewingImages, completed: index + 1, total: pageCount))
                        continue
                    }
                    attempts += 1
                    do {
                        let bytes = try await NarrationPreparationWork.run { try autoreleasepool { () throws -> Data in
                            let image = try PDFDocumentExtractor.render(selectedPage.page, maximumDimension: 1024)
                            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw DocumentReadError.malformed }
                            return data
                        } }
                        if let text = try await generate(bytes, context: context) {
                            let insertion = blocks.lastIndex(where: { $0.pdfPageIndex == index }).map { $0 + 1 } ?? blocks.count
                            let previousOutline = outline
                            outline = try await NarrationPreparationWork.run { previousOutline?.map { $0.shiftedForInsertion(at: insertion) } }
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
