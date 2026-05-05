import Foundation
@testable import Tama
import Testing

/// Tests that FileSystemToolHelpers.resolvePath and the tools that use it
/// refuse to access paths outside the working directory.
@Suite("Path Confinement")
struct PathConfinementTests {
    // MARK: - resolvePath unit tests

    @Suite("resolvePath")
    struct ResolvePathTests {
        /// Create a real temp directory so symlink resolution works.
        let tempDir: String

        init() throws {
            let base = NSTemporaryDirectory() + "PathConfinementTests-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            // Resolve any symlinks in the temp path itself (e.g. /var → /private/var on macOS).
            tempDir = (base as NSString).resolvingSymlinksInPath
        }

        private func cleanup() {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        @Test("relative path inside working directory is allowed")
        func relativeInsideAllowed() throws {
            let resolved = try FileSystemToolHelpers.resolvePath("subdir/file.txt", workingDirectory: tempDir)
            #expect(resolved.hasPrefix(tempDir))
            cleanup()
        }

        @Test("dot-dot traversal is rejected")
        func dotDotTraversalRejected() throws {
            #expect(throws: (any Error).self) {
                try FileSystemToolHelpers.resolvePath("../../etc/passwd", workingDirectory: tempDir)
            }
            cleanup()
        }

        @Test("absolute path outside working directory is rejected")
        func absoluteOutsideRejected() throws {
            #expect(throws: (any Error).self) {
                try FileSystemToolHelpers.resolvePath("/etc/passwd", workingDirectory: tempDir)
            }
            cleanup()
        }

        @Test("absolute path inside working directory is allowed")
        func absoluteInsideAllowed() throws {
            let insidePath = tempDir + "/some/file.txt"
            let resolved = try FileSystemToolHelpers.resolvePath(insidePath, workingDirectory: tempDir)
            #expect(resolved.hasPrefix(tempDir))
            cleanup()
        }

        @Test("tilde expansion to home directory is rejected")
        func tildeExpansionRejected() throws {
            // ~ expands to the home directory which is outside the sandbox tempDir
            #expect(throws: (any Error).self) {
                try FileSystemToolHelpers.resolvePath("~/secret.txt", workingDirectory: tempDir)
            }
            cleanup()
        }

        @Test("dot-dot in the middle of a path is rejected")
        func dotDotMiddleRejected() throws {
            #expect(throws: (any Error).self) {
                try FileSystemToolHelpers.resolvePath("subdir/../../etc/passwd", workingDirectory: tempDir)
            }
            cleanup()
        }

        @Test("error message is descriptive")
        func errorMessageDescriptive() throws {
            do {
                _ = try FileSystemToolHelpers.resolvePath("../../etc/passwd", workingDirectory: tempDir)
                Issue.record("Expected confinement error")
            } catch {
                let message = error.localizedDescription
                #expect(message.contains("outside the working directory"))
            }
            cleanup()
        }

        @Test("working directory itself resolves correctly")
        func workingDirectoryItselfAllowed() throws {
            let resolved = try FileSystemToolHelpers.resolvePath(".", workingDirectory: tempDir)
            // The result must be the working directory (or a canonical equivalent).
            let canonicalTempDir = (tempDir as NSString).resolvingSymlinksInPath
            let canonicalResolved = (resolved as NSString).resolvingSymlinksInPath
            #expect(canonicalResolved == canonicalTempDir)
            cleanup()
        }
    }

    // MARK: - ReadTool confinement

    @Suite("ReadTool confinement")
    struct ReadToolConfinementTests {
        let tempDir: String
        let tool: ReadTool

        init() throws {
            let base = NSTemporaryDirectory() + "ReadConfinement-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            tempDir = (base as NSString).resolvingSymlinksInPath
            tool = ReadTool(workingDirectory: tempDir)
        }

        private func cleanup() {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        @Test("read dot-dot path is rejected")
        func readDotDotRejected() async throws {
            do {
                _ = try await tool.execute(args: ["file_path": "../../etc/passwd"])
                Issue.record("Expected confinement error")
            } catch {
                #expect(error.localizedDescription.contains("outside the working directory"))
            }
            cleanup()
        }

        @Test("read valid relative path succeeds")
        func readValidRelativeSucceeds() async throws {
            let path = (tempDir as NSString).appendingPathComponent("valid.txt")
            try "hello".write(toFile: path, atomically: true, encoding: .utf8)
            let result = try await tool.execute(args: ["file_path": "valid.txt"])
            #expect(result.text.contains("hello"))
            cleanup()
        }

        @Test("read tilde path is rejected")
        func readTildeRejected() async throws {
            do {
                _ = try await tool.execute(args: ["file_path": "~/Library/Preferences"])
                Issue.record("Expected confinement error")
            } catch {
                #expect(error.localizedDescription.contains("outside the working directory"))
            }
            cleanup()
        }
    }

    // MARK: - WriteTool confinement

    @Suite("WriteTool confinement")
    struct WriteToolConfinementTests {
        let tempDir: String
        let tool: WriteTool

        init() throws {
            let base = NSTemporaryDirectory() + "WriteConfinement-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            tempDir = (base as NSString).resolvingSymlinksInPath
            tool = WriteTool(workingDirectory: tempDir)
        }

        private func cleanup() {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        @Test("write dot-dot path is rejected")
        func writeDotDotRejected() async throws {
            do {
                _ = try await tool.execute(args: ["file_path": "../../tmp/x", "content": "evil"])
                Issue.record("Expected confinement error")
            } catch {
                #expect(error.localizedDescription.contains("outside the working directory"))
            }
            cleanup()
        }

        @Test("write valid relative path succeeds")
        func writeValidRelativeSucceeds() async throws {
            let result = try await tool.execute(args: ["file_path": "safe.txt", "content": "safe content"])
            #expect(result.text.contains("Wrote"))
            let written = try String(
                contentsOfFile: (tempDir as NSString).appendingPathComponent("safe.txt"),
                encoding: .utf8
            )
            #expect(written == "safe content")
            cleanup()
        }

        @Test("write tilde path is rejected")
        func writeTildeRejected() async throws {
            do {
                _ = try await tool.execute(args: ["file_path": "~/evil.txt", "content": "evil"])
                Issue.record("Expected confinement error")
            } catch {
                #expect(error.localizedDescription.contains("outside the working directory"))
            }
            cleanup()
        }
    }
}
