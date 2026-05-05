import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.write"
)

final class WriteTool: AgentTool {
    let name = "write"
    let description = "Write content to a file. Creates parent directories if needed."
    let workingDirectory: String

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "The file path to write to",
                ],
                "content": [
                    "type": "string",
                    "description": "The content to write",
                ],
            ],
            "required": ["file_path", "content"],
        ]
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    private struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let filePath = args["file_path"] as? String else {
            throw ToolError(message: "Missing required parameter: file_path")
        }
        guard let content = args["content"] as? String else {
            throw ToolError(message: "Missing required parameter: content")
        }

        let absolutePath = try FileSystemToolHelpers.resolvePath(filePath, workingDirectory: workingDirectory)
        logger.info("Writing file: \(absolutePath, privacy: .public), contentBytes: \(content.utf8.count)")

        let fileURL = URL(fileURLWithPath: absolutePath)
        let parentDir = fileURL.deletingLastPathComponent()

        let fm = FileManager.default
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        guard let data = content.data(using: .utf8) else {
            logger.error("Failed to encode content as UTF-8 for \(absolutePath, privacy: .public)")
            throw ToolError(message: "Failed to encode content as UTF-8")
        }

        do {
            try data.write(to: fileURL)
        } catch {
            logger
                .error(
                    "Failed to write file \(absolutePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            throw error
        }

        logger.info("Write complete: \(data.count) bytes to \(absolutePath, privacy: .public)")
        return ToolOutput(text: "Wrote \(data.count) bytes to \(absolutePath)")
    }
}
