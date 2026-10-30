import Foundation
import Pronunciation

/// Common discretionary-wrap handling and narrow Kokoro spoken forms.
/// Native G2P still owns cardinal/decimal and
/// currency pronunciation. Explicit capital-A labels use its existing letter-name
/// spelling; no formatter parses arbitrary prose or converts units.
final class SpokenFormNormalizer {
    static let version = "spoken-forms-2"
    static func locale(_ settings: SpeechSettings) -> String { settings.voice.hasPrefix("b") ? "en_GB" : "en_US" }
    private static let candidates = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{M}\p{N}_.,/:+\-−=])(?:([\-−]?[0-9]{1,7}(?:\.[0-9]{1,6})?)[ ]*(kg|°[ ]*[CF])|([0-9]{1,2}):([0-9]{2})[ ]*([ap])\.?m\.?|(?:package|plan|option|appendix|section|figure|table|part|group|class|type|grade|vitamin|letter)[ ]+((?-i:A))(?![\p{L}\p{M}\p{N}_'’+\-−])(?!\.[\p{L}\p{M}\p{N}_]))(?![\p{L}\p{M}\p{N}_/:°%])(?!\.[0-9])"#, options: .caseInsensitive)
    private static let discretionaryHyphens = try! NSRegularExpression(pattern: #"(?<=[\p{L}\p{M}])\u00ad[ ]*(?=[\p{L}\p{M}])"#)
    private let usesSpokenForms: Bool
    var discretionaryCount = 0
    let locale: String
    var count = 0
    var skipped = false
    var codeProtected = false
    // Foundation can cache a MeasurementFormatter's numeric pattern after first
    // use. Keep at most seven immutable precision configurations per job instead
    // of mutating a cached formatter between quantities.
    private var formatters: [Int: MeasurementFormatter] = [:]
    private func formatter(fractionDigits: Int) -> MeasurementFormatter {
        if let value = formatters[fractionDigits] { return value }
        let numbers = NumberFormatter()
        numbers.locale = Locale(identifier: locale); numbers.numberStyle = .decimal
        numbers.usesGroupingSeparator = false; numbers.maximumFractionDigits = 6
        numbers.minimumFractionDigits = fractionDigits
        let value = MeasurementFormatter()
        value.locale = Locale(identifier: locale); value.unitOptions = .providedUnit; value.unitStyle = .long
        value.numberFormatter = numbers
        formatters[fractionDigits] = value
        return value
    }
    init(settings: SpeechSettings) { locale = Self.locale(settings); usesSpokenForms = settings.model == .kokoro || (settings.expandSpokenForms == true && settings.effectiveLanguage == "English") }
    struct Result {
        let text: String
        let applications: [PronunciationApplication]
        let mappings: [ProjectionMapping]?
    }
    private func protectedRegions(in text: String) throws -> [NSRange] {
        let ns = text as NSString
        var regions: [NSRange] = [], start = 0, hasPath = false, tick: Int?
        let operators: Set<UInt16> = [43, 42, 47, 61, 94, 215, 60, 62, 8804, 8805]
        func word(endingAt end: Int) {
            if hasPath || (end - start >= 4 && ns.substring(with: NSRange(location: start, length: 4)).lowercased() == "www.") {
                regions.append(NSRange(location: start, length: end - start))
            }
        }
        // Whitespace has already been normalized to ASCII spaces by the planner.
        // Track UTF-16 offsets as we scan; no repeated prefix counts or wildcard
        // regex backtracking on long URLs, equations or unbroken identifiers.
        for (offset, unit) in text.utf16.enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            if unit == 96 {
                if let opening = tick { regions.append(NSRange(location: opening, length: offset + 1 - opening)); tick = nil }
                else { tick = offset }
            }
            if unit == 47 || unit == 64 || unit == 92 { hasPath = true }
            if operators.contains(unit) {
                let low = max(0, offset - 120)
                regions.append(NSRange(location: low, length: min(ns.length, offset + 121) - low))
            }
            if unit == 32 { word(endingAt: offset); start = offset + 1; hasPath = false }
            guard regions.count <= 100_000 else { throw NarrationError.invalidInput("Spoken-form context budget exceeded. No text was truncated.") }
        }
        word(endingAt: ns.length)
        if let tick { regions.append(NSRange(location: tick, length: ns.length - tick)) }
        var merged: [NSRange] = []
        for range in regions.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= range.location { merged[merged.count - 1] = NSUnionRange(last, range) }
            else { merged.append(range) }
        }
        return merged
    }
    func apply(text: String, application: PronunciationApplicationResult, block: ContentBlock?, index: Int?, canonical: Bool, initialProjection: MappedProjection? = nil) throws -> Result {
        func unchanged() throws -> Result {
            guard var mapped = initialProjection else { return .init(text: application.text, applications: application.applications, mappings: nil) }
            if !application.applications.isEmpty {
                mapped = try mapped.applying(application.applications.map { .init(range: NSRange(location: $0.sourceLocation, length: $0.sourceLength), replacement: $0.spelling, rule: "pronunciation-1") })
            }
            guard mapped.text == application.text else { throw NarrationError.invalidInput("PDF projection source alignment failed. No text was truncated.") }
            return .init(text: mapped.text, applications: application.applications, mappings: mapped.mappings)
        }
        let ns = application.text as NSString
        var candidates: [NSTextCheckingResult] = [], exceeded = false
        var expressions = usesSpokenForms ? [Self.candidates] : []
        if ns.range(of: "\u{ad}", options: .literal).location != NSNotFound { expressions.append(Self.discretionaryHyphens) }
        for expression in expressions {
            expression.enumerateMatches(in: application.text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                if let match {
                    if candidates.count >= 100_000 { exceeded = true; stop.pointee = true; return }
                    candidates.append(match)
                }
            }
            if exceeded { break }
        }
        candidates.sort { $0.range.location < $1.range.location }
        try Task.checkCancellation()
        if exceeded { throw NarrationError.invalidInput("Spoken-form candidate budget exceeded. No text was truncated.") }
        guard !candidates.isEmpty else { return try unchanged() }
        let protected = try protectedRegions(in: application.text)
        var protectedIndex = 0, userIndex = 0, edits: [ProjectionEdit] = []
        for match in candidates {
            try Task.checkCancellation()
            while protectedIndex < protected.count && NSMaxRange(protected[protectedIndex]) <= match.range.location { protectedIndex += 1 }
            while userIndex < application.applications.count && application.applications[userIndex].spokenLocation + application.applications[userIndex].spokenLength <= match.range.location { userIndex += 1 }
            if protectedIndex < protected.count && NSIntersectionRange(protected[protectedIndex], match.range).length > 0 { continue }
            if userIndex < application.applications.count {
                let user = application.applications[userIndex]
                if NSIntersectionRange(NSRange(location: user.spokenLocation, length: user.spokenLength), match.range).length > 0 { continue }
            }
            var range = match.range
            let replacement: String
            let rule: String
            if match.numberOfRanges == 1 {
                replacement = ""; rule = "discretionary-hyphen-1"
            } else if match.range(at: 6).location != NSNotFound {
                // The native tagger can mistake uppercase labels (Package A,
                // Plan A) for determiners. Its existing "ay" entry is the letter
                // name in both regions. Replace only A, retaining its source span.
                range = match.range(at: 6)
                replacement = "ay"; rule = "letter-label-a-1"
            } else if match.range(at: 1).location != NSNotFound {
                let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "−", with: "-")
                guard let number = Double(raw), number.isFinite else { continue }
                let unit = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: " ", with: "").lowercased()
                let formatter = formatter(fractionDigits: raw.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0)
                let rendered: String
                if unit == "kg" {
                    let render: (Measurement<UnitMass>) -> String = formatter.string(from:)
                    rendered = render(.init(value: abs(number), unit: .kilograms)); rule = "quantity-kg-1"
                }
                else {
                    let render: (Measurement<UnitTemperature>) -> String = formatter.string(from:)
                    rendered = render(.init(value: abs(number), unit: unit == "°c" ? .celsius : .fahrenheit))
                    rule = "temperature-1"
                }
                // The actual frontend treats a leading minus as punctuation.
                replacement = (raw.hasPrefix("-") ? "minus " : "") + rendered
            } else {
                guard let hour = Int(ns.substring(with: match.range(at: 3))), (1...12).contains(hour),
                      let minute = Int(ns.substring(with: match.range(at: 4))), (0...59).contains(minute) else { continue }
                let period = ns.substring(with: match.range(at: 5)).lowercased() + ".m."
                replacement = "\(hour)" + (minute == 0 ? "" : minute < 10 ? " oh \(minute)" : " \(minute)") + " " + period
                rule = "explicit-time-1"
            }
            edits.append(.init(range: range, replacement: replacement, rule: rule))
            guard count + discretionaryCount + edits.count <= 100_000 else { throw NarrationError.invalidInput("Too many spoken-form changes to prepare safely. No text was truncated.") }
        }
        guard !edits.isEmpty else { return try unchanged() }
        if block?.containsInlineCode == true {
            codeProtected = true
            return try unchanged()
        }
        guard let block, initialProjection != nil || block.origin != nil || block.containsInlineCode == false, let index, var mapped = try initialProjection ?? MappedProjection.aligned(canonical ? text.precomposedStringWithCanonicalMapping : text, block: block, index: index, canonical: canonical) else {
            skipped = true
            return try unchanged()
        }
        if !application.applications.isEmpty {
            mapped = try mapped.applying(application.applications.map { .init(range: NSRange(location: $0.sourceLocation, length: $0.sourceLength), replacement: $0.spelling, rule: "pronunciation-1") })
        }
        guard mapped.text == application.text else { throw NarrationError.invalidInput("Spoken-form source alignment failed. No text was truncated.") }
        mapped = try mapped.applying(edits)
        let discretionary = edits.filter { $0.rule == "discretionary-hyphen-1" }.count
        discretionaryCount += discretionary
        count += edits.count - discretionary
        // Existing dictionary source offsets retain their documented normalized
        // pre-dictionary coordinates. Only the spoken offsets shift here.
        var editIndex = 0, delta = 0
        let applications = application.applications.map { value in
            while editIndex < edits.count && NSMaxRange(edits[editIndex].range) <= value.spokenLocation {
                delta += edits[editIndex].replacement.utf16.count - edits[editIndex].range.length; editIndex += 1
            }
            return value.shiftedSpoken(by: delta)
        }
        return .init(text: mapped.text, applications: applications, mappings: mapped.mappings)
    }
}
