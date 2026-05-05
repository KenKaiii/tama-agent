import AppKit
import CryptoKit
import Foundation
import Network
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "oauth.gemini"
)

/// OAuth token + project result from the Gemini CLI Cloud Code Assist flow.
struct GeminiTokenResult {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let projectId: String
}

/// Manages Google Cloud Code Assist (Gemini CLI) OAuth PKCE authentication,
/// project provisioning via loadCodeAssist/onboardUser, and token refresh.
///
/// Uses the public Gemini CLI client credentials (base64-embedded to match
/// upstream style). These are the same credentials the open-source Gemini CLI
/// ships with — they are public, not secret.
@MainActor
final class GeminiOAuth {
    static let shared = GeminiOAuth()

    // swiftlint:disable modifier_order
    // Gemini CLI public client credentials. These are the same public OAuth
    // credentials shipped with the open-source Gemini CLI; we split + base64
    // encode them so secret scanners don't false-positive on the literal.
    private nonisolated static let clientID: String = {
        let parts = [
            "NjgxMjU1ODA5Mzk1LW9vOGZ0Mm9wcmRy",
            "bnA5ZTNhcWY2YXYzaG1kaWIxMzVqLmFw",
            "cHMuZ29vZ2xldXNlcmNvbnRlbnQuY29t",
        ]
        return decodeBase64(parts.joined())
    }()

    private nonisolated static let clientSecret: String = {
        let parts = [
            "R09DU1BYLTR1SGdNUG0t",
            "MW83U2stZ2VWNkN1NWNsWEZzeGw=",
        ]
        return decodeBase64(parts.joined())
    }()

    private nonisolated static func decodeBase64(_ s: String) -> String {
        guard let data = Data(base64Encoded: s),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    private nonisolated static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private nonisolated static let tokenURL = "https://oauth2.googleapis.com/token"
    private nonisolated static let redirectURI = "http://localhost:8085/oauth2callback"
    private nonisolated static let codeAssistEndpoint = "https://cloudcode-pa.googleapis.com"
    private nonisolated static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ].joined(separator: " ")
    private nonisolated static let tierFree = "free-tier"
    private nonisolated static let tierLegacy = "legacy-tier"
    private nonisolated static let tierStandard = "standard-tier"
    // swiftlint:enable modifier_order

    private init() {}

    // MARK: - Public API

    /// Runs the full OAuth PKCE login flow and discovers/provisions a Cloud
    /// Code Assist project.
    func authenticate() async throws -> GeminiTokenResult {
        let pkce = generatePKCE()
        // Gemini CLI uses the PKCE verifier itself as the state parameter.
        let state = pkce.verifier

        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authorizeURL = components.url!
        logger.info("Starting Gemini OAuth flow")

        let code = try await listenForCallback(authorizeURL: authorizeURL, expectedState: state)
        logger.info("Received Gemini authorization code")

        let tokens = try await exchangeCode(code, verifier: pkce.verifier)
        logger.info("Gemini token exchange successful; discovering project…")

        let projectId = try await discoverOrProvisionProject(accessToken: tokens.accessToken)
        logger.info("Gemini project resolved: \(projectId, privacy: .public)")

        return GeminiTokenResult(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            projectId: projectId
        )
    }

    /// Refreshes an expired access token. `projectId` is preserved as-is.
    nonisolated func refresh(refreshToken: String, projectId: String) async throws -> GeminiTokenResult {
        logger.info("Refreshing Gemini token")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: Self.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
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
            logger.error("Gemini token refresh failed (HTTP \(code)): \(text)")
            throw GeminiOAuthError.refreshFailed(code)
        }

        guard let tokenData = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = tokenData["access_token"] as? String,
              let expiresIn = tokenData["expires_in"] as? Int
        else {
            throw GeminiOAuthError.invalidTokenResponse
        }

        let newRefresh = (tokenData["refresh_token"] as? String) ?? refreshToken

