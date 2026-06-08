import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySortOption: String, CaseIterable {
    case newest, oldest, nameAZ, nameZA, largest

    var label: String {
        let lang = AppLanguage.current
        switch self {
        case .newest: return lang.sortNewest
        case .oldest: return lang.sortOldest
        case .nameAZ: return lang.sortNameAZ
        case .nameZA: return lang.sortNameZA
        case .largest: return lang.sortLargest
        }
    }

    var icon: String {
        switch self {
        case .newest: return "arrow.down.circle"
        case .oldest: return "arrow.up.circle"
        case .nameAZ: return "textformat.abc"
        case .nameZA: return "textformat.abc"
        case .largest: return "arrow.up.right.square"
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var documents: [Document] = []
    @Published var folders: [Folder] = []
    @Published var showImporter = false
    @Published var showCamera = false
    @Published var filterType: FileType?
    @Published var sortOption: LibrarySortOption = .newest
    @Published var userErrorMessage: String?

    // Content search
    @Published var contentSearchResults: [ContentSearchResult] = []
    @Published var isSearchingContent = false

    // Folder navigation
    @Published var currentFolderId: String?
    @Published var folderPath: [Folder] = []
    @Published var documentCounts: [String: Int] = [:]
    @Published var allFolders: [Folder] = []

    private let repository = DocumentRepository()
    private let folderRepository = FolderRepository()
    private let chunkRepository = ChunkRepository()
    private var searchTask: Task<Void, Never>?

    let allowedContentTypes: [UTType] = [
        .pdf, .image, .plainText,
        UTType("org.openxmlformats.wordprocessingml.document") ?? .data, // .docx
        UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data, // .xlsx
    ]

    var filteredDocuments: [Document] {
        var docs = documents
        if let filterType {
            docs = docs.filter { $0.fileType == filterType.rawValue }
        }
        return sortDocuments(docs)
    }

    private func sortDocuments(_ docs: [Document]) -> [Document] {
        switch sortOption {
        case .newest: return docs.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return docs.sorted { $0.createdAt < $1.createdAt }
        case .nameAZ: return docs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .nameZA: return docs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .largest: return docs.sorted { ($0.fileSizeBytes ?? 0) > ($1.fileSizeBytes ?? 0) }
        }
    }

    private var processingDocuments: [Document] {
        documents.filter { $0.processingStatusEnum.isInProgress }
    }

    var hasProcessingDocuments: Bool { !processingDocuments.isEmpty }
    var processingCount: Int { processingDocuments.count }

    var isInFolder: Bool {
        currentFolderId != nil
    }

    var currentFolderName: String {
        folderPath.last?.name ?? AppLanguage.current.libraryTitle
    }

    func loadDocuments() async {
        do {
            // Load documents for current folder
            documents = try await repository.fetchByFolder(currentFolderId)

            // Load subfolders
            if let folderId = currentFolderId {
                folders = try await folderRepository.fetchChildren(of: folderId)
            } else {
                folders = try await folderRepository.fetchRootFolders()
            }

            // Load document counts for visible folders
            var counts: [String: Int] = [:]
            for folder in folders {
                counts[folder.id] = try await folderRepository.documentCount(folderId: folder.id)
            }
            documentCounts = counts

            // Load all folders for the move picker
            allFolders = try await folderRepository.fetchAll()
        } catch {
            AppLogger.error("Error cargando documentos: \(error.localizedDescription)")
            userErrorMessage = AppLanguage.current.errorLoadDocuments
        }
    }

    // MARK: - Folder Navigation

    func navigateToFolder(_ folder: Folder) {
        folderPath.append(folder)
        currentFolderId = folder.id
        Task { await loadDocuments() }
    }

    func navigateBack() {
        guard !folderPath.isEmpty else { return }
        folderPath.removeLast()
        currentFolderId = folderPath.last?.id
        Task { await loadDocuments() }
    }

    func navigateToRoot() {
        folderPath = []
        currentFolderId = nil
        Task { await loadDocuments() }
    }

    func navigateToPath(_ path: [Folder]) {
        folderPath = path
        currentFolderId = path.last?.id
        Task { await loadDocuments() }
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                let folder = Folder(name: trimmed, parentFolderId: currentFolderId)
                try await folderRepository.save(folder)
                await loadDocuments()
            } catch {
                AppLogger.error("Error creando carpeta: \(error.localizedDescription)")
                userErrorMessage = AppLanguage.current.errorCreateFolder
            }
        }
    }

    func renameFolder(_ folder: Folder, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                var updated = folder
                updated.name = trimmed
                try await folderRepository.update(updated)
                await loadDocuments()
            } catch {
                AppLogger.error("Error renombrando carpeta: \(error.localizedDescription)")
                userErrorMessage = AppLanguage.current.errorRenameFolder
            }
        }
    }

    func deleteFolder(id: String) {
        Task {
            do {
                try await folderRepository.delete(id: id)
                await loadDocuments()
            } catch {
                AppLogger.error("Error eliminando carpeta: \(error.localizedDescription)")
                userErrorMessage = AppLanguage.current.errorDeleteFolder
            }
        }
    }

    // MARK: - Move Documents

    func moveDocument(_ documentId: String, toFolder folderId: String?) {
        Task {
            do {
                try await repository.moveToFolder(documentId: documentId, folderId: folderId)
                await loadDocuments()
            } catch {
                AppLogger.error("Error moviendo documento: \(error.localizedDescription)")
                userErrorMessage = AppLanguage.current.errorMoveDocument
            }
        }
    }

    // MARK: - Content Search

    func searchContent(query: String) {
        searchTask?.cancel()

        guard query.count >= 2 else {
            contentSearchResults = []
            isSearchingContent = false
            return
        }

        isSearchingContent = true
        searchTask = Task {
            // 300ms debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let results = try await chunkRepository.searchContent(query: query)
                if !Task.isCancelled {
                    contentSearchResults = results
                    isSearchingContent = false
                }
            } catch {
                if !Task.isCancelled {
                    contentSearchResults = []
                    isSearchingContent = false
                }
            }
        }
    }

    // MARK: - Retry

    func retryDocument(id: String) {
        Task {
            try? await repository.updateStatus(id: id, status: .pending)
            await loadDocuments()
            await DocumentProcessor.shared.process(documentId: id)
            await loadDocuments()
        }
    }

    // MARK: - Document CRUD

    func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                Task { await importFile(from: url) }
            }
        case .failure(let error):
            AppLogger.error("Error importando: \(error.localizedDescription)")
            userErrorMessage = AppLanguage.current.errorImportFile
        }
    }

    func handleCameraCapture(image: UIImage) {
        Task {
            await importCameraImage(image)
        }
    }

    func deleteDocument(id: String) {
        Task {
            do {
                let doc = documents.first(where: { $0.id == id })
                try await repository.delete(id: id)
                if let doc {
                    repository.deleteFile(for: doc)
                }
                documents.removeAll { $0.id == id }
            } catch {
                AppLogger.error("Error eliminando: \(error.localizedDescription)")
                userErrorMessage = AppLanguage.current.errorDeleteDocument
            }
        }
    }

    // MARK: - Import Logic

    private func importFile(from url: URL) async {
        let fileType = FileType.detect(from: url)
        let title = url.deletingPathExtension().lastPathComponent

        do {
            let (relativePath, fileSize) = try repository.importFile(from: url, fileType: fileType)
            let cleanTitle = String.cleanedDocumentTitle(title)

            let document = Document(
                title: cleanTitle,
                fileType: fileType,
                fileURL: relativePath,
                fileSizeBytes: fileSize,
                sourceType: .files,
                processingStatus: .pending,
                folderId: currentFolderId
            )

            try await repository.save(document)
            documents.insert(document, at: 0)

            Task { [weak self] in
                await DocumentProcessor.shared.process(documentId: document.id)
                await self?.refreshDocument(id: document.id)
            }
        } catch {
            AppLogger.error("Error importando archivo: \(error.localizedDescription)")
            userErrorMessage = AppLanguage.current.errorSaveFile
        }
    }

    private func importCameraImage(_ image: UIImage) async {
        let fileManager = FileManager.default
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileName = "\(UUID().uuidString).jpg"
        let relativePath = "files/\(fileName)"
        let destinationURL = documentsDir.appendingPathComponent(relativePath)

        guard let data = image.jpegData(compressionQuality: 0.8) else { return }

        do {
            try data.write(to: destinationURL)

            let document = Document(
                title: AppLanguage.current.libraryPhotoTitle(date: Date().formatted(date: .abbreviated, time: .shortened)),
                fileType: .image,
                fileURL: relativePath,
                fileSizeBytes: Int64(data.count),
                sourceType: .camera,
                processingStatus: .pending,
                folderId: currentFolderId
            )

            try await repository.save(document)
            documents.insert(document, at: 0)

            Task { [weak self] in
                await DocumentProcessor.shared.process(documentId: document.id)
                await self?.refreshDocument(id: document.id)
            }
        } catch {
            AppLogger.error("Error guardando foto: \(error.localizedDescription)")
            userErrorMessage = AppLanguage.current.errorSavePhoto
        }
    }

    private func refreshDocument(id: String) async {
        if let updated = try? await repository.fetchOne(id: id),
           let index = documents.firstIndex(where: { $0.id == id }) {
            documents[index] = updated
        }
    }
}
