import Foundation
import GRDB

struct ChunkRepository {
    private let db: AppDatabase

    nonisolated init(db: AppDatabase = .shared) {
        self.db = db
    }

    // MARK: - Chunks

    func saveChunk(_ chunk: DocumentChunk, embedding: [Float]) async throws {
        try await db.dbWriter.write { db in
            try chunk.save(db)
            let vector = ChunkVector(chunkId: chunk.id, embedding: embedding)
            try vector.save(db)
        }
    }

    func saveChunks(_ chunks: [(chunk: DocumentChunk, embedding: [Float])]) async throws {
        try await db.dbWriter.write { db in
            for item in chunks {
                try item.chunk.save(db)
                let vector = ChunkVector(chunkId: item.chunk.id, embedding: item.embedding)
                try vector.save(db)
            }
        }
    }

    func deleteChunks(forDocumentId documentId: String) async throws {
        _ = try await db.dbWriter.write { db in
            try DocumentChunk
                .filter(Column("documentId") == documentId)
                .deleteAll(db)
        }
    }

    func fetchChunks(forDocumentId documentId: String) async throws -> [DocumentChunk] {
        try await db.dbWriter.read { db in
            try DocumentChunk
                .filter(Column("documentId") == documentId)
                .order(Column("chunkIndex"))
                .fetchAll(db)
        }
    }

    // MARK: - Vector Search

