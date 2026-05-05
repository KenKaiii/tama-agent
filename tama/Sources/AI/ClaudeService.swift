import Foundation
import os

// MARK: - Anthropic Constants

/// Versioned constants for the Anthropic Claude Code OAuth path.
///
/// **These need periodic review** against Anthropic's changelog:
/// - `anthropic-beta` flags expire when the feature graduates to GA or is renamed.
/// - `cliVersion` should track the upstream `claude-cli` release that the OAuth
///   app was registered against — an outdated value may trigger auth rejections.
///
/// Docs: https://docs.anthropic.com/en/api/versioning
///       https://docs.anthropic.com/en/api/beta-features
enum AnthropicConstants {
    /// User-Agent sent with Claude Code OAuth requests.
    /// Review when Anthropic releases a new CLI version.
    static let cliUserAgent = "claude-cli/2.1.75"

    /// Beta feature flags joined into the `anthropic-beta` header.
    /// Remove or replace flags once they graduate to stable or are superseded.
    static let betaFlags: [String] = [
        "claude-code-20250219", // Claude Code tool-use capability
        "oauth-2025-04-20", // OAuth token auth scheme
        "fine-grained-tool-streaming-2025-05-14", // Per-tool streaming events
        "interleaved-thinking-2025-05-14", // Interleaved extended thinking
    ]

    /// Comma-separated `anthropic-beta` header value derived from `betaFlags`.
    static let betaHeader = betaFlags.joined(separator: ",")
}

