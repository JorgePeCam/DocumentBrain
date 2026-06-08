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

    /// Extracts an excerpt of `windowSize` characters centered around the first
    /// query-term match, with leading/trailing ellipses when the text is clipped.
    func snippet(for query: String, windowSize: Int = 150, leftContext: Int = 40) -> String {
        let terms = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 1 }

        let chars = Array(chunkContent)
        let normalized = chunkContent.normalizedForSearch

        // Earliest match offset (as an integer position) across all query terms.
        // Searching/measuring stays within `normalized` so indices are never mixed
        // across strings; the integer is clamped before indexing into `chars`.
        var matchOffset: Int?
        for term in terms {
            guard let range = normalized.range(of: term.normalizedForSearch) else { continue }
            let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
            matchOffset = matchOffset.map { min($0, offset) } ?? offset
        }

        let start: Int
        if let match = matchOffset {
            start = max(0, min(match, chars.count) - leftContext)
        } else {
            start = 0
        }
        let end = min(chars.count, start + windowSize)

        let excerpt = String(chars[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        let prefix = start > 0 ? "…" : ""
        let suffix = end < chars.count ? "…" : ""
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
