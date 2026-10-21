import Foundation
import AppKit
import CoreText
import Darwin

// Opt-in operator fixtures made only with Apple document APIs. No real inputs.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift prepare-intake-fixtures.swift ABSOLUTE_EMPTY_DIRECTORY\n", stderr)
    exit(2)
}
let path = CommandLine.arguments[1]
guard path.hasPrefix("/") else { exit(2) }
let root = URL(fileURLWithPath: path, isDirectory: true)
let manager = FileManager.default
if manager.fileExists(atPath: root.path), !(try manager.contentsOfDirectory(atPath: root.path)).isEmpty {
    fputs("Choose an empty fixture directory; existing contents are preserved.\n", stderr)
    exit(2)
}
try manager.createDirectory(at: root, withIntermediateDirectories: true)

func write(_ relative: String, _ text: String) throws {
    let url = root.appendingPathComponent(relative)
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func pdf(_ relative: String, pages: [String], locked: Bool = false) throws {
    let url = root.appendingPathComponent(relative)
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 500, height: 500)
    let options = locked ? [kCGPDFContextUserPassword as String: "fixture", kCGPDFContextOwnerPassword as String: "owner"] as CFDictionary : nil
    guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, options) else { throw CocoaError(.fileWriteUnknown) }
    for text in pages {
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 350)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)])), context)
        context.endPDFPage()
    }
    context.closePDF()
}

try write("A/Book/Part 1/Chapter.txt", "\u{feff}Dr. Smith paid $12.50 at 3 p.m. [12]\n\nSecond paragraph. Hello, Anna!")
try pdf("A/Book/Part 1/Chapter.pdf", pages: ["First PDF page.", "Second PDF page."])
try write("A/Book/.hidden/Notes.md", "# Heading\n\nFirst *paragraph* with [a link label](https://example.invalid).\n\nSecond paragraph.\n\n- List one\n- List two\n\n> Quotation\n\n```swift\nlet example = 1\n```")
try write("B/Book/Notes.markdown", "# Another book\n\nA distinct root label should keep this file separate.")
try write("A/Book/ignore.png", "Unsupported fixture: ignore this file.")
try write("A/Book/Tool.app/ignored.txt", "Do not enumerate application bundles.")
try manager.createSymbolicLink(at: root.appendingPathComponent("A/Book/cycle"), withDestinationURL: root.appendingPathComponent("A/Book"))
let rich = NSAttributedString(string: "Rich first paragraph.\n\nRich second paragraph: Café and 中文.")
try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: root.appendingPathComponent("Rich.rtf"))
try pdf("No-text.pdf", pages: [""])
try pdf("Locked.pdf", pages: ["Locked fixture."], locked: true)
try Data([0xff, 0x80]).write(to: root.appendingPathComponent("Invalid.txt"))
try manager.createDirectory(at: root.appendingPathComponent("Chosen Output"), withIntermediateDirectories: true)
print("Prepared mixed-document operator fixtures at \(root.path)")
