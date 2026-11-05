import PDFKit

// A reader alone owns these PDFKit objects. Sole access transfers to an awaited
// CPU unit before the next access. Neither the GUI nor OCR shares these objects;
// OCR receives only the rendered CGImage.
final class OwnedPDFDocument: @unchecked Sendable {
    let document: PDFDocument
    init(_ value: PDFDocument) { document = value }
}
final class OwnedPDFPage: @unchecked Sendable {
    let page: PDFPage
    init(_ value: PDFPage) { page = value }
}
