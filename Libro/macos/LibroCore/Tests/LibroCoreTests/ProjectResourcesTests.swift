import Foundation
import XCTest
import LibroCore

final class ProjectResourcesTests: XCTestCase {
    func testEveryAppSourceHasOneUniqueGUIBuildReference() throws {
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: macOS.appendingPathComponent("Libro/Libro.xcodeproj/project.pbxproj"))
        let text = String(decoding: data, as: UTF8.self)
        let definitions = try NSRegularExpression(pattern: "(?m)^\\t{2}([A-F0-9]{24})\\s*(?:/\\*[^\\n]*\\*/\\s*)?=\\s*\\{")
        let identifiers = definitions.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        XCTAssertEqual(identifiers.count, objects.count)
        let target = try XCTUnwrap(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "Libro" })
        let phases = try XCTUnwrap(target["buildPhases"] as? [String])
        let sources = try XCTUnwrap(phases.compactMap { objects[$0] }.first { $0["isa"] as? String == "PBXSourcesBuildPhase" })
        let files = try XCTUnwrap(sources["files"] as? [String])
        let paths = try files.map { identifier in
            let build = try XCTUnwrap(objects[identifier])
            XCTAssertEqual(build["isa"] as? String, "PBXBuildFile")
            let reference = try XCTUnwrap(build["fileRef"] as? String)
            return try XCTUnwrap(objects[reference]?["path"] as? String)
        }
        let expected = try FileManager.default.contentsOfDirectory(atPath: macOS.appendingPathComponent("Libro/App").path)
            .filter { $0.hasSuffix(".swift") }.map { "App/\($0)" }
        XCTAssertEqual(paths.count, Set(paths).count)
        XCTAssertEqual(Set(paths), Set(expected))
    }

    func testEPUBIsRegisteredForFinderAndImportPanels() throws {
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: macOS.appendingPathComponent("Libro/App/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let documents = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertTrue(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains("org.idpf.epub-container") == true })
        XCTAssertTrue(DocumentKind.contentTypes.contains { $0.identifier == "org.idpf.epub-container" })
    }

    func testCommonNoticesBelongToTheGUIResourcePhase() throws {
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: macOS.appendingPathComponent("Libro/Libro.xcodeproj/project.pbxproj"))
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        let target = try XCTUnwrap(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "Libro" })
        let phases = try XCTUnwrap(target["buildPhases"] as? [String])
        let resources = try XCTUnwrap(phases.compactMap { objects[$0] }.first { $0["isa"] as? String == "PBXResourcesBuildPhase" })
        let files = try XCTUnwrap(resources["files"] as? [String])
        let references = files.compactMap { objects[$0]?["fileRef"] as? String }.compactMap { objects[$0] }
        XCTAssertTrue(references.contains { $0["path"] as? String == "../../../swift-packages/ThirdPartyNotices" })
    }
    func testTypographyUsesItsIndependentPackage() throws {
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: macOS.appendingPathComponent("Libro/Libro.xcodeproj/project.pbxproj"))
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        let target = try XCTUnwrap(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "Libro" })
        let products = try XCTUnwrap(target["packageProductDependencies"] as? [String])
        let typography = try XCTUnwrap(products.compactMap { objects[$0] }.first { $0["productName"] as? String == "AppPresentation" })
        let reference = try XCTUnwrap(typography["package"] as? String)
        XCTAssertEqual(objects[reference]?["relativePath"] as? String, "../../../swift-packages/AppPresentation")
    }

    func testSharedSettingsLibraryIsLinkedOnlyIntoTheGUI() throws {
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: macOS.appendingPathComponent("Libro/Libro.xcodeproj/project.pbxproj"))
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        for target in objects.values.filter({ $0["isa"] as? String == "PBXNativeTarget" }) {
            let products = (target["packageProductDependencies"] as? [String] ?? []).compactMap { objects[$0]?["productName"] as? String }
            if target["name"] as? String == "Libro" {
                XCTAssertTrue(products.contains("NarrationUI"))
                XCTAssertFalse(products.contains("NativeSpeechEngine"))
            } else { XCTAssertFalse(products.contains("NarrationUI")) }
        }
    }

}
