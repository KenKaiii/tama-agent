import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.read"
)

final class ReadTool: AgentTool {
    let workingDirectory: String

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    var name: String { "read" }

    var description: String {
        "Read a file's contents. Returns numbered lines (cat -n style). Output truncated to 2000 lines or 50KB."
    }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "required": ["file_path"],
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "The file path to read",
                ],
                "offset": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "Line number to start reading from (1-based)",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "Maximum number of lines to read",
                ],
            ],
        ]
    }

    // MARK: - Constants

    private static let maxLines = 2000
    private static let maxBytes = 51200 // 50KB

    // MARK: - Errors

    private enum ToolError: LocalizedError {
        case invalidArguments(String)
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidArguments(msg): msg
            case let .executionFailed(msg): msg
            }
        }
    }

    // MARK: - Execute

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let filePath = args["file_path"] as? String else {
            throw ToolError.invalidArguments("Missing required argument: file_path")
        }

        let resolvedPath = try FileSystemToolHelpers.resolvePath(filePath, workingDirectory: workingDirectory)
        let offset = args["offset"] as? Int
        let limit = args["limit"] as? Int
        logger.info("Reading file: \(resolvedPath, privacy: .public), offset: \(offset ?? 1), limit: \(limit ?? -1)")
        let url = URL(fileURLWithPath: resolvedPath)
        let filename = url.lastPathComponent

        if FileSystemToolHelpers.binaryExtensions.contains(url.pathExtension.lowercased()) {
            logger.warning("Binary file detected: \(resolvedPath, privacy: .public)")
            return ToolOutput(text: "Binary file detected: \(filename)")
        }

        let content = try readUTF8(url: url, filename: filename)
        let lines = splitLines(content)
        let slice = applyOffsetAndLimit(lines: lines, args: args)

        let result = formatLines(slice)
        logger.info("Read complete: \(slice.count) lines returned")
        return ToolOutput(text: result)
    }

    // MARK: - Helpers

    private func readUTF8(url: URL, filename: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read file: \(error.localizedDescription, privacy: .public)")
            throw ToolError.executionFailed("Failed to read file: \(error.localizedDescription)")
        }

        guard let content = String(data: data, encoding: .utf8) else {
            // Non-decodable content is treated as binary
            throw ToolError.executionFailed("Binary file detected: \(filename)")
        }
        return content
    }

    private func splitLines(_ content: String) -> [Substring] {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        // If the file ends with a newline, split produces a trailing empty element — drop it
        // to match the behavior of cat -n which doesn't number a trailing empty line.
        if content.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private func applyOffsetAndLimit(
        lines: [Substring],
        args: [String: Any]
    ) -> ArraySlice<Substring> {
        let offset = args["offset"] as? Int ?? 1
        let startIndex = max(offset - 1, 0)

        guard startIndex < lines.count else {
            return lines[0 ..< 0]
        }

        var endIndex = lines.count
        if let limit = args["limit"] as? Int {
            endIndex = min(startIndex + limit, lines.count)
        }

        return lines[startIndex ..< endIndex]
    }

    private func formatLines(_ selectedLines: ArraySlice<Substring>) -> String {
        var result = ""
        var byteCount = 0
        var lineCount = 0

        for (index, line) in zip(selectedLines.indices, selectedLines) {
            let lineNumber = index + 1
            let formatted = String(format: "%6d\t%@\n", lineNumber, String(line))
            let formattedBytes = formatted.utf8.count

            if byteCount + formattedBytes > Self.maxBytes {
                result += "[...truncated at 50KB...]\n"
                break
            }

            lineCount += 1
            if lineCount > Self.maxLines {
                result += "[...truncated...]\n"
                break
            }

            result += formatted
            byteCount += formattedBytes
        }

        return result
    }
}
