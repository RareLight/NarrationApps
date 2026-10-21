import Foundation
import NarrationCore

public enum QueueStatusPresentation {
    public static func preparation(_ progress: DocumentPreparationProgress) -> String {
        let label: String
        switch progress.stage {
        case .readingFile: label = "Opening document"
        case .readingEPUBStructure, .readingPDFStructure: label = "Analyzing structure"
        case .reviewingPDFLayout: label = "Analyzing layout"
        case .extractingEPUBChapter, .extractingText: label = "Analyzing text"
        case .renderingOCR, .recognizingText: label = "Recognizing text"
        case .waitingForOCR, .waitingForImageDescription: label = "Waiting for analysis"
        case .reviewingImages, .describingImage: label = "Analyzing images"
        case .planningNarration: label = "Preparing narration"
        case .phonemizing: label = "Preparing pronunciation"
        }
        if let total = progress.total, total > 0 { return "\(label) \(progress.completed)/\(total)" }
        return label + "…"
    }
}
