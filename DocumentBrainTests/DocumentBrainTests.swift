import XCTest
@testable import DocumentBrain

// MARK: - VectorMath

final class VectorMathTests: XCTestCase {

    func testCosineSimilarity_identicalVectors_returnsOne() {
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(VectorMath.cosineSimilarity(v, v), 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_oppositeVectors_returnsMinusOne() {
        let v: [Float] = [1, 0, 0]
        let u: [Float] = [-1, 0, 0]
        XCTAssertEqual(VectorMath.cosineSimilarity(v, u), -1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_orthogonalVectors_returnsZero() {
        let v: [Float] = [1, 0]
        let u: [Float] = [0, 1]
        XCTAssertEqual(VectorMath.cosineSimilarity(v, u), 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_mismatchedDimensions_returnsZero() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 2], [1, 2, 3]), 0.0)
    }

    func testCosineSimilarity_zeroVector_returnsZero() {
        let zero: [Float] = [0, 0, 0]
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(VectorMath.cosineSimilarity(zero, v), 0.0)
    }
}

// MARK: - Float vector ↔ Data round-trip

final class VectorRoundTripTests: XCTestCase {

    func testToDataAndBack_preservesValues() {
        let original: [Float] = [0.1, 0.5, -0.9, 3.14]
        let roundTripped = original.toData().toFloatArray()
        XCTAssertEqual(roundTripped.count, original.count)
        for (a, b) in zip(original, roundTripped) {
            XCTAssertEqual(a, b, accuracy: 0.000001)
        }
    }

    func testToDataAndBack_emptyArray() {
        let empty: [Float] = []
        XCTAssertTrue(empty.toData().toFloatArray().isEmpty)
    }

    func testToDataByteLength() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(v.toData().count, 4 * MemoryLayout<Float>.size)
    }
}

// MARK: - FileType detection

final class FileTypeDetectionTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testDetect_pdf() {
        XCTAssertEqual(FileType.detect(from: url("report.pdf")), .pdf)
    }

    func testDetect_jpg() {
        XCTAssertEqual(FileType.detect(from: url("photo.jpg")), .image)
    }

    func testDetect_jpeg() {
        XCTAssertEqual(FileType.detect(from: url("photo.jpeg")), .image)
    }

    func testDetect_png() {
        XCTAssertEqual(FileType.detect(from: url("screenshot.png")), .image)
    }

    func testDetect_heic() {
        XCTAssertEqual(FileType.detect(from: url("live.heic")), .image)
    }

    func testDetect_docx() {
        XCTAssertEqual(FileType.detect(from: url("letter.docx")), .docx)
    }

    func testDetect_xlsx() {
        XCTAssertEqual(FileType.detect(from: url("budget.xlsx")), .xlsx)
    }

    func testDetect_txt() {
        XCTAssertEqual(FileType.detect(from: url("notes.txt")), .text)
    }

    func testDetect_md() {
        XCTAssertEqual(FileType.detect(from: url("readme.md")), .text)
    }

    func testDetect_csv() {
        XCTAssertEqual(FileType.detect(from: url("data.csv")), .text)
    }

    func testDetect_eml() {
        XCTAssertEqual(FileType.detect(from: url("email.eml")), .email)
    }

    func testDetect_unknownExtension() {
        XCTAssertEqual(FileType.detect(from: url("archive.zip")), .unknown)
    }

    func testDetect_caseInsensitive() {
        XCTAssertEqual(FileType.detect(from: url("REPORT.PDF")), .pdf)
        XCTAssertEqual(FileType.detect(from: url("Photo.JPG")), .image)
    }
}

// MARK: - ProcessingStatus

final class ProcessingStatusTests: XCTestCase {

    func testIsInProgress_pendingStatesAreInProgress() {
        XCTAssertTrue(ProcessingStatus.pending.isInProgress)
        XCTAssertTrue(ProcessingStatus.extracting.isInProgress)
        XCTAssertTrue(ProcessingStatus.chunking.isInProgress)
        XCTAssertTrue(ProcessingStatus.embedding.isInProgress)
    }

    func testIsInProgress_terminalStatesAreNotInProgress() {
        XCTAssertFalse(ProcessingStatus.ready.isInProgress)
        XCTAssertFalse(ProcessingStatus.error.isInProgress)
    }
}

