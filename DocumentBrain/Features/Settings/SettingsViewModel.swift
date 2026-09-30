import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var documentCount = 0
    @Published var storageUsed = "..."
    @Published var showDeleteConfirmation = false
    @Published var userErrorMessage: String?
    @Published var selectedLanguage: AppLanguage = AppLanguage.current
    private let repository = DocumentRepository()

    var lang: AppLanguage { selectedLanguage }

    var embeddingModelStatus: String {
        EmbeddingService.shared != nil ? "multilingual-e5-small (activo)" : "No disponible"
    }

    var isAIAvailable: Bool {
        QAService.shared.hasAnyProvider
    }

    var isOnDeviceAIActive: Bool {
        QAService.shared.activeProviderKind == .onDevice
    }

    var activeProviderName: String {
        QAService.shared.activeProviderName
    }

    var aiStatusText: String {
        switch QAService.shared.activeProviderKind {
        case .onDevice: return lang.aiActiveOnDevice
        case .cloud:    return lang.aiActiveCloud
        case nil:       return lang.aiBasicMode
        }
    }

    var aiFooterText: String {
        switch QAService.shared.activeProviderKind {
        case .onDevice: return lang.aiFooterOnDevice
        case .cloud:    return lang.aiFooterCloud
        case nil:       return lang.aiFooterBasic
        }
    }

    func changeLanguage(to language: AppLanguage) {
        selectedLanguage = language
        AppLanguage.current = language
    }

    func loadStats() async {
        do {
            let docs = try await repository.fetchAll()
            documentCount = docs.count

            let totalBytes = docs.compactMap(\.fileSizeBytes).reduce(0, +)
            storageUsed = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        } catch {
            AppLogger.error("Error cargando estadisticas: \(error.localizedDescription)")
            userErrorMessage = lang.errorLoadStats
        }
    }

    func reindexAll() {
        Task {
            do {
                let docs = try await repository.fetchAll()
                guard !docs.isEmpty else { return }
                await Self.reindexDocuments(docs)
                await loadStats()
            } catch {
                AppState.shared.isReindexing = false
                AppLogger.error("Error reindexando documentos: \(error.localizedDescription)")
                userErrorMessage = lang.errorReindex
            }
        }
    }

    /// Reprocesses all documents with a progress overlay. Called from startup (model change)
    /// and from the Settings reindex action.
    static func reindexAllDocuments() async {
        let repo = DocumentRepository()
        guard let docs = try? await repo.fetchAll(), !docs.isEmpty else { return }
        await reindexDocuments(docs)
    }

    private static func reindexDocuments(_ docs: [Document]) async {
        let state = AppState.shared
        state.reindexTotal = docs.count
        state.reindexCompleted = 0
        state.isReindexing = true

        for doc in docs {
            await DocumentProcessor.shared.reprocess(documentId: doc.id)
            state.reindexCompleted += 1
        }

        state.isReindexing = false
        state.reindexTotal = 0
        state.reindexCompleted = 0
    }

    func deleteAllData() {
        Task {
            do {
                // Delete all documents and files
                let docs = try await repository.fetchAll()
                for doc in docs {
                    try await repository.delete(id: doc.id)
                    repository.deleteFile(for: doc)
                }

                // Delete all conversations
                let conversationRepo = ConversationRepository()
                try await conversationRepo.deleteAllConversations()

                // Clear thumbnail cache
                await ThumbnailService.shared.clearCache()

                documentCount = 0
                storageUsed = "0 bytes"

                // Notify other views to reset
                NotificationCenter.default.post(name: .allDataDidDelete, object: nil)
            } catch {
                AppLogger.error("Error borrando datos: \(error.localizedDescription)")
                userErrorMessage = lang.errorDeleteAll
            }
        }
    }
}
