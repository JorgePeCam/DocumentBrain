import Foundation

/// Q&A provider that calls DocumentBrain's Cloudflare Worker proxy.
/// The Gemini API key lives server-side — it never touches the device.
final class GeminiQAProvider: StreamableQAProvider {
    var name: String { "Asistente inteligente" }
    var kind: QAProviderKind { .cloud }

    var isAvailable: Bool { true } // Worker is always reachable when online

    // MARK: - Worker config (read from Config.plist — not committed to git)

    private static let config: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            return [:]
        }
        return dict
    }()

    private static var workerURL: String {
        (config["WorkerURL"] as? String) ?? ""
    }

    private static var appSecret: String {
        (config["AppSecret"] as? String) ?? ""
    }

    // MARK: - Request builder

    private func makeRequest(path: String) async -> URLRequest? {
        guard !Self.workerURL.isEmpty,
              let url = URL(string: Self.workerURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(Self.appSecret, forHTTPHeaderField: "x-app-secret")
        // App Attest session token (gates /chat once the Worker enforces it)
        if let token = await AppAttestService.shared.currentToken() {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Multi-turn builder

    private func buildContents(history: [ConversationTurn], currentPrompt: String) -> [[String: Any]] {
        var contents: [[String: Any]] = []
        for turn in history {
            contents.append(["role": "user",  "parts": [["text": turn.userMessage]]])
            contents.append(["role": "model", "parts": [["text": turn.assistantMessage]]])
        }
        contents.append(["role": "user", "parts": [["text": currentPrompt]]])
        return contents
    }

    // MARK: - Answer

    func answer(query: String, context: [SearchResult], history: [ConversationTurn] = []) async throws -> String {
        AppLogger.debug("[Worker] 🚀 Starting request")

        guard var request = await makeRequest(path: "/chat") else {
            AppLogger.debug("[Worker] ❌ Worker URL not configured")
            throw QAError.noProviderAvailable
        }

        let contextPrompt = QAService.buildContextPrompt(query: query, context: Array(context.prefix(8)))
        AppLogger.debug("[Worker] Prompt length: \(contextPrompt.count) chars, history turns: \(history.count)")

        let requestBody: [String: Any] = [
            "systemInstruction": ["parts": [["text": AppLanguage.current.systemPrompt]]],
            "contents": buildContents(history: history, currentPrompt: contextPrompt),
            "generationConfig": ["maxOutputTokens": 2048, "temperature": 0.3]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 30

        AppLogger.debug("[Worker] 📡 Calling proxy...")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            AppLogger.debug("[Worker] ❌ Network error: \(error.localizedDescription)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QAError.apiError("Respuesta no válida")
        }

        if httpResponse.statusCode == 429 {
            AppLogger.debug("[Worker] HTTP 429 — rate limit reached.")
            throw QAError.noProviderAvailable
        }

        if httpResponse.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "(no body)"
            AppLogger.debug("[Worker] ❌ HTTP \(httpResponse.statusCode): \(bodyStr.prefix(300))")
            throw QAError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw QAError.apiError("No se pudo leer la respuesta")
        }

        AppLogger.debug("[Worker] ✅ Response OK (\(text.count) chars)")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming

    func streamAnswer(query: String, context: [SearchResult], history: [ConversationTurn] = [], onUpdate: @escaping (String) -> Void) async throws {
        AppLogger.debug("[Worker] 🚀 Starting STREAM request")

        guard var request = await makeRequest(path: "/chat/stream") else {
            throw QAError.noProviderAvailable
        }

        let contextPrompt = QAService.buildContextPrompt(query: query, context: Array(context.prefix(8)))

        let requestBody: [String: Any] = [
            "systemInstruction": ["parts": [["text": AppLanguage.current.systemPrompt]]],
            "contents": buildContents(history: history, currentPrompt: contextPrompt),
            "generationConfig": ["maxOutputTokens": 2048, "temperature": 0.3]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60

        AppLogger.debug("[Worker] 📡 Streaming from proxy...")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QAError.apiError("Respuesta no válida")
        }

        if httpResponse.statusCode == 429 {
            AppLogger.debug("[Worker] HTTP 429 — rate limit. Falling back.")
            throw QAError.noProviderAvailable
        }

        guard httpResponse.statusCode == 200 else {
            AppLogger.debug("[Worker] ❌ Stream HTTP \(httpResponse.statusCode)")
            throw QAError.apiError("HTTP \(httpResponse.statusCode)")
        }

        var accumulated = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard !jsonString.isEmpty else { continue }

            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { continue }

            accumulated += text
            onUpdate(accumulated)
        }

        guard !accumulated.isEmpty else {
            throw QAError.apiError("No se recibió contenido en el stream")
        }

        AppLogger.debug("[Worker] ✅ Stream complete. Length=\(accumulated.count) chars")
    }
}
