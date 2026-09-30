import Foundation

/// Supported app languages. Persisted in UserDefaults.
enum AppLanguage: String, CaseIterable, Identifiable {
    case spanish = "es"
    case english = "en"

    var id: String { rawValue }

    /// Display name shown in the language selector (always in its own language)
    var displayName: String {
        switch self {
        case .spanish: return "Español"
        case .english: return "English"
        }
    }

    /// Flag emoji for visual identification
    var flag: String {
        switch self {
        case .spanish: return "🇪🇸"
        case .english: return "🇬🇧"
        }
    }

    // MARK: - Persistence

    /// Current app language. Defaults to Spanish.
    static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.appLanguage),
                  let lang = AppLanguage(rawValue: raw) else {
                return .spanish
            }
            return lang
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.appLanguage)
        }
    }

    // MARK: - LLM Prompt Strings

    /// System prompt for the LLM (Gemini / Apple Intelligence)
    var systemPrompt: String {
        switch self {
        case .spanish:
            return """
            Eres un asistente personal que responde preguntas basándose ÚNICAMENTE en los documentos del usuario.

            REGLAS:
            - Responde SOLO con información que aparezca en los fragmentos proporcionados.
            - Si los fragmentos NO contienen información relevante, responde EXACTAMENTE: "\(noInfoFound)"
            - NO inventes ni supongas información que no esté en los fragmentos.
            - Responde en español.
            - Cita el nombre del documento cuando sea relevante.
            - Usa el historial de conversación para entender preguntas de seguimiento (por ejemplo, "¿y el precio?" se refiere al mismo tema de la pregunta anterior).
            - Si los fragmentos contienen varios elementos distintos que responden a la pregunta (por ejemplo, dos vuelos, dos facturas), NO muestres todos los detalles. En su lugar, lista brevemente las opciones (una línea cada una) y pregunta: "Encontré varias opciones, ¿sobre cuál quieres información?" Espera la respuesta del usuario antes de dar los detalles completos.
            - Solo da detalles completos de un único elemento a la vez, salvo que el usuario pida explícitamente compararlos o verlos todos.

            ESTILO DE RESPUESTA:
            - Desarrolla la respuesta con detalle: incluye todos los datos relevantes (fechas, nombres, cantidades, etc.)
            - Organiza la información de forma clara usando párrafos, listas o secciones según convenga.
            - Si hay información distribuida en varios fragmentos del mismo documento, sintetízala en una respuesta coherente.
            - No te limites a una línea; elabora una respuesta completa.
            """
        case .english:
            return """
            You are a personal assistant that answers questions based ONLY on the user's documents.

            RULES:
            - Answer ONLY with information that appears in the provided snippets.
            - If the snippets do NOT contain relevant information, reply EXACTLY: "\(noInfoFound)"
            - NEVER invent or guess information not in the snippets.
            - Reply in English.
            - Cite the document name when relevant.
            - Use the conversation history to understand follow-up questions (e.g., "and the price?" refers to the same topic as the previous question).
            - If the snippets contain multiple distinct items that answer the question (e.g., two flights, two invoices), do NOT show all details. Instead, briefly list the options (one line each) and ask: "I found several options, which one would you like details about?" Wait for the user's response before providing full details.
            - Only give full details for one item at a time, unless the user explicitly asks to compare or see all of them.

            RESPONSE STYLE:
            - Provide detailed, thorough answers: include all relevant data (dates, names, amounts, etc.)
            - Organize information clearly using paragraphs, bullet points, or sections as appropriate.
            - If information is spread across multiple snippets from the same document, synthesize it into one coherent answer.
            - Don't limit yourself to one line; elaborate fully.
            """
        }
    }

    /// Prompt wrapper for document snippets
    var snippetsHeader: String {
        switch self {
        case .spanish: return "FRAGMENTOS DE DOCUMENTOS:"
        case .english: return "DOCUMENT SNIPPETS:"
        }
    }

    /// Label for each snippet
    func snippetLabel(title: String, index: Int) -> String {
        switch self {
        case .spanish: return "--- Documento: \(title) (fragmento \(index)) ---"
        case .english: return "--- Document: \(title) (snippet \(index)) ---"
        }
    }

    var questionLabel: String {
        switch self {
        case .spanish: return "PREGUNTA"
        case .english: return "QUESTION"
        }
    }

    // MARK: - UI Strings

    var noInfoFound: String {
        switch self {
        case .spanish: return "No encontré información sobre esto en tus documentos."
        case .english: return "I didn't find information about this in your documents."
        }
    }

    var noRelevantResults: String {
        switch self {
        case .spanish: return "No encontré información relevante en tus documentos. Prueba con otra pregunta o importa más archivos."
        case .english: return "I didn't find relevant information in your documents. Try another question or import more files."
        }
    }

    var embeddingsUnavailable: String {
        switch self {
        case .spanish: return "El modelo de embeddings no está disponible. Asegúrate de que E5Small.mlpackage y e5_vocab.tsv están incluidos en el proyecto (ver convert_model.py)."
        case .english: return "The embedding model is not available. Make sure E5Small.mlpackage and e5_vocab.tsv are included in the project (see convert_model.py)."
        }
    }

    // Settings
    var settingsTitle: String {
        switch self { case .spanish: return "Ajustes"; case .english: return "Settings" }
    }
    var aiSectionTitle: String {
        switch self { case .spanish: return "Inteligencia Artificial"; case .english: return "Artificial Intelligence" }
    }
    var storageSectionTitle: String {
        switch self { case .spanish: return "Almacenamiento"; case .english: return "Storage" }
    }
    var actionsSectionTitle: String {
        switch self { case .spanish: return "Acciones"; case .english: return "Actions" }
    }
    var aboutSectionTitle: String {
        switch self { case .spanish: return "Acerca de"; case .english: return "About" }
    }
    var languageSectionTitle: String {
        switch self { case .spanish: return "Idioma"; case .english: return "Language" }
    }
    var documentsLabel: String {
        switch self { case .spanish: return "Documentos"; case .english: return "Documents" }
    }
    var storageUsedLabel: String {
        switch self { case .spanish: return "Espacio usado"; case .english: return "Storage used" }
    }
    var reindexLabel: String {
        switch self { case .spanish: return "Reindexar documentos"; case .english: return "Reindex documents" }
    }
    var deleteAllLabel: String {
        switch self { case .spanish: return "Borrar todos los datos"; case .english: return "Delete all data" }
    }
    var deleteAllTitle: String {
        switch self { case .spanish: return "Borrar todos los datos"; case .english: return "Delete all data" }
    }
    var deleteAllMessage: String {
        switch self {
        case .spanish: return "Se eliminarán todos los documentos y datos. Esta acción no se puede deshacer."
        case .english: return "All documents and data will be deleted. This action cannot be undone."
        }
    }
    var cancelButton: String {
        switch self { case .spanish: return "Cancelar"; case .english: return "Cancel" }
    }
    var deleteButton: String {
        switch self { case .spanish: return "Borrar todo"; case .english: return "Delete all" }
    }
    var versionLabel: String {
        switch self { case .spanish: return "Versión"; case .english: return "Version" }
    }
    var tagline: String {
        switch self { case .spanish: return "DocumentBrain — Tu segundo cerebro digital"; case .english: return "DocumentBrain — Your digital second brain" }
    }

    // AI status
    var aiActiveOnDevice: String {
        switch self { case .spanish: return "Activo — en tu dispositivo"; case .english: return "Active — on your device" }
    }
    var aiActiveCloud: String {
        switch self { case .spanish: return "Activo — asistente inteligente"; case .english: return "Active — smart assistant" }
    }
    var aiBasicMode: String {
        switch self { case .spanish: return "Modo básico"; case .english: return "Basic mode" }
    }
    var aiFooterOnDevice: String {
        switch self {
        case .spanish: return "Las respuestas se procesan en tu dispositivo. Privado y sin coste."
        case .english: return "Responses are processed on your device. Private and free."
        }
    }
    var aiFooterCloud: String {
        switch self {
        case .spanish: return "Las respuestas se generan con inteligencia artificial. Requiere conexión a internet."
        case .english: return "Responses are generated with AI. Requires internet connection."
        }
    }
    var aiFooterBasic: String {
        switch self {
        case .spanish: return "Las respuestas se extraen directamente de tus documentos."
        case .english: return "Responses are extracted directly from your documents."
        }
    }

    // iCloud
    var iCloudTitle: String {
        switch self { case .spanish: return "Sincronización iCloud"; case .english: return "iCloud Sync" }
    }
    var iCloudSyncing: String {
        switch self { case .spanish: return "Sincronizando..."; case .english: return "Syncing..." }
    }
    var iCloudActive: String {
        switch self { case .spanish: return "Activa"; case .english: return "Active" }
    }
    var iCloudUnavailable: String {
        switch self { case .spanish: return "No disponible"; case .english: return "Not available" }
    }
    var iCloudFooter: String {
        switch self {
        case .spanish: return "Documentos, carpetas y conversaciones se sincronizan automáticamente entre tus dispositivos."
        case .english: return "Documents, folders, and conversations sync automatically across your devices."
        }
    }

    // Chat
    var chatPlaceholder: String {
        switch self { case .spanish: return "Pregunta sobre tus documentos..."; case .english: return "Ask about your documents..." }
    }
    var chatEmptyTitle: String {
        switch self { case .spanish: return "Tu segundo cerebro"; case .english: return "Your second brain" }
    }
    var chatEmptySubtitle: String {
        switch self {
        case .spanish: return "Pregunta cualquier cosa sobre tus documentos importados"
        case .english: return "Ask anything about your imported documents"
        }
    }

    // Extractive answer labels
    func extractiveHeader(docTitle: String, entityName: String) -> String {
        switch self {
        case .spanish: return "Según **\(docTitle)**, esta es la información que encontré sobre \(entityName):"
        case .english: return "According to **\(docTitle)**, here's what I found about \(entityName):"
        }
    }
    func extractiveMultiHeader(entityName: String, count: Int) -> String {
        switch self {
        case .spanish: return "Encontré información sobre \(entityName) en \(count) documentos:"
        case .english: return "I found information about \(entityName) in \(count) documents:"
        }
    }

    // MARK: - Onboarding

    var onboardingTitle1: String {
        switch self { case .spanish: return "Tu segundo cerebro"; case .english: return "Your second brain" }
    }
    var onboardingSubtitle1: String {
        switch self {
        case .spanish: return "Guarda facturas, garantías, contratos y cualquier documento importante. DocumentBrain los organiza y los tiene siempre listos para ti."
        case .english: return "Store invoices, warranties, contracts, and any important documents. DocumentBrain organizes them and keeps them ready for you."
        }
    }
    var onboardingTitle2: String {
        switch self { case .spanish: return "Pregunta lo que quieras"; case .english: return "Ask anything" }
    }
    var onboardingSubtitle2: String {
        switch self {
        case .spanish: return "¿Cuánto pagué de luz? ¿Mi lavadora sigue en garantía? Pregunta en lenguaje natural y obtén respuestas al instante."
        case .english: return "How much was my electricity bill? Is my washing machine still under warranty? Ask in natural language and get instant answers."
        }
    }
    var onboardingTitle3: String {
        switch self { case .spanish: return "Importa desde cualquier app"; case .english: return "Import from any app" }
    }
    var onboardingSubtitle3: String {
        switch self {
        case .spanish: return "Comparte PDFs, fotos, documentos Word o Excel directamente desde cualquier aplicación usando el botón compartir."
        case .english: return "Share PDFs, photos, Word or Excel documents directly from any app using the share button."
        }
    }
    var onboardingTitle4: String {
        switch self { case .spanish: return "Privacidad total"; case .english: return "Total privacy" }
    }
    var onboardingSubtitle4: String {
        switch self {
        case .spanish: return "Tus documentos se procesan de forma privada. Puedes usar IA en el dispositivo y, cuando lo necesites, asistencia en la nube."
        case .english: return "Your documents are processed privately. You can use on-device AI and, when needed, cloud assistance."
        }
    }
    var onboardingStart: String {
        switch self { case .spanish: return "Empezar"; case .english: return "Get Started" }
    }
    var onboardingSkip: String {
        switch self { case .spanish: return "Saltar"; case .english: return "Skip" }
    }
    var onboardingNext: String {
        switch self { case .spanish: return "Siguiente"; case .english: return "Next" }
    }

    // MARK: - Accessibility labels

    var accessibilityNewConversation: String {
        switch self { case .spanish: return "Nueva conversación"; case .english: return "New conversation" }
    }
    var accessibilitySend: String {
        switch self { case .spanish: return "Enviar"; case .english: return "Send" }
    }
    var okButton: String {
        switch self { case .spanish: return "OK"; case .english: return "OK" }
    }

    // MARK: - Reindexing overlay

    var reindexOverlayTitle: String {
        switch self { case .spanish: return "Actualizando documentos"; case .english: return "Updating documents" }
    }
    var reindexOverlaySubtitle: String {
        switch self {
        case .spanish: return "El modelo de IA ha sido actualizado.\nReindexando tus documentos…"
        case .english: return "The AI model has been updated.\nReindexing your documents…"
        }
    }

    // MARK: - Tabs

    var tabLibrary: String {
        switch self { case .spanish: return "Biblioteca"; case .english: return "Library" }
    }
    var tabChat: String {
        switch self { case .spanish: return "Preguntar"; case .english: return "Ask" }
    }
    var tabSettings: String {
        switch self { case .spanish: return "Ajustes"; case .english: return "Settings" }
    }

    // MARK: - Library

    var libraryTitle: String {
        switch self { case .spanish: return "Biblioteca"; case .english: return "Library" }
    }
    var librarySearch: String {
        switch self { case .spanish: return "Buscar documentos..."; case .english: return "Search documents..." }
    }
    var libraryBack: String {
        switch self { case .spanish: return "Atrás"; case .english: return "Back" }
    }
    var libraryFromFiles: String {
        switch self { case .spanish: return "Desde archivos"; case .english: return "From files" }
    }
    var libraryTakePhoto: String {
        switch self { case .spanish: return "Hacer foto"; case .english: return "Take photo" }
    }
    var libraryNewFolder: String {
        switch self { case .spanish: return "Nueva carpeta"; case .english: return "New folder" }
    }
    var libraryRename: String {
        switch self { case .spanish: return "Renombrar"; case .english: return "Rename" }
    }
    var libraryDeleteFolder: String {
        switch self { case .spanish: return "Eliminar carpeta"; case .english: return "Delete folder" }
    }
    var libraryMoveToFolder: String {
        switch self { case .spanish: return "Mover a carpeta"; case .english: return "Move to folder" }
    }
    var libraryRemoveFromFolder: String {
        switch self { case .spanish: return "Sacar de carpeta"; case .english: return "Remove from folder" }
    }
    var libraryDeleteDoc: String {
        switch self { case .spanish: return "Eliminar"; case .english: return "Delete" }
    }
    var libraryRetry: String {
        switch self { case .spanish: return "Reintentar"; case .english: return "Retry" }
    }
    var libraryRootFolder: String {
        switch self { case .spanish: return "Raíz (sin carpeta)"; case .english: return "Root (no folder)" }
    }
    var libraryNoFolders: String {
        switch self { case .spanish: return "No hay carpetas. Crea una primero."; case .english: return "No folders. Create one first." }
    }
    var libraryMoveToTitle: String {
        switch self { case .spanish: return "Mover a..."; case .english: return "Move to..." }
    }
    var libraryFolderEmpty: String {
        switch self { case .spanish: return "Carpeta vacía"; case .english: return "Empty folder" }
    }
    var libraryFolderEmptySubtitle: String {
        switch self { case .spanish: return "Importa archivos o mueve documentos aquí"; case .english: return "Import files or move documents here" }
    }
    var libraryEmptyTitle: String {
        switch self { case .spanish: return "Tu segundo cerebro"; case .english: return "Your second brain" }
    }
    var libraryEmptySubtitle: String {
        switch self {
        case .spanish: return "Importa documentos y pregunta lo que\nnecesites saber sobre ellos"
        case .english: return "Import documents and ask anything\nyou need to know about them"
        }
    }
    var libraryImportFiles: String {
        switch self { case .spanish: return "Importar archivos"; case .english: return "Import files" }
    }
    var libraryScanDocument: String {
        switch self { case .spanish: return "Escanear documento"; case .english: return "Scan document" }
    }
    func libraryItemCount(_ count: Int) -> String {
        switch self {
        case .spanish: return "\(count) elemento\(count == 1 ? "" : "s")"
        case .english: return "\(count) item\(count == 1 ? "" : "s")"
        }
    }
    var libraryFolderNameField: String {
        switch self { case .spanish: return "Nombre"; case .english: return "Name" }
    }
    var libraryCreate: String {
        switch self { case .spanish: return "Crear"; case .english: return "Create" }
    }
    var libraryRenameFolderTitle: String {
        switch self { case .spanish: return "Renombrar carpeta"; case .english: return "Rename folder" }
    }
    var libraryAll: String {
        switch self { case .spanish: return "Todos"; case .english: return "All" }
    }
    var libraryImportedDocument: String {
        switch self { case .spanish: return "Documento importado"; case .english: return "Imported document" }
    }
    func libraryPhotoTitle(date: String) -> String {
        switch self {
        case .spanish: return "Foto \(date)"
        case .english: return "Photo \(date)"
        }
    }

    // Sort options
    var sortNewest: String {
        switch self { case .spanish: return "Más recientes"; case .english: return "Newest" }
    }
    var sortOldest: String {
        switch self { case .spanish: return "Más antiguos"; case .english: return "Oldest" }
    }
    var sortNameAZ: String {
        switch self { case .spanish: return "Nombre A-Z"; case .english: return "Name A-Z" }
    }
    var sortNameZA: String {
        switch self { case .spanish: return "Nombre Z-A"; case .english: return "Name Z-A" }
    }
    var sortLargest: String {
        switch self { case .spanish: return "Mayor tamaño"; case .english: return "Largest" }
    }
    var librarySortTitle: String {
        switch self { case .spanish: return "Ordenar"; case .english: return "Sort" }
    }

    // Processing banner
    var processingDocuments: String {
        switch self { case .spanish: return "Procesando documentos..."; case .english: return "Processing documents..." }
    }

    // FileType display names
    var fileTypePDF: String { "PDF" }
    var fileTypeImage: String {
        switch self { case .spanish: return "Imagen"; case .english: return "Image" }
    }
    var fileTypeWord: String { "Word" }
    var fileTypeExcel: String { "Excel" }
    var fileTypeText: String {
        switch self { case .spanish: return "Texto"; case .english: return "Text" }
    }
    var fileTypeEmail: String { "Email" }
    var fileTypeOther: String {
        switch self { case .spanish: return "Otro"; case .english: return "Other" }
    }

    // Chat history
    var chatHistory: String {
        switch self { case .spanish: return "Historial"; case .english: return "History" }
    }
    var chatClose: String {
        switch self { case .spanish: return "Cerrar"; case .english: return "Close" }
    }
    var chatDeleteAllHistory: String {
        switch self { case .spanish: return "Borrar todo el historial"; case .english: return "Delete all history" }
    }
    var chatDeleteAllHistoryMessage: String {
        switch self {
        case .spanish: return "Se eliminarán todas las conversaciones. Esta acción no se puede deshacer."
        case .english: return "All conversations will be deleted. This action cannot be undone."
        }
    }
    var chatNoConversations: String {
        switch self { case .spanish: return "Sin conversaciones"; case .english: return "No conversations" }
    }
    var chatConversationsAppearHere: String {
        switch self { case .spanish: return "Tus conversaciones aparecerán aquí"; case .english: return "Your conversations will appear here" }
    }
    var chatRecentConversations: String {
        switch self { case .spanish: return "Conversaciones recientes"; case .english: return "Recent conversations" }
    }
    var chatSeeAll: String {
        switch self { case .spanish: return "Ver todas"; case .english: return "See all" }
    }
    var chatSearching: String {
        switch self { case .spanish: return "Buscando en tus documentos..."; case .english: return "Searching your documents..." }
    }
    var chatSources: String {
        switch self { case .spanish: return "Fuentes"; case .english: return "Sources" }
    }
    var chatSourceFragment: String {
        switch self { case .spanish: return "Fragmento del documento"; case .english: return "Document fragment" }
    }
    var chatRelevance: String {
        switch self { case .spanish: return "relevancia"; case .english: return "relevance" }
    }
    var chatDeleteAction: String {
        switch self { case .spanish: return "Borrar"; case .english: return "Delete" }
    }

    // Chat suggestion examples
    var chatSuggestion1: String {
        switch self {
        case .spanish: return "¿Mi lavadora sigue en garantía?"
        case .english: return "Is my washing machine still under warranty?"
        }
    }
    var chatSuggestion2: String {
        switch self {
        case .spanish: return "¿Cuánto pagué de luz el mes pasado?"
        case .english: return "How much did I pay for electricity last month?"
        }
    }
    var chatSuggestion3: String {
        switch self {
        case .spanish: return "¿Qué cubre mi seguro de hogar?"
        case .english: return "What does my home insurance cover?"
        }
    }

    // Date grouping labels
    var dateToday: String {
        switch self { case .spanish: return "Hoy"; case .english: return "Today" }
    }
    var dateYesterday: String {
        switch self { case .spanish: return "Ayer"; case .english: return "Yesterday" }
    }
    var dateThisWeek: String {
        switch self { case .spanish: return "Esta semana"; case .english: return "This week" }
    }
    var dateThisMonth: String {
        switch self { case .spanish: return "Este mes"; case .english: return "This month" }
    }
    var dateOlder: String {
        switch self { case .spanish: return "Anteriores"; case .english: return "Older" }
    }

    // MARK: - Document Detail

    var detailDocument: String {
        switch self { case .spanish: return "Documento"; case .english: return "Document" }
    }
    var detailRetryProcessing: String {
        switch self { case .spanish: return "Reintentar procesado"; case .english: return "Retry processing" }
    }
    var detailShare: String {
        switch self { case .spanish: return "Compartir"; case .english: return "Share" }
    }
    var detailViewOriginal: String {
        switch self { case .spanish: return "Ver archivo original"; case .english: return "View original file" }
    }
    var detailExtractedText: String {
        switch self { case .spanish: return "Texto extraído"; case .english: return "Extracted text" }
    }
    func detailCharCount(_ count: Int) -> String {
        switch self {
        case .spanish: return "\(count) caracteres"
        case .english: return "\(count) characters"
        }
    }
    var detailStatusReady: String {
        switch self { case .spanish: return "Procesado correctamente"; case .english: return "Processed successfully" }
    }
    var detailStatusError: String {
        switch self { case .spanish: return "Error al procesar"; case .english: return "Processing error" }
    }
    var detailStatusPending: String {
        switch self { case .spanish: return "Pendiente"; case .english: return "Pending" }
    }
    var detailStatusExtracting: String {
        switch self { case .spanish: return "Extrayendo texto..."; case .english: return "Extracting text..." }
    }
    var detailStatusChunking: String {
        switch self { case .spanish: return "Fragmentando..."; case .english: return "Chunking..." }
    }
    var detailStatusEmbedding: String {
        switch self { case .spanish: return "Generando embeddings..."; case .english: return "Generating embeddings..." }
    }

    // MARK: - Error Messages

    var errorLoadDocuments: String {
        switch self { case .spanish: return "No se pudieron cargar los documentos."; case .english: return "Could not load documents." }
    }
    var errorCreateFolder: String {
        switch self { case .spanish: return "No se pudo crear la carpeta."; case .english: return "Could not create folder." }
    }
    var errorRenameFolder: String {
        switch self { case .spanish: return "No se pudo renombrar la carpeta."; case .english: return "Could not rename folder." }
    }
    var errorDeleteFolder: String {
        switch self { case .spanish: return "No se pudo eliminar la carpeta."; case .english: return "Could not delete folder." }
    }
    var errorMoveDocument: String {
        switch self { case .spanish: return "No se pudo mover el documento."; case .english: return "Could not move document." }
    }
    var errorImportFile: String {
        switch self { case .spanish: return "No se pudo importar el archivo seleccionado."; case .english: return "Could not import the selected file." }
    }
    var errorSaveFile: String {
        switch self { case .spanish: return "No se pudo guardar el archivo importado."; case .english: return "Could not save the imported file." }
    }
    var errorDeleteDocument: String {
        switch self { case .spanish: return "No se pudo eliminar el documento."; case .english: return "Could not delete the document." }
    }
    var errorSavePhoto: String {
        switch self { case .spanish: return "No se pudo guardar la foto capturada."; case .english: return "Could not save the captured photo." }
    }
    var errorGeneric: String {
        switch self { case .spanish: return "Ha ocurrido un error."; case .english: return "An error occurred." }
    }
    var errorLoadStats: String {
        switch self { case .spanish: return "No se pudieron cargar las estadísticas."; case .english: return "Could not load statistics." }
    }
    var errorReindex: String {
        switch self { case .spanish: return "No se pudieron reindexar los documentos."; case .english: return "Could not reindex documents." }
    }
    var errorDeleteAll: String {
        switch self { case .spanish: return "No se pudieron borrar todos los datos."; case .english: return "Could not delete all data." }
    }
}
