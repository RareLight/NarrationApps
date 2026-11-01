import Testing
@testable import AppPresentation

@Test func buildDescriptionIncludesShortRevisionAndModifiedFlag() {
    let info = AppBuildInformation(version: "0.1.0", build: "71", revision: "431413c1234567890abcdef", modified: true)
    #expect(info.buildDescription == "71, 431413c modified")
    let clean = AppBuildInformation(version: "0.1.0", build: "71", revision: "431413c1234567890abcdef", modified: false)
    #expect(clean.buildDescription == "71, 431413c" && clean.version == "0.1.0")
}

@Test func buildDescriptionOmitsEmptyRevision() {
    let info = AppBuildInformation(version: "0.1.0", build: "42", revision: "", modified: false)
    #expect(info.buildDescription == "42")
}

@Test func dictionaryInitReadsGeneratedKeysAndMissingMetadataFallsBack() {
    let info = AppBuildInformation(info: [
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "71",
        "NarrationAppsGitRevision": "431413c1234567890abcdef", "NarrationAppsSourceModified": true])
    #expect(info.version == "0.1.0" && info.build == "71" && info.modified && info.buildDescription.hasSuffix("modified"))
    let missing = AppBuildInformation(info: [:])
    #expect(missing.version == "unknown" && missing.build == "unknown" && missing.buildDescription == "unknown")
}

@Test func aboutDisplayMapsGeneratedProvenance() {
    let info = AppBuildInformation(info: [
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "71",
        "NarrationAppsGitRevision": "431413c1234567890abcdef", "NarrationAppsSourceModified": true])
    let display = AppBuildInformation.aboutDisplay(info)
    #expect(display.version == "0.1.0" && display.build == "71, 431413c modified")
}
