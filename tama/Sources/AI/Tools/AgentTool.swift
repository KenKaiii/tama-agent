import Foundation

/// Shared helpers for file-system-based tools (path resolution, binary detection, directory filtering).
enum FileSystemToolHelpers {
    // MARK: - Errors

    enum ConfinementError: LocalizedError {
        case outsideWorkingDirectory(resolved: String, workingDirectory: String)

        var errorDescription: String? {
            switch self {
            case let .outsideWorkingDirectory(resolved, wd):
                "Path '\(resolved)' is outside the working directory '\(wd)'. "
                    + "Access to paths outside the working directory is not permitted."
            }
        }
    }

    // MARK: - Path resolution

    /// Resolves a possibly-relative or `~`-prefixed path against the given working directory,
    /// then verifies the canonical result is confined to that directory.
    /// Throws `ConfinementError.outsideWorkingDirectory` if the resolved path escapes.
    static func resolvePath(_ path: String, workingDirectory: String) throws -> String {
        // Expand `~` or `~/…` — these must resolve inside the working directory to be allowed.
        let expanded: String = if path == "~" || path.hasPrefix("~/") || path.hasPrefix("~\\") {
            (path as NSString).expandingTildeInPath
        } else if path.hasPrefix("/") {
            path
        } else {
            (workingDirectory as NSString).appendingPathComponent(path)
        }

        // Canonicalize both paths to resolve any `..`, `.`, or symlink components.
        // Use `standardizingPath` (pure lexical) first so that non-existent paths
        // (e.g. a new file about to be written) still get `..` collapsed correctly,
        // then overlay with `resolvingSymlinksInPath` for paths that do exist.
        let fm = FileManager.default
        let standardized = (expanded as NSString).standardizingPath
        let canonicalExpanded: String = if fm.fileExists(atPath: standardized) {
            (standardized as NSString).resolvingSymlinksInPath
        } else {
            standardized
        }

        let standardizedWD = (workingDirectory as NSString).standardizingPath
        let canonicalWD: String = if fm.fileExists(atPath: standardizedWD) {
            (standardizedWD as NSString).resolvingSymlinksInPath
        } else {
            standardizedWD
        }

        // The resolved path must be exactly the working directory or a descendant of it.
        let confinedPrefix = canonicalWD.hasSuffix("/") ? canonicalWD : canonicalWD + "/"
        guard canonicalExpanded == canonicalWD || canonicalExpanded.hasPrefix(confinedPrefix) else {
            throw ConfinementError.outsideWorkingDirectory(
                resolved: canonicalExpanded,
                workingDirectory: canonicalWD
            )
        }

        return canonicalExpanded
    }

    /// File extensions treated as binary (skipped by read/grep).
    static let binaryExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "ico", "webp", "svg",
        "mp3", "mp4", "avi", "mov", "mkv", "wav", "flac",
        "pdf", "zip", "tar", "gz", "bz2", "7z", "rar",
        "exe", "dll", "dylib", "so", "o", "a",
        "class", "jar", "pyc", "wasm",
        "ttf", "otf", "woff", "woff2", "eot",
        "sqlite", "db",
    ]

    /// Directories that should be skipped during recursive file enumeration.
    static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "__pycache__",
    ]
}

/// An image attached to a tool's output. The agent loop may forward this to
/// the LLM in the provider's native vision format when the selected model
/// supports vision; otherwise it's discarded and only `text` is shipped.
struct ToolImage: Sendable {
    /// MIME type, e.g. "image/png" or "image/jpeg".
    let mediaType: String
    /// Raw image bytes. Will be base64-encoded at request build time.
    let data: Data
}

/// The result of a tool execution — the text shown to the agent plus any
/// images that should be attached to the LLM's context.
struct ToolOutput: Sendable {
    /// Text shown to the agent (and used as the `tool_result` text content).
    let text: String
    /// Images to attach. Empty for text-only tools.
    let images: [ToolImage]

    init(text: String, images: [ToolImage] = []) {
        self.text = text
        self.images = images
    }
}

/// Protocol that all agent tools must conform to.
protocol AgentTool: Sendable {
    /// The tool name as sent to the Anthropic API (e.g. "bash", "read").
    var name: String { get }

    /// Human-readable description of what the tool does.
    var description: String { get }

    /// JSON Schema describing the tool's input parameters,
    /// matching Anthropic's `input_schema` format.
    var inputSchema: [String: Any] { get }

    /// Execute the tool with the given arguments and return text plus any
    /// optional image attachments.
    func execute(args: [String: Any]) async throws -> ToolOutput
}

/// Holds the set of available tools and serializes their schemas for the API.
final class ToolRegistry: Sendable {
    let tools: [AgentTool]

    init(tools: [AgentTool]) {
        self.tools = tools
    }

    /// Tools shared between `defaultRegistry` and `callRegistry`. The two registries
    /// differ only by their terminator tool (`DismissTool` vs `EndCallTool`).
    private static func sharedTools(workingDirectory cwd: String) -> [AgentTool] {
        [
            BashTool(workingDirectory: cwd),
            ReadTool(workingDirectory: cwd),
            WriteTool(workingDirectory: cwd),
            EditTool(workingDirectory: cwd),
            LsTool(workingDirectory: cwd),
            FindTool(workingDirectory: cwd),
            GrepTool(workingDirectory: cwd),
            WebFetchTool(),
            WebSearchTool(),
            CreateReminderTool(),
            CreateRoutineTool(),
            ListSchedulesTool(),
            DeleteScheduleTool(),
            TaskTool(),
            BrowserTool(),
            ScreenshotTool(),
            SkillTool(),
        ]
    }

    /// Creates the default registry with all built-in tools (terminator: `dismiss`).
    static func defaultRegistry(workingDirectory: String? = nil) -> ToolRegistry {
        let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath
        return ToolRegistry(tools: sharedTools(workingDirectory: cwd) + [DismissTool()])
    }

    /// Creates a registry for voice calls — same as default but swaps `dismiss` for `end_call`.
    static func callRegistry(workingDirectory: String? = nil) -> ToolRegistry {
        let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath
        return ToolRegistry(tools: sharedTools(workingDirectory: cwd) + [EndCallTool()])
    }

    /// Look up a tool by name.
    func tool(named name: String) -> AgentTool? {
        tools.first { $0.name == name }
    }

    /// Serializes all tool definitions into the format expected by the Anthropic API.
    func apiToolDefinitions() -> [[String: Any]] {
        tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema,
            ]
        }
    }
}
