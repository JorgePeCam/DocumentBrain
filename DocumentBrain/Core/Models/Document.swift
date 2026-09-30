import Foundation
import GRDB

enum FileType: String, Codable, CaseIterable {
    case pdf
    case image
    case docx
    case xlsx
    case text
    case email
    case unknown

    var displayName: String {
        let lang = AppLanguage.current
        switch self {
        case .pdf: return lang.fileTypePDF
        case .image: return lang.fileTypeImage
        case .docx: return lang.fileTypeWord
        case .xlsx: return lang.fileTypeExcel
        case .text: return lang.fileTypeText
        case .email: return lang.fileTypeEmail
        case .unknown: return lang.fileTypeOther
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .docx: return "doc.text"
        case .xlsx: return "tablecells"
        case .text: return "doc.plaintext"
        case .email: return "envelope"
        case .unknown: return "doc"
        }
    }

    /// Detects the file type from a URL's path extension.
    static func detect(from url: URL) -> FileType {
        switch url.pathExtension.lowercased() {
        case "pdf":                             return .pdf
        case "jpg", "jpeg", "png", "heic",
             "heif", "tiff", "bmp", "webp":    return .image
        case "docx":                            return .docx
        case "xlsx":                            return .xlsx
        case "txt", "md", "csv", "rtf":        return .text
        case "eml":                             return .email
        default:                               return .unknown
        }
    }
}

enum ProcessingStatus: String, Codable {
    case pending
    case extracting
    case chunking
    case embedding
    case ready
    case error

    /// True while the document is going through the ingestion pipeline.
    var isInProgress: Bool {
        switch self {
        case .pending, .extracting, .chunking, .embedding: return true
        case .ready, .error: return false
        }
    }
}

enum SourceType: String, Codable {
    case files
    case camera
    case photos
    case manual
}

struct Document: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "document"

    var id: String
    var title: String
    var content: String
    var createdAt: Date
    var fileType: String
    var fileURL: String?
    var fileSizeBytes: Int64?
    var thumbnailURL: String?
    var sourceType: String
    var processingStatus: String
    var errorMessage: String?
    var folderId: String?

    // Sync metadata
    var syncChangeTag: String?
    var needsSyncPush: Bool
    var modifiedAt: Date?

    // Structured metadata extracted by LLM (JSON-encoded StructuredDocumentData)
    var structuredData: String?

    // Barcode/QR payloads detected in the document (JSON-encoded [String])
    var barcodes: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        content: String = "",
        createdAt: Date = Date(),
        fileType: FileType = .unknown,
        fileURL: String? = nil,
        fileSizeBytes: Int64? = nil,
        thumbnailURL: String? = nil,
        sourceType: SourceType = .files,
        processingStatus: ProcessingStatus = .pending,
        errorMessage: String? = nil,
        folderId: String? = nil,
        syncChangeTag: String? = nil,
        needsSyncPush: Bool = true,
        modifiedAt: Date? = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.fileType = fileType.rawValue
        self.fileURL = fileURL
        self.fileSizeBytes = fileSizeBytes
        self.thumbnailURL = thumbnailURL
        self.sourceType = sourceType.rawValue
        self.processingStatus = processingStatus.rawValue
        self.errorMessage = errorMessage
        self.folderId = folderId
        self.syncChangeTag = syncChangeTag
        self.needsSyncPush = needsSyncPush
        self.modifiedAt = modifiedAt
    }

    var fileTypeEnum: FileType {
        FileType(rawValue: fileType) ?? .unknown
    }

    var processingStatusEnum: ProcessingStatus {
        ProcessingStatus(rawValue: processingStatus) ?? .pending
    }

    var sourceTypeEnum: SourceType {
        SourceType(rawValue: sourceType) ?? .files
    }

    var isReady: Bool {
        processingStatusEnum == .ready
    }

    var barcodesDecoded: [String] {
        guard let json = barcodes,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }

    var structuredDataDecoded: StructuredDocumentData? {
        guard let json = structuredData,
              let data = json.data(using: .utf8) else { return nil }
        // Sanitised on read too, so data stored before sanitising existed (e.g. a CV
        // with "N/A" flight fields) is cleaned without re-extraction. An empty "{}"
        // marker (nothing to extract) decodes to nil.
        return (try? JSONDecoder().decode(StructuredDocumentData.self, from: data))?.sanitized()
    }

    var absoluteFileURL: URL? {
        guard let fileURL else { return nil }
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent(fileURL)
    }

    var absoluteThumbnailURL: URL? {
        guard let thumbnailURL else { return nil }
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent(thumbnailURL)
    }
}
