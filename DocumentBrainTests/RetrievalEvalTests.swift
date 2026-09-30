import XCTest
import GRDB
@testable import DocumentBrain

/// Retrieval-quality benchmark over the labelled synthetic corpus in
/// `DocumentBrainTests/RetrievalEval/retrieval_eval_corpus.json`.
///
/// Runs the same pipeline the chat uses — ChunkingService → EmbeddingService (CoreML)
/// → ChunkRepository.hybridSearch(limit: 12, minScore: 0.2) → top-5 seeds — against an
/// in-memory database, then prints doc@1 / doc@5 / evid@5 / MRR overall and per question
/// type. `eval/run_retrieval_eval.py` replicates the pipeline in Python to compare
/// embedding models before converting them; this test confirms the numbers with the real
/// app code and the real CoreML model.
///
///   xcodebuild test -project DocumentBrain.xcodeproj -scheme DocumentBrain \
///     -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:DocumentBrainTests/RetrievalEvalTests
@MainActor
final class RetrievalEvalTests: XCTestCase {

    struct Corpus: Decodable {
        struct Doc: Decodable { let id: String; let title: String; let text: String }
        struct Question: Decodable { let q: String; let doc: String; let evidence: String; let type: String }
        let documents: [Doc]
        let questions: [Question]
    }

    /// Regression floors for the hybrid pipeline (all questions). Measured with the Python
    /// replica on multi-qa-MiniLM-L6-cos-v1: doc@5 0.76, evid@5 0.76. Raise them when the
    /// model or scoring improves so regressions are caught.
    enum Floors {
        static let hybridDocAt5 = 0.70
        static let hybridEvidenceAt5 = 0.70
    }

    struct Tally {
        var n = 0, docAt1 = 0, docAt5 = 0, evidenceAt5 = 0
        var reciprocalRankSum = 0.0

        mutating func add(results: [SearchResult], question: Corpus.Question) {
            n += 1
            let rank = results.firstIndex { $0.documentId == question.doc }.map { $0 + 1 }
            if rank == 1 { docAt1 += 1 }
            if let rank, rank <= 5 { docAt5 += 1; reciprocalRankSum += 1 / Double(rank) }
            else if let rank { reciprocalRankSum += 1 / Double(rank) }
            let evidence = RetrievalEvalTests.fold(question.evidence)
            if results.prefix(5).contains(where: {
                $0.documentId == question.doc && RetrievalEvalTests.fold($0.chunkContent).contains(evidence)
            }) { evidenceAt5 += 1 }
        }

        func rate(_ x: Int) -> Double { n == 0 ? 0 : Double(x) / Double(n) }
        var mrr: Double { n == 0 ? 0 : reciprocalRankSum / Double(n) }
        func row(_ label: String) -> String {
            String(format: "%-20@ %3d  %5.2f  %5.2f  %6.2f  %5.2f",
                   label as NSString, n, rate(docAt1), rate(docAt5), rate(evidenceAt5), mrr)
        }
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func testRetrievalQuality() async throws {
        guard let embedder = EmbeddingService.shared else {
            throw XCTSkip("CoreML embedding model not available in the test host")
        }
        let corpus = try loadCorpus()
        let database = try AppDatabase.makeInMemory()
        let repository = ChunkRepository(db: database)
        let chunker = ChunkingService()

        // Index
        var chunkCount = 0
        for doc in corpus.documents {
            let document = Document(id: doc.id, title: doc.title, content: doc.text, processingStatus: .ready)
            try await database.dbWriter.write { try document.save($0) }
            var items: [(chunk: DocumentChunk, embedding: [Float])] = []
            for chunk in chunker.chunk(text: doc.text, documentId: doc.id) {
                items.append((chunk, try await embedder.generateEmbedding(for: chunk.content)))
            }
            chunkCount += items.count
            try await repository.saveChunks(items)
        }

        // Query
        var hybrid: [String: Tally] = [:]
        var vector: [String: Tally] = [:]
        var misses: [String] = []
        for question in corpus.questions {
            let queryVector = try await embedder.generateEmbedding(for: question.q)
            let hybridResults = try await repository.hybridSearch(
                queryVector: queryVector, queryText: question.q, limit: 12, minScore: 0.2)
            let vectorResults = try await repository.searchByVector(
                queryVector: queryVector, limit: 12, minScore: -1)

            for bucket in ["all", question.type] {
                hybrid[bucket, default: Tally()].add(results: hybridResults, question: question)
                vector[bucket, default: Tally()].add(results: vectorResults, question: question)
            }
            var probe = Tally()
            probe.add(results: hybridResults, question: question)
            if probe.evidenceAt5 == 0 {
                let got = hybridResults.prefix(3).map(\.documentId).joined(separator: ", ")
                misses.append("[\(question.type)] \(question.q) → expected \(question.doc), got [\(got)]")
            }
        }

        // Report
        var report = """
        Retrieval eval — model \(EmbeddingService.modelVersion)
        \(corpus.documents.count) documents, \(chunkCount) chunks, \(corpus.questions.count) questions

        mode/bucket            n  doc@1  doc@5  evid@5    MRR
        """
        for (mode, tallies) in [("hybrid", hybrid), ("vector", vector)] {
            for bucket in ["all", "lexical", "semantic", "crosslingual"] {
                if let t = tallies[bucket] { report += "\n" + t.row("\(mode)/\(bucket)") }
            }
        }
        if !misses.isEmpty {
            report += "\n\nHybrid misses (evidence not in top 5):\n" + misses.joined(separator: "\n")
        }
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "retrieval-eval-report"
        attachment.lifetime = .keepAlways
        add(attachment)

        let all = try XCTUnwrap(hybrid["all"])
        XCTAssertGreaterThanOrEqual(all.rate(all.docAt5), Floors.hybridDocAt5, "hybrid doc@5 regressed")
        XCTAssertGreaterThanOrEqual(all.rate(all.evidenceAt5), Floors.hybridEvidenceAt5, "hybrid evid@5 regressed")
    }

    private func loadCorpus() throws -> Corpus {
        let bundle = Bundle(for: RetrievalEvalTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "retrieval_eval_corpus", withExtension: "json"),
            "retrieval_eval_corpus.json must be a resource of the test target")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
}

// MARK: - Entity detection

final class EntityTermsTests: XCTestCase {

    func testSentenceInitialCapital_isNotAnEntity() {
        XCTAssertTrue(ChunkRepository.entityTerms(from: "¿Cuántos días de vacaciones tengo?").isEmpty)
        XCTAssertTrue(ChunkRepository.entityTerms(from: "Can I get a refund?").isEmpty)
    }

    func testProperNounsInsideSentence_areEntities() {
        let terms = ChunkRepository.entityTerms(from: "¿Qué idiomas habla Lucía en Madrid?")
        XCTAssertEqual(terms, ["lucia", "madrid"])
    }

    func testCodesAtStart_areEntities() {
        XCTAssertTrue(ChunkRepository.entityTerms(from: "SL2471 qué asiento").contains("sl2471"))
        XCTAssertTrue(ChunkRepository.entityTerms(from: "IBI quién lo paga").contains("ibi"))
    }

    func testEachSentenceSkipsItsOwnFirstWord() {
        let terms = ChunkRepository.entityTerms(from: "Vuelo a Londres. Cuándo vuelvo?")
        XCTAssertEqual(terms, ["londres"])
    }
}