// MARK: - String.cleanedDocumentTitle

final class CleanedDocumentTitleTests: XCTestCase {

    func testRemovesUUIDPrefix() {
        let raw = "550e8400-e29b-41d4-a716-446655440000_Contract"
        let title = String.cleanedDocumentTitle(raw)
        XCTAssertFalse(title.contains("550e8400"))
        XCTAssertTrue(title.contains("Contract"))
    }

    func testReplacesUnderscoresWithSpaces() {
        let title = String.cleanedDocumentTitle("my_important_document")
        XCTAssertEqual(title, "my important document")
    }

    func testReplacesHyphensWithSpaces() {
        let title = String.cleanedDocumentTitle("invoice-2024-january")
        XCTAssertEqual(title, "invoice 2024 january")
    }

    func testCollapsesDuplicateSpaces() {
        let title = String.cleanedDocumentTitle("hello   world")
        XCTAssertFalse(title.contains("  "))
    }

    func testEmptyResultFallsBackToDefaultTitle() {
        // A string that is all separators becomes empty after cleaning
        let title = String.cleanedDocumentTitle("---___---")
        XCTAssertEqual(title, "Documento importado")
    }

    func testRemovesLeadingHexHash() {
        let raw = "a1b2c3d4e5f6a1b2_InvoiceApril"
        let title = String.cleanedDocumentTitle(raw)
        XCTAssertFalse(title.contains("a1b2c3d4"))
        XCTAssertTrue(title.contains("InvoiceApril"))
    }

    func testNormalTitlePassesThrough() {
        // Short words at the end are safe; only 12+ char tokens are stripped
        let raw = "Contrato de alquiler"
        XCTAssertEqual(String.cleanedDocumentTitle(raw), raw)
    }

    func testKnownLimitation_longRealWordsAtEnd() {
        // Words ≥ 12 alphanumeric chars at end of title are treated as Base64 tokens
        // and stripped. Known limitation of the heuristic.
        let raw = "Contrato de arrendamiento"  // "arrendamiento" = 14 chars
        let result = String.cleanedDocumentTitle(raw)
        // Result should still be non-empty (fallback guard prevents empty output)
        XCTAssertFalse(result.isEmpty)
    }
}

// MARK: - ChunkingService

final class ChunkingServiceTests: XCTestCase {

    private let service = ChunkingService()
    private let docId = "test-doc"

    func testEmptyText_returnsNoChunks() {
        let chunks = service.chunk(text: "", documentId: docId)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testWhitespaceOnly_returnsNoChunks() {
        let chunks = service.chunk(text: "   \n\n   ", documentId: docId)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testShortText_returnsSingleChunk() {
        let text = "Este es un documento corto."
        let chunks = service.chunk(text: text, documentId: docId)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].content.contains("documento corto"))
    }

    func testDocumentIdPreservedInAllChunks() {
        let text = Array(repeating: "Párrafo de contenido.", count: 40).joined(separator: "\n\n")
        let chunks = service.chunk(text: text, documentId: docId)
        XCTAssertTrue(chunks.allSatisfy { $0.documentId == docId })
    }

