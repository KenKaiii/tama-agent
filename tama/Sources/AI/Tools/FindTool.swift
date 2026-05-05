import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.find"
)

private struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FindTool: AgentTool {
    let name = "find"
    let description = "Find files matching a glob pattern. Returns sorted file paths, max 100 results."

    let workingDirectory: String

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "Glob pattern to match files (e.g. '**/*.swift', 'src/**/*.ts')",
                ],
                "path": [
                    "type": "string",
                    "description": "Directory to search in (defaults to cwd)",
                ],
            ],
            "required": ["pattern"],
        ]
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let pattern = args["pattern"] as? String else {
            throw ToolError(message: "Missing required parameter: pattern")
        }

        let pathArg = args["path"] as? String ?? "."
        logger.info("Finding files: pattern=\(pattern, privacy: .public), path=\(pathArg, privacy: .public)")
        let searchPath = try FileSystemToolHelpers.resolvePath(pathArg, workingDirectory: workingDirectory)

        let standardized = (searchPath as NSString).standardizingPath
        return try ToolOutput(text: findFiles(pattern: pattern, in: standardized))
    }

    private func findFiles(
        pattern: String,
        in directory: String
    ) throws -> String {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDir),
              isDir.boolValue
        else {
            logger.error("Directory not found: \(directory, privacy: .public)")
            throw ToolError(message: "Directory not found: \(directory)")
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.producesRelativePathURLs]
        ) else {
            throw ToolError(
                message: "Could not enumerate directory: \(directory)"
            )
        }

        var matches: [String] = []
        var totalMatches = 0

        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL else { continue }
            let relativePath = url.relativePath
            let lastComponent = url.lastPathComponent

            if FileSystemToolHelpers.ignoredDirectories.contains(lastComponent) {
                enumerator.skipDescendants()
                continue
            }

            let matched = fnmatch(pattern, relativePath, FNM_PATHNAME) == 0
                || fnmatch(pattern, lastComponent, 0) == 0

            if matched {
                totalMatches += 1
                if matches.count < 100 {
                    matches.append(relativePath)
                }
            }
        }

        matches.sort()
        logger.info("Find complete: \(totalMatches) matches")

        if matches.isEmpty {
            return "No files found matching pattern: \(pattern)"
        }

        var result = matches.joined(separator: "\n")

        if totalMatches > 100 {
            result += "\n[100 of \(totalMatches) results shown]"
        }

        return result
    }
}