    func searchByVector(queryVector: [Float], limit: Int = 5, minScore: Float = 0.25) async throws -> [SearchResult] {
        try await db.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.content, c.documentId, c.chunkIndex, d.title, v.embedding
                FROM documentChunk c
                JOIN chunkVector v ON c.id = v.chunkId
                JOIN document d ON c.documentId = d.id
                WHERE d.processingStatus = 'ready'
            """)

            var results: [SearchResult] = []
            for row in rows {
                let vectorData: Data = row["embedding"]
                let vector = vectorData.toFloatArray()
                let score = VectorMath.cosineSimilarity(queryVector, vector)

                if score >= minScore {
                    results.append(SearchResult(
                        id: row["id"],
                        chunkContent: row["content"],
                        documentId: row["documentId"],
                        documentTitle: row["title"],
                        score: score,
                        chunkIndex: row["chunkIndex"]
                    ))
                }
            }

            return results
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0 }
        }
    }

    // MARK: - FTS Search

    func searchByKeywords(query: String, limit: Int = 5) async throws -> [SearchResult] {
        let terms = Self.ftsTerms(from: query)
        guard !terms.isEmpty else { return [] }

        return try await db.dbWriter.read { db in
            let strictQuery = Self.buildFTSQuery(from: terms, useOR: false)
            var rows = try Self.executeFTSQuery(strictQuery, limit: limit, in: db)

            // If strict matching is too restrictive, fallback to OR for recall.
            if rows.isEmpty && terms.count > 1 {
                let relaxedQuery = Self.buildFTSQuery(from: terms, useOR: true)
                rows = try Self.executeFTSQuery(relaxedQuery, limit: limit, in: db)
            }

            return rows.map { row in
                SearchResult(
                    id: row["id"],
                    chunkContent: row["content"],
                    documentId: row["documentId"],
                    documentTitle: row["title"],
                    score: 1.0,
                    chunkIndex: row["chunkIndex"]
                )
            }
        }
    }

    /// Spanish + English stopwords to exclude from keyword searches
    nonisolated private static let stopwords: Set<String> = [
        // Spanish
        "que", "qué", "de", "del", "la", "el", "en", "es", "lo", "los", "las",
        "un", "una", "uno", "por", "con", "para", "al", "se", "su", "sus",
        "mi", "mis", "tu", "tus", "nos", "les", "como", "pero", "mas", "más",
        "ya", "este", "esta", "ese", "esa", "hay", "fue", "son", "ser", "sin",
        "sobre", "entre", "cuando", "muy", "puede", "donde", "tiene", "sido",
        "desde", "está", "están", "era", "han", "todo", "otra", "otro",
        "cual", "cuál", "aquí", "también", "cada", "nos", "porque",
        // English
        "the", "is", "at", "which", "on", "and", "or", "in", "to", "of",
        "for", "with", "was", "are", "has", "have", "had", "not", "but",
        "from", "this", "that", "these", "those", "what", "when", "where",
        "how", "who", "why", "my", "your", "his", "her", "its", "our",
        "do", "does", "did", "will", "would", "could", "should", "can",
        "about", "been", "being", "were", "they", "them", "their",
        "all", "any", "some", "much", "many", "more", "most", "very"
    ]

    /// Converts user text into a valid FTS5 query.
    /// Removes punctuation, stopwords, and joins meaningful words with OR.
    nonisolated static func sanitizeFTSQuery(_ query: String) -> String {
        let words = ftsTerms(from: query)

        guard !words.isEmpty else { return "" }

        // Keep legacy behavior for callers that still use this utility directly.
        return words.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Returns meaningful words from a query (excluding stopwords)
    nonisolated static func meaningfulWords(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 }
            .filter { !stopwords.contains($0.lowercased()) }
    }

    nonisolated private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func tokenSet(from text: String) -> Set<String> {
        Set(
            normalize(text)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count > 1 }
        )
    }

    nonisolated private static func ftsTerms(from query: String) -> [String] {
        query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 1 }
            .filter { !stopwords.contains($0.lowercased()) }
    }

    nonisolated private static func buildFTSQuery(from terms: [String], useOR: Bool) -> String {
        guard !terms.isEmpty else { return "" }
        let separator = useOR ? " OR " : " AND "
        return terms.map { "\"\($0)\"" }.joined(separator: separator)
    }

    nonisolated private static func executeFTSQuery(_ query: String, limit: Int, in db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT c.id, c.content, c.documentId, c.chunkIndex, d.title,
                   rank AS ftsScore
            FROM documentChunk_fts fts
            JOIN documentChunk c ON c.rowid = fts.rowid
            JOIN document d ON c.documentId = d.id
            WHERE documentChunk_fts MATCH ?
            AND d.processingStatus = 'ready'
            ORDER BY rank
            LIMIT ?
        """, arguments: [query, limit])
    }

    // MARK: - Hybrid Search

    func hybridSearch(
        queryVector: [Float],
        queryText: String,
        limit: Int = 5,
        minScore: Float = 0.3
    ) async throws -> [SearchResult] {
        // Get vector results (lower threshold to let lexical matching boost good results)
        let vectorResults = try await searchByVector(
            queryVector: queryVector,
            limit: limit * 3,
            minScore: 0.15
        )

        // Get keyword results (already uses stopword-filtered query)
        let ftsResults = try await searchByKeywords(query: queryText, limit: limit * 3)

        AppLogger.debug("[HybridSearch] vector=\(vectorResults.count) fts=\(ftsResults.count) query=\"\(queryText)\"")

        // Extract meaningful query words (no stopwords)
        let meaningfulWords = Self.meaningfulWords(from: queryText)
        let normalizedMeaningful = Set(meaningfulWords.map(Self.normalize))

        // Detect entity terms: words that start with an uppercase letter in the original
        // query (likely proper nouns: names, companies, places, flight numbers, etc.).
        // Simpler and more robust than a manual intent-verb exclusion list.
        let entityTerms = Set(
            queryText
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { word in
                    guard word.count > 1, let first = word.first else { return false }
                    return first.isUppercase
                }
                .map(Self.normalize)
        )

        // Merge: combine scores for chunks that appear in both
        var scoreMap: [String: (result: SearchResult, vectorScore: Float, ftsHit: Bool)] = [:]

        for result in vectorResults {
            scoreMap[result.id] = (result, result.score, false)
        }

        for result in ftsResults {
            if var existing = scoreMap[result.id] {
                existing.ftsHit = true
                scoreMap[result.id] = existing
            } else {
                scoreMap[result.id] = (result, 0, true)
            }
        }

        // Calculate final scores
        var merged: [SearchResult] = scoreMap.values.compactMap { entry in
            let semanticScore = entry.vectorScore
            let chunkTokens = Self.tokenSet(from: entry.result.chunkContent)
            let titleTokens = Self.tokenSet(from: entry.result.documentTitle)
            let searchableTokens = chunkTokens.union(titleTokens)
            let lexicalMatches = normalizedMeaningful.intersection(searchableTokens)
            let lexicalCoverage = normalizedMeaningful.isEmpty
                ? 0.0
                : Float(lexicalMatches.count) / Float(normalizedMeaningful.count)

            // Check if any proper noun from the query appears in this chunk
            let hasEntityMatch = !entityTerms.isEmpty && !entityTerms.isDisjoint(with: searchableTokens)

            // Reject pure semantic matches that contain no query keywords and no entity,
            // unless semantic similarity is strong enough on its own.
            // Threshold lowered from 0.72 → 0.50: Q&A-optimized embeddings are typically
            // in the 0.4-0.7 range so 0.72 was discarding many valid results.
            if !normalizedMeaningful.isEmpty && lexicalMatches.isEmpty && !hasEntityMatch && semanticScore < 0.50 {
                return nil
            }

            // Keyword bonus: small boost for FTS-confirmed hits
            let keywordBonus: Float
            if entry.ftsHit && !lexicalMatches.isEmpty {
                keywordBonus = 0.05 + lexicalCoverage * 0.10
            } else if !lexicalMatches.isEmpty {
                keywordBonus = lexicalCoverage * 0.05
            } else {
                keywordBonus = 0.0
            }

            // Entity bonus: reduced 0.25 → 0.10 to avoid FTS-only results with no
            // semantic backing scoring too high.
            let entityBonus: Float = hasEntityMatch ? 0.10 : 0.0

            // Score formula: semantic is now the dominant signal (0.65 vs 0.45 before).
            // Lexical coverage acts as a tiebreaker / precision signal.
            let finalScore = 0.65 * semanticScore + 0.20 * lexicalCoverage + keywordBonus + entityBonus

            guard finalScore >= minScore else { return nil }

            return SearchResult(
                id: entry.result.id,
                chunkContent: entry.result.chunkContent,
                documentId: entry.result.documentId,
                documentTitle: entry.result.documentTitle,
                score: finalScore,
                chunkIndex: entry.result.chunkIndex
            )
        }

        merged.sort { $0.score > $1.score }

        AppLogger.debug("[HybridSearch] entityTerms=\(entityTerms) meaningful=\(normalizedMeaningful)")
        AppLogger.debug("[HybridSearch] merged=\(merged.count) results (limit=\(limit))")
        for (i, r) in merged.prefix(5).enumerated() {
            AppLogger.debug("[HybridSearch]   [\(i)] score=\(String(format: "%.3f", r.score)) doc=\"\(r.documentTitle)\" chunk=\(r.chunkIndex ?? -1)")
        }

        return Array(merged.prefix(limit))
    }
}
