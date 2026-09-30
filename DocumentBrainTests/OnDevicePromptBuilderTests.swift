import XCTest
@testable import DocumentBrain

@MainActor
final class OnDevicePromptBuilderTests: XCTestCase {

    private func result(_ title: String, _ content: String) -> SearchResult {
        SearchResult(id: UUID().uuidString, chunkContent: content, documentId: title,
                     documentTitle: title, score: 0.8)
    }

    private func longText(_ n: Int) -> String {
        String(repeating: "palabra ", count: n / 8)
    }

    func testFewSmallChunks_allIncluded() {
        let context = (1...3).map { result("Doc \($0)", "Contenido único \($0)") }
        let prompt = OnDevicePromptBuilder.build(query: "¿Qué hay?", context: context, history: [],
                                                 budget: .standard, language: .spanish)
        for i in 1...3 { XCTAssertTrue(prompt.contains("Contenido único \(i)")) }
        XCTAssertTrue(prompt.hasSuffix("PREGUNTA: ¿Qué hay?"))
    }

    func testManyLargeChunks_promptStaysWithinBudget() {
        // 15 neighbour-expanded chunks of ~1100 chars: the case that overflowed the 4K window.
        let context = (1...15).map { result("Doc \($0)", longText(1100)) }
        let history = (1...3).map { _ in ConversationTurn(userMessage: longText(400), assistantMessage: longText(2000)) }

        for budget in OnDevicePromptBuilder.Budget.attempts {
            let prompt = OnDevicePromptBuilder.build(query: "¿Cuánto pagué?", context: context,
                                                     history: history, budget: budget, language: .spanish)
            XCTAssertLessThanOrEqual(prompt.count, budget.promptChars, "budget \(budget.promptChars)")
            XCTAssertTrue(prompt.contains("fragmento 1"), "top-ranked snippet must always be present")
        }
    }

    func testBudgets_shrinkMonotonically() {
        let attempts = OnDevicePromptBuilder.Budget.attempts
        for (a, b) in zip(attempts, attempts.dropFirst()) {
            XCTAssertGreaterThan(a.promptChars, b.promptChars)
            XCTAssertGreaterThanOrEqual(a.historyTurns, b.historyTurns)
        }
    }

    func testRankingOrderPreserved() {
        let context = [result("Primero", "AAA"), result("Segundo", "BBB")]
        let prompt = OnDevicePromptBuilder.build(query: "q", context: context, history: [],
                                                 budget: .standard, language: .spanish)
        let first = prompt.range(of: "AAA")!.lowerBound
        let second = prompt.range(of: "BBB")!.lowerBound
        XCTAssertLessThan(first, second)
    }

    func testHugeFirstChunk_isTruncatedNotDropped() {
        let context = [result("Enorme", longText(20_000))]
        let prompt = OnDevicePromptBuilder.build(query: "q", context: context, history: [],
                                                 budget: .minimal, language: .spanish)
        XCTAssertTrue(prompt.contains("Enorme"))
        XCTAssertLessThanOrEqual(prompt.count, OnDevicePromptBuilder.Budget.minimal.promptChars)
    }

    func testMinimalBudget_dropsHistory() {
        let history = [ConversationTurn(userMessage: "pregunta anterior", assistantMessage: "respuesta anterior")]
        let prompt = OnDevicePromptBuilder.build(query: "q", context: [result("D", "x")], history: history,
                                                 budget: .minimal, language: .spanish)
        XCTAssertFalse(prompt.contains("pregunta anterior"))
    }

    func testStandardBudget_includesRecentHistoryTruncated() {
        let longAnswer = longText(3000)
        let history = [ConversationTurn(userMessage: "¿Y el vuelo?", assistantMessage: longAnswer)]
        let prompt = OnDevicePromptBuilder.build(query: "q", context: [result("D", "x")], history: history,
                                                 budget: .standard, language: .spanish)
        XCTAssertTrue(prompt.contains("¿Y el vuelo?"))
        XCTAssertFalse(prompt.contains(longAnswer))
    }

    func testTruncate() {
        XCTAssertEqual(OnDevicePromptBuilder.truncate("hola", to: 10), "hola")
        XCTAssertEqual(OnDevicePromptBuilder.truncate("hola mundo", to: 5), "hola…")
        XCTAssertEqual(OnDevicePromptBuilder.truncate("hola", to: 0), "")
    }

    func testBestScoringSnippet_keptEvenWhenLastInReadingOrder() {
        // ChatViewModel orders context by chunk position, so the seed can come last.
        var context = (1...6).map { i in
            SearchResult(id: "n\(i)", chunkContent: "vecino \(i) " + longText(900), documentId: "d",
                         documentTitle: "Contrato", score: 0.30, chunkIndex: i)
        }
        context.append(SearchResult(id: "seed", chunkContent: "CLAVE: animales de compañía", documentId: "d",
                                    documentTitle: "Contrato", score: 0.72, chunkIndex: 7))
        let prompt = OnDevicePromptBuilder.build(query: "¿Puedo tener perro?", context: context, history: [],
                                                 budget: .minimal, language: .spanish)
        XCTAssertTrue(prompt.contains("CLAVE: animales de compañía"))
        XCTAssertLessThanOrEqual(prompt.count, OnDevicePromptBuilder.Budget.minimal.promptChars)
    }

    func testSelectedSnippets_renderedInReadingOrder() {
        let context = [
            SearchResult(id: "a", chunkContent: "PRIMERO", documentId: "d", documentTitle: "D", score: 0.3, chunkIndex: 0),
            SearchResult(id: "b", chunkContent: "SEGUNDO", documentId: "d", documentTitle: "D", score: 0.9, chunkIndex: 1)
        ]
        let prompt = OnDevicePromptBuilder.build(query: "q", context: context, history: [],
                                                 budget: .standard, language: .spanish)
        XCTAssertLessThan(prompt.range(of: "PRIMERO")!.lowerBound, prompt.range(of: "SEGUNDO")!.lowerBound)
    }
}
