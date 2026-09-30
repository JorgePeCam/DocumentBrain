import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Q&A provider using Apple Foundation Models (iOS 26+, on-device)
/// Runs entirely on-device — free, private, no API key needed.
///
/// The on-device model has a small context window (~4K tokens shared between
/// instructions, prompt AND the generated answer). Prompts are therefore built
/// against an explicit character budget (see `OnDevicePromptBuilder`), and if the
/// model still reports `exceededContextWindowSize` we retry with progressively
/// smaller budgets instead of dropping straight to the extractive fallback.
@available(iOS 26, macOS 26, *)
final class FoundationModelQAProvider: StreamableQAProvider {
    var name: String { "Apple Intelligence (on-device)" }
    var kind: QAProviderKind { .onDevice }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    func answer(query: String, context: [SearchResult], history: [ConversationTurn] = []) async throws -> String {
        #if canImport(FoundationModels)
        return try await withShrinkingBudget { budget in
            let prompt = OnDevicePromptBuilder.build(query: query, context: context, history: history, budget: budget)
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(to: prompt).content
        }
        #else
        throw QAError.noProviderAvailable
        #endif
    }

    func streamAnswer(query: String, context: [SearchResult], history: [ConversationTurn] = [], onUpdate: @escaping (String) -> Void) async throws {
        #if canImport(FoundationModels)
        try await withShrinkingBudget { budget in
            let prompt = OnDevicePromptBuilder.build(query: query, context: context, history: history, budget: budget)
            // A fresh session per attempt: a session that already failed is not reused.
            let session = LanguageModelSession(instructions: Self.instructions)
            for try await partial in session.streamResponse(to: prompt) {
                onUpdate(partial.content)
            }
        }
        #else
        throw QAError.noProviderAvailable
        #endif
    }

    // MARK: - Private

    private static var instructions: String { AppLanguage.current.systemPrompt }

    #if canImport(FoundationModels)
    /// Runs `operation` with the largest budget first and retries with the next,
    /// smaller budget only when the model reports that the context window overflowed.
    /// Any other error is rethrown immediately so QAService can fall back.
    private func withShrinkingBudget<T>(_ operation: (OnDevicePromptBuilder.Budget) async throws -> T) async throws -> T {
        var lastError: Error = QAError.noProviderAvailable
        for budget in OnDevicePromptBuilder.Budget.attempts {
            do {
                return try await operation(budget)
            } catch let error as LanguageModelSession.GenerationError {
                guard case .exceededContextWindowSize = error else { throw error }
                AppLogger.debug("[FoundationModels] Context window exceeded with budget \(budget.promptChars) chars — retrying smaller")
                lastError = error
            }
        }
        throw lastError
    }
    #endif
}

// MARK: - Prompt budgeting

/// Builds prompts for the on-device model within a fixed character budget.
///
/// Kept free of FoundationModels types so it can be unit-tested on any OS version.
/// Characters are used as a proxy for tokens: Spanish text averages roughly
/// 3–4 characters per token, so the budgets below keep the prompt around
/// 2K tokens and leave room for the system instructions and the answer.
struct OnDevicePromptBuilder {

    struct Budget: Equatable {
        /// Total characters allowed for history + snippets + question.
        let promptChars: Int
        /// Max characters kept from any single snippet.
        let maxCharsPerChunk: Int
        /// Number of previous turns included.
        let historyTurns: Int

        static let standard = Budget(promptChars: 6500, maxCharsPerChunk: 1200, historyTurns: 2)
        static let reduced  = Budget(promptChars: 4000, maxCharsPerChunk: 900, historyTurns: 1)
        static let minimal  = Budget(promptChars: 2200, maxCharsPerChunk: 700, historyTurns: 0)

        static let attempts: [Budget] = [.standard, .reduced, .minimal]
    }

    /// Max characters kept from each side of a past turn (answers can be long).
    static let maxHistoryUserChars = 200
    static let maxHistoryAssistantChars = 350

    static func build(
        query: String,
        context: [SearchResult],
        history: [ConversationTurn],
        budget: Budget,
        language: AppLanguage = .current
    ) -> String {
        let questionBlock = "\(language.questionLabel): \(query)"
        var remaining = budget.promptChars - questionBlock.count

        // 1. History (most recent turns only), only if it leaves room for snippets.
        var historyBlock = ""
        let turns = history.suffix(budget.historyTurns)
        if !turns.isEmpty {
            let historyLabel = language == .spanish ? "CONVERSACIÓN PREVIA" : "PREVIOUS CONVERSATION"
            let userLabel = language == .spanish ? "Usuario" : "User"
            let assistantLabel = language == .spanish ? "Asistente" : "Assistant"
            var block = "\(historyLabel):\n"
            for turn in turns {
                block += "\(userLabel): \(truncate(turn.userMessage, to: maxHistoryUserChars))\n"
                block += "\(assistantLabel): \(truncate(turn.assistantMessage, to: maxHistoryAssistantChars))\n\n"
            }
            // Never let history eat more than a third of the budget.
            if block.count <= budget.promptChars / 3 {
                historyBlock = block
                remaining -= block.count
            }
        }

        // 2. Snippets. The caller orders context for reading (by document, then by
        //    chunk position), so relevance order is recovered from the scores:
        //    snippets are *selected* by score until the budget runs out, then
        //    *rendered* in their original order so neighbouring chunks stay adjacent.
        //    The highest-scoring snippet is always included (truncated if needed).
        let header = "\(language.snippetsHeader)\n\n"
        remaining -= header.count
        let byRelevance = context.indices.sorted {
            context[$0].score != context[$1].score ? context[$0].score > context[$1].score : $0 < $1
        }
        var selectedText: [Int: String] = [:]
        for index in byRelevance {
            let result = context[index]
            // Conservative label length (2-digit index) so rendering never exceeds the estimate.
            let overhead = language.snippetLabel(title: result.documentTitle, index: 99).count + 3
            var text = truncate(result.chunkContent, to: budget.maxCharsPerChunk)

            if overhead + text.count > remaining {
                guard selectedText.isEmpty else { continue } // a shorter snippet may still fit
                text = truncate(text, to: max(0, remaining - overhead))
            }
            selectedText[index] = text
            remaining -= overhead + text.count
        }

        var snippetsBlock = header
        for (position, index) in selectedText.keys.sorted().enumerated() {
            let label = language.snippetLabel(title: context[index].documentTitle, index: position + 1)
            snippetsBlock += "\(label)\n\(selectedText[index]!)\n\n"
        }

        return historyBlock + snippetsBlock + questionBlock
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return "" }
        return String(text.prefix(limit - 1)) + "…"
    }
}
