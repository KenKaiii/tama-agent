import Foundation
@testable import Tama
import Testing

@Suite("WebFetchTool SSRF Validation")
struct WebFetchToolTests {
    let tool: WebFetchTool

    init() {
        tool = WebFetchTool()
    }

    @Test("blocks localhost")
    func blocksLocalhost() async {
        do {
            _ = try await tool.execute(args: ["url": "http://localhost:8080/secret"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 127.0.0.1")
    func blocksLoopback() async {
        do {
            _ = try await tool.execute(args: ["url": "http://127.0.0.1/admin"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 10.x.x.x private range")
    func blocks10Range() async {
        do {
            _ = try await tool.execute(args: ["url": "http://10.0.0.1/internal"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 172.16-31.x.x private range")
    func blocks172Range() async {
        do {
            _ = try await tool.execute(args: ["url": "http://172.16.0.1/internal"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 192.168.x.x private range")
    func blocks192Range() async {
        do {
            _ = try await tool.execute(args: ["url": "http://192.168.1.1/router"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    // MARK: - Non-standard IP representation bypass tests

    @Test("blocks decimal integer IP (http://2130706433 == 127.0.0.1)")
    func blocksDecimalIntegerIP() async {
        do {
            _ = try await tool.execute(args: ["url": "http://2130706433"])
            Issue.record("Expected blocked host error for decimal integer IP")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks hex IP (http://0x7f000001 == 127.0.0.1)")
    func blocksHexIP() async {
        do {
            _ = try await tool.execute(args: ["url": "http://0x7f000001"])
            Issue.record("Expected blocked host error for hex IP")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks octal IP (http://017700000001 == 127.0.0.1)")
    func blocksOctalIP() async {
        do {
            _ = try await tool.execute(args: ["url": "http://017700000001"])
            Issue.record("Expected blocked host error for octal IP")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks IPv6-mapped loopback (http://[::ffff:7f00:1] == 127.0.0.1)")
    func blocksIPv6MappedLoopback() async {
        do {
            _ = try await tool.execute(args: ["url": "http://[::ffff:7f00:1]"])
            Issue.record("Expected blocked host error for IPv6-mapped loopback")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("missing URL parameter throws")
    func missingURLThrows() async {
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected missing URL error")
        } catch {
            #expect(error.localizedDescription.contains("url"))
        }
    }

    @Test("invalid URL throws")
    func invalidURLThrows() async {
        do {
            _ = try await tool.execute(args: ["url": "not a url at all %%%"])
            Issue.record("Expected invalid URL error")
        } catch {
            #expect(error.localizedDescription.contains("Invalid URL"))
        }
    }
}
