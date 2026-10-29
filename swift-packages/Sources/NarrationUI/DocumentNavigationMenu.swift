import SwiftUI
import NarrationCore
import AppPresentation

public struct DocumentNavigationMenu: View {
    private let entries: [DocumentOutlineEntry]
    private let select: (DocumentOutlineEntry) -> Void
    public init(entries: [DocumentOutlineEntry], select: @escaping (DocumentOutlineEntry) -> Void) { self.entries = entries; self.select = select }
    public var body: some View {
        if !entries.isEmpty {
            Menu("Contents", systemImage: "list.bullet.indent") {
                ForEach(entries.prefix(DocumentNavigation.maximumEntries)) { entry in
                    Button(String(repeating: "  ", count: min(max(entry.depth, 0), 31)) + entry.label + (entry.precision == .page ? " (page \((entry.pageIndex ?? 0) + 1))" : "")) { select(entry) }
                        .disabled(entry.blockIndex == nil || entry.precision == .unresolved)
                }
            }
        }
    }
}

public struct NarrationOptionsControls: View {
    @Binding private var options: NarrationOptions
    private let showsExamples: Bool
    public init(options: Binding<NarrationOptions>, showsExamples: Bool = false) {
        _options = options; self.showsExamples = showsExamples
    }
    public var body: some View {
        Picker("Footnotes", selection: $options.notes) {
            ForEach(NarrationOptions.NotePlacement.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .help("Choose when marked notes are read.")
        if showsExamples {
            DocumentTextExample(source: "Main text¹ → more text\n¹ Footnote", narration: noteExample)
        }
        Toggle("Strip inline citations", isOn: $options.stripInlineCitations)
            .help("Skip recognized citations; keep ordinary numbers and parentheses.")
        if showsExamples {
            DocumentTextExample(source: "Forests recover (Smith, 2020).",
                narration: options.stripInlineCitations ? "Forests recover." : "Forests recover (Smith, 2020).")
        }
        Toggle("Strip endnote citations", isOn: $options.stripEndnoteCitations)
            .help("Skip reference lists and citation-only notes.")
        if showsExamples {
            DocumentTextExample(source: "Main text → reference list → explanatory note",
                narration: options.stripEndnoteCitations ? "Main text → explanatory note" : "Main text → reference list → explanatory note")
        }
        Toggle("Read appendices and extra sections", isOn: $options.includeAuxiliary)
            .help("Include marked appendices and extra sections.")
        if showsExamples {
            DocumentTextExample(source: "Main text → appendix",
                narration: options.includeAuxiliary ? "Main text → appendix" : "Main text")
        }
        Toggle("Join split words in PDFs (experimental)", isOn: $options.experimentalPDFWordJoining)
            .help("Join verified split English words; keep compounds and uncertain spellings.")
        if showsExamples {
            DocumentTextExample(source: "inter-\nnational",
                narration: options.experimentalPDFWordJoining ? "international" : "inter- national",
                detail: "Keeps recognized compounds such as well-known. Uncertain words stay unchanged; review PDF narration before exporting.")
        }
    }

    private var noteExample: String {
        switch options.notes {
        case .current: "Main text → footnote → more text"
        case .endOfDocument: "Main text → more text → footnote"
        case .omit: "Main text → more text"
        }
    }
}
