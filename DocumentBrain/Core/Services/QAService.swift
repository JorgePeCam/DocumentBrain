import Foundation

/// A single exchange in the conversation history passed to LLM providers.
struct ConversationTurn {
    let userMessage: String
    let assistantMessage: String
}

/// Protocol for Q&A providers (on-device or cloud API)
protocol QAProvider {
    func answer(query: String, context: [SearchResult], history: [ConversationTurn]) async throws -> String
    var isAvailable: Bool { get }
    var name: String { get }
    var kind: QAProviderKind { get }
}

/// Protocol for providers that support streaming responses
protocol StreamableQAProvider: QAProvider {
    func streamAnswer(query: String, context: [SearchResult], history: [ConversationTurn], onUpdate: @escaping (String) -> Void) async throws
}

enum QAProviderKind {
    case onDevice
    case cloud
}

/// Orchestrates Q&A with automatic fallback chain:
/// 1. Gemini Flash (cloud, free) — best quality, primary
/// 2. Apple Intelligence (on-device, free) — offline/rate-limit fallback
/// 3. Extractive (no LLM) — last resort, handled by ChatViewModel
final class QAService {
    static let shared = QAService()

    private var providers: [QAProvider] = []

    private init() {
        // 1. Gemini Flash — best quality, free tier (20 queries/day per device)
        providers.append(GeminiQAProvider())

        // 2. Apple Foundation Models — fallback when offline or Gemini limit reached
        if #available(iOS 26, macOS 26, *) {
            providers.append(FoundationModelQAProvider())
        }
    }

    /// Returns the first available provider, or nil
    var activeProvider: QAProvider? {
        providers.first { $0.isAvailable }
    }

    var activeProviderName: String {
        activeProvider?.name ?? "No disponible"
    }

    var activeProviderKind: QAProviderKind? {
        activeProvider?.kind
    }

    var hasAnyProvider: Bool {
        activeProvider != nil
    }

    /// Whether the active provider supports streaming
    var canStream: Bool {
        activeProvider is StreamableQAProvider
    }

    /// Try each provider in order until one succeeds
    func answer(query: String, context: [SearchResult], history: [ConversationTurn] = []) async throws -> String {
        var lastError: Error?

        AppLogger.debug("[QAService] Providers: \(providers.map { "\($0.name) available=\($0.isAvailable)" })")
        for provider in providers where provider.isAvailable {
            do {
                AppLogger.debug("[QAService] Trying provider: \(provider.name)")
                let result = try await provider.answer(query: query, context: context, history: history)
                AppLogger.debug("[QAService] ✅ \(provider.name) succeeded")
                return result
            } catch {
                AppLogger.debug("[QAService] ⚠️ \(provider.name) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }

        throw lastError ?? QAError.noProviderAvailable
    }

    /// Stream the answer, falling back to non-streaming providers
    func streamAnswer(query: String, context: [SearchResult], history: [ConversationTurn] = [], onUpdate: @escaping (String) -> Void) async throws {
        var lastError: Error?

        AppLogger.debug("[QAService] Stream — Providers: \(providers.map { "\($0.name) available=\($0.isAvailable)" })")
        for provider in providers where provider.isAvailable {
            do {
                AppLogger.debug("[QAService] Stream — Trying: \(provider.name)")
                if let streamable = provider as? StreamableQAProvider {
                    try await streamable.streamAnswer(query: query, context: context, history: history, onUpdate: onUpdate)
                } else {
                    let result = try await provider.answer(query: query, context: context, history: history)
                    onUpdate(result)
                }
                AppLogger.debug("[QAService] ✅ Stream — \(provider.name) succeeded")
                return
            } catch {
                AppLogger.debug("[QAService] ⚠️ Stream — \(provider.name) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }

        throw lastError ?? QAError.noProviderAvailable
    }

    /// Builds the context+question block sent as the current user turn.
    /// System instructions are passed separately (via systemInstruction or session instructions).
    static func buildContextPrompt(query: String, context: [SearchResult]) -> String {
        let lang = AppLanguage.current
        var prompt = lang.snippetsHeader

        for (index, result) in context.enumerated() {
            prompt += "\n\n\(lang.snippetLabel(title: result.documentTitle, index: index + 1))\n"
            prompt += result.chunkContent
        }

        prompt += "\n\n\(lang.questionLabel): \(query)"
        return prompt
    }
}

enum QAError: LocalizedError {
    case noProviderAvailable
    case apiError(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noProviderAvailable:
            return "No se pudo generar una respuesta. Inténtalo de nuevo."
        case .apiError(let message):
            return message
        case .rateLimited:
            return "Se alcanzó el límite de consultas."
        }
    }
}
