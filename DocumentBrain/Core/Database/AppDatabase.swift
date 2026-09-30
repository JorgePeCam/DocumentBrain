import Foundation
import GRDB

final class AppDatabase {
    nonisolated(unsafe) static let shared = makeShared()

    let dbWriter: any DatabaseWriter

    private init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    private static func makeShared() -> AppDatabase {
        do {
            let fileManager = FileManager.default
            let folderURL = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = folderURL.appendingPathComponent("documentbrain.sqlite")
            let dbPool = try DatabasePool(path: dbURL.path)
            return try AppDatabase(dbWriter: dbPool)
        } catch {
            fatalError("Error iniciando base de datos: \(error)")
        }
    }

    /// Empty in-memory database with the full schema (FTS5 included), for tests and
    /// retrieval evaluation.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(dbWriter: DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createDocuments") { db in
            try db.create(table: "document") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("fileType", .text).notNull().defaults(to: "unknown")
                t.column("fileURL", .text)
                t.column("fileSizeBytes", .integer)
                t.column("thumbnailURL", .text)
                t.column("sourceType", .text).notNull().defaults(to: "files")
                t.column("processingStatus", .text).notNull().defaults(to: "pending")
                t.column("errorMessage", .text)
            }

            try db.create(table: "documentChunk") { t in
                t.column("id", .text).primaryKey()
                t.column("documentId", .text).notNull()
                    .references("document", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("chunkIndex", .integer).notNull()
                t.column("startOffset", .integer)
                t.column("endOffset", .integer)
            }

            try db.create(table: "chunkVector") { t in
                t.column("chunkId", .text).primaryKey()
                    .references("documentChunk", onDelete: .cascade)
                t.column("embedding", .blob).notNull()
            }

            // FTS5 para busqueda por keywords
            try db.execute(sql: """
                CREATE VIRTUAL TABLE documentChunk_fts USING fts5(
                    content,
                    content=documentChunk,
                    content_rowid=rowid
                )
            """)

            // Triggers para mantener FTS sincronizado
            try db.execute(sql: """
                CREATE TRIGGER documentChunk_ai AFTER INSERT ON documentChunk BEGIN
                    INSERT INTO documentChunk_fts(rowid, content)
                    VALUES (new.rowid, new.content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER documentChunk_ad AFTER DELETE ON documentChunk BEGIN
                    INSERT INTO documentChunk_fts(documentChunk_fts, rowid, content)
                    VALUES ('delete', old.rowid, old.content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER documentChunk_au AFTER UPDATE ON documentChunk BEGIN
                    INSERT INTO documentChunk_fts(documentChunk_fts, rowid, content)
                    VALUES ('delete', old.rowid, old.content);
                    INSERT INTO documentChunk_fts(rowid, content)
                    VALUES (new.rowid, new.content);
                END
            """)
        }

        migrator.registerMigration("addFolders") { db in
            // Create folder table
            try db.create(table: "folder") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("parentFolderId", .text)
                    .references("folder", onDelete: .cascade)
                t.column("createdAt", .datetime).notNull()
            }

            // Add folderId to existing documents (nullable — nil means root)
            try db.alter(table: "document") { t in
                t.add(column: "folderId", .text)
                    .references("folder", onDelete: .setNull)
            }
        }

        migrator.registerMigration("addConversations") { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "Nueva conversación")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "chatMessage") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("isUser", .boolean).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("citationsJSON", .text)
            }

            try db.create(index: "chatMessage_conversationId", on: "chatMessage", columns: ["conversationId"])
        }

        // MARK: - iCloud Sync metadata

        migrator.registerMigration("addSyncMetadata") { db in
            // Add sync columns to document
            try db.alter(table: "document") { t in
                t.add(column: "syncChangeTag", .text)
                t.add(column: "needsSyncPush", .boolean).defaults(to: true)
                t.add(column: "modifiedAt", .datetime)
            }

            // Add sync columns to folder
            try db.alter(table: "folder") { t in
                t.add(column: "syncChangeTag", .text)
                t.add(column: "needsSyncPush", .boolean).defaults(to: true)
                t.add(column: "modifiedAt", .datetime)
            }

            // Add sync columns to conversation
            try db.alter(table: "conversation") { t in
                t.add(column: "syncChangeTag", .text)
                t.add(column: "needsSyncPush", .boolean).defaults(to: true)
                t.add(column: "modifiedAt", .datetime)
            }

            // Add sync columns to chatMessage
            try db.alter(table: "chatMessage") { t in
                t.add(column: "syncChangeTag", .text)
                t.add(column: "needsSyncPush", .boolean).defaults(to: true)
                t.add(column: "modifiedAt", .datetime)
            }

            // Pending deletions to push to CloudKit
            try db.create(table: "pendingSyncDeletion") { t in
                t.column("recordName", .text).notNull()
                t.column("recordType", .text).notNull()
                t.primaryKey(["recordName", "recordType"])
            }

            // Persistent state for CKSyncEngine
            try db.create(table: "syncState") { t in
                t.column("key", .text).primaryKey()
                t.column("data", .blob).notNull()
            }

            // Mark all existing records as needing sync push
            let now = Date().timeIntervalSinceReferenceDate
            try db.execute(sql: "UPDATE document SET needsSyncPush = 1, modifiedAt = ?", arguments: [now])
            try db.execute(sql: "UPDATE folder SET needsSyncPush = 1, modifiedAt = ?", arguments: [now])
            try db.execute(sql: "UPDATE conversation SET needsSyncPush = 1, modifiedAt = ?", arguments: [now])
            try db.execute(sql: "UPDATE chatMessage SET needsSyncPush = 1, modifiedAt = ?", arguments: [now])
        }

        // MARK: - Clean up document titles (remove hashes, UUIDs, Base64)

        migrator.registerMigration("cleanupDocumentTitles") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, title FROM document")
            for row in rows {
                let id: String = row["id"]
                let rawTitle: String = row["title"]
                let cleaned = String.cleanedDocumentTitle(rawTitle)
                if cleaned != rawTitle {
                    try db.execute(
                        sql: "UPDATE document SET title = ?, needsSyncPush = 1 WHERE id = ?",
                        arguments: [cleaned, id]
                    )
                }
            }
        }

        // MARK: - Re-clean titles with improved regex (booking codes like J3ZN2TEN6)

        migrator.registerMigration("cleanupDocumentTitlesV2") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, title FROM document")
            for row in rows {
                let id: String = row["id"]
                let rawTitle: String = row["title"]
                let cleaned = String.cleanedDocumentTitle(rawTitle)
                if cleaned != rawTitle {
                    try db.execute(
                        sql: "UPDATE document SET title = ?, needsSyncPush = 1 WHERE id = ?",
                        arguments: [cleaned, id]
                    )
                }
            }
        }

        migrator.registerMigration("addStructuredData") { db in
            try db.alter(table: "document") { t in
                t.add(column: "structuredData", .text)
            }
        }

        migrator.registerMigration("addBarcodes") { db in
            try db.alter(table: "document") { t in
                t.add(column: "barcodes", .text)
            }
        }

        return migrator
    }

}
