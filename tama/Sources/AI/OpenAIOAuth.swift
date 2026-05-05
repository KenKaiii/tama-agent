import AppKit
import CryptoKit
import Foundation
import Network
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "oauth.openai"
)

/// OAuth token response from OpenAI.
struct OpenAITokenResult {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountId: String
}

/// Manages OpenAI OAuth PKCE authentication, token exchange, and refresh.
@MainActor
final class OpenAIOAuth {
    static let shared = OpenAIOAuth()

    // swiftlint:disable modifier_order
    private nonisolated static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private nonisolated static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private nonisolated static let tokenURL = "https://auth.openai.com/oauth/token"
    private nonisolated static let redirectURI = "http://localhost:1455/auth/callback"
    private nonisolated static let scope = "openid profile email offline_access"
    private nonisolated static let jwtClaimPath = "https://api.openai.com/auth"
    // swiftlint:enable modifier_order

    private init() {}

    // MARK: - Public API

    /// Runs the full OAuth PKCE login flow: opens browser, waits for callback, exchanges code.
    func authenticate() async throws -> OpenAITokenResult {
        let pkce = generatePKCE()
        let state = generateState()

        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "tama"),
        ]

        let authorizeURL = components.url!
        logger.info("Starting OpenAI OAuth flow")

        let code = try await listenForCallback(authorizeURL: authorizeURL, expectedState: state)
        logger.info("Received authorization code")

        let result = try await exchangeCode(code, verifier: pkce.verifier)
        logger.info("Token exchange successful, accountId=\(result.accountId.prefix(8))…")
        return result
    }

    /// Refreshes an expired access token using the refresh token.
    nonisolated func refresh(refreshToken: String) async throws -> OpenAITokenResult {
        logger.info("Refreshing OpenAI token")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID),
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token refresh failed (HTTP \(code)): \(text)")
            throw OpenAIOAuthError.refreshFailed(code)
        }

        let tokenData = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try parseTokenResponse(tokenData)
    }

    // MARK: - Local Callback Server

    /// Thread-safe one-shot guard for continuation resumption.
    private final class ResumeGuard: @unchecked Sendable {
        private var resumed = false

        /// Returns true the first time called, false thereafter.
        func claim() -> Bool {
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private func listenForCallback(authorizeURL: URL, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let resumeOnce = ResumeGuard()
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: 1455)
            } catch {
                continuation.resume(
                    throwing: OpenAIOAuthError.serverFailed("Failed to bind port 1455: \(error.localizedDescription)")
                )
                return
            }

            listener.newConnectionHandler = { [weak listener] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }

                    let result = Self.parseCallbackRequest(request, expectedState: expectedState)

                    let html = if result.code != nil {
                        "<html><body><h1>Login successful!</h1><p>You can close this tab.</p></body></html>"
                    } else {
                        "<html><body><h1>Login failed</h1><p>\(result.error ?? "Unknown error")</p></body></html>"
                    }

                    let httpResponse =
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
                    let responseData = httpResponse.data(using: .utf8)!
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        connection.cancel()
                    })

                    listener?.cancel()

                    guard resumeOnce.claim() else { return }
                    if let code = result.code {
                        continuation.resume(returning: code)
                    } else {
                        continuation.resume(
                            throwing: OpenAIOAuthError.callbackFailed(result.error ?? "No code received")
                        )
                    }
                }
            }

            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    guard resumeOnce.claim() else { return }
                    continuation.resume(
                        throwing: OpenAIOAuthError.serverFailed(error.localizedDescription)
                    )
                }
                if case .ready = state {
                    NSWorkspace.shared.open(authorizeURL)
                    logger.info("Opened browser for OpenAI login")
                }
            }

            listener.start(queue: .main)

            // Timeout after 2 minutes
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak listener] in
                guard resumeOnce.claim() else { return }
                listener?.cancel()
                continuation.resume(throwing: OpenAIOAuthError.timeout)
            }
        }
    }

    /// Parse the raw HTTP request from the browser callback.
    nonisolated static func parseCallbackRequest(
        _ raw: String,
        expectedState: String
    ) -> (code: String?, error: String?) {
        // Extract the path from "GET /auth/callback?code=...&state=... HTTP/1.1"
        guard let firstLine = raw.split(separator: "\r\n").first ?? raw.split(separator: "\n").first,
              let pathStart = firstLine.range(of: " /"),
              let pathEnd = firstLine.range(of: " HTTP")
        else {
            return (nil, "Invalid request")
        }

        let path = String(firstLine[pathStart.upperBound ..< pathEnd.lowerBound])
        guard let components = URLComponents(string: path) else {
            return (nil, "Invalid callback URL")
        }

        let items = components.queryItems ?? []
        let state = items.first(where: { $0.name == "state" })?.value
        let code = items.first(where: { $0.name == "code" })?.value

        if state != expectedState {
            return (nil, "State mismatch")
        }
        if let code, !code.isEmpty {
            return (code, nil)
        }

        let errorDesc = items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value
        return (nil, errorDesc ?? "No authorization code")
    }

    // MARK: - Token Exchange

    private func exchangeCode(_ code: String, verifier: String) async throws -> OpenAITokenResult {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token exchange failed (HTTP \(code)): \(text)")
            throw OpenAIOAuthError.tokenExchangeFailed(code)
        }

        let tokenData = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try parseTokenResponse(tokenData)
    }

    // swiftlint:disable:next modifier_order
    private nonisolated func parseTokenResponse(_ tokenData: [String: Any]) throws -> OpenAITokenResult {
        guard let accessToken = tokenData["access_token"] as? String,
              let refreshToken = tokenData["refresh_token"] as? String,
              let expiresIn = tokenData["expires_in"] as? Int
        else {
            throw OpenAIOAuthError.invalidTokenResponse
        }

        guard let accountId = Self.extractAccountId(from: accessToken) else {
            throw OpenAIOAuthError.noAccountId
        }

        return OpenAITokenResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            accountId: accountId
        )
    }

    // MARK: - PKCE

    private struct PKCEPair {
        let verifier: String
        let challenge: String
    }

    private func generatePKCE() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URLEncode(Data(bytes))

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(hash))

        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - JWT Decode

    /// Extract the chatgpt_account_id from the JWT access token payload.
    nonisolated static func extractAccountId(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        // Base64url → Base64 → Data → JSON
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json[jwtClaimPath] as? [String: Any],
              let accountId = auth["chatgpt_account_id"] as? String,
              !accountId.isEmpty
        else {
            return nil
        }

        return accountId
    }

    // MARK: - Errors

    enum OpenAIOAuthError: LocalizedError {
        case callbackFailed(String)
        case serverFailed(String)
        case timeout
        case tokenExchangeFailed(Int)
        case refreshFailed(Int)
        case invalidTokenResponse
        case noAccountId

        var errorDescription: String? {
            switch self {
            case let .callbackFailed(detail):
                "OAuth callback failed: \(detail)"
            case let .serverFailed(detail):
                "Could not start login server: \(detail)"
            case .timeout:
                "Login timed out. Try again."
            case let .tokenExchangeFailed(code):
                "Token exchange failed (HTTP \(code))."
            case let .refreshFailed(code):
                "Token refresh failed (HTTP \(code)). Sign in again."
            case .invalidTokenResponse:
                "Invalid token response from OpenAI."
            case .noAccountId:
                "Could not extract account ID from OpenAI token."
            }
        }
    }
}
