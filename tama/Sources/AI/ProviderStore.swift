import CryptoKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "provider-store"
)

// MARK: - CredentialsRefresher

/// Abstraction over the per-provider OAuth refresh call.
/// Injected into `ProviderStore` so tests can mock the network hop.
protocol CredentialsRefresher: Sendable {
    func refresh(
        provider: AIProvider,
        refreshToken: String,
        accountId: String?
    ) async throws -> ProviderCredential
}

/// Production implementation — delegates to the real OAuth singletons.
struct LiveCredentialsRefresher: CredentialsRefresher {
    func refresh(
        provider: AIProvider,
        refreshToken: String,
        accountId: String?
    ) async throws -> ProviderCredential {
        switch provider {
        case .openai:
            let result = try await OpenAIOAuth.shared.refresh(refreshToken: refreshToken)
            return ProviderCredential.oauth(
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                expiresAt: result.expiresAt,
                accountId: result.accountId
            )
        case .gemini:
            let projectId = accountId ?? ""
            let result = try await GeminiOAuth.shared.refresh(
                refreshToken: refreshToken,
                projectId: projectId
            )
            return ProviderCredential.oauth(
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                expiresAt: result.expiresAt,
                accountId: result.projectId
            )
        case .anthropic:
            let result = try await AnthropicOAuth.shared.refresh(refreshToken: refreshToken)
            return ProviderCredential.oauth(
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                expiresAt: result.expiresAt,
                accountId: ""
            )
        default:
            throw ProviderStore.ProviderStoreError.noCredentials(provider)
        }
    }
}

/// Credential for a single provider — API key or OAuth tokens.
struct ProviderCredential: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let accountId: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var isOAuth: Bool {
        refreshToken != nil
    }

    /// Create from a simple API key.
    static func apiKey(_ key: String) -> ProviderCredential {
        ProviderCredential(accessToken: key, refreshToken: nil, expiresAt: nil, accountId: nil)
    }

    /// Create from OAuth token exchange result.
    static func oauth(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountId: String
    ) -> ProviderCredential {
        ProviderCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountId: accountId
        )
    }
}

/// Persisted state for all provider credentials and model selection.
private struct StoreData: Codable {
    var credentials: [String: ProviderCredential]
    var selectedModelId: String?

    static let empty = StoreData(credentials: [:], selectedModelId: nil)
}

/// Manages API keys for all providers and persists selected model.
@MainActor
final class ProviderStore {
    static let shared = ProviderStore()

    private var data: StoreData
    private static let fileName = "provider-store.enc"

    /// In-flight refresh tasks keyed by provider ID.
    /// Concurrent callers that find an expired token await the same task
    /// instead of each firing an independent OAuth refresh.
    private var refreshTasks: [String: Task<String, Error>] = [:]

    /// OAuth refresh implementation — swapped out in tests via `init(refresher:)`.
    private let refresher: any CredentialsRefresher

    private init(refresher: any CredentialsRefresher = LiveCredentialsRefresher()) {
        self.refresher = refresher
        data = Self.loadFromDisk() ?? .empty
    }

    /// Creates a store backed by an in-memory credential dictionary and a
    /// custom refresher.  Used by unit tests only.
    static func makeForTesting(refresher: any CredentialsRefresher) -> ProviderStore {
        let store = ProviderStore(refresher: refresher)
        // Bypass disk I/O entirely — start with empty in-memory state.
        store.data = .empty
        return store
    }

    // MARK: - Credentials

    func hasCredentials(for provider: AIProvider) -> Bool {
        data.credentials[provider.rawValue] != nil
    }

    func credential(for provider: AIProvider) -> ProviderCredential? {
        data.credentials[provider.rawValue]
    }

    func setCredential(_ credential: ProviderCredential, for provider: AIProvider) {
        data.credentials[provider.rawValue] = credential
        save()
    }

    func removeCredential(for provider: AIProvider) {
        data.credentials.removeValue(forKey: provider.rawValue)
        // If the selected model belongs to this provider, clear it
        if let modelId = data.selectedModelId,
           let model = ModelRegistry.model(withId: modelId),
           model.provider == provider
        {
            data.selectedModelId = nil
        }
        save()
    }

    /// Returns the access token for the given provider.
    /// For OAuth providers, auto-refreshes expired tokens.
    /// Concurrent calls that race on the same expired token are coalesced:
    /// the first caller starts the refresh task and subsequent callers
    /// await that same task, ensuring each single-use refresh token is
    /// consumed exactly once.
    func validAccessToken(for provider: AIProvider) async throws -> String {
        guard let cred = data.credentials[provider.rawValue] else {
            throw ProviderStoreError.noCredentials(provider)
        }

        // Auto-refresh expired OAuth tokens
        guard cred.isOAuth, cred.isExpired, let refreshToken = cred.refreshToken else {
            return cred.accessToken
        }

        // Coalesce concurrent refresh attempts for the same provider.
        if let existing = refreshTasks[provider.rawValue] {
            logger.debug("Coalescing token refresh for \(provider.displayName) onto existing task")
            return try await existing.value
        }

        logger.info("Token expired for \(provider.displayName), refreshing…")

        let accountId = cred.accountId
        let credRefresher = refresher
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw ProviderStoreError.noCredentials(provider) }

