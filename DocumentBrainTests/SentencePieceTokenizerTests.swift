import XCTest
import CoreML
@testable import DocumentBrain

/// Golden token IDs produced by the Hugging Face tokenizer of
/// intfloat/multilingual-e5-small (XLM-R SentencePiece unigram). If these drift, the
/// CoreML model receives different input than it was trained on and retrieval quality
/// silently collapses — which is exactly what happened with the previous model's vocab.
@MainActor
final class SentencePieceTokenizerTests: XCTestCase {

    private static var cached: SentencePieceTokenizer?

    private func tokenizer() throws -> SentencePieceTokenizer {
        if let cached = Self.cached { return cached }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "e5_vocab", withExtension: "tsv"),
                                "e5_vocab.tsv must be bundled with the app")
        let loaded = try SentencePieceTokenizer(vocabURL: url)
        Self.cached = loaded
        return loaded
    }

    func testVocabulary_matchesModel() throws {
        XCTAssertEqual(try tokenizer().vocabularySize, 250_002)
    }

    func testQueryPrefix_spanishQuestion() throws {
        XCTAssertEqual(try tokenizer().tokenIDs(for: "query: ¿Puedo tener un perro en casa?"),
                       [41, 1294, 12, 3936, 27559, 37421, 9574, 51, 117, 516, 22, 2349, 32])
    }

    func testPassagePrefix_amountsAndSymbols() throws {
        XCTAssertEqual(try tokenizer().tokenIDs(for: "passage: El importe total es 85,43 € (IVA 21 %)."),
                       [46692, 12, 540, 76242, 3622, 198, 9365, 4, 11548, 2505, 15, 44089, 952, 65209, 5])
    }

    func testCodesAndArrows() throws {
        XCTAssertEqual(try tokenizer().tokenIDs(for: "query: Vuelo SL2471 Madrid → Lisboa, asiento 17C"),
                       [41, 1294, 12, 35443, 8242, 42135, 2357, 15770, 8884, 2863, 91330, 4, 5644, 20193, 729, 441])
    }

    func testWhitespaceIsCollapsed() throws {
        XCTAssertEqual(try tokenizer().tokenIDs(for: "Hola   mundo\n\tfin"), [47958, 3307, 2270])
    }

    func testEmptyText_hasNoTokens() throws {
        XCTAssertEqual(try tokenizer().tokenIDs(for: "   \n "), [])
    }

    func testNormalize() {
        XCTAssertEqual(SentencePieceTokenizer.normalize("  a\u{200B}b\u{00A0}c\u{0B}d  "), "a b cd")
        XCTAssertEqual(SentencePieceTokenizer.normalize("ﬁ Ｆｕｌｌ"), "fi Full")
    }

    func testMLArrays_useSmallestBucket_withBosEosAndPadding() throws {
        let (ids, mask) = try tokenizer().tokenizeToMLArrays(text: "query: hola")
        XCTAssertEqual(ids.shape, [1, 128])
        XCTAssertEqual(ids[0].intValue, SentencePieceTokenizer.bosID)
        let n = (0..<128).filter { mask[$0].intValue == 1 }.count
        XCTAssertEqual(ids[n - 1].intValue, SentencePieceTokenizer.eosID)
        XCTAssertEqual(ids[n].intValue, SentencePieceTokenizer.padID)
    }

    func testLongText_isTruncatedTo512KeepingEos() throws {
        let long = String(repeating: "palabra ", count: 1_000)
        let (ids, mask) = try tokenizer().tokenizeToMLArrays(text: long)
        XCTAssertEqual(ids.shape, [1, 512])
        XCTAssertEqual(mask[511].intValue, 1)
        XCTAssertEqual(ids[511].intValue, SentencePieceTokenizer.eosID)
    }

    func testMediumText_uses256Bucket() throws {
        let medium = String(repeating: "casa ", count: 150)   // ~150 tokens + <s></s>
        let (ids, _) = try tokenizer().tokenizeToMLArrays(text: medium)
        XCTAssertEqual(ids.shape, [1, 256])
    }
}
