import Foundation
@testable import Tama
import Testing

/// Locks in the behaviour of the clause/sentence splitting pipeline that
/// chunks streaming text for Kokoro TTS. After the hot-path regex
/// recompilation fix, both `splitAtClauseBoundaries` and the eager-flush
/// clause matching share precompiled static patterns — these tests cover
/// the boundary cases that those patterns control.
@Suite("SpeechService splitting")
@MainActor
struct SpeechServiceSplittingTests {
    @Test("clausePattern matches comma, semicolon, colon, em-dash, en-dash followed by whitespace")
    func clausePatternMatchesAllBoundaries() {
        let text = "alpha, beta; gamma: delta — epsilon – zeta"
        let range = NSRange(text.startIndex..., in: text)
        let matches = SpeechService.clausePattern.matches(in: text, options: [], range: range)
        #expect(matches.count == 5)
    }

    @Test("clauseSplitPattern excludes the colon (used for over-long sentence chunking)")
    func clauseSplitPatternSkipsColons() {
        let text = "alpha, beta; gamma: delta — epsilon – zeta"
        let range = NSRange(text.startIndex..., in: text)
        let matches = SpeechService.clauseSplitPattern.matches(in: text, options: [], range: range)
        // Same boundaries minus the colon → 4
        #expect(matches.count == 4)
    }

    @Test("splitAtClauseBoundaries returns the input unchanged when under the chunk limit")
    func shortSentenceUntouched() {
        let svc = SpeechService.shared
        let text = "A short clause, with a comma."
        let chunks = svc.splitAtClauseBoundaries(text)
        // No chunking happens because the sentence fits in one chunk; the
        // function still emits the trailing piece as-is.
        #expect(chunks.count == 1)
        #expect(chunks.first?.contains("short clause") == true)
    }

    @Test("splitAtClauseBoundaries breaks an over-long sentence at clause boundaries")
    func longSentenceSplitsAtClauses() {
        let svc = SpeechService.shared
        // Build a sentence well over the 200-char chunk limit with comma boundaries
        // every ~40 chars so the splitter has somewhere to break.
        let segment = "this is a comma-separated clause of moderate length"
        let text = Array(repeating: segment, count: 8).joined(separator: ", ") + "."
        #expect(text.count > 200)

        let chunks = svc.splitAtClauseBoundaries(text)
        #expect(chunks.count > 1)
        for chunk in chunks {
            // Each chunk should respect the 200-char target (allow slop for the
            // final piece which may carry the tail past a boundary).
            #expect(chunk.count <= 260)
            #expect(!chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("splitAtClauseBoundaries falls back to hard slicing when no clause boundary exists")
    func noBoundariesHardSplits() {
        let svc = SpeechService.shared
        // 250 chars of solid text with no comma/semicolon/dash anywhere.
        let text = String(repeating: "a", count: 250)
        let chunks = svc.splitAtClauseBoundaries(text)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.count <= 200 })
        #expect(chunks.joined().count == 250)
    }

    @Test("splitAtClauseBoundaries does not split at colons (delegated to clausePattern)")
    func colonIsNotASplitBoundaryHere() {
        let svc = SpeechService.shared
        // Long text whose only candidate boundaries are colons. The split
        // function should NOT carve at colons — it must fall back to the
        // hard-slice branch.
        let segment = "alpha bravo charlie delta echo foxtrot golf hotel: "
        let text = String(repeating: segment, count: 6)
        #expect(text.count > 200)

        let chunks = svc.splitAtClauseBoundaries(text)
        // Hard-slice path: every chunk except possibly the last is exactly 200.
        #expect(chunks.count >= 2)
        #expect(chunks.dropLast().allSatisfy { $0.count == 200 })
    }
}
