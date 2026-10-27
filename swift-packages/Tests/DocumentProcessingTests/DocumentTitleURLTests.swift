import Foundation
import Testing
import NarrationCore
@testable import DocumentProcessing

@Test func documentTitleKeepsDescriptiveHTMLSlugMatches() async throws {
    let title = "How Wetlands Protect Coastal Communities"
    let url = URL(string: "https://articles.example/how-wetlands-protect-coastal-communities")!
    let blocks = [ContentBlock(kind: .heading, text: title, headingLevel: 1),
                  .init(kind: .heading, text: "Restoration Methods and Results", headingLevel: 2)]
    #expect(!DocumentTitles.isWeak(title, urls: [url]))
    let metadata = try await DocumentTitles.resolve(title: title, sourceTitle: title, blocks: blocks, urls: [url])
    #expect(metadata == DocumentTitle(text: title, origin: .metadata))
    let readingList = try await DocumentTitles.resolve(title: "Untitled article", sourceTitle: title, blocks: blocks, urls: [url])
    #expect(readingList == DocumentTitle(text: title, origin: .readingList))
    let heading = try await DocumentTitles.resolve(title: "Untitled article", blocks: blocks, urls: [url])
    #expect(heading == DocumentTitle(text: title, origin: .headline))
}

@Test func documentTitleRetainsFilenameRecoveryForExtensionlessPDFs() async throws {
    let urls = [URL(string: "https://articles.example/original-report")!, URL(string: "https://cdn.example/cache/download")!]
    let blocks = [ContentBlock(kind: .heading, text: "How Wetlands Protect Coastal Communities", headingLevel: 1)]
    #expect(DocumentTitles.isWeak("Original Report", urls: urls, isPDF: true))
    let result = try await DocumentTitles.resolve(title: "Original Report", blocks: blocks, urls: urls, isPDF: true)
    #expect(result == DocumentTitle(text: blocks[0].text, origin: .headline))
}
