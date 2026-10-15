import Foundation
import PDFKit
import NarrationCore

public enum PDFImageMetadata {
    public static func hasImage(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var current: CGPDFDictionaryRef? = dictionary
        for _ in 0..<16 {
            guard let node = current else { return false }
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, "Resources", &resources) {
                return CGPDFDictionaryGetDictionary(resources!, "XObject", &objects) && CGPDFDictionaryGetCount(objects!) > 0
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), parent != current else { return false }
            current = parent
        }
        return false
    }
    public static func alternatives(_ pdf: PDFDocument) -> [Int: [String]] {
        guard let document = pdf.documentRef, let catalog = document.catalog else { return [:] }
        var root: CGPDFDictionaryRef?, kids: CGPDFObjectRef?
        guard CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &root), CGPDFDictionaryGetObject(root!, "K", &kids) else { return [:] }
        let pages = Dictionary((0..<pdf.pageCount).compactMap { index -> (CGPDFDictionaryRef, Int)? in
            document.page(at: index + 1)?.dictionary.map { ($0, index) }
        }, uniquingKeysWith: { first, _ in first })
        var result: [Int: [String]] = [:], visited: Set<CGPDFDictionaryRef> = [], budget = 2000
        func visit(_ object: CGPDFObjectRef, page: Int?, depth: Int) {
            guard depth < 64, budget > 0 else { return }; budget -= 1
            var array: CGPDFArrayRef?
            if CGPDFObjectGetValue(object, .array, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var child: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, index, &child), let child { visit(child, page: page, depth: depth + 1) }
                }
                return
            }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary, visited.insert(dictionary).inserted else { return }
            var pg: CGPDFDictionaryRef?, name: UnsafePointer<CChar>?, alt: CGPDFStringRef?
            let owner = CGPDFDictionaryGetDictionary(dictionary, "Pg", &pg) ? pg.flatMap { pages[$0] } : page
            if CGPDFDictionaryGetName(dictionary, "S", &name), let name, String(cString: name) == "Figure",
               CGPDFDictionaryGetString(dictionary, "Alt", &alt), let alt,
               let value = CGPDFStringCopyTextString(alt) as String?, let owner {
                let text = NarrationText.normalizeWhitespace(value)
                if !text.isEmpty, text.count <= 5000, !result[owner, default: []].contains(text) { result[owner, default: []].append(text) }
            }
            var child: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "K", &child), let child { visit(child, page: owner, depth: depth + 1) }
        }
        if let kids { visit(kids, page: nil, depth: 0) }
        return result
    }
}
