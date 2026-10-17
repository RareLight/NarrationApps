import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import NarrationCore

enum PDFCoverImage {
    static func read(_ url: URL) throws -> Data? {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url), !document.isLocked,
              let page = document.page(at: 0), let reference = page.pageRef else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw DocumentReadError.malformed
        }
        let rotation = (page.rotation % 360 + 360) % 360
        let size = [90, 270].contains(rotation) ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = 1200 / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded(.down)))
        let height = max(1, Int((size.height * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DocumentReadError.malformed
        }
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(destination)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: destination, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        try Task.checkCancellation()
        guard let image = context.makeImage(), try hasVisibleContent(image) else { return nil }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DocumentReadError.malformed
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw DocumentReadError.malformed }
        return data as Data
    }

    private static func hasVisibleContent(_ image: CGImage) throws -> Bool {
        var pixels = [UInt8](repeating: 255, count: 128 * 128 * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 128, height: 128, bitsPerComponent: 8,
                bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw DocumentReadError.malformed
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                if buffer[offset] < 250 || buffer[offset + 1] < 250 || buffer[offset + 2] < 250 { return true }
            }
            return false
        }
    }
}
