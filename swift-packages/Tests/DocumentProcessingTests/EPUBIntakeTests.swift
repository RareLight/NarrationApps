import XCTest
import Foundation
import ZIPFoundation
import NarrationCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DocumentProcessing

private final class EPUBProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DocumentPreparationProgress] = []
    func append(_ value: DocumentPreparationProgress) { lock.withLock { values.append(value) } }
    var snapshot: [DocumentPreparationProgress] { lock.withLock { values } }
}

final class EPUBIntakeTests: XCTestCase {
    private func coverPNG(width: Int = 120, height: Int = 180) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
    private func book(version: String = "3.0", manifest: String = "", spine: String = "", files: [(String, Data)] = [],
                      package: String? = nil, compression: CompressionMethod = .deflate) throws -> Data {
        let archive = try Archive(accessMode: .create)
        let container = "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='EPUB/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"
        let opf = package ?? """
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Synthetic Book</dc:title><dc:creator>Fixture Author</dc:creator><dc:language>en</dc:language><dc:identifier id="id">fixture</dc:identifier></metadata>
        <manifest><item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/><item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/>\(manifest)</manifest>
        <spine><itemref idref="one"/><itemref idref="two"/>\(spine)</spine></package>
        """
        var contents: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)), ("EPUB/book.opf", Data(opf.utf8)),
            ("EPUB/Text/one.xhtml", Data("<html><body><h1 id='same'>First chapter</h1><p>Original first prose.</p></body></html>".utf8)),
            ("EPUB/Text/two.xhtml", Data("<html><body><h1 id='same'>Second chapter</h1><p>Original second prose.</p></body></html>".utf8))]
        for (path, bytes) in files { contents.removeAll { $0.0 == path }; contents.append((path, bytes)) }
        for (path, bytes) in contents {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: path == "mimetype" ? .none : compression) { offset, count in
                bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
            }
        }
        return try XCTUnwrap(archive.data)
    }
    func testEPUB2And3UseSpineOrderMetadataAndChapterProvenanceWithoutNCXRequirement() async throws {
        for version in ["2.0", "3.0", "3.3"] {
            let result = try await EPUBDocumentExtractor.extract(data: book(version: version))
            XCTAssertEqual(result.title, "Synthetic Book"); XCTAssertEqual(result.author, "Fixture Author")
            XCTAssertEqual(result.blocks.filter { $0.kind == .heading }.map(\.text), ["First chapter", "Second chapter"])
            XCTAssertEqual(result.blocks.map(\.resourcePath), ["EPUB/Text/one.xhtml", "EPUB/Text/one.xhtml", "EPUB/Text/two.xhtml", "EPUB/Text/two.xhtml"])
            XCTAssertTrue(result.blocks.allSatisfy { $0.origin == .authored })
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(result, settings: .init()).chunks.filter { $0.boundaryAfter == .heading }.count, 2)
        }
    }
    func testCrossChapterAndNonSpineNotesResolveOnceWithoutCollidingLocalIDs() async throws {
        let one = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><p>Read this <a epub:type='noteref' href='notes.xhtml#note'>[1]</a> carefully.</p></body></html>"
        let notes = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><aside epub:type='footnote' id='note'><p>Authored note text.</p></aside><p>Unlinked auxiliary prose.</p></body></html>"
        let bytes = try book(manifest: "<item id='notes' href='Text/notes.xhtml' media-type='application/xhtml+xml'/>", files: [
            ("EPUB/Text/one.xhtml", Data(one.utf8)), ("EPUB/Text/notes.xhtml", Data(notes.utf8))])
        let result = try await EPUBDocumentExtractor.extract(data: bytes)
        let reference = try XCTUnwrap(result.blocks.first?.footnoteReferences?.first)
        XCTAssertTrue(result.blocks.first?.text.contains("[1]") == true)
        XCTAssertTrue(result.blocks.contains { $0.footnoteID == reference && $0.resourcePath == "EPUB/Text/notes.xhtml" })
        let spoken = try NarrationPlanner.prepareForSpeech(result, settings: .init()).chunks.map(\.text).joined(separator: " ")
        XCTAssertEqual(spoken.components(separatedBy: "Authored note text.").count - 1, 1)
        XCTAssertTrue(spoken.contains("Footnote:")); XCTAssertTrue(spoken.contains("End Footnote"))
        XCTAssertFalse(spoken.contains("Unlinked auxiliary prose"))
    }
    func testEmbeddedAuthoredALTAndGeneratedDescriptionsUseSharedDedupWithoutExternalFetches() async throws {
        let html = "<html><body><p>Visible source prose.</p><img src='../Images/alt.png' alt='An authored boat.'/><img src='../Images/a.png'/><img src='../Images/b.png'/><img src='https://example.invalid/remote.png' alt='Remote authored ALT.'/><nav>Navigation only</nav></body></html>"
        let manifest = ["alt", "a", "b"].map { "<item id='\($0)' href='Images/\($0).png' media-type='image/png'/>" }.joined()
        let bytes = try book(manifest: manifest, files: [("EPUB/Text/one.xhtml", Data(html.utf8)), ("EPUB/Images/a.png", Data("same image".utf8)), ("EPUB/Images/b.png", Data("same image".utf8))])
        let result = try await EPUBDocumentExtractor.extract(data: bytes, describeImages: true, caption: { bytes in
            XCTAssertEqual(bytes, Data("same image".utf8)); return "A synthetic lake."
        })
        XCTAssertTrue(result.blocks.contains { $0.text == "An authored boat." })
        XCTAssertTrue(result.blocks.contains { $0.text == "Remote authored ALT." })
        XCTAssertEqual(result.blocks.filter { $0.imageDescriptionGenerated == true }.count, 1)
        XCTAssertTrue(result.blocks.first { $0.imageDescriptionGenerated == true }?.resourcePath == "EPUB/Text/one.xhtml")
        XCTAssertFalse(result.blocks.map(\.text).contains("Navigation only"))
        XCTAssertTrue(result.warnings.contains { $0.contains("External") })
    }
    func testProtectedTextFailsButStandardFontObfuscationIsAllowed() async throws {
        let encrypted = "<encryption xmlns='urn:oasis:names:tc:opendocument:xmlns:container' xmlns:enc='http://www.w3.org/2001/04/xmlenc#'><enc:EncryptedData><enc:EncryptionMethod Algorithm='http://www.w3.org/2001/04/xmlenc#aes128-cbc'/><enc:CipherData><enc:CipherReference URI='EPUB/Text/one.xhtml'/></enc:CipherData></enc:EncryptedData></encryption>"
        let protected = try book(files: [("META-INF/encryption.xml", Data(encrypted.utf8))])
        do { _ = try await EPUBDocumentExtractor.extract(data: protected); XCTFail("Protected book was accepted") }
        catch { XCTAssertEqual(error as? EPUBReadError, .protected) }
        let fonts = encrypted.replacingOccurrences(of: "http://www.w3.org/2001/04/xmlenc#aes128-cbc", with: "http://www.idpf.org/2008/embedding").replacingOccurrences(of: "EPUB/Text/one.xhtml", with: "EPUB/Fonts/book.ttf")
        _ = try await EPUBDocumentExtractor.extract(data: book(manifest: "<item id='font' href='Fonts/book.ttf' media-type='application/vnd.ms-opentype'/>", files: [("META-INF/encryption.xml", Data(fonts.utf8))]))
    }
    func testArchivePathsReferencesXMLBudgetsAndCRCFailuresCannotBecomePartialNarration() throws {
        XCTAssertThrowsError(try EPUBDocumentExtractor.read(data: book(files: [("../escape.txt", Data("no".utf8))]), title: nil))
        XCTAssertThrowsError(try EPUBContainer.reference("../../../escape.xhtml", relativeTo: "EPUB/book.opf"))
        XCTAssertThrowsError(try EPUBContainer.reference("file:///etc/passwd", relativeTo: "EPUB/book.opf"))
        XCTAssertThrowsError(try EPUBContainer.reference("%2e%2e/%2e%2e/escape.xhtml", relativeTo: "EPUB/book.opf"))
        XCTAssertThrowsError(try parseEPUBXML(Data("<!DOCTYPE package [<!ENTITY bad 'expanded'>]><package>&bad;</package>".utf8)))
        let bytes = try book()
        XCTAssertThrowsError(try EPUBDocumentExtractor.read(data: bytes, title: nil, limits: .init(maximumEntries: 2)))
        XCTAssertThrowsError(try EPUBDocumentExtractor.read(data: bytes, title: nil, limits: .init(maximumExpandedBytes: 100)))
        XCTAssertThrowsError(try EPUBDocumentExtractor.read(data: bytes, title: nil, limits: .init(maximumTextBytes: 10)))
        XCTAssertThrowsError(try EPUBDocumentExtractor.read(data: bytes, title: nil, limits: .init(maximumChapters: 1)))
        var corrupt = try book(compression: .none)
        let match = try XCTUnwrap(corrupt.range(of: Data("Original first prose.".utf8)))
        corrupt[match.lowerBound] ^= 1
        XCTAssertThrowsError(try EPUBDocumentExtractor.read(data: corrupt, title: nil))
    }
    func testSVGSpineFallbackPreservesAccessibleText() async throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><title>Illustrated page</title><text x='0' y='10'>Readable SVG text.</text></svg>"
        let package = "<package version='3.0'><metadata/><manifest><item id='foreign' href='unknown.bin' media-type='application/x-unknown' fallback='svg'/><item id='svg' href='page.svg' media-type='image/svg+xml'/></manifest><spine><itemref idref='foreign'/></spine></package>"
        let result = try await EPUBDocumentExtractor.extract(data: book(files: [("EPUB/page.svg", Data(svg.utf8))], package: package))
        XCTAssertTrue(result.blocks.contains { $0.text == "Readable SVG text." })
        XCTAssertTrue(result.warnings.contains { $0.contains("SVG") })
    }
    func testFileIngressDiscoveryAndMeasuredChapterProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("book.EPUB"), bytes = try book()
        try bytes.write(to: url)
        let discovered = try InputCollector.collect([root, url])
        XCTAssertEqual(discovered.documents.count, 1); XCTAssertEqual(discovered.documents.first?.kind, .epub)
        XCTAssertTrue(DocumentKind.contentTypes.contains { $0.identifier == "org.idpf.epub-container" })
        let progress = EPUBProgress()
        let result = try await DocumentReader.readSemantic(try XCTUnwrap(discovered.documents.first), progress: { progress.append($0) })
        XCTAssertEqual(result.title, "Synthetic Book")
        XCTAssertEqual(progress.snapshot.filter { $0.stage == .extractingEPUBChapter }.last?.fractionCompleted, 1)
        XCTAssertTrue(progress.snapshot.contains { $0.unit == .chapters && $0.countLabel?.contains("sections prepared") == true })
        XCTAssertTrue(try DocumentReader.read(discovered.documents[0]).contains("Original first prose."))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testEmbeddedSVGAndUnresolvedNoteWarningsRemainVisible() async throws {
        let html = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><p>Before <a epub:type='noteref' href='#missing'>[1]</a>.</p><svg xmlns='http://www.w3.org/2000/svg'><title>Plot</title><text>Embedded SVG prose.</text></svg><p>After.</p></body></html>"
        let result = try await EPUBDocumentExtractor.extract(data: book(files: [("EPUB/Text/one.xhtml", Data(html.utf8))]))
        XCTAssertTrue(result.blocks.contains { $0.text == "Embedded SVG prose." && $0.resourcePath == "EPUB/Text/one.xhtml" })
        XCTAssertTrue(result.warnings.contains { $0.contains("could not be resolved") })
    }
    func testXMLCDATAAndDeclaredUTF16AreReadByFoundation() throws {
        let xml = "<?xml version='1.0' encoding='UTF-16'?><package><title><![CDATA[A café title]]></title></package>"
        let result = try parseEPUBXML(XCTUnwrap(xml.data(using: .utf16)))
        XCTAssertEqual(result.children.first?.text, "A café title")
    }

    func testEPUBResourceProvenanceIsOptionalForRetainedPreEPUBDocuments() throws {
        let old = Data(#"{"title":"Retained article","blocks":[{"kind":"paragraph","text":"Original café prose."}],"warnings":[],"extractorVersion":"fixture-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(SemanticDocument.self, from: old)
        XCTAssertNil(decoded.blocks.first?.resourcePath)
        XCTAssertNil(decoded.blocks.first?.containsInlineCode)
        let book = try EPUBDocumentExtractor.read(data: self.book(), title: nil).document
        XCTAssertEqual(try JSONDecoder().decode(SemanticDocument.self, from: JSONEncoder().encode(book)), book)
    }

    func testCancelledBookStopsBeforePublication() async throws {
        let bytes = try book()
        let task = Task { try await EPUBDocumentExtractor.extract(data: bytes) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import was accepted") } catch is CancellationError { }
    }

    func testAuthoredNavigationResolvesFragmentsWithoutChangingSpineNarration() async throws {
        let nav = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><ol><li><a href='Text/one.xhtml#same'>Start here</a></li><li><span>Part</span><ol><li><a href='Text/two.xhtml#same'>Continue here</a></li></ol></li><li><a href='Text/missing.xhtml#no'>Unavailable</a></li></ol></nav></body></html>"
        let bytes = try book(manifest: "<item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>", files: [("EPUB/nav.xhtml", Data(nav.utf8))])
        let document = try await EPUBDocumentExtractor.extract(data: bytes)
        let entries = try XCTUnwrap(document.outline)
        XCTAssertEqual(entries.map(\.label), ["Start here", "Part", "Continue here", "Unavailable"])
        XCTAssertEqual(entries.map(\.blockIndex), [0, nil, 2, nil])
        XCTAssertEqual(entries.map(\.depth), [0, 0, 1, 0])
        XCTAssertEqual(entries.last?.precision, .unresolved)
        XCTAssertFalse(document.blocks.map(\.text).joined().contains("Start here"))
        XCTAssertEqual(document.blocks.filter { $0.kind == .heading }.map(\.text), ["First chapter", "Second chapter"])
        XCTAssertEqual(try JSONDecoder().decode(SemanticDocument.self, from: JSONEncoder().encode(document)), document)
    }
    func testEPUB2NCXAndExplicitCoverResourcesRemainOptionalMetadata() async throws {
        let package = "<package version='2.0'><metadata><meta name='cover' content='cover'/></metadata><manifest><item id='one' href='Text/one.xhtml' media-type='application/xhtml+xml'/><item id='toc' href='toc.ncx' media-type='application/x-dtbncx+xml'/><item id='cover' href='cover.jpg' media-type='image/jpeg'/></manifest><spine toc='toc'><itemref idref='one'/></spine></package>"
        let ncx = "<ncx><navMap><navPoint id='n'><navLabel><text>Authored chapter</text></navLabel><content src='Text/one.xhtml#same'/></navPoint></navMap></ncx>"
        let bytes = try book(files: [("EPUB/toc.ncx", Data(ncx.utf8)), ("EPUB/cover.jpg", Data([1, 2, 3]))], package: package)
        let document = try await EPUBDocumentExtractor.extract(data: bytes)
        XCTAssertEqual(document.outline?.first?.label, "Authored chapter")
        XCTAssertEqual(document.outline?.first?.blockIndex, 0)
        XCTAssertEqual(try EPUBDocumentExtractor.coverImage(data: bytes), Data([1, 2, 3]))
        XCTAssertEqual(document.blocks.count, 2)
    }
    func testMalformedAndExcessiveNavigationAbstainsWithoutFailingReadableBook() async throws {
        for nav in ["<html><body>No TOC</body></html>", "<html xmlns:epub='http://www.idpf.org/2007/ops'><nav epub:type='toc'><ol>" + String(repeating: "<li><a href='Text/one.xhtml'>Chapter</a></li>", count: 4100) + "</ol></nav></html>"] {
            let bytes = try book(manifest: "<item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>", files: [("EPUB/nav.xhtml", Data(nav.utf8))])
            let document = try await EPUBDocumentExtractor.extract(data: bytes)
            XCTAssertNil(document.outline)
            XCTAssertTrue(document.warnings.contains { $0.contains("outline could not") })
            XCTAssertEqual(document.blocks.count, 4)
        }
    }

    func testEPUB3DeclaredCoverTakesPriorityOverFirstSpineIllustrations() throws {
        let marked = try coverPNG(), illustration = try coverPNG(width: 300, height: 400)
        let bytes = try book(manifest: "<item id='cover' href='cover.png' media-type='image/png' properties='cover-image'/><item id='illustration' href='illustration.png' media-type='image/png'/>",
            files: [("EPUB/cover.png", marked), ("EPUB/illustration.png", illustration),
                ("EPUB/Text/one.xhtml", Data("<html><body><img src='../illustration.png'/></body></html>".utf8))])
        XCTAssertEqual(try EPUBDocumentExtractor.coverImage(data: bytes), marked)
    }

    func testCoverGuideCanFindAnEmbeddedRasterInsideAnSVGWrapperOutsideTheSpine() throws {
        let cover = try coverPNG()
        let opf = "<package version='2.0'><metadata/><manifest><item id='one' href='Text/one.xhtml' media-type='application/xhtml+xml'/><item id='page' href='cover.svg' media-type='image/svg+xml'/><item id='art' href='Images/book.png' media-type='image/png'/></manifest><spine><itemref idref='one'/></spine><guide><reference type='cover' href='cover.svg'/></guide></package>"
        let bytes = try book(files: [("EPUB/cover.svg", Data("<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'><image xlink:href='Images/book.png'/></svg>".utf8)),
            ("EPUB/Images/book.png", cover)], package: opf)
        XCTAssertEqual(try EPUBDocumentExtractor.coverImage(data: bytes), cover)
    }

    func testUnmarkedFirstPageChoosesTheLargestPlausibleImageWithoutRewritingProse() async throws {
        let cover = try coverPNG(), logo = try coverPNG(width: 16, height: 16)
        let bytes = try book(manifest: "<item id='art' href='Images/book.png' media-type='image/png'/><item id='logo' href='Images/logo.png' media-type='image/png'/>",
            files: [("EPUB/Images/book.png", cover), ("EPUB/Images/logo.png", logo),
                ("EPUB/Text/one.xhtml", Data("<html><body><p>Original first prose.</p><img src='../Images/logo.png'/><img src='../Images/book.png'/></body></html>".utf8))])
        let before = try await EPUBDocumentExtractor.extract(data: bytes)
        XCTAssertEqual(try EPUBDocumentExtractor.coverImage(data: bytes), cover)
        let after = try await EPUBDocumentExtractor.extract(data: bytes)
        XCTAssertEqual(after, before)
        XCTAssertTrue(before.blocks.contains { $0.text == "Original first prose." })
    }

    func testFirstPageDoesNotFollowExternalOrUnmanifestedImagesOrSearchLaterChapters() throws {
        let cover = try coverPNG()
        for reference in ["https://example.invalid/cover.png", "file:///private/cover.png", "../../../escape.png", "../Images/hidden.png"] {
            let bytes = try book(manifest: "<item id='later' href='Images/later.png' media-type='image/png'/>",
                files: [("EPUB/Images/hidden.png", cover), ("EPUB/Images/later.png", cover),
                    ("EPUB/Text/one.xhtml", Data("<html><body><img src='\(reference)'/></body></html>".utf8)),
                    ("EPUB/Text/two.xhtml", Data("<html><body><img src='../Images/later.png'/></body></html>".utf8))])
            XCTAssertNil(try EPUBDocumentExtractor.coverImage(data: bytes))
        }
    }
}
