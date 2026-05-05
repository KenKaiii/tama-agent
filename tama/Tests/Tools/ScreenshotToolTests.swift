import CoreGraphics
import Foundation
@testable import Tama
import Testing

@Suite("ScreenshotTool")
struct ScreenshotToolTests {
    // MARK: - Helpers

    /// Build a ScreenshotTool whose vision-support check is forced to a known
    /// outcome, with a deterministic alternatives list. This lets us exercise
    /// the guard logic without depending on the host's ProviderStore state.
    private func tool(
        model: ModelInfo,
        alternatives: [String] = ["Kimi K2.5", "GPT-5.4"]
    ) -> ScreenshotTool {
        ScreenshotTool(
            currentModelProvider: { model },
            visionAlternativesProvider: { alternatives }
        )
    }

    /// A vision-capable model (Kimi K2.5) \u2014 lets tests skip the vision guard
    /// and reach the permission/display branches.
    private func visionModel() -> ModelInfo {
        ModelRegistry.model(withId: "kimi-k2.6")!
    }

    /// A non-vision model (MiMo-V2-Pro) used to exercise the new guard.
    private func nonVisionModel() -> ModelInfo {
        ModelRegistry.model(withId: "xiaomi-token-plan-sgp/mimo-v2-pro")!
    }

    // MARK: - Schema

    @Test("name is 'screenshot'")
    func toolName() {
        #expect(tool(model: visionModel()).name == "screenshot")
    }

    @Test("description mentions vision and screen")
    func descriptionMentionsScreen() {
        let lowered = tool(model: visionModel()).description.lowercased()
        #expect(lowered.contains("screen"))
        #expect(lowered.contains("screenshot") || lowered.contains("capture"))
    }

    @Test("input schema has correct structure")
    func inputSchemaStructure() {
        let schema = tool(model: visionModel()).inputSchema
        #expect(schema["type"] as? String == "object")

        let properties = schema["properties"] as? [String: Any]
        #expect(properties != nil)
        #expect(properties?["display"] != nil)

        // No required parameters — all defaults are sensible.
        let required = schema["required"] as? [String]
        #expect(required?.isEmpty == true)
    }

    // MARK: - Vision Guard (new)

    @Test("non-vision model throws visionNotSupported before capturing anything")
    func nonVisionModelBlocksEarly() async {
        let mimo = nonVisionModel()
        let alts = ["Kimi K2.5", "GPT-5.4 Mini"]
        let tool = tool(model: mimo, alternatives: alts)
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected visionNotSupported error")
        } catch let error as ScreenshotToolError {
            #expect(error == .visionNotSupported(currentModelName: mimo.name, alternatives: alts))
            let msg = error.localizedDescription
            #expect(msg.contains(mimo.name), "Error message should name the current model")
            #expect(msg.contains("Kimi K2.5"), "Error should suggest at least one vision alternative")
            #expect(msg.contains("AI Settings"), "Error should point users to AI Settings (matching AppError tone)")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("visionNotSupported message stays friendly when no alternatives are configured")
    func noAlternativesFallback() async {
        let mimo = nonVisionModel()
        let tool = tool(model: mimo, alternatives: [])
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected visionNotSupported error")
        } catch let error as ScreenshotToolError {
            let msg = error.localizedDescription
            #expect(msg.contains(mimo.name))
            // Falls back to a generic suggestion instead of an empty list.
            #expect(msg.contains("Kimi") || msg.contains("GPT"), "Should suggest well-known vision models")
            #expect(msg.contains("AI Settings"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Permission Path (reachable only with a vision model selected)

    /// With a vision model selected, the next gate is Screen Recording
    /// permission. XCTest bundles typically don't have it, so we expect
    /// permissionDenied here.
    @Test("missing permission throws permissionDenied with actionable message")
    func permissionDeniedPath() async {
        guard !CGPreflightScreenCaptureAccess() else {
            // Host has Screen Recording granted; we can't simulate denial.
            return
        }
        let tool = tool(model: visionModel())
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected permissionDenied error")
        } catch let error as ScreenshotToolError {
            #expect(error == .permissionDenied)
            let msg = error.localizedDescription
            #expect(msg.contains("Screen Recording"))
            #expect(msg.contains("System Settings"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Display Index Validation

    @Test("invalid display index throws noDisplay")
    func invalidDisplayIndex() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            // Can't reach the display-index check without permission; skip.
            return
        }
        let tool = tool(model: visionModel())
        do {
            _ = try await tool.execute(args: ["display": 9999])
            Issue.record("Expected noDisplay error")
        } catch let error as ScreenshotToolError {
            #expect(error == .noDisplay)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Equatable for Testing

extension ScreenshotToolError: Equatable {
    public static func == (lhs: ScreenshotToolError, rhs: ScreenshotToolError) -> Bool {
        switch (lhs, rhs) {
        case (.permissionDenied, .permissionDenied),
             (.noDisplay, .noDisplay),
             (.encodeFailed, .encodeFailed):
            true
        case let (.captureFailed(a), .captureFailed(b)):
            a == b
        case let (.visionNotSupported(lName, lAlts), .visionNotSupported(rName, rAlts)):
            lName == rName && lAlts == rAlts
        default:
            false
        }
    }
}
