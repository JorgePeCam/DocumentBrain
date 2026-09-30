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

    /// Cosine similarity of every ready chunk against the query, keyed by chunk id.
    /// Brute force over all stored vectors — fine for a personal library (tens of
    /// thousands of chunks); vectors are unit-normalised, so this is a dot product.
    private func scoreAllChunks(queryVector: [Float]) async throws -> [String: SearchResult] {
        try await db.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.content, c.documentId, c.chunkIndex, d.title, v.embedding
                FROM documentChunk c
                JOIN chunkVector v ON c.id = v.chunkId
                JOIN document d ON c.documentId = d.id
                WHERE d.processingStatus = 'ready'
            """)

            var results: [String: SearchResult] = [:]
            results.reserveCapacity(rows.count)
            for row in rows {
                let vectorData: Data = row["embedding"]
                let id: String = row["id"]
                results[id] = SearchResult(
                    id: id,
                    chunkContent: row["content"],
                    documentId: row["documentId"],
                    documentTitle: row["title"],
                    score: VectorMath.cosineSimilarity(queryVector, vectorData.toFloatArray()),
                    chunkIndex: row["chunkIndex"]
                )
            }
            return results
        }
    }

    func searchByVector(queryVector: [Float], limit: Int = 5, minScore: Float = 0.25) async throws -> [SearchResult] {
        try await scoreAllChunks(queryVector: queryVector).values
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
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

    /// Capitalised words that are likely proper nouns (names, companies, places, codes).
    /// The first word of each sentence is skipped unless it looks like a code
    /// ("SL2471", "IBI"): in "¿Cuántos días…?" the capital comes from grammar, and
    /// treating it as an entity boosted unrelated chunks that happen to contain the word.
    nonisolated static func entityTerms(from query: String) -> Set<String> {
        var result = Set<String>()
        for sentence in query.components(separatedBy: CharacterSet(charactersIn: ".?!¿¡\n")) {
            let words = sentence
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 }
            for (position, word) in words.enumerated() {
                guard let first = word.first, first.isUppercase else { continue }
                let looksLikeCode = word.contains(where: \.isNumber) || word == word.uppercased()
                if position == 0 && !looksLikeCode { continue }
                result.insert(normalize(word))
            }
        }
        return result
    }

    nonisolated private static func normalize(_ text: String) -> String {
        text.normalizedForSearch
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

    // MARK: - Content Search (library full-text search)

    /// Searches chunk content across all documents.
    /// Returns the best-matching chunk per document, up to `limit` documents.
    func searchContent(query: String, limit: Int = 15) async throws -> [ContentSearchResult] {
        let terms = Self.ftsTerms(from: query)
        guard !terms.isEmpty else { return [] }

        return try await db.dbWriter.read { db in
            let ftsQuery = Self.buildFTSQuery(from: terms, useOR: true)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.documentId, c.content, c.chunkIndex, d.title, d.fileType
                FROM documentChunk_fts fts
                JOIN documentChunk c ON c.rowid = fts.rowid
                JOIN document d ON c.documentId = d.id
                WHERE documentChunk_fts MATCH ?
                  AND d.processingStatus = 'ready'
                ORDER BY rank
                LIMIT 50
            """, arguments: [ftsQuery])

            // Deduplicate: keep only the best (first) chunk per document
            var seenDocuments = Set<String>()
            var results: [ContentSearchResult] = []

            for row in rows {
                let documentId: String = row["documentId"]
                guard !seenDocuments.contains(documentId) else { continue }
                seenDocuments.insert(documentId)

                results.append(ContentSearchResult(
                    documentId: documentId,
                    documentTitle: row["title"],
                    fileType: row["fileType"],
                    chunkContent: row["content"]
                ))

                if results.count >= limit { break }
            }

            return results
        }
    }

    // MARK: - Hybrid Search

    /// Bonus for chunks containing a proper noun or code from the query (names,
    /// companies, flight numbers). Small on purpose: it breaks near-ties in favour of
    /// exact identifiers without overriding the semantic ranking.
    nonisolated static let entityBonus: Float = 0.03

    /// Semantic-first hybrid retrieval.
    ///
    /// Candidates come from vector search (top `limit * 3` by cosine) and from FTS5
    /// (keyword recall for exact terms the vector top-k may miss). Every candidate is
    /// ranked by its *real* cosine similarity — FTS-only hits used to be scored as 0 —
    /// plus `entityBonus` when it contains an entity from the query. Candidates below
    /// the model's `semanticFloor` survive only with a keyword or entity match.
    ///
    /// The previous formula (0.65·semantic + 0.20·lexical coverage + keyword bonus)
    /// compensated for an English-only embedding model. With multilingual e5 the
    /// semantic signal already covers lexical matches, and keyword bonuses let a
    /// Spanish chunk sharing a word ("días") outrank the English document that answers.
    /// Retrieval benchmark (e5-small): evid@5 0.96 → 1.00, MRR 0.89 → 0.97.
    func hybridSearch(queryVector: [Float], queryText: String, limit: Int = 5) async throws -> [SearchResult] {
        let scored = try await scoreAllChunks(queryVector: queryVector)
        let vectorTop = scored.values.sorted { $0.score > $1.score }.prefix(limit * 3)
        let keywordHits = try await searchByKeywords(query: queryText, limit: limit * 3)

        var candidateIDs = Set(vectorTop.map(\.id))
        candidateIDs.formUnion(keywordHits.map(\.id))

        let meaningful = Set(Self.meaningfulWords(from: queryText).map(Self.normalize))
        let entities = Self.entityTerms(from: queryText)

        var merged: [SearchResult] = []
        for id in candidateIDs {
            guard var result = scored[id] else { continue }
            let tokens = Self.tokenSet(from: result.chunkContent)
                .union(Self.tokenSet(from: result.documentTitle))
            let hasKeyword = !meaningful.isDisjoint(with: tokens)
            let hasEntity = !entities.isEmpty && !entities.isDisjoint(with: tokens)

            if result.score < EmbeddingService.semanticFloor && !hasKeyword && !hasEntity { continue }
            if hasEntity { result.score += Self.entityBonus }
            merged.append(result)
        }
        merged.sort { $0.score > $1.score }

        AppLogger.debug("[HybridSearch] candidates=\(candidateIDs.count) (vector=\(vectorTop.count) fts=\(keywordHits.count)) kept=\(merged.count) entities=\(entities)")
        for (i, r) in merged.prefix(5).enumerated() {
            AppLogger.debug("[HybridSearch]   [\(i)] score=\(String(format: "%.3f", r.score)) doc=\"\(r.documentTitle)\" chunk=\(r.chunkIndex ?? -1)")
        }

        return Array(merged.prefix(limit))
    }
}
