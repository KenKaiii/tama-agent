import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.web"
)

/// Agent tool that fetches and reads content from a URL.
final class WebFetchTool: AgentTool {
    let name = "web_fetch"

    let description =
        "Fetch and read content from a URL. Returns text content with HTML tags stripped."

    /// Maximum response body size (10 MB).
    private static let maxResponseBytes = 10 * 1024 * 1024

    /// Shared session with redirect delegate — reused across calls.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: SafeRedirectDelegate.shared, delegateQueue: nil)
    }()

    init() {}

    // MARK: - Input Schema

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The URL to fetch",
                ],
                "max_length": [
                    "type": "number",
                    "description":
                        "Maximum number of characters to return (default: 10000)",
                ],
            ],
            "required": ["url"],
        ]
    }

    // MARK: - Execution

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let urlString = args["url"] as? String else {
            throw WebFetchError.missingURL
        }

        let maxLength = (args["max_length"] as? NSNumber)?.intValue ?? 10000
        logger.info("Fetching URL: \(urlString, privacy: .public), maxLength: \(maxLength)")

        guard let url = URL(string: urlString) else {
            logger.error("Invalid URL: \(urlString, privacy: .public)")
            throw WebFetchError.invalidURL(urlString)
        }

        // Only allow http and https schemes.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            logger.error("Blocked scheme for URL: \(urlString, privacy: .public)")
            throw WebFetchError.invalidURL(urlString)
        }

        // SSRF protection — block private/local addresses.
        do {
            try validateHost(url)
        } catch {
            logger.error("Blocked host for URL: \(urlString, privacy: .public)")
            throw error
        }

        // Stream the response with a byte limit to avoid unbounded memory usage.
        let request = URLRequest(url: url)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error \(httpResponse.statusCode) for URL: \(urlString, privacy: .public)")
            return ToolOutput(text: "HTTP error: \(httpResponse.statusCode)")
        }

        // Read incrementally up to maxResponseBytes.
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= Self.maxResponseBytes {
                logger.warning("Response exceeded \(Self.maxResponseBytes) byte limit, truncating")
                break
            }
        }

        guard var text = String(data: collected, encoding: .utf8) else {
            throw WebFetchError.requestFailed(
                "Unable to decode response as UTF-8"
            )
        }

        text = Self.extractReadableText(from: text)

        // Truncate if needed.
        if text.count > maxLength {
            let truncated = String(text.prefix(maxLength))
            logger.info("Fetch complete: \(text.count) chars, truncated=true")
            return ToolOutput(text: truncated + "\n[...truncated at \(maxLength) chars]")
        }

        logger.info("Fetch complete: \(text.count) chars, truncated=false")
        return ToolOutput(text: text)
    }

    // MARK: - Content Extraction

    /// Extracts readable text from raw HTML by removing scripts, styles,
    /// navigation elements, and other non-content blocks before stripping tags.
    private static func extractReadableText(from html: String) -> String {
        var text = html

        // Remove entire <script>...</script> blocks (including content).
        text = text.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove entire <style>...</style> blocks.
        text = text.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove <noscript> blocks (usually fallback content, not useful).
        text = text.replacingOccurrences(
            of: "<noscript[^>]*>[\\s\\S]*?</noscript>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove <nav>, <header>, <footer> blocks — typically boilerplate.
        for tag in ["nav", "header", "footer"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Remove SVG blocks.
        text = text.replacingOccurrences(
            of: "<svg[^>]*>[\\s\\S]*?</svg>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove HTML comments.
        text = text.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )

        // Strip remaining HTML tags.
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode common HTML entities.
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&#x27;", "'"), ("&#x2F;", "/"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&laquo;", "«"), ("&raquo;", "»"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Decode numeric HTML entities (&#123; and &#x1F; forms).
        // swiftlint:disable:next force_try
        let numericEntity = try! NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
        text = numericEntity.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )

        // Collapse runs of whitespace on each line.
        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        // Collapse 3+ newlines into double newline.
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SSRF Protection

    /// Validates that the URL host is not a private or local address.
    private func validateHost(_ url: URL) throws {
        guard let host = url.host?.lowercased() else {
            throw WebFetchError.invalidURL(url.absoluteString)
        }

        let blockedHosts: Set<String> = [
            "localhost", "0.0.0.0",
        ]
        if blockedHosts.contains(host) {
            throw WebFetchError.blockedHost(host)
        }

        // Normalize the host via getaddrinfo so that non-standard representations
        // (decimal integer, hex, octal, IPv6-mapped) are canonicalized before the
        // pattern checks run.  This defeats forms like http://2130706433,
        // http://0x7f000001, http://017700000001, and http://[::ffff:7f00:1].
        let checkHost = Self.normalizeHost(host) ?? host

        if Self.isPrivateIPv4(checkHost) || Self.isPrivateIPv6(checkHost) {
            throw WebFetchError.blockedHost(host)
        }

        // Also resolve DNS to catch hostnames that point to private IPs
        // (DNS rebinding defense).  normalizeHost already resolves numeric forms,
        // so this path handles real hostnames.
        if Self.resolvesToPrivateIP(host) {
            throw WebFetchError.blockedHost(host)
        }
    }

    /// Normalizes a host string to its canonical IP representation using getaddrinfo.
    /// Returns `nil` if the host cannot be resolved (e.g. a real DNS hostname — let
    /// `resolvesToPrivateIP` handle those).
    /// Handles: dotted-decimal, decimal integer, hex (0x…), octal (0…), IPv6 including
    /// IPv4-mapped forms like `::ffff:7f00:1`.
    private static func normalizeHost(_ host: String) -> String? {
        // Strip brackets from bare IPv6 addresses (URL.host already strips them,
        // but guard against direct calls with bracketed strings).
        let stripped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        // AI_NUMERICHOST tells getaddrinfo to interpret the string as a numeric address
        // and NOT perform DNS lookup — this is exactly what we want for normalizing
        // integer/hex/octal literals and IPv6-mapped forms without touching the network.
        hints.ai_flags = AI_NUMERICHOST

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(stripped, nil, &hints, &result)
        guard status == 0, let head = result else {
            // Not a numeric address literal — leave as-is for DNS resolution later.
            return nil
        }
        defer { freeaddrinfo(head) }

        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if head.pointee.ai_family == AF_INET {
            var sa = head.pointee.ai_addr
                .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
        } else if head.pointee.ai_family == AF_INET6 {
            var sa = head.pointee.ai_addr
                .withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET6, &sa.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
        } else {
            return nil
        }
        let canonical = String(cString: buf)
        return canonical.isEmpty ? nil : canonical
    }

    /// Resolves a hostname via DNS and returns true if ANY resolved IP is private/reserved.
    private static func resolvesToPrivateIP(_ hostname: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let addrList = result else { return false }
        defer { freeaddrinfo(addrList) }

        var current: UnsafeMutablePointer<addrinfo>? = addrList
        while let addr = current {
            if addr.pointee.ai_family == AF_INET {
                var sa = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ipBytes = withUnsafeBytes(of: &sa.sin_addr) { Array($0) }
                let ipString = ipBytes.map { String($0) }.joined(separator: ".")
                if isPrivateIPv4(ipString) { return true }
            } else if addr.pointee.ai_family == AF_INET6 {
                var sa = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &sa.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                let ipString = String(cString: buf)
                if isPrivateIPv6(ipString) { return true }
            }
            current = addr.pointee.ai_next
        }
        return false
    }

    /// Returns true if the given string is an IPv4 address in a private/reserved range.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        // 127.0.0.0/8 — full loopback range
        if parts[0] == 127 {
            return true
        }

        // 10.0.0.0/8
        if parts[0] == 10 {
            return true
        }

        // 172.16.0.0/12
        if parts[0] == 172, (16 ... 31).contains(parts[1]) {
            return true
        }

        // 192.168.0.0/16
        if parts[0] == 192, parts[1] == 168 {
            return true
        }

        // 169.254.0.0/16 — link-local
        if parts[0] == 169, parts[1] == 254 {
            return true
        }

        // 100.64.0.0/10 — Carrier-Grade NAT (CGNAT) / shared address space
        if parts[0] == 100, (64 ... 127).contains(parts[1]) {
            return true
        }

        // 0.0.0.0/8
        if parts[0] == 0 {
            return true
        }

        return false
    }

    /// Returns true if the given string is an IPv6 address in a private/reserved range.
    private static func isPrivateIPv6(_ host: String) -> Bool {
        // Strip brackets if present (e.g. from URL host)
        let cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // ::1 loopback
        if cleaned == "::1" {
            return true
        }

        // IPv4-mapped IPv6 (::ffff:x.x.x.x)
        let lowerCleaned = cleaned.lowercased()
        if lowerCleaned.hasPrefix("::ffff:") {
            let ipv4Part = String(lowerCleaned.dropFirst(7))
            return isPrivateIPv4(ipv4Part)
        }

        // Expand to check prefix-based ranges
        let expanded = expandIPv6(lowerCleaned)
        guard !expanded.isEmpty else { return false }

        // fe80::/10 — link-local
        if expanded.hasPrefix("fe8") || expanded.hasPrefix("fe9") ||
            expanded.hasPrefix("fea") || expanded.hasPrefix("feb")
        {
            return true
        }

        // fc00::/7 — unique local addresses
        if expanded.hasPrefix("fc") || expanded.hasPrefix("fd") {
            return true
        }

        return false
    }

    /// Minimal IPv6 expansion — returns the full lowercased hex string (no colons) or empty on parse failure.
    private static func expandIPv6(_ addr: String) -> String {
        var parts = addr.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        // Handle :: expansion
        if let emptyIdx = parts.firstIndex(where: { $0.isEmpty }) {
            // Count existing non-empty groups
            let nonEmpty = parts.filter { !$0.isEmpty }
            let missing = 8 - nonEmpty.count
            if missing > 0 {
                var expanded: [String] = []
                for (i, part) in parts.enumerated() {
                    if part.isEmpty, i == emptyIdx {
                        for _ in 0 ..< missing {
                            expanded.append("0000")
                        }
                    } else if !part.isEmpty {
                        expanded.append(part)
                    }
                }
                parts = expanded
            }
        }

        guard parts.count == 8 else { return "" }

        return parts.map { group in
            let padded = String(repeating: "0", count: max(0, 4 - group.count)) + group
            return padded.suffix(4).lowercased()
        }.joined()
    }

    /// Validates a redirect target URL against the same SSRF rules.
    static func isAllowedRedirectTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }

        guard let host = url.host?.lowercased() else { return false }

        let blockedHosts: Set<String> = ["localhost", "0.0.0.0"]
        if blockedHosts.contains(host) { return false }

        // Normalize non-standard numeric forms before pattern checks.
        let checkHost = normalizeHost(host) ?? host
        if isPrivateIPv4(checkHost) || isPrivateIPv6(checkHost) { return false }

        // DNS resolution check for rebinding defense.
        if resolvesToPrivateIP(host) { return false }

        return true
    }
}

// MARK: - Safe Redirect Delegate

/// URLSession delegate that validates redirect targets against SSRF rules.
private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SafeRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, WebFetchTool.isAllowedRedirectTarget(url) else {
            logger.warning("Blocked redirect to: \(request.url?.absoluteString ?? "nil", privacy: .public)")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - Errors

enum WebFetchError: LocalizedError {
    case missingURL
    case invalidURL(String)
    case blockedHost(String)
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "Missing required parameter: url"
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        case let .blockedHost(host):
            "Blocked host: \(host) — requests to private/local addresses are not allowed"
        case let .requestFailed(reason):
            "Request failed: \(reason)"
        case .invalidResponse:
            "Invalid response from server"
        }
    }
}
