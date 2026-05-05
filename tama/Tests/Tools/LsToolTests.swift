import Foundation
@testable import Tama
import Testing

@Suite("LsTool")
struct LsToolTests {
    let tempDir: String
    let tool: LsTool

    init() throws {
        tempDir = NSTemporaryDirectory() + "LsToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        tool = LsTool(workingDirectory: tempDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("lists directories first then files, sorted")
    func directoriesFirstThenFiles() async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (tempDir as NSString).appendingPathComponent("beta"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            atPath: (tempDir as NSString).appendingPathComponent("alpha"),
            withIntermediateDirectories: true
        )
        try "content".write(
            toFile: (tempDir as NSString).appendingPathComponent("zebra.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "content".write(
            toFile: (tempDir as NSString).appendingPathComponent("aardvark.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await tool.execute(args: [:]).text
        let lines = result.components(separatedBy: "\n")

        // Directories should come first
        #expect(lines[0].hasPrefix("d"))
        #expect(lines[0].contains("alpha/"))
        #expect(lines[1].hasPrefix("d"))
        #expect(lines[1].contains("beta/"))
        // Then files
        #expect(lines[2].hasPrefix("f"))
        #expect(lines[2].contains("aardvark.txt"))
        #expect(lines[3].hasPrefix("f"))
        #expect(lines[3].contains("zebra.txt"))
        cleanup()
    }

    @Test("hidden files excluded by default")
    func hiddenFilesExcluded() async throws {
        try "visible".write(
            toFile: (tempDir as NSString).appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "hidden".write(
            toFile: (tempDir as NSString).appendingPathComponent(".hidden"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await tool.execute(args: [:]).text
        #expect(result.contains("visible.txt"))
        #expect(!result.contains(".hidden"))
        cleanup()
    }

    @Test("all flag includes hidden files")
    func allFlagIncludesHidden() async throws {
        try "visible".write(
            toFile: (tempDir as NSString).appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "hidden".write(
            toFile: (tempDir as NSString).appendingPathComponent(".hidden"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await tool.execute(args: ["all": true]).text
        #expect(result.contains("visible.txt"))
        #expect(result.contains(".hidden"))
        cleanup()
    }

    @Test("empty directory returns message")
    func emptyDirectory() async throws {
        let result = try await tool.execute(args: [:]).text
        #expect(result == "(empty directory)")
        cleanup()
    }

    @Test("non-existent directory throws")
    func nonExistentDirectoryThrows() async throws {
        do {
            _ = try await tool.execute(args: ["path": "nonexistent-\(UUID().uuidString)"])
            Issue.record("Expected error for non-existent directory")
        } catch {
            #expect(error.localizedDescription.contains("not found"))
        }
        cleanup()
    }
}