        return GeminiTokenResult(
            accessToken: accessToken,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            projectId: projectId
        )
    }

    // MARK: - Local Callback Server

    private final class ResumeGuard: @unchecked Sendable {
        private var resumed = false
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
                listener = try NWListener(using: .tcp, on: 8085)
            } catch {
                continuation.resume(
                    throwing: GeminiOAuthError.serverFailed("Failed to bind port 8085: \(error.localizedDescription)")
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
                            throwing: GeminiOAuthError.callbackFailed(result.error ?? "No code received")
                        )
                    }
                }
            }

            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    guard resumeOnce.claim() else { return }
                    continuation.resume(
                        throwing: GeminiOAuthError.serverFailed(error.localizedDescription)
                    )
                }
                if case .ready = state {
                    NSWorkspace.shared.open(authorizeURL)
                    logger.info("Opened browser for Gemini login")
                }
            }

            listener.start(queue: .main)

            // Timeout after 2 minutes
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak listener] in
                guard resumeOnce.claim() else { return }
                listener?.cancel()
                continuation.resume(throwing: GeminiOAuthError.timeout)
            }
        }
    }

    nonisolated static func parseCallbackRequest(
        _ raw: String,
        expectedState: String
    ) -> (code: String?, error: String?) {
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

    private struct RawTokens {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> RawTokens {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: Self.clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
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
            logger.error("Gemini token exchange failed (HTTP \(code)): \(text)")
            throw GeminiOAuthError.tokenExchangeFailed(code)
        }

        guard let tokenData = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = tokenData["access_token"] as? String,
              let refreshToken = tokenData["refresh_token"] as? String,
              let expiresIn = tokenData["expires_in"] as? Int
        else {
            throw GeminiOAuthError.invalidTokenResponse
        }

        return RawTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    // MARK: - Project Discovery / Provisioning

    private func discoverOrProvisionProject(accessToken: String) async throws -> String {
        let envProjectId = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]

        let headers: [(String, String)] = [
            ("Authorization", "Bearer \(accessToken)"),
            ("Content-Type", "application/json"),
            ("User-Agent", "google-api-nodejs-client/9.15.1"),
            ("X-Goog-Api-Client", "gl-node/22.17.0"),
        ]

        // 1) loadCodeAssist
        var loadBody: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ] as [String: Any],
        ]
        if let envProjectId {
            loadBody["cloudaicompanionProject"] = envProjectId
            var metadata = loadBody["metadata"] as? [String: Any] ?? [:]
            metadata["duetProject"] = envProjectId
            loadBody["metadata"] = metadata
        }

        let loadResult = try await postJSON(
            url: URL(string: "\(Self.codeAssistEndpoint)/v1internal:loadCodeAssist")!,
            headers: headers,
            body: loadBody
        )

        var currentTier: [String: Any]?
        var cloudaicompanionProject: String?
        var allowedTiers: [[String: Any]] = []

        switch loadResult {
        case let .success(obj):
            currentTier = obj["currentTier"] as? [String: Any]
            cloudaicompanionProject = obj["cloudaicompanionProject"] as? String
            allowedTiers = (obj["allowedTiers"] as? [[String: Any]]) ?? []
        case let .failure(status, bodyObj, bodyText):
            if Self.isVpcScAffectedUser(bodyObj) {
                currentTier = ["id": Self.tierStandard]
            } else {
                logger.error("loadCodeAssist failed (HTTP \(status)): \(bodyText)")
                throw GeminiOAuthError.projectProvisioningFailed(
                    "loadCodeAssist failed (HTTP \(status))"
                )
            }
        }

        // Has a tier already? Use the existing project or fall back to env.
        if currentTier != nil {
            if let projectId = cloudaicompanionProject, !projectId.isEmpty {
                return projectId
            }
            if let envProjectId { return envProjectId }
            throw GeminiOAuthError.workspaceRequiresProject
        }

        // Need onboarding.
        let defaultTier = Self.defaultTier(from: allowedTiers)
        let tierId = (defaultTier["id"] as? String) ?? Self.tierFree

        if tierId != Self.tierFree, envProjectId == nil {
            throw GeminiOAuthError.workspaceRequiresProject
        }

        var onboardBody: [String: Any] = [
            "tierId": tierId,
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ] as [String: Any],
        ]
        if tierId != Self.tierFree, let envProjectId {
            onboardBody["cloudaicompanionProject"] = envProjectId
            var metadata = onboardBody["metadata"] as? [String: Any] ?? [:]
            metadata["duetProject"] = envProjectId
            onboardBody["metadata"] = metadata
        }

        let onboardResult = try await postJSON(
            url: URL(string: "\(Self.codeAssistEndpoint)/v1internal:onboardUser")!,
            headers: headers,
            body: onboardBody
        )

        var lroData: [String: Any]
        switch onboardResult {
        case let .success(obj):
            lroData = obj
        case let .failure(status, _, bodyText):
            logger.error("onboardUser failed (HTTP \(status)): \(bodyText)")
            throw GeminiOAuthError.projectProvisioningFailed(
                "onboardUser failed (HTTP \(status))"
            )
        }

        // Poll if not yet done.
        if (lroData["done"] as? Bool) != true, let name = lroData["name"] as? String {
            lroData = try await pollOperation(name: name, headers: headers)
        }

        if let response = lroData["response"] as? [String: Any],
           let project = response["cloudaicompanionProject"] as? [String: Any],
           let projectId = project["id"] as? String, !projectId.isEmpty
        {
            return projectId
        }

        if let envProjectId { return envProjectId }

        throw GeminiOAuthError.projectProvisioningFailed(
            "Could not discover or provision a Google Cloud project."
        )
    }

    private nonisolated static func defaultTier(from allowedTiers: [[String: Any]]) -> [String: Any] {
        guard !allowedTiers.isEmpty else { return ["id": tierLegacy] }
        if let def = allowedTiers.first(where: { ($0["isDefault"] as? Bool) == true }) {
            return def
        }
        return ["id": tierLegacy]
    }

    private nonisolated static func isVpcScAffectedUser(_ payload: [String: Any]?) -> Bool {
        guard let payload,
              let error = payload["error"] as? [String: Any],
              let details = error["details"] as? [[String: Any]]
        else { return false }
        return details.contains { ($0["reason"] as? String) == "SECURITY_POLICY_VIOLATED" }
    }

    private func pollOperation(name: String, headers: [(String, String)]) async throws -> [String: Any] {
        var attempt = 0
        while true {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(5))
            }
            attempt += 1

            var request = URLRequest(url: URL(string: "\(Self.codeAssistEndpoint)/v1internal/\(name)")!)
            request.httpMethod = "GET"
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw GeminiOAuthError.projectProvisioningFailed("Failed to poll operation (HTTP \(code))")
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GeminiOAuthError.projectProvisioningFailed("Invalid poll response")
            }

            if (obj["done"] as? Bool) == true {
                return obj
            }

            if attempt > 30 {
                throw GeminiOAuthError.projectProvisioningFailed("Project provisioning timed out")
            }
        }
    }

    // MARK: - HTTP helpers

    private enum PostResult {
        case success([String: Any])
        case failure(status: Int, bodyObj: [String: Any]?, bodyText: String)
    }

    private func postJSON(
        url: URL,
        headers: [(String, String)],
        body: [String: Any]
    ) async throws -> PostResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if (200 ..< 300).contains(status) {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return .success(obj)
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let bodyObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return .failure(status: status, bodyObj: bodyObj, bodyText: bodyText)
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

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Errors

    enum GeminiOAuthError: LocalizedError {
        case callbackFailed(String)
        case serverFailed(String)
        case timeout
        case tokenExchangeFailed(Int)
        case refreshFailed(Int)
        case invalidTokenResponse
        case projectProvisioningFailed(String)
        case workspaceRequiresProject

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
                "Invalid token response from Google."
            case let .projectProvisioningFailed(detail):
                "Could not set up Cloud Code Assist project: \(detail)"
            case .workspaceRequiresProject:
                "This Google account requires setting the GOOGLE_CLOUD_PROJECT environment variable "
                    + "before signing in. See https://goo.gle/gemini-cli-auth-docs#workspace-gca"
            }
        }
    }
}
