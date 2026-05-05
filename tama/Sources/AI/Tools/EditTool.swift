import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.edit"
)

final class EditTool: AgentTool {
    let name = "edit"
    let description = "Replace a specific text string in a file. The old_text must uniquely match exactly one location."
    let workingDirectory: String

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "The file path to edit",
                ],
                "old_text": [
                    "type": "string",
                    "description": "The exact text to find and replace",
                ],
                "new_text": [
                    "type": "string",
                    "description": "The replacement text",
                ],
            ],
            "required": ["file_path", "old_text", "new_text"],
        ]
    }

    private enum ToolError: LocalizedError {
        case missingParameter(String)
        case fileNotReadable(String)
        case notFound
        case multipleMatches(Int)
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case let .missingParameter(name):
                "Missing required parameter: \(name)"
            case let .fileNotReadable(path):
                "Could not read file at \(path)"
            case .notFound:
                "old_text not found in file"
            case let .multipleMatches(count):
                "old_text matches \(count) locations — must be unique"
            case let .encodingFailed(path):
                "Could not encode modified content as UTF-8 for file at \(path)"
            }
        }
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let filePath = args["file_path"] as? String else {
            throw ToolError.missingParameter("file_path")
        }
        guard let rawOldText = args["old_text"] as? String else {
            throw ToolError.missingParameter("old_text")
        }
        guard let rawNewText = args["new_text"] as? String else {
            throw ToolError.missingParameter("new_text")
        }

        let absolutePath = try FileSystemToolHelpers.resolvePath(filePath, workingDirectory: workingDirectory)
        logger
            .info(
                "Editing file: \(absolutePath, privacy: .public), oldTextLength: \(rawOldText.count), newTextLength: \(rawNewText.count)"
            )

        let fileURL = URL(fileURLWithPath: absolutePath)

        guard let rawData = try? Data(contentsOf: fileURL),
              let rawContent = String(data: rawData, encoding: .utf8)
        else {
            logger.error("File not readable: \(absolutePath, privacy: .public)")
            throw ToolError.fileNotReadable(absolutePath)
        }

        // Normalize CRLF → LF
        let content = rawContent.replacingOccurrences(of: "\r\n", with: "\n")
        let oldText = rawOldText.replacingOccurrences(of: "\r\n", with: "\n")
        let newText = rawNewText.replacingOccurrences(of: "\r\n", with: "\n")

        // Count occurrences
        let count = countOccurrences(of: oldText, in: content)

        if count == 0 {
            logger.error("old_text not found in \(absolutePath, privacy: .public)")
            throw ToolError.notFound
        }
        if count > 1 {
            logger.error("old_text matches \(count) locations in \(absolutePath, privacy: .public)")
            throw ToolError.multipleMatches(count)
        }

        // Perform the single replacement
        let modified = content.replacingOccurrences(of: oldText, with: newText, range: content.range(of: oldText))

        guard let outData = modified.data(using: .utf8) else {
            logger.error("UTF-8 encoding failed for modified content: \(absolutePath, privacy: .public)")
            throw ToolError.encodingFailed(absolutePath)
        }
        try outData.write(to: fileURL)

        // Generate a simple unified diff
        let diff = generateDiff(
            filePath: filePath,
            oldContent: content,
            newContent: modified,
            oldText: oldText,
            newText: newText
        )

        logger.info("Edit complete: \(absolutePath, privacy: .public)")
        return ToolOutput(text: diff)
    }

    // MARK: - Private helpers

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex ..< haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound ..< haystack.endIndex
        }
        return count
    }

    private func generateDiff(
        filePath: String,
        oldContent: String,
        newContent: String,
        oldText: String,
        newText: String
    ) -> String {
        let oldLines = oldContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Find the line range that was affected
        let oldTextLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newTextLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Find where oldText starts in oldLines
        var matchStartLine = 0
        let joinedSoFar = NSMutableString()
        for (i, line) in oldLines.enumerated() {
            if i > 0 { joinedSoFar.append("\n") }
            joinedSoFar.append(line)
            let joined = joinedSoFar as String
            if joined.contains(oldText) {
                // The match starts somewhere at or before line i
                // Walk backwards to find the start
                matchStartLine = max(0, i - oldTextLines.count + 1)
                break
            }
        }

        let contextLines = 3
        let oldStart = max(0, matchStartLine - contextLines)
        let oldEnd = min(oldLines.count, matchStartLine + oldTextLines.count + contextLines)
        let newEnd = min(newLines.count, matchStartLine + newTextLines.count + contextLines)

        var result = "--- a/\(filePath)\n+++ b/\(filePath)\n"
        result += "@@ -\(oldStart + 1),\(oldEnd - oldStart) +\(oldStart + 1),\(newEnd - oldStart) @@\n"

        // Context before
        for i in oldStart ..< matchStartLine where i < oldLines.count {
            result += " \(oldLines[i])\n"
        }

        // Removed lines
        for line in oldTextLines {
            result += "-\(line)\n"
        }

        // Added lines
        for line in newTextLines {
            result += "+\(line)\n"
        }

        // Context after
        let afterStart = matchStartLine + oldTextLines.count
        let afterEnd = min(oldLines.count, afterStart + contextLines)
        for i in afterStart ..< afterEnd {
            result += " \(oldLines[i])\n"
        }

        return result
    }
}
