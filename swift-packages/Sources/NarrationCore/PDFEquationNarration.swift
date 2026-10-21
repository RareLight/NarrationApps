import Foundation
import Pronunciation

/// PDF text lacks a math tree. Read only unambiguous linear notation; never
/// interpret flattened fractions, missing glyphs or implicit subscripts as math.
enum PDFEquationNarration {
    static let complexCue = "For full equations, refer to the original text."
    static let complexCueRule = "complex-equation-cue-1"
    struct Result {
        var edits: [Int: [ProjectionEdit]] = [:]
        var omissions: [NarrationOmission] = []
        var readable = 0
        var complex = 0
    }
    // Legacy PDFs sometimes decode math glyphs as Latin-1 letters. Treat these
    // as boundaries for classification only; never guess their intended value.
    private static let proseWords = try! NSRegularExpression(pattern: #"[\p{L}&&[^þðÞ]]{3,}"#)
    private static let numberLabel = try! NSRegularExpression(pattern: #"\(\s*([0-9]{1,3})\s*\)\s*[.,:]?$"#)

    static func analyze(_ document: SemanticDocument, excluded: Set<Int>, pronunciations: PronunciationDictionary = .empty) throws -> Result {
        var result = Result(), count = 0
        let lexicon = DocumentWordLexicon()
        let anchors = CharacterSet(charactersIn: "=<>≤≥≈≠∫∑∏→¼þ")
        for (index, block) in document.blocks.enumerated() {
            try Task.checkCancellation()
            guard !excluded.contains(index), block.kind == .paragraph, block.role != .bibliography,
                  block.narrationText == nil, block.containsInlineCode != true,
                  block.origin == .authored || block.origin == .ocr,
                  let page = block.pdfPageIndex, let layout = block.pdfLayout,
                  layout.basis == .cropBox, layout.rotation == 0, layout.lines.count <= 1_024,
                  block.text.rangeOfCharacter(from: anchors) != nil else { continue }
            let ns = block.text as NSString
            var verifiedEnd = 0, valid = true
            for line in layout.lines {
                guard line.location >= verifiedEnd, line.length > 0, line.location <= ns.length,
                      line.length <= ns.length - line.location, line.bounds.isValid,
                      Range(NSRange(location: line.location, length: line.length), in: block.text) != nil,
                      ns.substring(with: NSRange(location: verifiedEnd, length: line.location - verifiedEnd)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { valid = false; break }
                verifiedEnd = line.location + line.length
            }
            guard valid, ns.substring(from: verifiedEnd).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let proseLines = layout.lines.filter { line in
                let value = ns.substring(with: NSRange(location: line.location, length: line.length)) as NSString
                let ordinary = proseWords.matches(in: value as String, range: NSRange(location: 0, length: value.length)).map { value.substring(with: $0.range) }
                    .filter { LinearMathSpeech.functionNames[$0] == nil && lexicon.contains($0) }
                return ordinary.count >= 2 || ordinary.contains { $0.count >= 5 }
            }
            var group: [PDFTextLine] = [], trailingComplex: Int?
            func flush() throws {
                defer { group = [] }
                guard let first = group.first, let last = group.last, group.count <= 80 else { return }
                let range = NSRange(location: first.location, length: last.location + last.length - first.location)
                guard range.length <= 2_000 else { return }
                let raw = ns.substring(with: range)
                // A wrapped link can leave a query such as c=12345 on its own
                // selection line. Keep it attached to its authored URL context.
                if group.count == 1,
                   let position = layout.lines.firstIndex(where: { $0.location == first.location }), position > 0 {
                    let previous = layout.lines[position - 1]
                    let prefix = ns.substring(with: NSRange(location: previous.location, length: previous.length))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                       prefix.range(of: #"(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)\S+$"#, options: .regularExpression) != nil {
                        trailingComplex = nil
                        return
                    }
                }
                if !pronunciations.entries.isEmpty, try !pronunciations.applyingWithMappings(to: raw).applications.isEmpty { trailingComplex = nil; return }
                let anchor = raw.rangeOfCharacter(from: anchors) != nil
                if !anchor, let priorIndex = trailingComplex {
                    let prior = result.omissions[priorIndex], end = prior.source.location + prior.source.length
                    let words = raw.split(whereSeparator: { !$0.isLetter }).map(String.init)
                    let prose = words.contains { $0.count >= 2 && LinearMathSpeech.functionNames[$0] == nil && lexicon.contains($0) }
                    if !prose, range.location >= end,
                       ns.substring(with: NSRange(location: end, length: range.location - end)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.omissions[priorIndex] = .init(source: .init(blockIndex: index, location: prior.source.location,
                            length: NSMaxRange(range) - prior.source.location), pageIndex: page, rule: prior.rule, reason: prior.reason)
                        for line in group {
                            result.edits[index, default: []].append(.init(range: NSRange(location: line.location, length: line.length),
                                replacement: "", rule: "scientific-equation-1"))
                        }
                        return
                    }
                }
                guard raw.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 1,
                      raw.filter({ !$0.isWhitespace }).count >= 3,
                      anchor else { return }
                // PDFKit splits inline symbols into separate selections too.
                // A prose fragment on the same visual baseline is not display math.
                let locations = Set(group.map(\.location))
                guard group.count > 1 || !proseLines.contains(where: { other in
                    !locations.contains(other.location) && group.contains { member in
                        let a = member.bounds, b = other.bounds
                        return (a.x < 0.5) == (b.x < 0.5) &&
                            abs(a.y - b.y) < min(a.height, b.height) * 0.65
                    }
                }) else { return }
                var expression = NarrationText.normalizeWhitespace(raw)
                let match = numberLabel.firstMatch(in: expression, range: NSRange(location: 0, length: expression.utf16.count))
                let label = match.map { (expression as NSString).substring(with: $0.range(at: 1)) }
                if let match { expression = (expression as NSString).substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines) }
                let prefix = label.map { "Equation \($0)" } ?? "Mathematical expression"
                let spoken: String
                // A sum limit or fraction fragment may parse as a complete
                // relation even though another selection overlaps it visually.
                // In that case, do not assert a standalone linear reading.
                let attachedFragment = group.count == 1 && layout.lines.contains { other in
                    guard other.location != first.location else { return false }
                    let a = first.bounds, b = other.bounds
                    return a.x < b.x + b.width + 0.002 && b.x < a.x + a.width + 0.002 &&
                        a.y < b.y + b.height + 0.002 && b.y < a.y + a.height + 0.002
                }
                if group.count == 1, !attachedFragment, first.bounds.height <= 0.028, let linear = LinearMathSpeech.read(expression) {
                    spoken = " " + prefix + ". " + linear + ". "
                    result.readable += 1
                    trailingComplex = nil
                } else {
                    spoken = " " + complexCue + " "
                    result.complex += 1
                    result.omissions.append(.init(source: .init(blockIndex: index, location: range.location, length: range.length),
                        pageIndex: page, rule: "complex-equation-1", reason: "\(prefix) retained in the original source; complex-equation speech is replaced by one document-level reference notice. Surrounding explanations are retained."))
                    trailingComplex = result.omissions.count - 1
                }
                for (position, line) in group.enumerated() {
                    result.edits[index, default: []].append(.init(range: NSRange(location: line.location, length: line.length),
                        replacement: position == 0 ? spoken : "", rule: position == 0 && trailingComplex != nil ? complexCueRule : "scientific-equation-1"))
                }
            }
            var previousEnd = 0
            for line in layout.lines {
                count += 1
                guard count <= 100_000, line.location >= previousEnd, line.length > 0,
                      line.location <= ns.length, line.length <= ns.length - line.location,
                      Range(NSRange(location: line.location, length: line.length), in: block.text) != nil,
                      line.bounds.isValid else { try flush(); break }
                let text = ns.substring(with: NSRange(location: line.location, length: line.length))
                let words = proseWords.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
                // A named function assignment is display math even when its
                // name is an English word. Recognize the region for a cue;
                // never attempt to reconstruct its advanced operations.
                let functionAssignment = text.utf16.count <= 512 &&
                    text.range(of: #"^\s*[A-Za-z][A-Za-z0-9_]{1,31}\s*\([^=\n]{0,160}\)\s*="#, options: .regularExpression) != nil &&
                    text.split(separator: "=", maxSplits: 1).last.map { right in
                        let value = String(right) as NSString
                        let prose = proseWords.matches(in: value as String, range: NSRange(location: 0, length: value.length)).filter {
                            let word = value.substring(with: $0.range)
                            return LinearMathSpeech.functionNames[word] == nil && lexicon.contains(word)
                        }
                        return prose.count < 2
                    } == true
                let chemistry = text.rangeOfCharacter(from: CharacterSet(charactersIn: "→þ")) != nil || group.contains { member in
                    ns.substring(with: NSRange(location: member.location, length: member.length)).rangeOfCharacter(from: CharacterSet(charactersIn: "→þ")) != nil
                }
                let fragmented = group.contains { member in
                    ns.substring(with: NSRange(location: member.location, length: member.length)).rangeOfCharacter(from: CharacterSet(charactersIn: "=<>≤≥≈≠∫∑∏")) != nil
                } || (group.count >= 2 && group.allSatisfy { member in
                    ns.substring(with: NSRange(location: member.location, length: member.length)).trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy(\.isNumber)
                })
                let math = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (functionAssignment || words.allSatisfy {
                        let word = (text as NSString).substring(with: $0.range)
                        return LinearMathSpeech.functionNames[word] != nil ||
                            (chemistry && (word == "mol" || word.range(of: #"^(?:[A-Z][a-z]?)+$"#, options: .regularExpression) != nil)) ||
                            (fragmented && word.count <= 6 && word.allSatisfy(\.isASCII) && !lexicon.contains(word))
                    }) &&
                    text.range(of: #"[\"“”‘;?]"#, options: .regularExpression) == nil &&
                    line.bounds.y > 0.04 && line.bounds.y < 0.94
                // Extensible mathematical brackets are display structure even
                // when a font selection overlaps a nearby prose baseline.
                let delimiter = text.unicodeScalars.contains { (0x239B...0x23AD).contains($0.value) }
                let inline = !delimiter && text.unicodeScalars.contains(where: CharacterSet.letters.contains) && proseLines.contains { prose in
                    let a = line.bounds, b = prose.bounds
                    return line.location != prose.location && a.height <= b.height * 2.2 &&
                        (a.x < 0.5) == (b.x < 0.5) &&
                        (a.x + a.width <= b.x + 0.002 || b.x + b.width <= a.x + 0.002) &&
                        abs(a.y + a.height / 2 - b.y - b.height / 2) < (a.height + b.height) * 0.75
                }
                // A tall bracket's selection can extend across the gutter even
                // though its ink starts in the same column as the expression.
                if let previous = group.last,
                   (previous.bounds.x < 0.5) != (line.bounds.x < 0.5) { try flush() }
                if math && !inline {
                    if let previous = group.last,
                       !ns.substring(with: NSRange(location: previous.location + previous.length,
                            length: line.location - previous.location - previous.length)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try flush() }
                    group.append(line)
                } else { try flush(); trailingComplex = nil }
                previousEnd = line.location + line.length
            }
            try flush()
        }
        return result
    }
}

/// Small, bounded grammar for explicit linear notation, not a PDF/LaTeX parser.
/// A full MathML speech engine can be used once intake supplies a reliable tree.
enum LinearMathSpeech {
    private static let names: [Character: String] = [
        "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "epsilon", "ζ": "zeta", "η": "eta", "θ": "theta",
        "ι": "iota", "κ": "kappa", "λ": "lambda", "μ": "mu", "ν": "nu", "ξ": "xi", "π": "pi", "ρ": "rho",
        "σ": "sigma", "τ": "tau", "υ": "upsilon", "φ": "phi", "χ": "chi", "ψ": "psi", "ω": "omega", "Δ": "capital delta",
        "Φ": "capital phi", "Θ": "capital theta", "Σ": "capital sigma", "Ω": "capital omega"]
    private static let letters = ["ay", "bee", "see", "dee", "ee", "ef", "gee", "aitch", "eye", "jay", "kay", "el", "em", "en", "oh", "pee", "cue", "ar", "ess", "tee", "you", "vee", "double you", "ex", "why", "zee"]
    private static let operators: [String: String] = ["+": "plus", "-": "minus", "−": "minus", "×": "times", "*": "times", "·": "dot", "/": "divided by", "÷": "divided by", "=": "equals", "<": "is less than", ">": "is greater than", "≤": "is less than or equal to", "≥": "is greater than or equal to", "≈": "is approximately", "≠": "is not equal to", "±": "plus or minus"]
    // One vocabulary for detection and speech; longest-first tokenization keeps
    // hyperbolic names intact rather than splitting cosh into cos and h.
    static let functionNames = ["sin": "sine", "cos": "cosine", "tan": "tangent", "sec": "secant", "csc": "cosecant", "cot": "cotangent",
        "sinh": "hyperbolic sine", "cosh": "hyperbolic cosine", "tanh": "hyperbolic tangent",
        "ln": "natural logarithm", "log": "logarithm", "exp": "exponential", "sqrt": "square root",
        "erf": "error function", "abs": "absolute value", "min": "minimum", "max": "maximum"]
    private static let tokens = try! NSRegularExpression(pattern:
        functionNames.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|") +
        #"|[0-9]+(?:\.[0-9]+)?|[A-Za-zα-ωΔΦΘΣΩ]|[+\-−×*·/÷=<>≤≥≈≠±()^_²³]"#)

    static func read(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        guard text.utf16.count <= 240,
              text.range(of: #"[A-Za-zα-ω][0-9]|[A-Za-z]{2,}"#, options: .regularExpression).map({ range in functionNames[String(text[range])] == nil }) != true else { return nil }
        let ns = text as NSString
        let matches = tokens.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty, matches.count <= 80 else { return nil }
        var cursor = 0, values: [String] = []
        for match in matches {
            guard ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            values.append(ns.substring(with: match.range)); cursor = NSMaxRange(match.range)
        }
        guard ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var parser = Parser(tokens: values)
        guard let spoken = parser.relation(), parser.position == values.count else { return nil }
        return spoken
    }
    private struct Parser {
        let tokens: [String]
        var position = 0
        var depth = 0
        var next: String? { position < tokens.count ? tokens[position] : nil }
        mutating func relation() -> String? {
            guard var result = sum() else { return nil }
            if let op = next, ["=", "<", ">", "≤", "≥", "≈", "≠"].contains(op) {
                position += 1
                guard let right = sum() else { return nil }
                result += " \(operators[op]!) " + right
            }
            return result
        }
        mutating func sum() -> String? {
            guard var result = product() else { return nil }
            while let op = next, ["+", "-", "−", "±"].contains(op) {
                position += 1
                guard let right = product() else { return nil }
                result += " \(operators[op]!) " + right
            }
            return result
        }
        mutating func product() -> String? {
            guard var result = atom() else { return nil }
            while let op = next, ["×", "*", "·", "/", "÷"].contains(op) {
                position += 1
                guard let right = atom() else { return nil }
                result += " \(operators[op]!) " + right
            }
            return result
        }
        mutating func atom() -> String? {
            guard let token = next, depth < 12 else { return nil }
            position += 1; depth += 1
            defer { depth -= 1 }
            var value: String
            if token == "-" || token == "−" {
                guard let inner = atom() else { return nil }; value = "negative " + inner
            } else if token == "(" {
                guard let inner = sum(), next == ")" else { return nil }
                position += 1; value = "open parenthesis " + inner + " close parenthesis"
            } else if let function = functionNames[token] {
                guard let inner = atom() else { return nil }; value = function + " of " + inner
            } else if let number = Double(token), number.isFinite { value = token }
            else if let name = token.first.flatMap({ names[$0] }) { value = name }
            else if token.count == 1, let ascii = token.lowercased().utf8.first, (97...122).contains(ascii) {
                value = (token.first?.isUppercase == true ? "capital " : "") + letters[Int(ascii - 97)]
            } else { return nil }
            if next == "_" {
                position += 1
                guard let sub = next, sub.allSatisfy(\.isNumber) else { return nil }
                position += 1; value += " subscript " + sub
            }
            if next == "²" || next == "³" {
                value += next == "²" ? " squared" : " cubed"; position += 1
            } else if next == "^" {
                position += 1
                guard let exponent = atom() else { return nil }; value += " to the power " + exponent
            }
            return value
        }
    }
}
