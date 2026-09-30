import XCTest
@testable import DocumentBrain

/// Golden token IDs produced by the Hugging Face tokenizer of
/// sentence-transformers/multi-qa-MiniLM-L6-cos-v1 (BertTokenizer, uncased).
/// If these drift, the CoreML model receives different input than it was trained on
/// and retrieval quality silently collapses.
@MainActor
final class BERTTokenizerTests: XCTestCase {

    private func makeTokenizer() throws -> BERTTokenizer {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "vocab", withExtension: "txt"),
                                "vocab.txt must be bundled with the app")
        return try BERTTokenizer(vocabURL: url)
    }

    func testVocabulary_matchesModel() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "vocab", withExtension: "txt"))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 30_522, "vocab.txt must be the embedding model's own vocabulary")
    }

    func testSpanishQuestion_matchesHuggingFace() throws {
        XCTAssertEqual(try makeTokenizer().tokenIDs(for: "¿Puedo tener un perro en casa?"),
                       [1094, 16405, 26010, 2702, 2121, 4895, 2566, 3217, 4372, 14124, 1029])
    }

    func testAmountsAndSymbols_matchHuggingFace() throws {
        XCTAssertEqual(try makeTokenizer().tokenIDs(for: "El importe total es 85,43 € (IVA 21 %)."),
                       [3449, 12324, 2063, 2561, 9686, 5594, 1010, 4724, 1574, 1006, 4921, 2050, 2538, 1003, 1007, 1012])
    }

    func testCodesAndArrows_matchHuggingFace() throws {
        XCTAssertEqual(try makeTokenizer().tokenIDs(for: "Vuelo SL2471 Madrid → Lisboa, asiento 17C"),
                       [24728, 18349, 22889, 18827, 2581, 2487, 6921, 1585, 5622, 19022, 10441, 1010, 2004, 11638, 2080, 2459, 2278])
    }

    func testStripAccents() {
        XCTAssertEqual(BERTTokenizer.stripAccents("está niño pingüino"), "esta nino pinguino")
    }

    func testPunctuationRule() {
        XCTAssertTrue(BERTTokenizer.isBERTPunctuation("¿"))
        XCTAssertTrue(BERTTokenizer.isBERTPunctuation("$"))
        XCTAssertFalse(BERTTokenizer.isBERTPunctuation("°"))
        XCTAssertFalse(BERTTokenizer.isBERTPunctuation("€"))
        XCTAssertFalse(BERTTokenizer.isBERTPunctuation("a"))
    }

    func testMLArrays_haveCLSAndSEPAndMask() throws {
        let (ids, mask) = try makeTokenizer().tokenizeToMLArrays(text: "hola")
        XCTAssertEqual(ids[0].intValue, 101)                       // [CLS]
        let n = (0..<512).filter { mask[$0].intValue == 1 }.count
        XCTAssertEqual(ids[n - 1].intValue, 102)                   // [SEP]
        XCTAssertEqual(ids[n].intValue, 0)                         // [PAD]
    }

    func testLongText_isTruncatedKeepingSEP() throws {
        let long = String(repeating: "palabra ", count: 1_000)
        let (ids, mask) = try makeTokenizer().tokenizeToMLArrays(text: long)
        XCTAssertEqual(mask[511].intValue, 1)
        XCTAssertEqual(ids[511].intValue, 102)
    }
}
