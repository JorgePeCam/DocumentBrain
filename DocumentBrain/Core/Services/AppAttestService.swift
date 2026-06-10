import CryptoKit
import DeviceCheck
import Foundation

/// Apple App Attest client.
///
/// Proves to the Cloudflare proxy that requests come from a genuine instance of
/// this app and obtains short-lived session tokens used to gate `/chat`.
///
/// Security posture: the session token is kept in memory only — never written to
/// disk. Only the App Attest `keyId` (a non-secret public-key hash) is persisted,
/// so after a relaunch we refresh with a cheap assertion instead of re-attesting.
///
/// `currentToken()` returns `nil` (rather than throwing) when attestation is
/// unsupported or fails, so callers degrade gracefully while the Worker's
/// `REQUIRE_ATTESTATION` flag is still off during rollout.
actor AppAttestService {

    static let shared = AppAttestService()

    private let service = DCAppAttestService.shared
    private let session = URLSession.shared

    private var cachedToken: String?
    private var tokenExpiry: Date?
    private var cooldownUntil: Date?

    private let keyIdDefaultsKey = "appAttestKeyId"

    // MARK: - Config (same Config.plist as the providers)

    private static let config: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }
        return dict
    }()
    private var workerURL: String { (Self.config["WorkerURL"] as? String) ?? "" }
    private var appSecret: String { (Self.config["AppSecret"] as? String) ?? "" }

    private var storedKeyId: String? {
        get { UserDefaults.standard.string(forKey: keyIdDefaultsKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: keyIdDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: keyIdDefaultsKey) }
        }
    }

    // MARK: - Public API

    /// A valid session token, attesting or refreshing as needed. `nil` if
    /// unsupported, unconfigured, or recently failed (backoff active).
    func currentToken() async -> String? {
        guard service.isSupported, !workerURL.isEmpty else { return nil }

        if let token = cachedToken, let exp = tokenExpiry, exp > Date().addingTimeInterval(60) {
            return token
        }
        // Back off after a recent failure so we don't hammer the device's App
        // Attest key generation limits or the proxy on every request.
        if let cooldown = cooldownUntil, cooldown > Date() { return nil }

        do {
            if let keyId = storedKeyId {
                return try await refresh(keyId: keyId)
            } else {
                return try await attest()
            }
        } catch {
            AppLogger.debug("[AppAttest] token unavailable: \(error.localizedDescription)")
            cooldownUntil = Date().addingTimeInterval(3600) // retry in ~1h
            return nil
        }
    }

    // MARK: - Attestation (once per install)

    private func attest() async throws -> String {
        let keyId = try await generateKey()
        let challenge = try await fetchChallenge(keyId: keyId)
        let clientDataHash = Data(SHA256.hash(data: decodeChallenge(challenge)))
        let attestation = try await attestKey(keyId, clientDataHash: clientDataHash)
        let token = try await postVerify(keyId: keyId, attestation: attestation)
        storedKeyId = keyId
        cache(token)
        return token
    }

    // MARK: - Refresh (assertion proves possession of the attested key)

    private func refresh(keyId: String) async throws -> String {
        let challenge = try await fetchChallenge(keyId: keyId)
        let clientData = decodeChallenge(challenge)
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let assertion = try await generateAssertion(keyId, clientDataHash: clientDataHash)
        return try await postRefresh(keyId: keyId, assertion: assertion, clientData: clientData)
    }

    private func cache(_ token: String) {
        cachedToken = token
        tokenExpiry = Date().addingTimeInterval(23 * 3600) // refresh a little before the 24h TTL
        cooldownUntil = nil
    }

    private func decodeChallenge(_ challenge: String) -> Data {
        Data(base64Encoded: challenge) ?? Data(challenge.utf8)
    }

    // MARK: - DeviceCheck bridges (completion → async)

    private func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            service.generateKey { keyId, error in
                if let keyId { cont.resume(returning: keyId) }
                else { cont.resume(throwing: error ?? AppAttestError.generic) }
            }
        }
    }

    private func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
                if let attestation { cont.resume(returning: attestation) }
                else { cont.resume(throwing: error ?? AppAttestError.generic) }
            }
        }
    }

    private func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            service.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
                if let assertion { cont.resume(returning: assertion) }
                else { cont.resume(throwing: error ?? AppAttestError.generic) }
            }
        }
    }

    // MARK: - Worker calls

    private func fetchChallenge(keyId: String) async throws -> String {
        let data = try await post("/attest/challenge", body: ["keyId": keyId])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenge = json["challenge"] as? String else { throw AppAttestError.badResponse }
        return challenge
    }

    private func postVerify(keyId: String, attestation: Data) async throws -> String {
        let data = try await post("/attest/verify", body: [
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
        ])
        return try token(from: data)
    }

    private func postRefresh(keyId: String, assertion: Data, clientData: Data) async throws -> String {
        let data = try await post("/attest/refresh", body: [
            "keyId": keyId,
            "assertion": assertion.base64EncodedString(),
            "clientData": clientData.base64EncodedString(),
        ])
        let token = try token(from: data)
        cache(token)
        return token
    }

    private func token(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppAttestError.badResponse
        }
        if json["ok"] as? Bool == true, let token = json["token"] as? String { return token }
        throw AppAttestError.rejected(json["reason"] as? String ?? "unknown")
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: workerURL + path) else { throw AppAttestError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(appSecret, forHTTPHeaderField: "x-app-secret")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppAttestError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}

enum AppAttestError: LocalizedError {
    case generic
    case badResponse
    case rejected(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .generic:            return "App Attest error"
        case .badResponse:        return "Respuesta inválida del servidor de atestación"
        case .rejected(let r):    return "Atestación rechazada: \(r)"
        case .http(let code):     return "HTTP \(code)"
        }
    }
}
