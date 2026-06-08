import Foundation

extension String {
    /// Normalized form for search/comparison: case- and diacritic-insensitive.
    /// "Málaga" → "malaga", "AVIÓN" → "avion".
    var normalizedForSearch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// For long documents, returns the head + tail so key fields that appear near
    /// the end (boarding-pass seat numbers, totals on multi-page PDFs) aren't lost
    /// when the text is truncated before sending it to an LLM.
    /// Texts at or below `maxLength` are returned unchanged.
    func headAndTailTruncated(maxLength: Int = 4000, headLength: Int = 2500, tailLength: Int = 1000) -> String {
        guard count > maxLength else { return self }
        return String(prefix(headLength)) + "\n…\n" + String(suffix(tailLength))
    }
}
