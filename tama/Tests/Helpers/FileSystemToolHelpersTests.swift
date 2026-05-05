import Foundation
@testable import Tama
import Testing

@Suite("FileSystemToolHelpers")
struct FileSystemToolHelpersTests {
    // A real temp directory so symlink resolution works on macOS (/var → /private/var).
    let tempDir: String

    init() throws {
        let base = NSTemporaryDirectory() + "FSHelpersTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        tempDir = (base as NSString).resolvingSymlinksInPath
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("resolvePath joins relative path with working directory")
    func resolveRelativePath() throws {
        let result = try FileSystemToolHelpers.resolvePath("src/main.swift", workingDirectory: tempDir)
        #expect(result == tempDir + "/src/main.swift")
        cleanup()
    }

    @Test("resolvePath handles nested relative path")
    func resolveNestedRelativePath() throws {
        let result = try FileSystemToolHelpers.resolvePath("a/b/file.txt", workingDirectory: tempDir)
        #expect(result.hasPrefix(tempDir))
        #expect(result.hasSuffix("a/b/file.txt"))
        cleanup()
    }

    @Test("resolvePath with absolute path inside working directory is allowed")
    func resolveAbsoluteInsideWorkingDir() throws {
        let insidePath = tempDir + "/subdir/file.swift"
        let result = try FileSystemToolHelpers.resolvePath(insidePath, workingDirectory: tempDir)
        #expect(result.hasPrefix(tempDir))
        cleanup()
    }

    @Test("resolvePath rejects absolute path outside working directory")
    func resolveAbsoluteOutsideWorkingDir() throws {
        #expect(throws: (any Error).self) {
            try FileSystemToolHelpers.resolvePath("/usr/bin/swift", workingDirectory: tempDir)
        }
        cleanup()
    }

    @Test("resolvePath rejects dot-dot traversal")
    func resolveDotDotRejected() throws {
        #expect(throws: (any Error).self) {
            try FileSystemToolHelpers.resolvePath("../../etc/passwd", workingDirectory: tempDir)
        }
        cleanup()
    }

    @Test("binaryExtensions contains key types")
    func binaryExtensionsContainsKeyTypes() {
        let expected = ["jpg", "zip", "exe", "sqlite", "png", "pdf", "mp3", "wasm"]
        for ext in expected {
            #expect(FileSystemToolHelpers.binaryExtensions.contains(ext), "Expected binaryExtensions to contain \(ext)")
        }
    }

    @Test("ignoredDirectories contains .git and node_modules")
    func ignoredDirectoriesContainsExpected() {
        #expect(FileSystemToolHelpers.ignoredDirectories.contains(".git"))
        #expect(FileSystemToolHelpers.ignoredDirectories.contains("node_modules"))
        #expect(FileSystemToolHelpers.ignoredDirectories.contains(".build"))
        #expect(FileSystemToolHelpers.ignoredDirectories.contains("DerivedData"))
    }
}
