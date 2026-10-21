import XCTest
import Pronunciation
@testable import NarrationCore

final class ScientificNarrationTests: XCTestCase {
    func testLinearGrammarReadsExplicitOperationsWithoutGuessingLostStructure() {
        XCTAssertEqual(LinearMathSpeech.read("x = 2 + 3"), "ex equals 2 plus 3")
        XCTAssertEqual(LinearMathSpeech.read("α_1 = -0.5 / 2"), "alpha subscript 1 equals negative 0.5 divided by 2")
        XCTAssertEqual(LinearMathSpeech.read("x² + y² = r²"), "ex squared plus why squared equals ar squared")
        XCTAssertEqual(LinearMathSpeech.read("β = sin(θ)"), "beta equals sine of open parenthesis theta close parenthesis")
        XCTAssertEqual(LinearMathSpeech.read("x = cosh(θ)"), "ex equals hyperbolic cosine of open parenthesis theta close parenthesis")
        XCTAssertEqual(LinearMathSpeech.read("R = 2 * r"), "capital ar equals 2 times ar")
        XCTAssertEqual(LinearMathSpeech.read("a · b = c"), "ay dot bee equals see")
        for raw in ["x2 = 3", "x = .5", "x = (2 + 3", "x = 2 3", "W¼pV", "x = \u{f061}", "https://x=2", "x = ∫ y", "x = 1e-3"] {
            XCTAssertNil(LinearMathSpeech.read(raw), raw)
        }
    }
    private func pdf(_ lines: [(String, Double)]) -> SemanticDocument {
        var offset = 0
        let geometry = lines.map { text, y -> PDFTextLine in
            defer { offset += text.utf16.count + 1 }
            return .init(location: offset, length: text.utf16.count + 1,
                bounds: .init(x: 0.1, y: y, width: 0.35, height: 0.018))
        }
        return .init(blocks: [.init(kind: .paragraph, text: lines.map { $0.0 + "\n" }.joined(),
            pdfPageIndex: 2, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: geometry))], extractorVersion: "synthetic-scientific-pdf")
    }
    func testReadableAndComplexEquationsPreserveExplanationsAndSourceForBothEngines() throws {
        let source = pdf([("The following equations describe the experiment.", 0.8), ("x = 2 + 3 (7)", 0.7),
            ("The next expression has a stacked fraction.", 0.6), ("a =", 0.5), ("1", 0.48), ("b + c", 0.46),
            ("Here the denominator describes the measured temperature.", 0.4)])
        for model in SpeechModel.allCases {
            let plan = try NarrationPlanner.prepare(source, settings: .init(model: model))
            let text = plan.chunks.map(\.text).joined(separator: " ")
            XCTAssertTrue(text.contains("Equation 7. ex equals 2 plus 3."))
            XCTAssertTrue(text.contains(PDFEquationNarration.complexCue))
            XCTAssertTrue(text.contains("denominator describes the measured temperature"))
            XCTAssertEqual(plan.omissions?.filter { $0.rule == "complex-equation-1" }.count, 1)
            let omission = try XCTUnwrap(plan.omissions?.first)
            let range = try XCTUnwrap(Range(NSRange(location: omission.source.location, length: omission.source.length), in: source.blocks[0].text))
            XCTAssertEqual(String(source.blocks[0].text[range]), "a =\n1\nb + c\n")
            let prepared = try NarrationPlanner.prepareForSpeech(source, settings: .init(model: model))
            XCTAssertEqual(text.filter { !$0.isWhitespace }, prepared.chunks.map(\.text).joined().filter { !$0.isWhitespace })
            XCTAssertTrue(plan.chunks.flatMap { $0.sourceMappings ?? [] }.contains { $0.rule == "scientific-equation-1" })
        }
    }
    func testOrdinaryProseAndNonPDFTypographyDoNotBecomeEquations() throws {
        let source = pdf([("We measured x = 3, which agrees with the earlier result.", 0.8),
            ("The phrase Table 1 shows no actual table here.", 0.7), ("2020", 0.6), ("0000000000000", 0.5)])
        let result = try PDFEquationNarration.analyze(source, excluded: [])
        XCTAssertTrue(result.edits.isEmpty)
        let epub = SemanticDocument(blocks: [.init(kind: .paragraph, text: "x = 2 + 3", origin: .authored)], extractorVersion: "synthetic-epub")
        XCTAssertTrue(try PDFEquationNarration.analyze(epub, excluded: []).edits.isEmpty)
        let inline = pdf([("The observed value is", 0.8), ("x = 3", 0.8), ("as measured in the laboratory.", 0.8)])
        XCTAssertTrue(try PDFEquationNarration.analyze(inline, excluded: []).edits.isEmpty)
        let invalid = SemanticDocument(blocks: [.init(kind: .paragraph, text: "Important prose. x = 2",
            pdfPageIndex: 0, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: [
                .init(location: 17, length: 5, bounds: .init(x: 0.1, y: 0.5, width: 0.2, height: 0.02))]))], extractorVersion: "missing-geometry")
        XCTAssertTrue(try PDFEquationNarration.analyze(invalid, excluded: []).edits.isEmpty)
        let foreign = pdf([("Είναι ένα σημαντικό αποτέλεσμα = 3.", 0.8)])
        XCTAssertTrue(try PDFEquationNarration.analyze(foreign, excluded: []).edits.isEmpty)
        let incompleteDiagram = pdf([("A diagram label follows.", 0.8), ("D", 0.7), ("=", 0.68)])
        XCTAssertTrue(try PDFEquationNarration.analyze(incompleteDiagram, excluded: []).edits.isEmpty)
    }
    func testShortLabelledTablesReadEveryValueAndUncertainCellsDoNotBecomeClaims() throws {
        let rows = [["Material", "Result"], ["Sample A", "0.25"], ["Sample B", "No significant change after repeated heating"]]
        let spoken = TableNarration.render(rows: rows)
        XCTAssertTrue(spoken.contains("Material: Sample A. Result: 0.25"))
        XCTAssertTrue(spoken.contains("Sample B. No significant change after repeated heating"))
        XCTAssertEqual(TableNarration.render(rows: [["Material", "Result"], ["Ambiguous"]]), TableNarration.unavailable)
        XCTAssertEqual(TableNarration.render(rows: [["1", "2"], ["3", "4"]]), TableNarration.unavailable)
        let source = SemanticDocument(blocks: [.init(kind: .table, text: "Material | Result\nSample A | 0.25\nSample B | A verbose description of the resulting sample")], extractorVersion: "synthetic-table")
        let text = try NarrationPlanner.prepare(source).chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Sample A")); XCTAssertTrue(text.contains("0.25")); XCTAssertTrue(text.contains("verbose description"))
    }
    func testLongNumericTablesDiscloseTheirUnreadRowsButKeepVerboseEntries() {
        let rows = [["Sample", "Observation"]] + (1...45).map { ["Sample \($0)", "\($0) kg 2 kg 3 kg 4 kg 5 kg 6 kg"] } + [["Control", "The sample remained stable throughout the entire heating cycle"]]
        let spoken = TableNarration.render(rows: rows)
        XCTAssertFalse(spoken.contains("Columns:")); XCTAssertTrue(spoken.contains("Control"))
        XCTAssertTrue(spoken.contains("remained stable")); XCTAssertTrue(spoken.contains("45 numeric or brief rows remain"))
    }
    func testEquationProjectionAllowsZeroLengthWhitespaceCutsButRejectsInterleavedProse() throws {
        let source = try MappedProjection.source("Before. x = 2", block: 0, canonical: false)
        let cleaned = try source.applying([.init(range: NSRange(location: 7, length: 1), replacement: "", rule: "citation-whitespace-1")])
        let result = try cleaned.replacingSourceRanges([.init(range: NSRange(location: 8, length: 5), replacement: "ex equals 2.", rule: "scientific-equation-1")])
        XCTAssertEqual(result.text, "Before.ex equals 2.")
        let first = try MappedProjection.source("x = 2", block: 0, canonical: false)
        let prose = try MappedProjection.source("Important prose", block: 0, canonical: false, sourceOffset: 30)
        let last = try MappedProjection.source("+ 3", block: 0, canonical: false, sourceOffset: 5)
        let interleaved = try first.joining(prose).joining(last)
        XCTAssertThrowsError(try interleaved.replacingSourceRanges([.init(range: NSRange(location: 0, length: 8), replacement: "Wrong", rule: "scientific-equation-1")]))
    }
    func testCapturedPronunciationOverrideTakesPrecedenceOverEquationReading() throws {
        let source = pdf([("The measurement follows.", 0.8), ("x = 2", 0.7)])
        let dictionary = try PronunciationDictionary(entries: [.init(word: "x", spelling: "distance")])
        let plan = try NarrationPlanner.prepare(source, pronunciations: dictionary)
        let spoken = plan.chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(spoken.contains("distance = 2"))
        XCTAssertFalse(spoken.contains("ex equals"))
    }
    func testBrokenChemicalAndFunctionGlyphsAreNotLeftBesideCuesOrJoinedToProse() throws {
        let source = pdf([("The expression follows.", 0.85), ("W¼ p0 lnðp1=p0Þ:", 0.75),
            ("The reaction follows.", 0.65), ("NaCl þ H2O ! NaH þ Cl þ O2", 0.55), ("500 kJ/mol", 0.53),
            ("The resulting heat is discussed in the next paragraph.", 0.4)])
        let plan = try NarrationPlanner.prepareForSpeech(source, settings: .init())
        let spoken = plan.chunks.map(\.text).joined(separator: " ")
        XCTAssertFalse(spoken.contains("lnð")); XCTAssertFalse(spoken.contains("NaCl")); XCTAssertFalse(spoken.contains("500 kJ/mol"))
        XCTAssertTrue(spoken.contains("The resulting heat"))
        XCTAssertEqual(plan.omissions?.filter { $0.rule == "complex-equation-1" }.count, 2)
    }
    func testInlineNotationBeforeDisplayMathDoesNotHideTheFollowingFormula() throws {
        let base = pdf([("We compute the following matrix", 0.8), ("x = 2", 0.8),
            ("a =", 0.6), ("1", 0.58), ("b + c", 0.56), ("These terms describe the measured result.", 0.4)]).blocks[0]
        let lines = try XCTUnwrap(base.pdfLayout).lines.enumerated().map { index, line in
            PDFTextLine(location: line.location, length: line.length,
                bounds: .init(x: index == 1 ? 0.41 : 0.1, y: line.bounds.y,
                    width: index == 1 ? 0.08 : 0.3, height: line.bounds.height))
        }
        let source = SemanticDocument(blocks: [.init(kind: .paragraph, text: base.text, pdfPageIndex: 2,
            origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))], extractorVersion: "inline-before-display")
        let plan = try NarrationPlanner.prepare(source)
        let spoken = plan.chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(spoken.contains("matrix x = 2"))
        XCTAssertTrue(spoken.contains(PDFEquationNarration.complexCue))
        XCTAssertTrue(spoken.contains("These terms describe the measured result"))
        XCTAssertEqual(plan.omissions?.filter { $0.rule == "complex-equation-1" }.count, 1)
    }
    func testWideBracketSelectionStaysWithItsOriginalColumn() throws {
        let base = pdf([("The matrix follows.", 0.8), ("a =", 0.7), ("1", 0.68), ("b + c", 0.66), ("⎦", 0.64),
            ("An adjacent explanation begins.", 0.64),
            ("The explanation remains after the formula.", 0.5)]).blocks[0]
        let lines = try XCTUnwrap(base.pdfLayout).lines.enumerated().map { index, line in
            PDFTextLine(location: line.location, length: line.length,
                bounds: .init(x: index == 4 ? 0.52 : index == 5 ? 0.74 : line.bounds.x, y: line.bounds.y,
                    width: index == 4 || index == 5 ? 0.2 : line.bounds.width, height: line.bounds.height))
        }
        let source = SemanticDocument(blocks: [.init(kind: .paragraph, text: base.text, pdfPageIndex: 2,
            origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))], extractorVersion: "wide-math-selection")
        let plan = try NarrationPlanner.prepare(source)
        let spoken = plan.chunks.map(\.text).joined(separator: " ")
        XCTAssertFalse(spoken.contains("⎦")); XCTAssertTrue(spoken.contains("explanation remains"))
        XCTAssertTrue(spoken.contains("An adjacent explanation begins"))
        XCTAssertEqual(plan.omissions?.filter { $0.rule == "complex-equation-1" }.count, 1)
    }
    func testLongTablesReadVerboseDescriptionsInTheFirstColumn() {
        let description = "The sample remained unstable until it was cooled for several hours"
        let rows = [["Description", "Result"]] + (1...45).map { ["Item \($0)", "\($0)"] } + [[description, "42"]]
        let spoken = TableNarration.render(rows: rows)
        XCTAssertTrue(spoken.contains(description))
        XCTAssertTrue(spoken.contains("42."))
        XCTAssertTrue(spoken.contains("45 numeric or brief rows remain"))
    }
    func testWrappedURLQueryDoesNotBecomeAnEquation() throws {
        let source = pdf([("Reference information https://example.org/record/?", 0.8),
            ("c=12345.", 0.77), ("The next paragraph describes the experiment.", 0.7)])
        let result = try PDFEquationNarration.analyze(source, excluded: [])
        XCTAssertTrue(result.edits.isEmpty)
        XCTAssertEqual(result.readable, 0)
        XCTAssertEqual(result.complex, 0)
    }
    func testDetachedSummationLimitIsNotReadAsACompleteEquation() throws {
        let text = "d\ni=1\nThe resulting bound follows from the experiment.\n"
        let lines: [PDFTextLine] = [
            .init(location: 0, length: 2, bounds: .init(x: 0.505, y: 0.69, width: 0.016, height: 0.044)),
            .init(location: 2, length: 4, bounds: .init(x: 0.499, y: 0.698, width: 0.021, height: 0.008)),
            .init(location: 6, length: text.utf16.count - 6, bounds: .init(x: 0.1, y: 0.6, width: 0.7, height: 0.018))]
        let source = SemanticDocument(blocks: [.init(kind: .paragraph, text: text, pdfPageIndex: 0,
            origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))], extractorVersion: "detached-limit")
        let result = try PDFEquationNarration.analyze(source, excluded: [])
        XCTAssertEqual(result.readable, 0)
        XCTAssertEqual(result.complex, 1)
        XCTAssertEqual(source.blocks[0].text, text)
    }
    func testComplexEquationNoticeOccursOnceAcrossPagesAndHeadingsForBothEngines() throws {
        let first = pdf([("An explanation precedes the first formula.", 0.8), ("a =", 0.7), ("1", 0.68), ("b + c", 0.66)]).blocks[0]
        let second = pdf([("A different explanation precedes another formula.", 0.8), ("x =", 0.7), ("2", 0.68), ("y + z", 0.66)]).blocks[0]
        let source = SemanticDocument(blocks: [first, .init(kind: .heading, text: "A later chapter", headingLevel: 1), second], extractorVersion: "equation-cue-flow")
        for model in SpeechModel.allCases {
            for purpose in [NarrationPlanPurpose.preview, .speechPreparation] {
                let plan = try NarrationPlanner.prepare(source, settings: .init(model: model), purpose: purpose)
                let spoken = plan.chunks.map(\.text).joined(separator: " ")
                XCTAssertEqual(spoken.components(separatedBy: PDFEquationNarration.complexCue).count - 1, 1)
                XCTAssertEqual(plan.omissions?.filter { $0.rule == "complex-equation-1" }.count, 2)
                XCTAssertTrue(spoken.contains("A different explanation"))
                XCTAssertFalse(spoken.contains("y + z"))
            }
        }
    }
    func testProseTablesIgnoreRaggedGridButKeepAllWordsAndQuantities() {
        let rows = [["Topic", "Description"], ["Heating", "The sample remained unchanged throughout the entire heating cycle", "42 kg"],
            ["Cooling", "The sample changed colour after it was cooled overnight"]]
        let spoken = TableNarration.render(rows: rows, relationshipsReliable: false)
        XCTAssertTrue(spoken.contains("Heating. The sample remained unchanged"))
        XCTAssertTrue(spoken.contains("42 kg.")); XCTAssertTrue(spoken.contains("Cooling."))
        XCTAssertFalse(spoken.contains("Column")); XCTAssertFalse(spoken.contains("End table"))
        XCTAssertEqual(TableNarration.render(rows: [["Mass", "Volume"], ["2", "3"]], relationshipsReliable: false), TableNarration.unavailable)
    }
    func testCueOccursAtFirstSpokenFormulaRatherThanDeferredNote() throws {
        let note = pdf([("The note explains a complex formula.", 0.8), ("a =", 0.7), ("1", 0.68), ("b + c", 0.66)]).blocks[0]
        let body = pdf([("The body explains another formula.", 0.8), ("x =", 0.7), ("2", 0.68), ("y + z", 0.66)]).blocks[0]
        let source = SemanticDocument(blocks: [.init(kind: .paragraph, text: note.text, footnoteID: "n", pdfPageIndex: 2,
            origin: .authored, pdfLayout: note.pdfLayout), body], extractorVersion: "deferred-equation")
        let spoken = NarrationText.normalizeWhitespace(try NarrationPlanner.prepare(source, options: .init(notes: .endOfDocument)).chunks.map(\.text).joined(separator: " "))
        XCTAssertTrue(spoken.contains("The body explains another formula. " + PDFEquationNarration.complexCue), spoken)
        XCTAssertEqual(spoken.components(separatedBy: PDFEquationNarration.complexCue).count - 1, 1)
        XCTAssertTrue(spoken.contains("The note explains a complex formula."))
    }
    func testNamedFunctionFormulasGetACueWithoutRemovingTheirExplanation() throws {
        let source = pdf([("The following transformation combines the measurements.", 0.8),
            ("Transform(Q,K,V) = softmax(Q*K/V) (4)", 0.7),
            ("The explanation defines the inputs and the resulting value.", 0.6),
            ("Method(x) = the observed value", 0.5)])
        let plan = try NarrationPlanner.prepare(source)
        let spoken = plan.chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(spoken.contains(PDFEquationNarration.complexCue))
        XCTAssertFalse(spoken.contains("softmax"))
        XCTAssertTrue(spoken.contains("The explanation defines"))
        XCTAssertTrue(spoken.contains("Method(x) = the observed value"))
    }
    func testLongProseTableRetainsBriefSectionHeadingsAndQuantities() {
        let rows = [["Topic", "Details"], ["Methods"]] + (1...42).map { ["Item \($0)", "The sample remained unchanged throughout the entire heating cycle"] } + [["42 kg"]]
        let spoken = TableNarration.render(rows: rows, relationshipsReliable: false)
        XCTAssertTrue(spoken.contains("Methods.")); XCTAssertTrue(spoken.contains("42 kg."))
        XCTAssertFalse(spoken.contains("rows remain")); XCTAssertFalse(spoken.contains("Column"))
    }
    func testExplicitlyLinkedInsetNoteFollowsItsCalloutOnlyOnce() throws {
        let description = "This inset explains the measurements used throughout the experiment."
        let source = SemanticDocument(blocks: [
            .init(kind: .paragraph, text: "The discussion calls for this note.", footnoteReferences: ["inset"]),
            .init(kind: .paragraph, text: "The discussion continues afterwards."),
            .init(kind: .table, text: description, footnoteID: "inset")], extractorVersion: "linked-inset")
        let text = try NarrationPlanner.prepare(source).chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.range(of: description)!.lowerBound < text.range(of: "continues afterwards")!.lowerBound)
        XCTAssertEqual(text.components(separatedBy: description).count - 1, 1)
    }
}
