import Foundation

/// Normalized visual coordinates, with the origin at the bottom left. These are
/// extraction evidence, not reading-order guesses. No PDFKit/Vision objects persist.
public struct PDFTextBounds: Codable, Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct PDFTextLine: Codable, Equatable, Sendable {
    /// Block-local extracted UTF-16 range; includes native trailing line separators.
    public let location: Int, length: Int
    public let bounds: PDFTextBounds
    public init(location: Int, length: Int, bounds: PDFTextBounds) {
        self.location = location; self.length = length; self.bounds = bounds
    }
}

public struct PDFTextLayout: Codable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable { case cropBox, image }
    public let basis: Basis
    public let rotation: Int
    public let lines: [PDFTextLine]
    public init(basis: Basis, rotation: Int = 0, lines: [PDFTextLine]) {
        self.basis = basis; self.rotation = rotation; self.lines = lines
    }
}
