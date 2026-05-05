import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.ls"
)

private struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LsTool: AgentTool {
    let name = "ls"
    let description = "List directory contents with file types and sizes."

    let workingDirectory: String

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Directory path (defaults to cwd)",
                ],
                "all": [
                    "type": "boolean",
                    "description": "Show hidden files (default: false)",
                ],
            ],
            "required": [] as [String],
        ]
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        let pathArg = args["path"] as? String ?? "."
        let showAll = args["all"] as? Bool ?? false
        logger.info("Listing directory: \(pathArg, privacy: .public), showAll: \(showAll)")

        let resolvedPath = try FileSystemToolHelpers.resolvePath(pathArg, workingDirectory: workingDirectory)

        let standardized = (resolvedPath as NSString).standardizingPath
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else {
            logger.error("Directory not found: \(standardized, privacy: .public)")
            throw ToolError(message: "Directory not found: \(standardized)")
        }

        let contents = try fm.contentsOfDirectory(atPath: standardized)

        var dirs: [(String, UInt64)] = []
        var files: [(String, UInt64)] = []

        for entry in contents {
            if !showAll, entry.hasPrefix(".") {
                continue
            }

            let fullPath = (standardized as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &entryIsDir)

            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = (attrs?[.size] as? UInt64) ?? 0

            if entryIsDir.boolValue {
                dirs.append((entry, size))
            } else {
                files.append((entry, size))
            }
        }

        dirs.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        files.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }

        var lines: [String] = []

        for (name, _) in dirs {
            lines.append("d  -        \(name)/")
        }

        for (name, size) in files {
            let humanSize = Self.formatSize(size)
            let padded = humanSize.padding(toLength: 7, withPad: " ", startingAt: 0)
            lines.append("f  \(padded)  \(name)")
        }

        logger.info("Listing complete: \(dirs.count) dirs, \(files.count) files")

        if lines.isEmpty {
            return ToolOutput(text: "(empty directory)")
        }

        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    private static func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes)B"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return String(format: "%.1fK", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024 {
            return String(format: "%.1fM", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.1fG", gb)
    }
}