/// Singleton service for calling AI APIs. Supports Anthropic (Claude) and
/// OpenAI-compatible providers via ProviderStore.
@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let logger = Logger(
        subsystem: "com.unstablemind.tama",
        category: "claude"
    )

    /// Dedicated session with resource timeout so streaming connections
    /// don't hang forever on network issues (default is 7 days).
    private let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    var isLoggedIn: Bool { ProviderStore.shared.hasAnyCredentials }

    private init() {}

    /// The currently selected model from ProviderStore.
    var currentModel: ModelInfo {
        ProviderStore.shared.selectedModel
    }

    // MARK: - Connection Pre-Warming

    /// Opens a TCP+TLS connection to the provider's base URL so the first real
    /// streaming request doesn't pay TLS handshake + DNS lookup latency. Fire
    /// this when the user starts a voice call — the first user turn will then
    /// reuse the warm socket from `streamingSession`'s connection pool.
    ///
    /// Fire-and-forget; any error is harmless because the real request will
    /// try again from scratch.
    func prewarmConnection(for provider: AIProvider) {
        guard let host = URL(string: provider.baseURL)?.host,
              let warmURL = URL(string: "https://\(host)/")
        else { return }
        logger.info("Pre-warming connection to \(host, privacy: .public)")
        var request = URLRequest(url: warmURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        // Use the SAME streamingSession as real requests so the connection
        // lands in the right pool. Response status doesn't matter — a 404 on
        // `/` is fine, we only need the TLS handshake to complete.
        let session = streamingSession
        Task.detached(priority: .utility) {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try? await session.data(for: request)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let logger = Logger(subsystem: "com.unstablemind.tama", category: "claude")
            if result == nil {
                logger.debug("Connection pre-warm to \(host, privacy: .public) completed in \(ms)ms (error ignored)")
            } else {
                logger.info("Connection pre-warmed to \(host, privacy: .public) in \(ms)ms")
            }
        }
    }

    // MARK: - API

    /// Maximum retries for rate-limit (429) errors before giving up.
    private static let maxRetries = 3

    /// Base delay (seconds) for exponential backoff on 429 errors.
    private static let baseRetryDelay: UInt64 = 2

    /// Sends a conversation with tool definitions and streams events back.
    /// Automatically retries on 429 (rate limit) errors with exponential backoff.
    func sendWithTools(
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String? = nil,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let model = currentModel
        let provider = model.provider.displayName
        logger.info(
            "sendWithTools — model: \(model.id), provider: \(provider), msgs: \(messages.count), tools: \(tools.count)"
        )

        for attempt in 0 ... Self.maxRetries {
            try Task.checkCancellation()

            do {
                return try await sendOnce(
                    model: model,
                    messages: messages,
                    tools: tools,
                    systemPrompt: systemPrompt,
                    useBasePrompt: useBasePrompt,
                    maxTokens: maxTokens,
                    onEvent: onEvent
                )
            } catch let error as ClaudeServiceError {
                if case let .apiError(statusCode, body) = error,
                   statusCode == 429,
                   attempt < Self.maxRetries,
                   !Self.isHardUsageLimit(body)
                {
                    let delay = Self.baseRetryDelay * (1 << UInt64(attempt)) // 2s, 4s, 8s
                    let total = Self.maxRetries + 1
                    let cur = attempt + 1
                    logger.warning(
                        "Rate limited (429) attempt \(cur)/\(total) — retry in \(delay)s"
                    )
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            }
        }

        // Should not reach here, but satisfy the compiler
        throw ClaudeServiceError.apiError(statusCode: 429, body: "Rate limited after \(Self.maxRetries + 1) attempts")
    }

    /// Returns true if the 429 response body indicates a hard usage cap
    /// (e.g. OpenAI free-tier limit) that won't resolve with retries.
    private static func isHardUsageLimit(_ body: String) -> Bool {
        let lower = body.lowercased()
        if lower.contains("usage_limit_reached") || lower.contains("usage limit") {
            return true
        }
        // Gemini free-tier daily cap: RESOURCE_EXHAUSTED with a retryDelay
        // longer than our retry budget (~14s max) means we won't recover via retry.
        if lower.contains("resource_exhausted"), lower.contains("quota") {
            return true
        }
        return false
    }

    /// Sends a single request without retries.
    private func sendOnce(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        if model.provider.usesGeminiAPI {
            return try await streamGeminiRequest(
                model: model,
                messages: messages,
                tools: tools,
                systemPrompt: systemPrompt,
                useBasePrompt: useBasePrompt,
                onEvent: onEvent
            )
        }

        if model.provider.usesCodexAPI {
            return try await streamCodexRequest(
                model: model,
                messages: messages,
                tools: tools,
                systemPrompt: systemPrompt,
                useBasePrompt: useBasePrompt,
                onEvent: onEvent
            )
        }

        if model.provider.usesAnthropicAPI {
            return try await streamAnthropicRequest(
                model: model,
                messages: messages,
                tools: tools,
                systemPrompt: systemPrompt,
                useBasePrompt: useBasePrompt,
                maxTokens: maxTokens,
                onEvent: onEvent
            )
        }

        return try await streamOpenAIRequest(
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt,
            useBasePrompt: useBasePrompt,
            maxTokens: maxTokens,
            onEvent: onEvent
        )
    }

    // MARK: - Dynamic Context

    /// Static context included in the cached system-prompt prefix. Skills
    /// change rarely and platform is constant — keeping them here lets the
    /// Anthropic prompt cache hit across turns.
    private func staticContext() -> String {
        let skillsContext = SkillStore.shared.formatForPrompt()
        return """
        [environment]
        platform: macOS

        \(skillsContext)
        """
    }

    /// Time-varying context that must NOT be cached. Kept as the final system
    /// block so the cached prefix ends before this content.
    private func dynamicTimestamp() -> String {
        let now = Date()
        let dateStr = now.formatted(
            .dateTime.weekday(.wide).month(.wide).day().year()
        )
        let timeStr = now.formatted(.dateTime.hour().minute())
        let tz = TimeZone.current

        let seconds = tz.secondsFromGMT()
        let h = abs(seconds) / 3600
        let m = (abs(seconds) % 3600) / 60
        let sign = seconds >= 0 ? "+" : "-"
        let offsetString = m == 0
            ? "\(sign)\(h)"
            : String(format: "%@%d:%02d", sign, h, m)

        return """
        [now]
        date: \(dateStr)
        time: \(timeStr)
        timezone: \(tz.identifier) (UTC\(offsetString))
        """
    }

    /// Combined context for providers that don't support prompt caching —
    /// OpenAI-compatible, Gemini, Codex. Anthropic uses the split variants above.
    private func dynamicContext() -> String {
        """
        \(staticContext())

        \(dynamicTimestamp())
        """
    }

    // MARK: - Codex Streaming (OpenAI)

    private func streamCodexRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        guard let accountId = ProviderStore.shared.credential(for: model.provider)?.accountId else {
            throw ClaudeServiceError.notLoggedIn
        }

        // Build system prompt with dynamic context
        var fullSystemPrompt = useBasePrompt ? baseSystemPrompt : ""
        if let extra = systemPrompt {
            if !fullSystemPrompt.isEmpty { fullSystemPrompt += "\n\n" }
            fullSystemPrompt += extra
        }
        if !fullSystemPrompt.isEmpty { fullSystemPrompt += "\n\n" }
        fullSystemPrompt += dynamicContext()

        let request = try CodexRequestBuilder.buildRequest(
            token: token,
            accountId: accountId,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: fullSystemPrompt
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("Codex API failed — HTTP \(code, privacy: .public): \(body, privacy: .public)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = CodexStreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    // MARK: - Gemini (Cloud Code Assist) Streaming

    private func streamGeminiRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        guard let projectId = ProviderStore.shared.credential(for: model.provider)?.accountId,
              !projectId.isEmpty
        else {
            throw ClaudeServiceError.notLoggedIn
        }

        // Build system prompt with dynamic context
        var fullSystemPrompt = useBasePrompt ? baseSystemPrompt : ""
        if let extra = systemPrompt {
            if !fullSystemPrompt.isEmpty { fullSystemPrompt += "\n\n" }
            fullSystemPrompt += extra
        }
        if !fullSystemPrompt.isEmpty { fullSystemPrompt += "\n\n" }
        fullSystemPrompt += dynamicContext()

        let request = try GeminiRequestBuilder.buildRequest(
            token: token,
            projectId: projectId,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: fullSystemPrompt
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 8192 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("Gemini API failed — HTTP \(code, privacy: .public): \(body, privacy: .public)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = GeminiStreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    // MARK: - Anthropic-Compatible Streaming (MiniMax)

    private func streamAnthropicRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        let request = try buildAnthropicRequest(
            token: token,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt,
            useBasePrompt: useBasePrompt,
            maxTokens: maxTokens
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("Anthropic API failed — HTTP \(code, privacy: .public): \(body, privacy: .public)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = StreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    private func buildAnthropicRequest(
        token: String,
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil
    ) throws -> URLRequest {
        let url = URL(string: model.provider.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let isAnthropicOAuth = model.provider == .anthropic

        if isAnthropicOAuth {
            // Claude Code OAuth: bearer auth + beta headers + CLI identity.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AnthropicConstants.cliUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue(AnthropicConstants.betaHeader, forHTTPHeaderField: "anthropic-beta")
        } else {
            // MiniMax and other Anthropic-compatible providers: API-key auth.
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue("tama/1.0", forHTTPHeaderField: "User-Agent")
        }

        // Build the static (cacheable) system prompt — base + extra + skills.
        // Date/time goes in a separate uncached block so cache stays warm.
        var staticPrompt = useBasePrompt ? baseSystemPrompt : ""
        if let extra = systemPrompt {
            if !staticPrompt.isEmpty { staticPrompt += "\n\n" }
            staticPrompt += extra
        }
        if !staticPrompt.isEmpty { staticPrompt += "\n\n" }
        staticPrompt += staticContext()

        // Anthropic system blocks: [identity?, static-with-cache, dynamic].
        // `cache_control` on the last static block caches the prefix up to and
        // including it (tools + prior system blocks + this block). The dynamic
        // timestamp block that follows is deliberately uncached so it can
        // refresh each turn without invalidating the prefix.
        var systemBlocks: [[String: Any]] = []
        if isAnthropicOAuth {
            systemBlocks.append([
                "type": "text",
                "text": "You are Claude Code, Anthropic's official CLI for Claude.",
            ])
        }
        systemBlocks.append([
            "type": "text",
            "text": staticPrompt,
            "cache_control": ["type": "ephemeral"],
        ])
        systemBlocks.append([
            "type": "text",
            "text": dynamicTimestamp(),
        ])

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maxTokens ?? model.maxOutputTokens,
            "stream": true,
            "system": systemBlocks,
            "messages": messages,
            "temperature": 1.0,
        ]

        // Add tools if present (Anthropic native format — no conversion needed)
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }

        // Note: thinking/reasoning is omitted entirely (not disabled) — MiniMax
        // treats an absent field as "no thinking", matching real-world usage.

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - OpenAI-Compatible Streaming (Moonshot/Xiaomi)

    private func streamOpenAIRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        let request = try buildOpenAIRequest(
            token: token,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt,
            useBasePrompt: useBasePrompt,
            maxTokens: maxTokens
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("OpenAI API failed — HTTP \(code, privacy: .public): \(body, privacy: .public)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = OpenAIStreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    private func buildOpenAIRequest(
        token: String,
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        systemPrompt: String?,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil
    ) throws -> URLRequest {
        var baseURL = model.provider.baseURL
        // Xiaomi Token Plan needs /chat/completions appended
        if model.provider == .xiaomi {
            baseURL += "/chat/completions"
        }
        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("tama/1.0", forHTTPHeaderField: "User-Agent")

        // Build system message content
        var systemContent = useBasePrompt ? baseSystemPrompt : ""
        if let extra = systemPrompt {
            if !systemContent.isEmpty { systemContent += "\n\n" }
            systemContent += extra
        }
        if !systemContent.isEmpty { systemContent += "\n\n" }
        systemContent += dynamicContext()

        // OpenAI format: system message as first message in array
        var openAIMessages: [[String: Any]] = [
            ["role": "system", "content": systemContent],
        ]

        // Convert Anthropic-format messages to OpenAI format
        for msg in messages {
            openAIMessages.append(contentsOf: convertMessageToOpenAI(msg))
        }

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maxTokens ?? model.maxOutputTokens,
            "stream": true,
            "messages": openAIMessages,
        ]

        // Convert tools from Anthropic format to OpenAI function calling format
        if let tools, !tools.isEmpty {
            let openAITools: [[String: Any]] = tools.compactMap { convertToolToOpenAI($0) }
            body["tools"] = openAITools
        }

        // All providers: disable thinking to avoid latency. When adding new providers,
        // ensure thinking stays disabled unless explicitly opted in by the user.
        if model.provider.usesCustomThinkingParam {
            // Moonshot/Xiaomi use a custom "thinking" body parameter
            body["thinking"] = ["type": "disabled"]
        } else if model.provider == .openai {
            // OpenAI uses "reasoning_effort" to control thinking
            body["reasoning_effort"] = "none"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        return request
    }

    // MARK: - Format Conversion

    /// Convert an Anthropic-format message to OpenAI format.
    /// Returns an array because one Anthropic message (with multiple tool_results)
    /// may expand into multiple OpenAI messages.
    /// Internal so the test suite can exercise format conversion directly.
    func convertMessageToOpenAI(_ msg: [String: Any]) -> [[String: Any]] {
        guard let role = msg["role"] as? String else { return [msg] }

        // Simple string content
        if let content = msg["content"] as? String {
            return [["role": role, "content": content]]
        }

        // Array content (Anthropic uses content arrays for tool results)
        guard let blocks = msg["content"] as? [[String: Any]] else { return [msg] }

        // For assistant messages with tool_use blocks
        if role == "assistant" {
            var content = ""
            var toolCalls: [[String: Any]] = []

            for block in blocks {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    content += text
                } else if type == "tool_use",
                          let id = block["id"] as? String,
                          let name = block["name"] as? String,
                          let input = block["input"]
                {
                    let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                    let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": argsStr,
                        ],
                    ])
                }
            }

            var result: [String: Any] = ["role": "assistant"]
            if !content.isEmpty { result["content"] = content }
            if !toolCalls.isEmpty { result["tool_calls"] = toolCalls }
            // Round-trip reasoning_content if present (for providers with thinking)
            if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty {
                result["reasoning_content"] = reasoning
            }
            return [result]
        }

        // For user messages with tool_result blocks — each becomes a separate message.
        // For user messages mixing text and image blocks (vision input), emit a
        // single user message with array content.
        if role == "user" {
            var converted: [[String: Any]] = []
            var pendingMixed: [[String: Any]] = []

            func flushPending() {
                guard !pendingMixed.isEmpty else { return }
                converted.append(["role": "user", "content": pendingMixed])
                pendingMixed = []
            }

            for block in blocks {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    pendingMixed.append(["type": "text", "text": text])
                } else if type == "image",
                          let source = block["source"] as? [String: Any],
                          let mediaType = source["media_type"] as? String,
                          let data = source["data"] as? String
                {
                    pendingMixed.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(data)"],
                    ])
                } else if type == "tool_result",
                          let toolUseId = block["tool_use_id"] as? String
                {
                    flushPending()
                    converted.append(contentsOf: convertToolResultToOpenAI(
                        toolUseId: toolUseId,
                        content: block["content"]
                    ))
                }
            }
            flushPending()
            if !converted.isEmpty { return converted }
        }

        return [msg]
    }

    /// Convert an Anthropic `tool_result` block's content to an OpenAI
    /// `role:"tool"` message, plus an optional follow-up `role:"user"` message
    /// carrying any image blocks as `image_url` data URLs (Moonshot/Xiaomi
    /// vision format). Tool_results may have either string content or an array
    /// of typed blocks.
    func convertToolResultToOpenAI(toolUseId: String, content: Any?) -> [[String: Any]] {
        // Simple string content: emit a single tool message.
        if let str = content as? String {
            return [[
                "role": "tool",
                "tool_call_id": toolUseId,
                "content": str,
            ]]
        }

        guard let parts = content as? [[String: Any]] else {
            return []
        }

        var textParts: [String] = []
        var imageParts: [[String: Any]] = []

        for part in parts {
            guard let type = part["type"] as? String else { continue }
            if type == "text", let text = part["text"] as? String {
                textParts.append(text)
            } else if type == "image",
                      let source = part["source"] as? [String: Any],
                      let mediaType = source["media_type"] as? String,
                      let data = source["data"] as? String
            {
                imageParts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(data)"],
                ])
            }
        }

        var result: [[String: Any]] = []
        let toolText = textParts.isEmpty ? "" : textParts.joined(separator: "\n")
        result.append([
            "role": "tool",
            "tool_call_id": toolUseId,
            "content": toolText,
        ])

        if !imageParts.isEmpty {
            var userContent: [[String: Any]] = [[
                "type": "text",
                "text": "Screenshot attached from the previous tool call.",
            ]]
            userContent.append(contentsOf: imageParts)
            result.append([
                "role": "user",
                "content": userContent,
            ])
        }

        return result
    }

    /// Convert an Anthropic tool definition to OpenAI function calling format.
    private func convertToolToOpenAI(_ tool: [String: Any]) -> [String: Any]? {
        guard let name = tool["name"] as? String else { return nil }

        var function: [String: Any] = ["name": name]
        if let desc = tool["description"] as? String {
            function["description"] = desc
        }
        if let schema = tool["input_schema"] as? [String: Any] {
            function["parameters"] = schema
        }

        return [
            "type": "function",
            "function": function,
        ]
    }

    // MARK: - Errors

    enum ClaudeServiceError: LocalizedError {
        case notLoggedIn
        case apiError(statusCode: Int, body: String)
        case streamError(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                "Not logged in. Add an API key in Settings."
            case let .apiError(statusCode, body):
                "API error (HTTP \(statusCode)): \(body)"
            case let .streamError(message):
                "Stream error: \(message)"
            }
        }
    }
}
