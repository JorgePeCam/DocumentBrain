import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var queryText = ""
    @Published var isSearching = false
    @Published var streamingText = ""

    // Conversation history
    @Published var conversations: [Conversation] = []
    @Published var currentConversation: Conversation?

    private let chunkRepo = ChunkRepository()
    private let qaService = QAService.shared
    private let conversationRepo = ConversationRepository()
    private var cancellables = Set<AnyCancellable>()

    init() {
        Task { await loadConversations() }

        NotificationCenter.default.publisher(for: .allDataDidDelete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAllDataDeleted()
            }
            .store(in: &cancellables)
    }

    private func handleAllDataDeleted() {
        conversations = []
        currentConversation = nil
        messages = []
        queryText = ""
        streamingText = ""
        isSearching = false
    }

    // MARK: - Conversation Management

    func loadConversations() async {
        do {
            conversations = try await conversationRepo.fetchAll()
        } catch {
            conversations = []
        }
    }

    func startNewConversation() {
        currentConversation = nil
        messages = []
        queryText = ""
        streamingText = ""
    }

    func loadConversation(_ conversation: Conversation) async {
        currentConversation = conversation
        do {
            let persisted = try await conversationRepo.fetchMessages(for: conversation.id)
            messages = persisted.map { ChatMessage(from: $0) }
        } catch {
            messages = []
        }
    }

    func deleteConversation(_ conversation: Conversation) async {
        do {
            try await conversationRepo.delete(conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            if currentConversation?.id == conversation.id {
                startNewConversation()
            }
        } catch { }
    }

    func deleteAllConversations() async {
        do {
            try await conversationRepo.deleteAllConversations()
            conversations = []
            startNewConversation()
        } catch { }
    }

    // MARK: - Messaging

    func sendQuery() {
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        messages.append(ChatMessage(content: query, isUser: true))
        queryText = ""
        isSearching = true
        streamingText = ""

        Task {
            if currentConversation == nil {
                let title = generateTitle(from: query)
                let conv = Conversation(title: title)
                try? await conversationRepo.save(conv)
                currentConversation = conv
                conversations.insert(conv, at: 0)
            }

            if let convId = currentConversation?.id, let lastUserMsg = messages.last(where: { $0.isUser }) {
                let persisted = PersistedChatMessage(
                    id: lastUserMsg.id,
                    conversationId: convId,
                    content: lastUserMsg.content,
                    isUser: true
                )
                try? await conversationRepo.saveMessage(persisted)
            }

            await search(query: query)

            if let convId = currentConversation?.id {
                try? await conversationRepo.touchUpdatedAt(convId)
                await loadConversations()
            }
        }
    }

    func clearMessages() {
        startNewConversation()
    }

    // MARK: - Search & QA

    /// Returns the last `maxTurns` complete user/assistant exchanges before the current query.
    private func conversationHistory(maxTurns: Int = 3) -> [ConversationTurn] {
        // messages already contains the current user message at the end — skip it
        let prior = messages.dropLast()
        var turns: [ConversationTurn] = []
        var i = prior.startIndex

        while i < prior.endIndex {
            guard prior[i].isUser else { i = prior.index(after: i); continue }
            let next = prior.index(after: i)
            guard next < prior.endIndex, !prior[next].isUser else { i = next; continue }
            turns.append(ConversationTurn(
                userMessage: prior[i].content,
                assistantMessage: prior[next].content
            ))
            i = prior.index(after: next)
        }

        return Array(turns.suffix(maxTurns))
    }

    /// Expands a short follow-up query with key terms from the previous user message
    /// so the embedding search can still find the right document.
    /// Example: "¿y a qué terminal?" → "¿y a qué terminal? vuelo Blanca"
    private func expandedQuery(_ query: String) -> String {
        let meaningful = ChunkRepository.meaningfulWords(from: query)
        guard meaningful.count < 4 else { return query }

        // Find the last substantive user message
        let prior = messages.dropLast()
        guard let lastUserMsg = prior.last(where: { $0.isUser && ChunkRepository.meaningfulWords(from: $0.content).count >= 3 }) else {
            return query
        }

        let extraTerms = ChunkRepository.meaningfulWords(from: lastUserMsg.content)
            .filter { !meaningful.contains($0.lowercased()) }
            .prefix(4)
            .joined(separator: " ")

        return extraTerms.isEmpty ? query : "\(query) \(extraTerms)"
    }

    private func search(query: String) async {
        guard let embeddingService = EmbeddingService.shared else {
            await addBotMessage(AppLanguage.current.embeddingsUnavailable)
            return
        }

        do {
            let history = conversationHistory()
            let searchQuery = expandedQuery(query)

            let queryVector = try await embeddingService.generateEmbedding(for: searchQuery)

            let results = try await chunkRepo.hybridSearch(
                queryVector: queryVector,
                queryText: searchQuery,
                limit: 12,
                minScore: 0.2
            )

            AppLogger.debug("[QA] Query: \"\(query)\" → \(results.count) results")
            for (i, r) in results.prefix(5).enumerated() {
                AppLogger.debug("[QA]   [\(i)] score=\(String(format: "%.3f", r.score)) doc=\"\(r.documentTitle)\" chunk=\(r.chunkIndex ?? -1)")
            }

            if results.isEmpty {
                await addBotMessage(AppLanguage.current.noRelevantResults)
                return
            }

            let contextSeeds = Array(results.prefix(5))
            let contextForAnswer = await expandContextWithNeighbors(from: contextSeeds, limit: 15)

            let citations = Dictionary(grouping: contextSeeds, by: \.documentId)
                .compactMap { _, group -> Citation? in
                    guard let best = group.max(by: { $0.score < $1.score }) else { return nil }
                    return Citation(
                        documentId: best.documentId,
                        documentTitle: best.documentTitle,
                        chunkContent: best.chunkContent,
                        score: best.score
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.documentTitle.localizedCaseInsensitiveCompare(rhs.documentTitle) == .orderedAscending
                }

            AppLogger.debug("[QA] Provider: \(qaService.activeProvider?.name ?? "NONE") available=\(qaService.hasAnyProvider)")

            let debugInfo: RAGDebugInfo? = AppState.shared.isDebugMode ? RAGDebugInfo(
                originalQuery: query,
                expandedQuery: searchQuery,
                provider: qaService.activeProvider?.name ?? "Extractive fallback",
                results: results.prefix(12).map { r in
                    RAGDebugResult(
                        documentTitle: r.documentTitle,
                        chunkIndex: r.chunkIndex,
                        score: r.score,
                        preview: String(r.chunkContent.prefix(120))
                    )
                }
            ) : nil

            if qaService.hasAnyProvider {
                var placeholderIndex: Int?
                do {
                    if qaService.canStream {
                        placeholderIndex = messages.count
                        let placeholderMsg = ChatMessage(content: "", isUser: false, citations: citations, debugInfo: debugInfo)
                        messages.append(placeholderMsg)

                        try await qaService.streamAnswer(
                            query: query,
                            context: contextForAnswer,
                            history: history
                        ) { [weak self] partialText in
                            Task { @MainActor in
                                guard let self else { return }
                                self.streamingText = partialText
                                if let placeholderIndex, placeholderIndex < self.messages.count {
                                    self.messages[placeholderIndex] = ChatMessage(
                                        id: placeholderMsg.id,
                                        content: partialText,
                                        isUser: false,
                                        citations: citations,
                                        debugInfo: debugInfo
                                    )
                                }
                            }
                        }
                        streamingText = ""

                        if let placeholderIndex, placeholderIndex < messages.count {
                            await persistBotMessage(messages[placeholderIndex])
                        }
                    } else {
                        let answer = try await qaService.answer(query: query, context: contextForAnswer, history: history)
                        let msg = ChatMessage(content: answer, isUser: false, citations: citations, debugInfo: debugInfo)
                        messages.append(msg)
                        await persistBotMessage(msg)
                    }
                } catch {
                    AppLogger.debug("[QA] ⚠️ LLM failed, using extractive fallback. Error: \(error.localizedDescription)")
                    let answer = buildExtractiveAnswer(from: contextForAnswer, query: query)
                    if let placeholderIndex, placeholderIndex < messages.count {
                        let msg = ChatMessage(id: messages[placeholderIndex].id, content: answer, isUser: false, citations: citations, debugInfo: debugInfo)
                        messages[placeholderIndex] = msg
                        await persistBotMessage(msg)
                    } else {
                        let msg = ChatMessage(content: answer, isUser: false, citations: citations, debugInfo: debugInfo)
                        messages.append(msg)
                        await persistBotMessage(msg)
                    }
                }
            } else {
                AppLogger.debug("[QA] ⚠️ No LLM provider — using extractive fallback")
                let answer = buildExtractiveAnswer(from: contextForAnswer, query: query)
                let msg = ChatMessage(content: answer, isUser: false, citations: citations, debugInfo: debugInfo)
                messages.append(msg)
                await persistBotMessage(msg)
            }

        } catch {
            await addBotMessage("Error: \(error.localizedDescription)")
        }

        isSearching = false
    }

    private func expandContextWithNeighbors(from selected: [SearchResult], limit: Int) async -> [SearchResult] {
        guard !selected.isEmpty else { return [] }

        let groupedByDocument = Dictionary(grouping: selected, by: \.documentId)
        let rankedDocIds = groupedByDocument
            .map { docId, seeds -> (id: String, score: Float) in
                let top = seeds.map(\.score).max() ?? 0
                let sum = seeds.reduce(Float(0)) { $0 + $1.score }
                return (docId, top * 2 + sum)
            }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map(\.id)

        var merged: [String: SearchResult] = [:]
        var documentRank: [String: Int] = [:]
        for (index, docId) in rankedDocIds.enumerated() {
            documentRank[docId] = index
        }

        for docId in rankedDocIds {
            guard let seeds = groupedByDocument[docId], !seeds.isEmpty else { continue }
            for seed in seeds { merged[seed.id] = seed }

            guard let chunks = try? await chunkRepo.fetchChunks(forDocumentId: docId),
                  !chunks.isEmpty else { continue }

            let seedIndices = seeds.compactMap(\.chunkIndex)
            let strongestSeed = seeds.max(by: { $0.score < $1.score })
            let fallbackScore = strongestSeed?.score ?? 0.30
            let neighborRadius = 2 + min(2, max(0, seeds.count - 1))
            let seedIds = Set(seeds.map(\.id))

            var candidates: [SearchResult] = []
            for (position, chunk) in chunks.enumerated() {
                let distance: Int
                if !seedIndices.isEmpty {
                    distance = seedIndices.map { abs($0 - chunk.chunkIndex) }.min() ?? Int.max
                    guard distance <= neighborRadius else { continue }
                } else {
                    let seedPosition = strongestSeed.flatMap { seed in
                        chunks.firstIndex(where: { $0.id == seed.id })
                    } ?? 0
                    distance = abs(position - seedPosition)
                    guard distance <= neighborRadius else { continue }
                }
                let score = max(fallbackScore - Float(distance) * 0.05, 0.20)
                candidates.append(SearchResult(
                    id: chunk.id,
                    chunkContent: chunk.content,
                    documentId: docId,
                    documentTitle: strongestSeed?.documentTitle ?? seeds[0].documentTitle,
                    score: score,
                    chunkIndex: chunk.chunkIndex
                ))
            }

            let prioritized = candidates.sorted { lhs, rhs in
                let lhsIsSeed = seedIds.contains(lhs.id)
                let rhsIsSeed = seedIds.contains(rhs.id)
                if lhsIsSeed != rhsIsSeed { return lhsIsSeed }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (lhs.chunkIndex ?? 0) < (rhs.chunkIndex ?? 0)
            }

            for result in prioritized.prefix(6) {
                if let existing = merged[result.id], result.score <= existing.score { continue }
                merged[result.id] = result
            }
        }

        return merged.values
            .sorted { lhs, rhs in
                let leftRank = documentRank[lhs.documentId] ?? Int.max
                let rightRank = documentRank[rhs.documentId] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                if (lhs.chunkIndex ?? Int.max) != (rhs.chunkIndex ?? Int.max) {
                    return (lhs.chunkIndex ?? Int.max) < (rhs.chunkIndex ?? Int.max)
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func addBotMessage(_ text: String) async {
        let msg = ChatMessage(content: text, isUser: false)
        messages.append(msg)
        isSearching = false
        await persistBotMessage(msg)
    }

    private func persistBotMessage(_ msg: ChatMessage) async {
        guard let convId = currentConversation?.id else { return }
        let persisted = PersistedChatMessage(
            id: msg.id,
            conversationId: convId,
            content: msg.content,
            isUser: false,
            citations: msg.citations
        )
        try? await conversationRepo.saveMessage(persisted)
    }

    // MARK: - Title Generation

    private func generateTitle(from query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        let truncated = String(trimmed.prefix(37))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        return truncated + "..."
    }

    // MARK: - Extractive Fallback (used when no LLM provider is available)

    private func buildExtractiveAnswer(from results: [SearchResult], query: String = "") -> String {
        let meaningful = ChunkRepository.meaningfulWords(from: query)
        let fallbackWords = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        let baseWords = meaningful.isEmpty ? fallbackWords : meaningful
        let queryWords = Set(baseWords.map { $0.normalizedForSearch })
        let queryWordsOriginal = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        let boilerplate = Set(["contacto", "teléfono", "llamar", "sitio web", "www.", "http", "política", "condiciones", "registro", "raee"])

        var docGroups: [String: (title: String, results: [SearchResult])] = [:]
        for result in results {
            if var group = docGroups[result.documentId] {
                group.results.append(result)
                docGroups[result.documentId] = group
            } else {
                docGroups[result.documentId] = (result.documentTitle, [result])
            }
        }

        var docScores: [(docId: String, title: String, score: Int, results: [SearchResult])] = []
        for (docId, group) in docGroups {
            var totalScore = 0
            for result in group.results {
                let chunkTokens = normalizedTokenSet(result.chunkContent)
                for word in queryWords where chunkTokens.contains(word) { totalScore += 5 }
                for word in queryWordsOriginal where word.first?.isUppercase == true && result.chunkContent.contains(word) { totalScore += 8 }
                totalScore += Int(result.score * 10)
            }
            docScores.append((docId, group.title, totalScore, group.results))
        }
        docScores.sort { $0.score > $1.score }

        guard let bestDoc = docScores.first else { return AppLanguage.current.noInfoFound }

        let secondDocScore = docScores.count > 1 ? docScores[1].score : 0
        let docsToInclude = docScores.prefix(secondDocScore > bestDoc.score / 2 ? 2 : 1)

        var documentAnswers: [(title: String, content: String)] = []
        for doc in docsToInclude {
            let content = buildExtractiveContent(
                from: doc.results,
                queryWords: queryWords,
                queryWordsOriginal: queryWordsOriginal,
                boilerplate: boilerplate
            )
            if !content.isEmpty { documentAnswers.append((doc.title, content)) }
        }

        guard !documentAnswers.isEmpty else { return AppLanguage.current.noInfoFound }

        let fallbackLabel = AppLanguage.current == .spanish ? "tu consulta" : "your query"
        let entityName = queryWordsOriginal.first { $0.first?.isUppercase == true } ?? fallbackLabel
        let lang = AppLanguage.current

        if documentAnswers.count == 1 {
            return "\(lang.extractiveHeader(docTitle: documentAnswers[0].title, entityName: entityName))\n\n\(documentAnswers[0].content)"
        }

        var answer = "\(lang.extractiveMultiHeader(entityName: entityName, count: documentAnswers.count))\n"
        for docAnswer in documentAnswers {
            answer += "\n**\(docAnswer.title)**:\n\(docAnswer.content)\n"
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTokenSet(_ text: String) -> Set<String> {
        Set(
            text
                .normalizedForSearch
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count > 1 }
        )
    }

    private func buildExtractiveContent(
        from results: [SearchResult],
        queryWords: Set<String>,
        queryWordsOriginal: [String],
        boilerplate: Set<String>
    ) -> String {
        let sortedChunks = results.sorted { ($0.chunkIndex ?? 0) < ($1.chunkIndex ?? 0) }

        var seenLines = Set<String>()
        var allLines: [String] = []
        for chunk in sortedChunks {
            let lines = chunk.chunkContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.count > 3 }
            for line in lines {
                let key = line.normalizedForSearch
                if seenLines.insert(key).inserted {
                    allLines.append(line)
                }
            }
        }

        struct ScoredLine {
            let text: String
            let index: Int
            let score: Int
        }

        let scoredLines: [ScoredLine] = allLines.enumerated().map { (idx, line) in
            let lineLower = line.lowercased()
            let lineWords = normalizedTokenSet(line)
            var score = queryWords.intersection(lineWords).count * 3

            for word in queryWordsOriginal where word.first?.isUppercase == true && line.contains(word) { score += 5 }
            if line.contains(":") && line.count > 15 { score += 1 }
            for word in boilerplate where lineLower.contains(word) { score -= 5 }

            return ScoredLine(text: line, index: idx, score: max(score, 0))
        }

        var sections: [(lines: [String], relevance: Int)] = []
        var currentSection: [String] = []
        var currentRelevance = 0
        var gapCount = 0

        for scored in scoredLines {
            if scored.score > 0 {
                currentSection.append(scored.text)
                currentRelevance += scored.score
                gapCount = 0
            } else if !currentSection.isEmpty {
                gapCount += 1
                if gapCount <= 3 {
                    currentSection.append(scored.text)
                } else {
                    sections.append((currentSection, currentRelevance))
                    currentSection = []
                    currentRelevance = 0
                    gapCount = 0
                }
            }
        }
        if !currentSection.isEmpty { sections.append((currentSection, currentRelevance)) }

        sections.sort { $0.relevance > $1.relevance }
        let topSections = sections.prefix(4)
        guard !topSections.isEmpty else { return "" }

        var content = ""
        for (idx, section) in topSections.enumerated() {
            if idx > 0 { content += "\n" }
            let cleanedLines = section.lines.filter { $0.count > 5 }
            if cleanedLines.count <= 3 {
                content += cleanedLines.joined(separator: ". ") + "\n"
            } else {
                for line in cleanedLines {
                    if line.count < 10 && !line.contains(":") { continue }
                    content += "• \(line)\n"
                }
            }
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
