import Foundation

/// Prose keeps its source order; numeric grids require explicit relationships.
public enum TableNarration {
    public static let unavailable = "Table. The row and column relationships could not be read reliably. See the original document."

    private static func isVerbose(_ value: String) -> Bool {
        var words = 0, letters = 0
        value.enumerateSubstrings(in: value.startIndex..<value.endIndex, options: .byWords) { word, _, _, stop in
            let count = word?.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count ?? 0
            if count >= 2 { words += 1; letters += count }
            if words >= 6 && letters >= 24 { stop = true }
        }
        return words >= 6 && letters >= 24
    }

    public static func render(rows: [[String]], hasHeader: Bool = true, relationshipsReliable: Bool = true) -> String {
        let rows = rows.map { $0.map(NarrationText.normalizeWhitespace) }
        guard let first = rows.first, !first.isEmpty, rows.count <= 200,
              rows.allSatisfy({ $0.count <= 32 }),
              rows.flatMap({ $0 }).reduce(0, { $0 + $1.utf16.count }) <= 32_000 else { return unavailable }
        let data = hasHeader ? Array(rows.dropFirst()) : rows
        let verboseRows = data.filter { $0.contains(where: isVerbose) }.count
        let proseOriented = verboseRows > 0 && verboseRows * 2 > data.count
        let selected = data.enumerated().filter { _, row in
            proseOriented || data.count <= 40 || row.contains(where: isVerbose)
        }
        func sentence(_ text: String) -> String {
            text + (text.last.map { ".!?;:".contains($0) } == true ? "" : ".")
        }
        // A prose inset does not need a reconstructed grid. Keep every cell of
        // each selected row, including brief labels/quantities, in source order.
        if !selected.isEmpty, proseOriented || selected.allSatisfy({ $0.element.contains(where: isVerbose) }) {
            var prose = hasHeader ? first.filter { !$0.isEmpty }.map(sentence) : []
            prose += selected.map { $0.element.filter { !$0.isEmpty }.map(sentence).joined(separator: " ") }
            if selected.count < data.count {
                prose.append("\(data.count - selected.count) numeric or brief rows remain in the original table.")
            }
            return prose.joined(separator: " ")
        }
        guard relationshipsReliable, (1...8).contains(first.count), rows.allSatisfy({ $0.count == first.count }) else { return unavailable }
        let headers = hasHeader ? first : first.indices.map { "Column \($0 + 1)" }
        guard headers.allSatisfy({ !$0.isEmpty && $0.count <= 160 && $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }),
              Set(headers.map { $0.lowercased() }).count == headers.count else { return unavailable }
        // A long numeric grid is not useful as an unlabeled stream of numbers.
        // Verbose entries remain readable; disclose every row left to the source.
        var sentences = ["Table with \(data.count) rows. Columns: \(headers.joined(separator: "; "))."]
        for (index, row) in selected {
            if row.contains(where: isVerbose) {
                sentences.append(row.filter { !$0.isEmpty }.map(sentence).joined(separator: " "))
                continue
            }
            let label = row[0].isEmpty ? "Row \(index + 1)" : "\(headers[0]): \(row[0])"
            let cells = row.indices.dropFirst().map { "\(headers[$0]): \(row[$0].isEmpty ? "blank" : row[$0])" }
            sentences.append(label + (cells.isEmpty ? "." : ". " + cells.joined(separator: "; ") + "."))
        }
        if selected.count < data.count {
            sentences.append("\(data.count - selected.count) numeric or brief rows remain in the original table.")
        }
        sentences.append("End table.")
        return sentences.joined(separator: " ")
    }

    static func render(_ block: ContentBlock) -> String {
        if let spoken = block.narrationText { return spoken }
        guard block.text.contains("|") else {
            let letters = block.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let digits = block.text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            return block.text.utf16.count <= 32_000 && letters > digits * 2 && isVerbose(block.text) ? NarrationText.normalizeWhitespace(block.text) : unavailable
        }
        let rows = block.text.split(whereSeparator: \.isNewline).map { line in
            line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        }
        // Legacy/OCR pipe rows have cell boundaries but no header semantics.
        // Number the columns rather than treating the first data row as labels.
        return render(rows: rows, hasHeader: false)
    }
}
