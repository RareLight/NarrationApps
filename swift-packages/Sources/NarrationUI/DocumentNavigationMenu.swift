import SwiftUI
import NarrationCore

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
    public init(options: Binding<NarrationOptions>) { _options = options }
    public var body: some View {
        Picker("Notes", selection: $options.notes) {
            ForEach(NarrationOptions.NotePlacement.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Include auxiliary sections", isOn: $options.includeAuxiliary)
            .help("Applies only to sections explicitly marked as auxiliary, such as appendices. Unclassified prose and bibliographies are retained.")
        Toggle("Rejoin PDF word wraps (experimental)", isOn: $options.experimentalPDFWordJoining)
            .help("Tries Readium-style joining at verified PDF line endings before lowercase text. Can remove genuine compound hyphens. Off by default; original source stays intact. Applies to future jobs.")
    }
}