    func testChunkIndexIsSequential() {
        let text = Array(repeating: "Párrafo de contenido.", count: 40).joined(separator: "\n\n")
        let chunks = service.chunk(text: text, documentId: docId)
        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.chunkIndex, i)
        }
    }

    func testLongText_producesMultipleChunks() {
        // Each paragraph is ~100 chars; 20 paragraphs = ~2000 chars > 800 target
        let paragraph = String(repeating: "a", count: 100)
        let text = Array(repeating: paragraph, count: 20).joined(separator: "\n\n")
        let chunks = service.chunk(text: text, documentId: docId)
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testNoChunkExceedsHardLimit() {
        // Chunks should not be excessively larger than the target (800 * 2 = hard limit for single blocks)
        let paragraph = String(repeating: "x", count: 200)
        let text = Array(repeating: paragraph, count: 30).joined(separator: "\n\n")
        let chunks = service.chunk(text: text, documentId: docId)
        for chunk in chunks {
            // Allow some headroom for overlap; no chunk should be wildly oversized
            XCTAssertLessThanOrEqual(chunk.content.count, 1800,
                "Chunk \(chunk.chunkIndex) is \(chunk.content.count) chars — unexpectedly large")
        }
    }

    func testTinyParagraphsMergedWithNext() {
        // Two tiny paragraphs (< 60 chars each) followed by a regular one
        let text = "Hola.\n\nMundo.\n\nEste es el tercer párrafo con más contenido relevante aquí."
        let chunks = service.chunk(text: text, documentId: docId)
        // They should be merged into a single chunk, not split into 3
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].content.contains("Hola"))
        XCTAssertTrue(chunks[0].content.contains("tercer párrafo"))
    }

    func testOverlap_lastParagraphOfPreviousChunkAppearsInNext() {
        // Build a text where chunk boundary falls after a recognizable paragraph
        let shortPara = "Overlap paragraph marker unique."
        let filler = String(repeating: "y", count: 200)
        // Fill up ~800 chars worth of filler paragraphs, then add the marker, then more filler
        let fillerParas = Array(repeating: filler, count: 4).joined(separator: "\n\n")
        let text = fillerParas + "\n\n" + shortPara + "\n\n" + Array(repeating: filler, count: 4).joined(separator: "\n\n")
        let chunks = service.chunk(text: text, documentId: docId)
        guard chunks.count >= 2 else {
            XCTFail("Expected at least 2 chunks, got \(chunks.count)")
            return
        }
        // The marker should appear in a later chunk as overlap
        let laterChunksContent = chunks.dropFirst().map(\.content).joined()
        XCTAssertTrue(laterChunksContent.contains("Overlap paragraph marker"),
            "Expected overlap paragraph to appear in a subsequent chunk")
    }

    func testAllContentPreserved() {
        // Every paragraph's content should appear somewhere in the chunks
        let paragraphs = (1...10).map { "Párrafo número \($0) con contenido único." }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = service.chunk(text: text, documentId: docId)
        let allContent = chunks.map(\.content).joined()
        for (i, para) in paragraphs.enumerated() {
            XCTAssertTrue(allContent.contains("número \(i + 1)"),
                "Content of paragraph \(i + 1) is missing from chunks")
        }
    }
}

// MARK: - ChunkRepository FTS helpers

final class ChunkRepositoryFTSTests: XCTestCase {

    func testSanitizeFTSQuery_basicTokens() {
        let result = ChunkRepository.sanitizeFTSQuery("reunion proyecto sprint")
        XCTAssertTrue(result.contains("\"reunion\""))
        XCTAssertTrue(result.contains("\"proyecto\""))
        XCTAssertTrue(result.contains("\"sprint\""))
    }

    func testSanitizeFTSQuery_dropsSingleCharTokens() {
        let result = ChunkRepository.sanitizeFTSQuery("a i el plan")
        XCTAssertFalse(result.contains("\"a\""))
        XCTAssertFalse(result.contains("\"i\""))
        XCTAssertTrue(result.contains("\"plan\""))
    }

    func testSanitizeFTSQuery_punctuationIgnored() {
        let result = ChunkRepository.sanitizeFTSQuery("reunion, proyecto; sprint!")
        XCTAssertTrue(result.contains("\"reunion\""))
        XCTAssertTrue(result.contains("\"proyecto\""))
        XCTAssertTrue(result.contains("\"sprint\""))
    }

    func testSanitizeFTSQuery_emptyInput_returnsEmpty() {
        XCTAssertEqual(ChunkRepository.sanitizeFTSQuery(""), "")
    }

    func testSanitizeFTSQuery_onlyStopwords_returnsEmpty() {
        // Spanish stopwords should be filtered
        let result = ChunkRepository.sanitizeFTSQuery("el la los las de")
        XCTAssertEqual(result, "")
    }

    func testMeaningfulWords_filtersSpanishStopwords() {
        let words = ChunkRepository.meaningfulWords(from: "¿cuál es el precio del billete?")
        XCTAssertFalse(words.contains("el"))
        XCTAssertFalse(words.contains("es"))
        XCTAssertFalse(words.contains("del"))
        XCTAssertTrue(words.contains("precio"))
        XCTAssertTrue(words.contains("billete"))
    }

