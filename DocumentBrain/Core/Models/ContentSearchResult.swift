import Foundation
import SwiftUI

// MARK: - Result of a full-text content search across all document chunks

struct ContentSearchResult: Identifiable {
    let id = UUID()
    let documentId: String
    let documentTitle: String
    let fileType: String
    let chunkContent: String

    var fileTypeEnum: FileType { FileType(rawValue: fileType) ?? .unknown }

    /// Extracts a ~150-char excerpt centered around the first query term match.
    func snippet(for query: String) -> String {
        let terms = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 1 }

        let text = chunkContent
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // Find the earliest match position across all terms
        var matchStart: String.Index? = nil
        for term in terms {
            let normalizedTerm = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if let range = normalized.range(of: normalizedTerm) {
                if matchStart == nil || range.lowerBound < matchStart! {
                    matchStart = range.lowerBound
                }
            }
        }

        let windowSize = 150
        let start: String.Index
        let prefix: String

        if let match = matchStart {
            // Center the window around the match
            let offset = text.distance(from: text.startIndex, to: match)
            let windowStart = max(0, offset - 40)
            start = text.index(text.startIndex, offsetBy: windowStart)
            prefix = windowStart > 0 ? "…" : ""
        } else {
            start = text.startIndex
            prefix = ""
        }

        let end = text.index(start, offsetBy: min(windowSize, text.distance(from: start, to: text.endIndex)))
        let excerpt = String(text[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let suffix = end < text.endIndex ? "…" : ""

        return prefix + excerpt + suffix
    }

    /// Returns an AttributedString with query terms bolded.
    func highlightedSnippet(for query: String) -> AttributedString {
        let raw = snippet(for: query)
        var attributed = AttributedString(raw)

        let terms = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 1 }

        for term in terms {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex {
                guard let range = attributed[searchStart...].range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) else { break }
                attributed[range].font = .caption.bold()
                attributed[range].foregroundColor = Color.appAccent
                searchStart = range.upperBound
            }
        }

        return attributed
    }
}
