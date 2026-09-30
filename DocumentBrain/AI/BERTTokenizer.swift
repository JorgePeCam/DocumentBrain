import Foundation
import CoreML

final class BERTTokenizer {
    private let vocabulary: [String: Int]
    private let unknownToken = "[UNK]"
    private let startToken = "[CLS]"
    private let separatorToken = "[SEP]"
    private let padToken = "[PAD]"
    private let maxSequenceLength = 512
    /// Same as Hugging Face's `max_input_chars_per_word`.
    private let maxWordLength = 100

    init(vocabURL: URL) throws {
        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var vocab = [String: Int]()
        for (index, line) in lines.enumerated() {
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                vocab[key] = index
            }
        }
        self.vocabulary = vocab
    }

    /// Word-piece IDs for `text`, without [CLS]/[SEP]. Matches the Hugging Face
    /// `BertTokenizer` (uncased) used to train the embedding model.
    func tokenIDs(for text: String) -> [Int] {
        let unknownID = vocabulary[unknownToken] ?? 100
        return tokenize(text).map { vocabulary[$0] ?? unknownID }
    }

    func tokenizeToMLArrays(text: String) throws -> (inputIDs: MLMultiArray, attentionMask: MLMultiArray) {
        var finalIDs = [vocabulary[startToken]!] + tokenIDs(for: text)
        // Truncate like Hugging Face: keep room for the closing [SEP].
        if finalIDs.count > maxSequenceLength - 1 {
            finalIDs = Array(finalIDs.prefix(maxSequenceLength - 1))
        }
        finalIDs.append(vocabulary[separatorToken]!)

        let shape = [1, NSNumber(value: maxSequenceLength)]
        let inputIDsArray = try MLMultiArray(shape: shape, dataType: .int32)
        let maskArray = try MLMultiArray(shape: shape, dataType: .int32)

        // Contiguous [1, 512] Int32 buffers: write directly instead of boxing
        // every element through NSNumber subscripts.
        let ids = inputIDsArray.dataPointer.bindMemory(to: Int32.self, capacity: maxSequenceLength)
        let mask = maskArray.dataPointer.bindMemory(to: Int32.self, capacity: maxSequenceLength)
        for i in 0..<maxSequenceLength {
            let isToken = i < finalIDs.count
            ids[i] = isToken ? Int32(finalIDs[i]) : 0
            mask[i] = isToken ? 1 : 0
        }

        return (inputIDsArray, maskArray)
    }

    // MARK: - Real WordPiece Tokenization

    private func tokenize(_ text: String) -> [String] {
        // 1. Normalize like BERT uncased: lowercase, then NFD and drop combining marks
        //    ("está" → "esta", "niño" → "nino"). The vocabulary has no accented pieces.
        let normalized = Self.stripAccents(text.lowercased())

        // 2. Split into words (by whitespace and punctuation)
        let words = splitIntoWords(normalized)

        // 3. Apply WordPiece to each word
        var tokens: [String] = []
        for word in words {
            let subTokens = wordPieceTokenize(word)
            tokens.append(contentsOf: subTokens)
        }

        return tokens
    }

    /// Splits text into individual words, separating punctuation as its own token
    private func splitIntoWords(_ text: String) -> [String] {
        var words: [String] = []
        var currentWord = ""

        for char in text {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    currentWord = ""
                }
            } else if Self.isBERTPunctuation(char) {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    currentWord = ""
                }
                words.append(String(char))
            } else {
                currentWord.append(char)
            }
        }

        if !currentWord.isEmpty {
            words.append(currentWord)
        }

        return words
    }

    /// NFD-decompose and remove non-spacing marks, as BERT's `_run_strip_accents`.
    static func stripAccents(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// BERT splits on every ASCII non-alphanumeric symbol and on Unicode punctuation
    /// (P* categories) — but not on non-ASCII symbols like "°" or "€".
    static func isBERTPunctuation(_ char: Character) -> Bool {
        if char.isASCII {
            return (char.isPunctuation || char.isSymbol)
        }
        return char.isPunctuation
    }

    /// WordPiece tokenization: breaks a word into known subword units.
    /// Example: "Vietnam" -> ["vi", "##et", "##nam"] (if those subwords exist)
    private func wordPieceTokenize(_ word: String) -> [String] {
        if word.count > maxWordLength {
            return [unknownToken]
        }

        // Check if the whole word is in vocabulary
        if vocabulary[word] != nil {
            return [word]
        }

        var tokens: [String] = []
        var start = word.startIndex
        var isFirst = true

        while start < word.endIndex {
            var end = word.endIndex
            var found = false

            // Greedy longest-match-first: try the longest substring first
            while end > start {
                let substring = String(word[start..<end])
                let candidate = isFirst ? substring : "##\(substring)"

                if vocabulary[candidate] != nil {
                    tokens.append(candidate)
                    start = end
                    isFirst = false
                    found = true
                    break
                }

                // Try one character shorter
                end = word.index(before: end)
            }

            if !found {
                // No subword found at all — the whole word is unknown
                return [unknownToken]
            }
        }

        return tokens
    }
}
