import Foundation
import XCTest

final class ProjectResourcesTests: XCTestCase {
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
