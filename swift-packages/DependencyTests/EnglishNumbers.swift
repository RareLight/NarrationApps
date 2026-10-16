import Foundation

/// Compiled with the pinned, patched native converter; no MLX or model assets.
@main struct EnglishNumberFixtures {
    static func main() {
        let converter = EnglishNum2Word()
        for (source, expected) in [("0", "zero"), ("21", "twenty-one"), ("29", "twenty-nine"),
            ("1000000", "one million"), ("2.4", "two point four"), ("-2.4", "minus two point four"), ("12.50", "twelve point five")] {
            precondition(converter.convert(Decimal(string: source)!) == expected, "English numeric regression: \(source)")
        }
        precondition(converter.convert(21, to: .ordinal) == "twenty-first")
        precondition(converter.convert(0, to: .ordinal) == "zeroth")
        precondition(converter.convert(2026, to: .year) == "twenty twenty-six")
        precondition(converter.convert(.nan).isEmpty)
        print("Native Foundation English cardinal, decimal, negative, ordinal and year fixtures passed.")
    }
}
