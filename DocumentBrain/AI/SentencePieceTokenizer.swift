import Foundation
import CoreML

/// SentencePiece **unigram** tokenizer for `intfloat/multilingual-e5-small` (XLM-R vocabulary).
///
/// Reproduces the Hugging Face fast tokenizer the model was trained with:
/// 1. Normalisation: NFKC; tabs, newlines, Unicode spaces and zero-width spaces become
///    " "; other control characters are dropped; runs of spaces collapse; trimmed.
/// 2. Metaspace pre-tokenisation: " " → "▁", a leading "▁" is added, and the text is
///    split into words that each start with "▁".
/// 3. Viterbi over the unigram log-probabilities for each word; characters not in the
///    vocabulary become `<unk>` (consecutive unknowns are fused).
///
/// Works on Unicode scalars, not `Character`s, because vocabulary pieces are code-point
/// sequences ("👍🏽" is one Character but two pieces' worth of scalars).
/// Validated against the Hugging Face tokenizer on 270 texts (see SentencePieceTokenizerTests).
final class SentencePieceTokenizer {

    static let bosID = 0      // <s>
    static let padID = 1      // <pad>
    static let eosID = 2      // </s>
    static let unkID = 3      // <unk>

    /// Sequence lengths the CoreML model accepts (enumerated shapes).
    static let sequenceBuckets = [128, 256, 512]
    static var maxSequenceLength: Int { sequenceBuckets.last! }

    private let pieceIDs: [String: Int32]
    private let scores: [Float]
    private let maxPieceScalars: Int
    private let unknownScore: Float

    init(vocabURL: URL) throws {
        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        var ids = [String: Int32]()
        var scores = [Float]()
        ids.reserveCapacity(250_002)
        scores.reserveCapacity(250_002)
        var maxLength = 1

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.lastIndex(of: "\t") else { continue }
            let piece = String(line[..<tab])
            let score = Float(line[line.index(after: tab)...]) ?? 0
            ids[piece] = Int32(scores.count)
            scores.append(score)
            maxLength = max(maxLength, piece.unicodeScalars.count)
        }
        guard scores.count > Self.unkID else { throw TokenizerError.invalidVocabulary }

        self.pieceIDs = ids
        self.scores = scores
        self.maxPieceScalars = maxLength
        self.unknownScore = (scores.min() ?? 0) - 10
    }

    var vocabularySize: Int { scores.count }

    // MARK: - Public API

    /// Piece IDs for `text`, without <s> / </s>.
    func tokenIDs(for text: String) -> [Int] {
        Self.words(from: text).flatMap { encode(word: $0) }
    }

    /// `<s> … </s>` padded to the smallest accepted bucket, plus the attention mask.
    func tokenizeToMLArrays(text: String) throws -> (inputIDs: MLMultiArray, attentionMask: MLMultiArray) {
        var ids = [Self.bosID] + tokenIDs(for: text)
        if ids.count > Self.maxSequenceLength - 1 {
            ids = Array(ids.prefix(Self.maxSequenceLength - 1))
        }
        ids.append(Self.eosID)

        let length = Self.sequenceBuckets.first { $0 >= ids.count } ?? Self.maxSequenceLength
        let shape = [1, NSNumber(value: length)]
        let inputIDs = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        let idsPointer = inputIDs.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let maskPointer = mask.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length {
            let isToken = i < ids.count
            idsPointer[i] = isToken ? Int32(ids[i]) : Int32(Self.padID)
            maskPointer[i] = isToken ? 1 : 0
        }
        return (inputIDs, mask)
    }

    // MARK: - Normalisation & pre-tokenisation

    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasSpace = true // also trims leading spaces
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            let category = scalar.properties.generalCategory
            let isSpace: Bool
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x0C, 0x85, 0x200B, 0x200C, 0x200D, 0xFEFF:
                isSpace = true
            default:
                isSpace = category == .spaceSeparator || category == .lineSeparator
                    || category == .paragraphSeparator
            }
            if isSpace {
                if !previousWasSpace { scalars.append(" ") }
                previousWasSpace = true
            } else if category == .control && scalar.value != 0 {
                continue
            } else {
                scalars.append(scalar)
                previousWasSpace = false
            }
        }
        var result = String(scalars)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Words as scalar arrays, each starting with "▁".
    static func words(from text: String) -> [[Unicode.Scalar]] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }
        let marker: Unicode.Scalar = "\u{2581}"
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = [marker]
        for scalar in normalized.unicodeScalars {
            if scalar == " " {
                words.append(current)
                current = [marker]
            } else {
                current.append(scalar)
            }
        }
        words.append(current)
        return words
    }

    // MARK: - Viterbi

    private func encode(word: [Unicode.Scalar]) -> [Int] {
        let n = word.count
        var best = [Float](repeating: -.infinity, count: n + 1)
        var backStart = [Int](repeating: 0, count: n + 1)
        var backID = [Int32](repeating: 0, count: n + 1)
        best[0] = 0

        for end in 1...n {
            for start in max(0, end - maxPieceScalars)..<end where best[start] > -.infinity {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: word[start..<end])
                let candidateScore: Float
                let candidateID: Int32
                if let id = pieceIDs[String(view)], id > Int32(Self.unkID) {
                    candidateID = id
                    candidateScore = best[start] + scores[Int(id)]
                } else if end - start == 1 {
                    candidateID = Int32(Self.unkID)
                    candidateScore = best[start] + unknownScore
                } else {
                    continue
                }
                if candidateScore > best[end] {
                    best[end] = candidateScore
                    backStart[end] = start
                    backID[end] = candidateID
                }
            }
        }

        var ids: [Int] = []
        var position = n
        while position > 0 {
            ids.append(Int(backID[position]))
            position = backStart[position]
        }
        ids.reverse()

        // Fuse consecutive <unk>s, like the Hugging Face tokenizer.
        var fused: [Int] = []
        for id in ids where !(id == Self.unkID && fused.last == Self.unkID) {
            fused.append(id)
        }
        return fused
    }

    enum TokenizerError: Error {
        case invalidVocabulary
    }
}
