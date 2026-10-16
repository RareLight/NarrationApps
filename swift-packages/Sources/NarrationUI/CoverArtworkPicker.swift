import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AppPresentation

/// Selection presentation only; each app owns persistence and validation policy.
public struct CoverArtworkPicker: View {
    private let title: String
    private let url: URL?
    private let selected: Bool
    private let choose: (URL) -> Void
    private let remove: () -> Void
    private let failure: (String) -> Void
    @State private var importing = false
    @State private var thumbnail: NSImage?
    public init(title: String = "Cover Art", url: URL?, selected: Bool,
                choose: @escaping (URL) -> Void, remove: @escaping () -> Void,
                failure: @escaping (String) -> Void) {
        self.title = title; self.url = url; self.selected = selected
        self.choose = choose; self.remove = remove; self.failure = failure
    }
    public var body: some View {
        HStack(spacing: 10) {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 48, height: 56).accessibilityLabel(title) }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).appFont(.headline)
                HStack {
                    Button(selected ? "Replace…" : "Choose…") { importing = true }
                    if selected { Button("Remove", action: remove) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.jpeg, .png]) { result in
            switch result { case .success(let url): choose(url); case .failure: failure("The cover image could not be opened.") }
        }
        .task(id: url) {
            thumbnail = nil
            guard let url else { return }
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 112] as CFDictionary) else { return nil }
                let output = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(dest, image, nil)
                return CGImageDestinationFinalize(dest) ? output as Data : nil
            }.value
            if !Task.isCancelled, let data { thumbnail = NSImage(data: data) }
        }
    }
}
