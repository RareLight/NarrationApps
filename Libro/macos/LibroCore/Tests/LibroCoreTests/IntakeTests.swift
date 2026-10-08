import XCTest
import AppKit
import CoreText
@testable import LibroCore

final class IntakeTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func file(_ root: URL, _ path: String, _ text: String = "Chapter text.") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testMixedRecursiveOverlapHiddenUnsupportedLinksAndPackages() throws {
        let root = try temporary()
        let first = try file(root, "Book/Part/One.txt")
        _ = try file(root, "Book/.hidden/Two.MD")
        _ = try file(root, "Book/Three.rtf")
        _ = try file(root, "Book/ignore.png")
        _ = try file(root, "Book/Tool.app/hidden.txt")
        let loose = try file(root, "Loose.pdf")
        let hardlink = root.appendingPathComponent("copy.txt")
        try FileManager.default.linkItem(at: first, to: hardlink)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Book/cycle"), withDestinationURL: root.appendingPathComponent("Book"))
        let link = root.appendingPathComponent("selected.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let selected = [loose, first, root.appendingPathComponent("Book/Part"), link, root.appendingPathComponent("Book"), hardlink, loose]
        let result = try InputCollector.collect(selected)
        XCTAssertEqual(result.documents.map(\.relativePath), ["Book/.hidden/Two.MD", "Book/Part/One.txt", "Book/Three.rtf", "Loose.pdf"])
        XCTAssertEqual(Set(result.documents.map(\.source)).count, 4)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.ignoredCount, 3)
        // Panels/drop/Finder all pass URL groups into this one entry point.
        XCTAssertEqual(try InputCollector.collect(selected.reversed()).documents.map(\.relativePath), result.documents.map(\.relativePath))
    }

    func testStableRootLabelsExcludedOutputAndUnavailableSibling() throws {
        let root = try temporary()
        _ = try file(root, "A/Book/a.txt")
        _ = try file(root, "B/Book/b.md")
        _ = try file(root, "A/Book/output/old.txt")
        let result = try InputCollector.collect([root.appendingPathComponent("B/Book"), root.appendingPathComponent("gone.txt"), root.appendingPathComponent("A/Book")], excludingOutput: root.appendingPathComponent("A/Book/output"))
        XCTAssertEqual(result.documents.map(\.relativePath), ["Book/a.txt", "Book-2/b.md"])
        XCTAssertTrue(result.excludedOutput)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testExplicitInputsInsideDestinationRemainAcceptedWhileIncidentalSubtreeIsExcluded() throws {
        let root = try temporary()
        let markdown = try file(root, "shared/chapter.md")
        let pdf = try file(root, "shared/chapter.pdf")
        _ = try file(root, "shared/nested/notes.txt")
        _ = try file(root, "shared/recording.wav")
        let output = root.appendingPathComponent("shared")
        let direct = try InputCollector.collect([markdown, pdf], excludingOutput: output)
        XCTAssertEqual(Set(direct.documents.map(\.source)), [markdown, pdf])
        XCTAssertFalse(direct.excludedOutput)
        let folder = try InputCollector.collect([output], excludingOutput: output)
        XCTAssertEqual(folder.documents.count, 3)
        XCTAssertFalse(folder.excludedOutput)
        XCTAssertEqual(folder.ignoredCount, 1)
        let incidental = try InputCollector.collect([root], excludingOutput: output)
        XCTAssertTrue(incidental.documents.isEmpty)
        XCTAssertTrue(incidental.excludedOutput)
        let explicitOverride = try InputCollector.collect([root, output, markdown], excludingOutput: output)
        XCTAssertEqual(explicitOverride.documents.count, 3)
        XCTAssertEqual(Set(explicitOverride.documents.map(\.source)), Set(folder.documents.map(\.source)))
    }

    func testStrictTextMarkdownParagraphsAndRTF() throws {
        let root = try temporary()
        let text = try file(root, "bom.txt", "\u{feff}Hello [12]  world.\n\n\nNext.")
        XCTAssertEqual(try DocumentReader.read(InputDocument(source: text, kind: .text, relativePath: "bom.txt")), "Hello world.\n\nNext.")
        let invalid = root.appendingPathComponent("invalid.txt")
        try Data([0xff, 0x80]).write(to: invalid)
        XCTAssertThrowsError(try DocumentReader.read(InputDocument(source: invalid, kind: .text, relativePath: "invalid.txt")))
        let md = try file(root, "sample.md", "# Heading\n\nFirst *paragraph* with [a label](https://example.invalid).\n\nSecond paragraph.\n\n- One\n- Two\n\n> Quoted\n\n```swift\nlet x = 1\n```\n\n![Image description](https://example.invalid/image.png)")
        let narration = try DocumentReader.read(InputDocument(source: md, kind: .markdown, relativePath: "sample.md"))
        XCTAssertTrue(narration.contains("Heading\n\nFirst paragraph with a label.\n\nSecond paragraph."), narration)
        XCTAssertTrue(narration.contains("One\n\nTwo"), narration)
        XCTAssertTrue(narration.contains("Quoted"))
        XCTAssertTrue(narration.contains("let x = 1"))
        XCTAssertTrue(narration.contains("Image description"), narration)
        XCTAssertFalse(narration.contains("https://"))
        let rtf = root.appendingPathComponent("sample.rtf")
        let attributed = NSAttributedString(string: "Rich first.\n\nRich second.")
        try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        XCTAssertEqual(try DocumentReader.read(InputDocument(source: rtf, kind: .rtf, relativePath: "sample.rtf")), attributed.string)
        let broken = try file(root, "broken.rtf", "plain text")
        XCTAssertThrowsError(try DocumentReader.read(InputDocument(source: broken, kind: .rtf, relativePath: "broken.rtf")))
    }

    func testTextPDFPageOrderAndEmptyPDFFailure() throws {
        let root = try temporary()
        let pdf = root.appendingPathComponent("pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(url: pdf as CFURL)!, mediaBox: &box, nil))
        for text in ["First page.", "Second page."] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 300)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        XCTAssertEqual(try DocumentReader.read(InputDocument(source: pdf, kind: .pdf, relativePath: "pages.pdf")), "First page.\n\nSecond page.")
        let blank = root.appendingPathComponent("scanned.pdf")
        let blankContext = try XCTUnwrap(CGContext(consumer: CGDataConsumer(url: blank as CFURL)!, mediaBox: &box, nil))
        blankContext.beginPDFPage(nil); blankContext.endPDFPage(); blankContext.closePDF()
        XCTAssertThrowsError(try DocumentReader.read(InputDocument(source: blank, kind: .pdf, relativePath: "scanned.pdf"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("OCR"))
        }
        let locked = root.appendingPathComponent("locked.pdf")
        let lockedContext = try XCTUnwrap(CGContext(consumer: CGDataConsumer(url: locked as CFURL)!, mediaBox: &box,
            [kCGPDFContextUserPassword as String: "fixture-password", kCGPDFContextOwnerPassword as String: "owner-password"] as CFDictionary))
        lockedContext.beginPDFPage(nil); lockedContext.endPDFPage(); lockedContext.closePDF()
        XCTAssertThrowsError(try DocumentReader.read(InputDocument(source: locked, kind: .pdf, relativePath: "locked.pdf"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("password protected"))
        }
    }

    func testChunkCompletenessUnicodeBoundariesAndCleanup() throws {
        let text = NarrationText.clean("Dr. Smith paid $12.50 at 3 p.m. [2]\n\n" + String(repeating: "Café 👩🏽‍🚀 e\u{301} 中文 story. ", count: 30))
        let chunks = try NarrationText.chunks(text, settings: SpeechSettings())
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.count <= 198 })
        XCTAssertTrue(chunks[0].contains("Dr. Smith paid $12.50 at 3 p.m."))
        let long = String(repeating: "👩🏽‍🚀", count: 100)
        let split = try NarrationText.chunks(long, settings: SpeechSettings(model: .soprano))
        XCTAssertEqual(split.joined(), long)
        XCTAssertTrue(split.allSatisfy { $0.unicodeScalars.count <= 180 })
        XCTAssertEqual(try NarrationText.chunks("", settings: SpeechSettings()), [])
        let unusualSpacing = "Before." + String(repeating: "\u{a0}", count: 800) + "After."
        XCTAssertEqual(try NarrationText.chunks(unusualSpacing, settings: SpeechSettings()).joined(), unusualSpacing)
    }

    func testCancelledDiscovery() async throws {
        let root = try temporary()
        _ = try file(root, "a.txt")
        let task = Task { try Task.checkCancellation(); return try InputCollector.collect([root]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }

    func testUnreadableInputDoesNotSuppressReadableSibling() throws {
        let root = try temporary()
        let unreadable = try file(root, "unreadable.txt")
        _ = try file(root, "readable.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let result = try InputCollector.collect([root])
        XCTAssertEqual(result.documents.count, 2)
        XCTAssertThrowsError(try DocumentReader.read(result.documents.first { $0.source.lastPathComponent == "unreadable.txt" }!))
        XCTAssertEqual(try DocumentReader.read(result.documents.first { $0.source.lastPathComponent == "readable.txt" }!), "Chapter text.")
    }

    func testDeepDiscoveryAndUnreadableFolderContinue() throws {
        let root = try temporary()
        _ = try file(root, Array(repeating: "nested", count: 20).joined(separator: "/") + "/deep.txt")
        _ = try file(root, "denied/hidden.txt")
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let result = try InputCollector.collect([root])
        XCTAssertEqual(result.documents.map { $0.source.lastPathComponent }, ["deep.txt"])
        XCTAssertFalse(result.issues.isEmpty)
    }
}
