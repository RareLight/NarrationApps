/// Measured work within a preparation phase, never an estimate of overall job time.
public struct DocumentPreparationProgress: Sendable, Equatable {
    public enum Stage: Sendable { case readingFile, readingEPUBStructure, extractingEPUBChapter, readingPDFStructure, reviewingPDFLayout, extractingText, renderingOCR, waitingForOCR, recognizingText, reviewingImages, waitingForImageDescription, describingImage, planningNarration, phonemizing }
    public enum Unit: Sendable { case pages, images, passages, chapters }
    public let stage: Stage
    public let completed: Int
    public let total: Int?
    public let unit: Unit
    public let currentPage: Int?
    public let currentChapter: Int?
    public init(stage: Stage, completed: Int = 0, total: Int? = nil, unit: Unit = .pages, currentPage: Int? = nil, currentChapter: Int? = nil) {
        self.stage = stage; self.completed = completed; self.total = total; self.unit = unit; self.currentPage = currentPage; self.currentChapter = currentChapter
    }
    public func with(stage: Stage) -> Self {
        .init(stage: stage, completed: completed, total: total, unit: unit, currentPage: currentPage, currentChapter: currentChapter)
    }
    public var fractionCompleted: Double? {
        guard let total, total > 0 else { return nil }
        return Double(min(max(0, completed), total)) / Double(total)
    }
    public var status: String {
        let page = currentPage.map { page in total.map { "page \(page) of \($0)" } ?? "page \(page)" } ?? "the document"
        switch stage {
        case .readingFile: return "Opening and reading document file…"
        case .readingEPUBStructure: return "Reading EPUB metadata and book reading order…"
        case .extractingEPUBChapter: return currentChapter.map { "Reading EPUB section \($0) of \(total ?? $0)…" } ?? "Reading EPUB sections…"
        case .readingPDFStructure: return "Reading PDF structure and authored image captions…"
        case .reviewingPDFLayout: return "Measuring text layout on \(page)…"
        case .extractingText: return "Extracting text from \(page)…"
        case .renderingOCR: return "Rendering \(page) for text recognition…"
        case .waitingForOCR: return "Waiting for on-device text recognition · \(page)…"
        case .recognizingText: return "Recognizing text (OCR) on \(page)…"
        case .reviewingImages: return currentPage == nil ? "Reviewing image descriptions…" : "Reviewing imagery on \(page)…"
        case .waitingForImageDescription: return "Waiting for on-device image description · \(page)…"
        case .describingImage: return currentPage == nil ? "Describing image…" : "Describing imagery on \(page)…"
        case .phonemizing: return "Preparing pronunciation and model utterances…"
        case .planningNarration: return "Preparing narration and speech chunks…"
        }
    }
    public var countLabel: String? {
        guard let total, total > 0 else { return nil }
        let count = min(max(0, completed), total)
        if unit == .chapters { return "Book extraction: \(count) of \(total) sections prepared" }
        if unit == .passages { return "Speech preparation: \(count) of \(total) passages prepared" }
        if unit == .images { return "Image review: \(count) of \(total) image references checked" }
        switch stage {
        case .reviewingPDFLayout: return "PDF layout: \(count) of \(total) pages measured"
        case .reviewingImages, .waitingForImageDescription, .describingImage:
            return "Image review: \(count) of \(total) pages checked"
        default: return "Text extraction: \(count) of \(total) pages prepared"
        }
    }
}
