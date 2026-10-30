import Foundation
import Pronunciation

public enum ContentOrigin: String, Codable, Sendable { case authored, ocr, generated }

public struct ContentBlock: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case heading, paragraph, listItem, quote, code, table, caption, footnote, unsupported
    }
    public let kind: Kind
    public let text: String
    public let headingLevel: Int?
    public let narrationText: String?
    public let footnoteReferences: [String]?
    public let footnoteID: String?
    public let imageURL: URL?
    public let imageDescriptionGenerated: Bool?
    public let pdfPageIndex: Int?
    public let origin: ContentOrigin?
    public let resourcePath: String?
    public let pdfLayout: PDFTextLayout?
    public let sourceID: String?
    public let sourceAnchors: [String]?
    public let role: ContentRole?
    public let containsInlineCode: Bool?
    public init(kind: Kind, text: String, headingLevel: Int? = nil, narrationText: String? = nil,
                footnoteReferences: [String]? = nil, footnoteID: String? = nil,
                imageURL: URL? = nil, imageDescriptionGenerated: Bool? = nil, pdfPageIndex: Int? = nil, origin: ContentOrigin? = nil, resourcePath: String? = nil, containsInlineCode: Bool? = nil, pdfLayout: PDFTextLayout? = nil, sourceID: String? = nil, sourceAnchors: [String]? = nil, role: ContentRole? = nil) {
        self.sourceID = sourceID; self.sourceAnchors = sourceAnchors; self.role = role
        self.kind = kind; self.text = text; self.headingLevel = headingLevel
        self.narrationText = narrationText; self.footnoteReferences = footnoteReferences; self.footnoteID = footnoteID
        self.imageURL = imageURL; self.imageDescriptionGenerated = imageDescriptionGenerated
        self.pdfPageIndex = pdfPageIndex; self.origin = origin; self.resourcePath = resourcePath; self.containsInlineCode = containsInlineCode; self.pdfLayout = pdfLayout
    }
}

public struct SemanticDocument: Codable, Sendable, Equatable {
    public let title: String?
    public let author: String?
    public let blocks: [ContentBlock]
    public let warnings: [String]
    public let extractorVersion: String
    public let outline: [DocumentOutlineEntry]?
    public init(title: String? = nil, author: String? = nil, blocks: [ContentBlock], warnings: [String] = [], extractorVersion: String, outline: [DocumentOutlineEntry]? = nil) {
        self.outline = outline
        self.title = title; self.author = author; self.blocks = blocks; self.warnings = warnings; self.extractorVersion = extractorVersion
    }
}

public struct NarrationChunk: Codable, Sendable, Equatable {
    public let index: Int
    public let text: String
    public let blockIndices: [Int]
    public let boundaryAfter: SpeechBoundary?
    public let origin: ContentOrigin?
    public let pronunciationApplications: [PronunciationApplication]?
    public let preparedUtterance: PreparedUtterance?
    public let sourceMappings: [ProjectionMapping]?
    public init(index: Int, text: String, blockIndices: [Int], boundaryAfter: SpeechBoundary? = nil, origin: ContentOrigin? = nil, preparedUtterance: PreparedUtterance? = nil, pronunciationApplications: [PronunciationApplication]? = nil, sourceMappings: [ProjectionMapping]? = nil) {
        self.index = index; self.text = text; self.blockIndices = blockIndices
        self.boundaryAfter = boundaryAfter; self.origin = origin; self.preparedUtterance = preparedUtterance; self.pronunciationApplications = pronunciationApplications; self.sourceMappings = sourceMappings
    }
}

public struct NarrationPlan: Codable, Sendable, Equatable {
    public let version: String
    public let chunks: [NarrationChunk]
    public let notices: [String]
    public let omissions: [NarrationOmission]?
    public let documentTitle: String?
    public init(version: String, chunks: [NarrationChunk], notices: [String], omissions: [NarrationOmission]? = nil, documentTitle: String? = nil) {
        self.version = version; self.chunks = chunks; self.notices = notices; self.omissions = omissions; self.documentTitle = documentTitle
    }
}