            let newCred = try await credRefresher.refresh(
                provider: provider,
                refreshToken: refreshToken,
                accountId: accountId
            )

            await MainActor.run {
                self.data.credentials[provider.rawValue] = newCred
                self.save()
                self.refreshTasks.removeValue(forKey: provider.rawValue)
            }
            return newCred.accessToken
        }

        refreshTasks[provider.rawValue] = task
        return try await task.value
    }

    // MARK: - Model Selection

    var selectedModel: ModelInfo {
        if let id = data.selectedModelId, let model = ModelRegistry.model(withId: id) {
            if hasCredentials(for: model.provider) {
                return model
            }
        }
        // Fall back to first available model
        if let first = ModelRegistry.availableModels().first {
            return first
        }
        // Ultimate fallback
        return ModelRegistry.defaultModel(for: .moonshot)
    }

    func setSelectedModel(_ model: ModelInfo) {
        data.selectedModelId = model.id
        save()
    }

    /// Whether any provider has credentials configured.
    var hasAnyCredentials: Bool {
        !data.credentials.isEmpty
    }

    // MARK: - Validation

    /// Validates an API key by making a lightweight request to the provider.
    /// Returns nil on success, or an error message on failure.
    nonisolated func validateApiKey(_ key: String, for provider: AIProvider) async -> String? {
        if provider.usesAnthropicAPI {
            return await validateAnthropicKey(key, for: provider)
        }
        // Xiaomi doesn't support GET /v1/models, so use a minimal chat completion
        if provider == .xiaomi {
            return await validateXiaomiKey(key)
        }
        return await validateOpenAIKey(key, for: provider)
    }

    // swiftlint:disable modifier_order
    /// Validate via a minimal chat completion for Xiaomi (which doesn't support /v1/models).
    private nonisolated func validateXiaomiKey(_ key: String) async -> String? {
        guard let url = URL(string: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions") else {
            return "Invalid Xiaomi API URL."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": "xiaomi-token-plan-sgp/mimo-v2-pro",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Unexpected response from Xiaomi."
            }
            switch http.statusCode {
            case 200 ..< 300:
                return nil
            case 401, 403:
                return "Invalid API key. Check and try again."
            case 429:
                return nil // Rate limited = key is valid, just over limit
            default:
                return "Validation failed (HTTP \(http.statusCode)). The key may still work — try sending a message."
            }
        } catch {
            return "Couldn't reach Xiaomi. Check your internet and try again."
        }
    }

    /// Validate via GET /models for OpenAI-compatible providers.
    private nonisolated func validateOpenAIKey(_ key: String, for provider: AIProvider) async -> String? {
        guard let url = URL(string: provider.modelsURL) else {
            return "Invalid provider URL."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Unexpected response from server."
            }
            switch http.statusCode {
            case 200 ..< 300:
                return nil
            case 401, 403:
                return "Invalid API key. Check and try again."
            default:
                return "Validation failed (HTTP \(http.statusCode)). The key may still work — try sending a message."
            }
        } catch {
            return "Couldn't reach \(provider.displayName). Check your internet and try again."
        }
    }

    /// Validate via a minimal POST /messages for Anthropic-compatible providers (e.g. MiniMax).
    private nonisolated func validateAnthropicKey(_ key: String, for provider: AIProvider) async -> String? {
        guard let url = URL(string: provider.baseURL) else {
            return "Invalid provider URL."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10

        // Send a minimal request with max_tokens=1 to validate the key cheaply
        let body: [String: Any] = [
            "model": ModelRegistry.defaultModel(for: provider).id,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Unexpected response from server."
            }
            switch http.statusCode {
            case 200 ..< 300:
                return nil
            case 401, 403:
                return "Invalid API key. Check and try again."
            default:
                return nil // Non-auth errors mean the key itself is valid
            }
        } catch {
            return "Couldn't reach \(provider.displayName). Check your internet and try again."
        }
    }

    // swiftlint:enable modifier_order

    // MARK: - Persistence

    private func save() {
        do {
            let jsonData = try JSONEncoder().encode(data)
            let key = ClaudeCredentials.sharedEncryptionKey
            let sealed = try ChaChaPoly.seal(jsonData, using: key)
            try sealed.combined.write(to: Self.fileURL())
            logger.info("Provider store saved")
        } catch {
            logger.error("Failed to save provider store: \(error.localizedDescription)")
        }
    }

    private static func loadFromDisk() -> StoreData? {
        do {
            let url = try fileURL()
            let combined = try Data(contentsOf: url)
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let key = ClaudeCredentials.sharedEncryptionKey
            let jsonData = try ChaChaPoly.open(box, using: key)
            return try JSONDecoder().decode(StoreData.self, from: jsonData)
        } catch {
            return nil
        }
    }

    private static func fileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Tama", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Errors

    enum ProviderStoreError: LocalizedError {
        case noCredentials(AIProvider)

        var errorDescription: String? {
            switch self {
            case let .noCredentials(provider):
                "No API key configured for \(provider.displayName). Add one in Settings."
            }
        }
    }
}
