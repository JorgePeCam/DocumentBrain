import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - On-device structured metadata extraction using Apple Foundation Models (iOS 26+)
//
// Uses @Generable structured output instead of JSON parsing — the model fills in
// a type-safe struct directly, avoiding truncation and code-fence issues.

@available(iOS 26, macOS 26, *)
struct FoundationModelMetadataExtractor {

    // MARK: - Availability

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    // MARK: - Public API

    func extract(from text: String, documentTitle: String) async -> StructuredDocumentData? {
        #if canImport(FoundationModels)
        let prompt = buildPrompt(text: text, title: documentTitle)
        do {
            let session = LanguageModelSession(instructions: Self.systemInstructions)
            let response = try await session.respond(to: prompt, generating: MetadataResult.self)
            return convert(response.content)
        } catch {
            AppLogger.debug("[Metadata] Foundation Models extraction failed: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Prompt

    private func buildPrompt(text: String, title: String) -> String {
        let truncated = text.headAndTailTruncated()
        return """
        Título del documento: \(title)

        Texto:
        \(truncated)
        """
    }

    private static let systemInstructions = """
    Eres un extractor de datos estructurados de documentos. Analiza el documento y rellena los campos del resultado.

    REGLAS:
    - Tarjeta de embarque / boarding pass → documentType: "vuelo"
    - Billete de tren o autobús → documentType: "vuelo"
    - Entrada de concierto, teatro, festival → documentType: "evento"
    - Factura, recibo → documentType: "factura" o "recibo"
    - Si el documento no tiene datos estructurados → marca isEmpty como true y deja el resto vacío
    - date siempre en formato YYYY-MM-DD
    - departureTime y arrivalTime en formato HH:MM
    - amount solo el número decimal, sin símbolo de moneda
    - currency en ISO 4217 (EUR, USD, GBP…)
    - category: alimentación, transporte, salud, educación, entretenimiento, hogar, trabajo, finanzas, compras, suministros, viajes, o otro
    """

    // MARK: - Conversion

    #if canImport(FoundationModels)
    private func convert(_ result: MetadataResult) -> StructuredDocumentData? {
        if result.isEmpty == true { return nil }

        var data = StructuredDocumentData()

        if let raw = result.documentType, !raw.isEmpty {
            data.documentType = StructuredDocumentData.DocumentType(rawValue: raw)
        }
        if let v = result.vendor,        !v.isEmpty { data.vendor        = v }
        if let v = result.date,          !v.isEmpty { data.date          = v }
        if let v = result.amount                    { data.amount        = v }
        if let v = result.currency,      !v.isEmpty { data.currency      = v.uppercased() }
        if let raw = result.category,    !raw.isEmpty {
            data.category = StructuredDocumentData.Category(rawValue: raw)
        }
        if let v = result.origin,        !v.isEmpty { data.origin        = v }
        if let v = result.destination,   !v.isEmpty { data.destination   = v }
        if let v = result.flightNumber,  !v.isEmpty { data.flightNumber  = v }
        if let v = result.departureTime, !v.isEmpty { data.departureTime = v }
        if let v = result.arrivalTime,   !v.isEmpty { data.arrivalTime   = v }
        if let v = result.seat,          !v.isEmpty { data.seat          = v }
        if let v = result.eventTitle,    !v.isEmpty { data.eventTitle    = v }

        return data.isEmpty ? nil : data
    }
    #endif
}

// MARK: - Generable output type

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
struct MetadataResult {
    @Guide(description: "Document type: factura, recibo, contrato, nómina, extracto, ticket, presupuesto, vuelo, evento, or otro")
    var documentType: String?

    @Guide(description: "Vendor, airline, merchant, or issuer name")
    var vendor: String?

    @Guide(description: "Document date in YYYY-MM-DD format")
    var date: String?

    @Guide(description: "Total amount as a decimal number without currency symbol")
    var amount: Double?

    @Guide(description: "ISO 4217 currency code: EUR, USD, GBP, etc.")
    var currency: String?

    @Guide(description: "Category: alimentación, transporte, salud, educación, entretenimiento, hogar, trabajo, finanzas, compras, suministros, viajes, or otro")
    var category: String?

    @Guide(description: "Origin city or IATA airport code (flights/trains)")
    var origin: String?

    @Guide(description: "Destination city or IATA airport code (flights/trains)")
    var destination: String?

    @Guide(description: "Flight, train, or service number (e.g. FR347, AVE 02154)")
    var flightNumber: String?

    @Guide(description: "Departure time or event start time in HH:MM format")
    var departureTime: String?

    @Guide(description: "Arrival time in HH:MM format")
    var arrivalTime: String?

    @Guide(description: "Assigned seat, row, or position")
    var seat: String?

    @Guide(description: "Concert, show, or event name")
    var eventTitle: String?

    @Guide(description: "True if the document has no structured data worth extracting")
    var isEmpty: Bool?
}
#endif