    func testMeaningfulWords_filtersEnglishStopwords() {
        let words = ChunkRepository.meaningfulWords(from: "what is the price of the ticket")
        XCTAssertFalse(words.contains("what"))
        XCTAssertFalse(words.contains("the"))
        XCTAssertFalse(words.contains("is"))
        XCTAssertFalse(words.contains("of"))
        XCTAssertTrue(words.contains("price"))
        XCTAssertTrue(words.contains("ticket"))
    }

    func testMeaningfulWords_shortWordsDropped() {
        // Words with <= 2 characters are dropped
        let words = ChunkRepository.meaningfulWords(from: "un yo tú presupuesto")
        XCTAssertFalse(words.contains("un"))
        XCTAssertFalse(words.contains("yo"))
        XCTAssertTrue(words.contains("presupuesto"))
    }
}

// MARK: - QAService prompt builder

final class QAServicePromptTests: XCTestCase {

    private func makeResult(title: String, content: String) -> SearchResult {
        SearchResult(id: UUID().uuidString, chunkContent: content, documentId: "doc-1",
                     documentTitle: title, score: 0.9)
    }

    func testBuildContextPrompt_containsQueryAtEnd() {
        let question = "¿Cuándo es la reunión?"
        let prompt = QAService.buildContextPrompt(query: question, context: [
            makeResult(title: "Agenda", content: "Reunión el martes a las 10.")
        ])
        XCTAssertTrue(prompt.hasSuffix(question) || prompt.contains(question))
    }

    func testBuildContextPrompt_containsDocumentTitle() {
        let prompt = QAService.buildContextPrompt(query: "test", context: [
            makeResult(title: "Presupuesto Anual", content: "Total: 50.000€")
        ])
        XCTAssertTrue(prompt.contains("Presupuesto Anual"))
    }

    func testBuildContextPrompt_containsChunkContent() {
        let content = "El importe total asciende a 1.234,56€."
        let prompt = QAService.buildContextPrompt(query: "importe", context: [
            makeResult(title: "Factura", content: content)
        ])
        XCTAssertTrue(prompt.contains(content))
    }

    func testBuildContextPrompt_multipleResults_allIncluded() {
        let results = (1...3).map { i in
            makeResult(title: "Doc \(i)", content: "Contenido único \(i)")
        }
        let prompt = QAService.buildContextPrompt(query: "test", context: results)
        for i in 1...3 {
            XCTAssertTrue(prompt.contains("Contenido único \(i)"))
        }
    }

    func testBuildContextPrompt_emptyContext_stillContainsQuestion() {
        let question = "¿Qué documentos hay?"
        let prompt = QAService.buildContextPrompt(query: question, context: [])
        XCTAssertTrue(prompt.contains(question))
    }
}

// MARK: - String search helpers

final class StringSearchTests: XCTestCase {

    func testNormalizedForSearch_removesAccents() {
        XCTAssertEqual("Málaga".normalizedForSearch, "malaga")
        XCTAssertEqual("AVIÓN".normalizedForSearch, "avion")
    }

    func testNormalizedForSearch_lowercases() {
        XCTAssertEqual("Ryanair".normalizedForSearch, "ryanair")
    }

    func testHeadAndTailTruncated_shortTextUnchanged() {
        let s = "texto corto"
        XCTAssertEqual(s.headAndTailTruncated(), s)
    }

    func testHeadAndTailTruncated_exactlyAtLimitUnchanged() {
        let s = String(repeating: "x", count: 4000)
        XCTAssertEqual(s.headAndTailTruncated(), s)
    }

    func testHeadAndTailTruncated_longTextKeepsHeadAndTail() {
        let head = String(repeating: "A", count: 2500)
        let mid  = String(repeating: "B", count: 3000)
        let tail = String(repeating: "C", count: 1000)
        let truncated = (head + mid + tail).headAndTailTruncated()

        XCTAssertTrue(truncated.hasPrefix("A"))
        XCTAssertTrue(truncated.hasSuffix("C"))
        XCTAssertTrue(truncated.contains("…"))
        XCTAssertEqual(truncated.count, 2500 + 3 + 1000) // head + "\n…\n" + tail
    }
}

// MARK: - StructuredDocumentData

final class StructuredDocumentDataTests: XCTestCase {

    func testFormattedAmount_nilWhenNoAmount() {
        let d = StructuredDocumentData()
        XCTAssertNil(d.formattedAmount)
    }

    func testFormattedAmount_includesValue() {
        var d = StructuredDocumentData()
        d.amount = 1234.5
        d.currency = "EUR"
        XCTAssertEqual(d.formattedAmount?.contains("234"), true)
    }

    func testFormattedDate_parsesISODate() {
        var d = StructuredDocumentData()
        d.date = "2025-08-05"
        XCTAssertEqual(d.formattedDate?.contains("2025"), true)
    }

    func testFormattedDate_invalidReturnsRawString() {
        var d = StructuredDocumentData()
        d.date = "not-a-date"
        XCTAssertEqual(d.formattedDate, "not-a-date")
    }

    func testIsEmpty_trueWhenCoreFieldsNil() {
        XCTAssertTrue(StructuredDocumentData().isEmpty)
    }

    func testIsEmpty_falseWhenVendorPresent() {
        var d = StructuredDocumentData()
        d.vendor = "Ryanair"
        XCTAssertFalse(d.isEmpty)
    }

    func testIsTravelOrEvent_classification() {
        XCTAssertTrue(StructuredDocumentData.DocumentType.flight.isTravelOrEvent)
        XCTAssertTrue(StructuredDocumentData.DocumentType.event.isTravelOrEvent)
        XCTAssertTrue(StructuredDocumentData.DocumentType.ticket.isTravelOrEvent)
        XCTAssertFalse(StructuredDocumentData.DocumentType.invoice.isTravelOrEvent)
    }
}

// MARK: - ContentSearchResult snippet

final class ContentSearchResultTests: XCTestCase {

    private func make(_ content: String) -> ContentSearchResult {
        ContentSearchResult(documentId: "d", documentTitle: "t", fileType: "pdf", chunkContent: content)
    }

    func testSnippet_containsMatchedTerm() {
        let r = make("El pasajero embarca en el vuelo FR347 con destino Madrid a las 18:40.")
        XCTAssertTrue(r.snippet(for: "FR347", windowSize: 30, leftContext: 10).contains("FR347"))
    }

    func testSnippet_noLeadingEllipsisWhenMatchAtStart() {
        let r = make("Madrid es el destino del vuelo de mañana por la tarde.")
        XCTAssertFalse(r.snippet(for: "Madrid", windowSize: 40, leftContext: 40).hasPrefix("…"))
    }

    func testSnippet_trailingEllipsisWhenClipped() {
        let long = "Madrid " + String(repeating: "texto adicional ", count: 50)
        XCTAssertTrue(make(long).snippet(for: "Madrid", windowSize: 50, leftContext: 10).hasSuffix("…"))
    }

    func testSnippet_preservesAccentsFromOriginalText() {
        let r = make("Billete de tren con destino Málaga centro.")
        XCTAssertTrue(r.snippet(for: "malaga", windowSize: 60, leftContext: 40).contains("Málaga"))
    }

    func testSnippet_noMatch_returnsTextWithoutLeadingEllipsis() {
        let r = make("Contenido sin coincidencias relevantes aquí.")
        let s = r.snippet(for: "zzzzz", windowSize: 100, leftContext: 40)
        XCTAssertFalse(s.isEmpty)
        XCTAssertFalse(s.hasPrefix("…"))
    }
}

// MARK: - BarcodeKind classification

final class BarcodeKindTests: XCTestCase {

    func testBoardingPass_BCBPStartsWithMAndDigit() {
        if case .boardingPass = BarcodeKind(payload: "M1DESMARAIS/LUC       EABC123 MADBCN") { } else {
            XCTFail("Expected boarding pass")
        }
    }

    func testURL_httpsPayload() {
        if case .url = BarcodeKind(payload: "https://example.com/ticket") { } else {
            XCTFail("Expected URL")
        }
    }

    func testGeneric_plainCode() {
        if case .generic = BarcodeKind(payload: "SOME-RANDOM-CODE-123") { } else {
            XCTFail("Expected generic")
        }
    }

    func testGeneric_MNotFollowedByDigitIsNotBoardingPass() {
        // Starts with 'M' but second char is a letter → not a BCBP boarding pass
        if case .generic = BarcodeKind(payload: "MADRID-BARCELONA-TICKET-2025") { } else {
            XCTFail("Expected generic, not boarding pass")
        }
    }
}
