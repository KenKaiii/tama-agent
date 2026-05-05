import AVFoundation
import os

/// Text-to-speech service using Kokoro TTS.
/// Supports streaming: feed text chunks as they arrive, sentences are spoken as they complete.
/// Audio generation runs off the main thread to avoid blocking the UI.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let logger = Logger(subsystem: "com.unstablemind.tama", category: "speech")

    // MARK: - Persistent Audio Engine

    /// Single persistent audio engine — reused across all playback sessions.
    /// Recreating AVAudioEngine per play causes zombie engine instances that
    /// fight for audio resources and cause stuttering on subsequent plays.
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineStarted = false

    // MARK: - Streaming State

    /// Buffer for accumulating streamed text until a sentence boundary is found.
    private var streamBuffer = ""

    /// Whether we're in a streaming session.
    private var isStreaming = false

    /// Pending utterance count — used to know when all queued speech is done.
    private var pendingUtterances = 0

    /// Called when all queued utterances finish (after `finishStreaming`).
    private var streamCompletion: (() -> Void)?

    /// Whether the stream has ended (no more chunks coming).
    private var streamEnded = false

    /// A PCM buffer paired with its per-word timings from Kokoro. Carried
    /// through the ordered-slot and playback queues so the word-level visual
    /// scheduler (`firePendingVisualsForUpcoming`) has the exact offset at
    /// which each word is spoken.
    private struct PlaybackItem {
        let buffer: AVAudioPCMBuffer
        let wordTimings: [WordTiming]
    }

    /// Queue of audio buffers waiting to be played sequentially.
    private var bufferQueue: [PlaybackItem] = []

    /// Whether the player is currently playing a buffer.
    private var isPlaying = false

    /// Active generation tasks (so we can cancel on stop).
    private var generationTasks: [Task<Void, Never>] = []

    /// Ordered slots for audio buffers — ensures playback order matches enqueue order
    /// even when concurrent TTS requests complete out of order.
    private var orderedSlots: [Int: PlaybackItem] = [:]
    private var nextSlotIndex = 0
    private var nextPlaySlot = 0

    /// Timer that auto-flushes buffered text when no new chunks arrive for `flushDelay`.
    /// Tokens arrive every ~20-50ms, so the timer only fires during genuine pauses
    /// (between sentences, before tool calls, or at end of response).
    private var flushTimer: Timer?

    /// Whether we've already sent the first utterance to TTS in this streaming session.
    /// The first utterance is dispatched eagerly (at a clause boundary or `eagerFlushChars`)
    /// so that Kokoro can start generating audio while more text streams in.
    private var hasFlushedFirst = false

    // MARK: - Telemetry Callbacks

    /// Fires the first time a TTS chunk is handed to Kokoro in a streaming session.
    var onFirstChunkEnqueued: (@MainActor () -> Void)?
    /// Fires the first time a generated audio buffer lands in the play queue.
    var onFirstAudioReady: (@MainActor () -> Void)?
    /// Fires the first time the audio engine starts playing a buffer this session.
    var onFirstAudioPlayback: (@MainActor () -> Void)?
    /// Fires when a playback gap is detected (queue empty while stream still active).
    /// Argument is the gap duration in seconds.
    var onPlaybackGap: (@MainActor (TimeInterval) -> Void)?

    // Internal flags + timestamps driving the telemetry callbacks above.
    private var firstChunkEnqueuedFired = false
    private var firstAudioReadyFired = false
    private var firstAudioPlaybackFired = false
    /// Time the audio engine finished playing the last buffer, if the queue
    /// was empty and more utterances were still pending (we're waiting for
    /// Kokoro). Compared against the next playNextBuffer() call to compute
    /// mid-stream dead-air gaps.
    private var playbackUnderrunAt: Date?

    /// Serial queue for Kokoro TTS generation. KokoroTTS uses NLTagger internally
    /// (via MisakiSwift G2P) which is not thread-safe and crashes with EXC_BAD_ACCESS
    /// if called concurrently from multiple threads.
    private let generationQueue = DispatchQueue(
        label: "com.unstablemind.tama.tts-generation",
        qos: .userInitiated
    )

    // MARK: - Constants

    /// Max characters per chunk for Kokoro TTS. Kokoro's token limit is 510,
    /// and ~200 chars provides a safe margin accounting for phonemization variance.
    private static let maxChunkChars = 200

    /// Minimum fragment length — shorter pieces are merged to avoid choppy playback.
    private static let minFragmentLength = 20

    /// Minimum character count before the first eager flush.
    /// Lower = faster time-to-first-audio, higher = more natural speech.
    private static let eagerFlushChars = 30

    /// After the first flush, if the buffer grows past this many characters
    /// and contains a clause boundary (comma, semicolon, dash), we drain up to
    /// that boundary instead of waiting for a sentence-ending punctuation.
    /// Keeps Kokoro continuously fed during long sentences so playback never
    /// outruns generation (dead-air prevention).
    private static let clauseFlushChars = 60

    /// How long to wait after the last chunk before auto-flushing the buffer.
    /// Tokens arrive every ~20-50ms so the timer only fires during genuine
    /// pauses. Tight value keeps end-of-turn lag minimal while still allowing
    /// the LLM to naturally pause mid-sentence without truncation.
    private static let flushDelay: TimeInterval = 0.3

    private init() {
        audioEngine.attach(playerNode)
    }

    /// Whether the service is currently speaking.
    var isSpeaking: Bool { isPlaying || !bufferQueue.isEmpty || pendingUtterances > 0 }

    /// True while a streaming session is active (between `beginStreaming()`
    /// and `finishStreaming()`/`stop()`). Unlike `isSpeaking`, this stays
    /// true across the gap between the model finishing its narration and
    /// the next turn's audio starting — so callers that need "am I in a
    /// voice call right now?" (like `AgentLoop`'s visual-tool gating) can
    /// trust it between turns. `isSpeaking` answers the narrower "is audio
    /// physically playing this instant?" question and flips to false in
    /// those quiet inter-turn gaps.
    var isVoiceSessionActive: Bool { isStreaming }

    // MARK: - Streaming TTS

    /// Begins a streaming speech session. Call `feedChunk` as text arrives, then `finishStreaming`.
    func beginStreaming() {
        stop()
        streamBuffer = ""
        isStreaming = true
        streamEnded = false
        pendingUtterances = 0
        streamCompletion = nil
        hasFlushedFirst = false
        flushTimer?.invalidate()
        flushTimer = nil
        nextSlotIndex = 0
        nextPlaySlot = 0
        orderedSlots.removeAll()
        firstChunkEnqueuedFired = false
        firstAudioReadyFired = false
        firstAudioPlaybackFired = false
        playbackUnderrunAt = nil
        prewarmEngine()
        logger.info("Streaming speech session started")
    }

    /// Feeds a text chunk from the stream. Sentences are spoken as they complete.
    ///
    /// Strategy:
    /// 1. **First flush** — eagerly sent at the first clause/sentence boundary after
    ///    `eagerFlushChars` so Kokoro starts generating audio immediately.
    /// 2. **Subsequent flushes** — drained at sentence boundaries for natural pacing.
    /// 3. **Idle timer** — catches any remaining text after a short pause (e.g. the
    ///    last partial sentence before a tool call or end of response).
    func feedChunk(_ chunk: String) {
        guard isStreaming else { return }
        streamBuffer += chunk

        if !hasFlushedFirst {
            tryEagerFlush()
        } else {
            drainSentences()
        }

        scheduleFlush()
    }

    /// Attempts to flush the buffer eagerly for the first utterance.
    /// Flushes at the first sentence/clause boundary once the buffer reaches
    /// `eagerFlushChars`, or at any sentence boundary regardless of length.
    private func tryEagerFlush() {
        let cleaned = stripMarkdown(streamBuffer)

        // Try to find a sentence boundary first (works at any length)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let sentenceMatches = Self.sentencePattern.matches(in: cleaned, options: [], range: range)

        if let lastMatch = sentenceMatches.last {
            let splitIndex = cleaned.index(
                cleaned.startIndex,
                offsetBy: lastMatch.range.location + lastMatch.range.length
            )
            let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(cleaned[splitIndex...])
            streamBuffer = remainder
            hasFlushedFirst = true
            if !toSpeak.isEmpty {
                enqueueSentences(from: toSpeak)
            }
            return
        }

        // No sentence boundary yet — try clause boundary if we have enough text
        guard cleaned.count >= Self.eagerFlushChars else { return }

        let clauseMatches = Self.clausePattern.matches(in: cleaned, options: [], range: range)

        if let lastClause = clauseMatches.last {
            let splitIndex = cleaned.index(
                cleaned.startIndex,
                offsetBy: lastClause.range.location + lastClause.range.length
            )
            let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(cleaned[splitIndex...])
            streamBuffer = remainder
            hasFlushedFirst = true
            if !toSpeak.isEmpty {
                enqueueSentences(from: toSpeak)
            }
            return
        }

        // No boundaries at all — hard flush everything we have
        let toSpeak = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        streamBuffer = ""
        hasFlushedFirst = true
        if !toSpeak.isEmpty {
            enqueueSentences(from: toSpeak)
        }
    }

    /// Restarts the idle-flush timer. Fires when tokens stop arriving for `flushDelay`
    /// (between sentences, before tool calls, or at end of response).
    private func scheduleFlush() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushBuffer()
            }
        }
    }

    /// Forces any buffered text to be spoken immediately (e.g. before a tool call pause).
    /// Skips tiny fragments unless the stream has ended to avoid choppy mid-sentence breaks.
    func flushBuffer() {
        guard isStreaming else { return }
        let text = stripMarkdown(streamBuffer).trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip flushing tiny fragments while more text is still streaming —
        // let the buffer grow until a sentence boundary or end-of-stream.
        if text.count < Self.minFragmentLength, !streamEnded {
            return
        }

        logger.info("flushBuffer — text: \(text.prefix(80), privacy: .public)")
        streamBuffer = ""

        if !text.isEmpty {
            enqueueSentences(from: text)
        }
    }

    /// Signals that the stream is complete. Speaks any remaining buffered text.
    /// Awaits until all queued utterances finish speaking.
    func finishStreaming() async {
        guard isStreaming else { return }
        streamEnded = true
        flushTimer?.invalidate()
        flushTimer = nil

        let remaining = stripMarkdown(streamBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        streamBuffer = ""

        if !remaining.isEmpty {
            enqueueSentences(from: remaining)
        }

        if pendingUtterances == 0 {
            logger.info("Streaming finished — nothing to speak")
            completeStream()
            return
        }

        // swiftformat:disable:next redundantSelf
        logger.info("Streaming finished — waiting for \(self.pendingUtterances) utterances")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            streamCompletion = {
                cont.resume()
            }
        }
    }

    /// Stops any ongoing speech immediately.
    func stop() {
        let wasSpeaking = isStreaming || isPlaying
        isStreaming = false
        streamEnded = false
        streamBuffer = ""
        pendingUtterances = 0

        flushTimer?.invalidate()
        flushTimer = nil

        for task in generationTasks {
            task.cancel()
        }
        generationTasks.removeAll()
        orderedSlots.removeAll()

        stopPlayback()

        if wasSpeaking {
            let cb = streamCompletion
            streamCompletion = nil
            cb?()
        }
    }

    /// Stops playback and the audio engine. Called when the panel is dismissed
    /// to fully release audio resources and prevent zombie engine instances.
    func shutdown() {
        stop()
        stopEngine()
    }

    private func stopPlayback() {
        bufferQueue.removeAll()
        isPlaying = false
        playerNode.stop()
    }

    // Helper converters for the Kokoro pipeline result.
    fileprivate typealias KokoroResult = KokoroManager.GenerationResult

    /// Stops the audio engine to fully release audio resources.
    /// The engine is restarted automatically by `ensureEngineRunning` when needed.
    private func stopEngine() {
        guard engineStarted else { return }
        audioEngine.stop()
        audioEngine.reset()
        engineStarted = false
        logger.debug("Audio engine stopped and reset")
    }

    // MARK: - Audio Engine Management

    /// Pre-warms the audio engine so the first buffer doesn't get clipped.
    /// Called at the start of a streaming session before any audio is ready.
    private func prewarmEngine() {
        // Use a standard format to get the engine running early
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        ensureEngineRunning(format: format)
    }

    private func ensureEngineRunning(format: AVAudioFormat) {
        if !engineStarted {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            do {
                try audioEngine.start()
                engineStarted = true
                logger.debug("Audio engine started")
            } catch {
                logger.error("Audio engine failed to start: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sentence Extraction

    // Sentence-ending punctuation followed by whitespace.
    // swiftlint:disable:next force_try
    private static let sentencePattern = try! NSRegularExpression(
        pattern: "(?<=[.!?])\\s+",
        options: []
    )

    /// Clause-boundary pattern: comma, semicolon, colon, em/en dash followed
    /// by whitespace. Used for mid-sentence draining once the buffer gets big
    /// enough to avoid dead air waiting for sentence-ending punctuation.
    // swiftlint:disable:next force_try
    static let clausePattern = try! NSRegularExpression(
        pattern: "[,;:—–]\\s+",
        options: []
    )

    /// Clause-boundary pattern used by `splitAtClauseBoundaries` when carving up
    /// over-long sentences for Kokoro. Same as `clausePattern` but excludes the
    /// colon — see the note on `splitAtClauseBoundaries` for rationale.
    // swiftlint:disable:next force_try
    static let clauseSplitPattern = try! NSRegularExpression(
        pattern: "[,;—–]\\s+",
        options: []
    )

    /// Extracts complete sentences from the buffer and enqueues them for speech.
    /// If no sentence boundary is present but the buffer has grown past
    /// `clauseFlushChars`, we fall back to draining at the latest clause
    /// boundary. This keeps Kokoro continuously fed during long sentences and
    /// prevents playback from outrunning generation (dead air).
    private func drainSentences() {
        let cleaned = stripMarkdown(streamBuffer)
        let range = NSRange(cleaned.startIndex..., in: cleaned)

        // Prefer sentence boundaries when available.
        if let lastMatch = Self.sentencePattern.matches(in: cleaned, range: range).last {
            drainAt(boundaryEnd: lastMatch.range.location + lastMatch.range.length, cleaned: cleaned, kind: "sentence")
            return
        }

        // No sentence boundary yet — drain at last clause boundary once buffer
        // has enough content that generation latency would bite.
        guard cleaned.count >= Self.clauseFlushChars,
              let lastClause = Self.clausePattern.matches(in: cleaned, range: range).last
        else { return }
        drainAt(boundaryEnd: lastClause.range.location + lastClause.range.length, cleaned: cleaned, kind: "clause")
    }

    /// Drains the buffer up to (and including) the given boundary index.
    private func drainAt(boundaryEnd: Int, cleaned: String, kind: String) {
        let splitIndex = cleaned.index(cleaned.startIndex, offsetBy: boundaryEnd)
        let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(cleaned[splitIndex...])
        streamBuffer = remainder
        logger
            .info(
                "drain(\(kind, privacy: .public)) — spoke: \(toSpeak.prefix(80), privacy: .public), remainder: \(remainder.prefix(40), privacy: .public)"
            )
        if !toSpeak.isEmpty {
            enqueueSentences(from: toSpeak)
        }
    }

    // MARK: - Utterance Creation

    /// Splits text into speakable chunks, merges short fragments, and enqueues each.
    private func enqueueSentences(from text: String) {
        logger.info("enqueueSentences input: \(text.prefix(120), privacy: .public)")
        let sentences = splitIntoSentences(text)
        let chunks = splitLongSentences(sentences)
        let merged = mergeShortFragments(chunks)

        for (i, chunk) in merged.enumerated() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            logger.info("  chunk[\(i)]: \(trimmed.prefix(100), privacy: .public)")
            enqueueUtterance(trimmed)
        }
    }

    /// Splits a block of text into individual sentences.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex...,
            options: .bySentences
        ) { substring, _, _, _ in
            if let s = substring {
                sentences.append(s)
            }
        }
        if sentences.isEmpty, !text.isEmpty {
            sentences.append(text)
        }
        return sentences
    }

    /// Splits any sentence exceeding maxChunkChars at clause boundaries.
    private func splitLongSentences(_ sentences: [String]) -> [String] {
        var result: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= Self.maxChunkChars {
                result.append(trimmed)
            } else {
                result.append(contentsOf: splitAtClauseBoundaries(trimmed))
            }
        }
        return result
    }

    /// Splits a long sentence at comma, semicolon, or dash boundaries.
    /// Note: deliberately omits the colon (which is included in `clausePattern`)
    /// because mid-sentence chunking at colons tends to leave awkward stranded
    /// fragments like "For example:" with nothing following.
    func splitAtClauseBoundaries(_ text: String) -> [String] {
        let nsText = text as NSString
        let matches = Self.clauseSplitPattern.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )

        guard !matches.isEmpty else {
            // No clause boundaries — hard split at maxChunkChars
            return stride(from: 0, to: text.count, by: Self.maxChunkChars).map { start in
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(startIdx, offsetBy: Self.maxChunkChars, limitedBy: text.endIndex) ?? text
                    .endIndex
                return String(text[startIdx ..< endIdx])
            }
        }

        var chunks: [String] = []
        var current = ""
        var lastEnd = 0

        for match in matches {
            let boundary = match.range.location + match.range.length
            let piece = nsText.substring(with: NSRange(location: lastEnd, length: boundary - lastEnd))
            if current.count + piece.count > Self.maxChunkChars, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = piece
            } else {
                current += piece
            }
            lastEnd = boundary
        }

        // Remainder
        if lastEnd < nsText.length {
            current += nsText.substring(from: lastEnd)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    /// Merges fragments shorter than minFragmentLength with adjacent chunks.
    private func mergeShortFragments(_ chunks: [String]) -> [String] {
        guard chunks.count > 1 else { return chunks }
        var result: [String] = []
        var accumulator = ""

        for chunk in chunks {
            if accumulator.isEmpty {
                accumulator = chunk
            } else if accumulator.count < Self.minFragmentLength || chunk.count < Self.minFragmentLength {
                accumulator += " " + chunk
            } else {
                result.append(accumulator)
                accumulator = chunk
            }
        }
        if !accumulator.isEmpty {
            result.append(accumulator)
        }
        return result
    }

    /// Enqueues text for TTS generation via Kokoro.
    private func enqueueUtterance(_ text: String) {
        pendingUtterances += 1
        logger.info("Enqueuing: \(text.prefix(60))…")

        if !firstChunkEnqueuedFired {
            firstChunkEnqueuedFired = true
            onFirstChunkEnqueued?()
        }

        let manager = KokoroManager.shared
        guard manager.isDownloaded else {
            logger.warning("Kokoro not downloaded, skipping: \(text.prefix(40))…")
            utteranceDidFinish()
            return
        }

        guard let snapshot = manager.captureGenerationContext() else {
            logger.warning("No voice/engine available, skipping: \(text.prefix(40))…")
            utteranceDidFinish()
            return
        }

        let slot = nextSlotIndex
        nextSlotIndex += 1

        let task = Task {
            let result: KokoroResult? = await withCheckedContinuation { continuation in
                self.generationQueue.async {
                    let gen = KokoroManager.generateAudioBufferOffMain(text: text, context: snapshot)
                    continuation.resume(returning: gen)
                }
            }

            guard !Task.isCancelled else { return }

            if let result {
                let item = PlaybackItem(buffer: result.buffer, wordTimings: result.wordTimings)
                self.slotReady(slot: slot, item: item)
            } else {
                logger.warning("Kokoro generation failed, skipping: \(text.prefix(40))…")
                self.slotFailed(slot: slot)
            }
        }
        generationTasks.append(task)
    }

    // MARK: - Ordered Slot Management

    /// Called when a TTS generation completes — stores the item in its ordered slot
    /// and drains any consecutive ready slots into the playback queue.
    private func slotReady(slot: Int, item: PlaybackItem) {
        orderedSlots[slot] = item
        if !firstAudioReadyFired {
            firstAudioReadyFired = true
            onFirstAudioReady?()
        }
        drainReadySlots()
    }

    /// Called when a TTS generation fails — skips this slot and drains.
    private func slotFailed(slot: Int) {
        utteranceDidFinish()
        // Mark slot as processed by advancing past it if it's next in line
        if slot == nextPlaySlot {
            nextPlaySlot += 1
            drainReadySlots()
        }
    }

    /// Drains consecutive ready slots into the playback buffer queue in order.
    private func drainReadySlots() {
        while let item = orderedSlots[nextPlaySlot] {
            orderedSlots.removeValue(forKey: nextPlaySlot)
            nextPlaySlot += 1
            bufferQueue.append(item)
            playNextBuffer()
        }
    }

    /// Decrements pending count and checks for stream completion.
    private func utteranceDidFinish() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if pendingUtterances == 0, streamEnded {
            completeStream()
        }
    }

    /// Plays the next buffer in the queue if nothing is currently playing.
    private func playNextBuffer() {
        guard !isPlaying, !bufferQueue.isEmpty else { return }

        // If we underran (queue emptied while more utterances were pending),
        // the gap between underrun and this call is audible dead air.
        if let underranAt = playbackUnderrunAt {
            let gap = Date().timeIntervalSince(underranAt)
            onPlaybackGap?(gap)
            playbackUnderrunAt = nil
        }

        isPlaying = true

        let item = bufferQueue.removeFirst()
        ensureEngineRunning(format: item.buffer.format)

        if !firstAudioPlaybackFired {
            firstAudioPlaybackFired = true
            onFirstAudioPlayback?()
        }

        // `.dataPlayedBack` fires AFTER the audio has actually been output
        // through the hardware (not when the buffer is merely consumed from
        // the render queue 100-300ms earlier).
        playerNode.scheduleBuffer(item.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.utteranceDidFinish()

                if !self.bufferQueue.isEmpty {
                    self.playNextBuffer()
                } else if self.pendingUtterances > 0, self.isStreaming {
                    // Buffer queue is empty but more text is on its way and we
                    // haven't finished streaming. Record an underrun; the next
                    // playNextBuffer() will report the gap.
                    self.playbackUnderrunAt = Date()
                }
            }
        }
        playerNode.play()
    }

    private func completeStream() {
        isStreaming = false
        streamEnded = false
        let cb = streamCompletion
        streamCompletion = nil
        cb?()
    }

    // MARK: - Text Cleaning

    /// Strips markdown, emojis, and other non-speech content.
    private func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove code blocks
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "",
            options: .regularExpression
        )

        // Remove inline code
        result = result.replacingOccurrences(
            of: "`[^`]+`",
            with: "",
            options: .regularExpression
        )

        // Remove headers
        result = result.replacingOccurrences(
            of: "(?m)^#{1,6}\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove bold/italic markers
        result = result.replacingOccurrences(
            of: "[*_]{1,3}",
            with: "",
            options: .regularExpression
        )

        // Remove bullet points
        result = result.replacingOccurrences(
            of: "(?m)^\\s*[-*+]\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove links — keep link text
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // Remove emojis
        result = result.unicodeScalars.filter { scalar in
            !(
                (0x1F600 ... 0x1F64F).contains(scalar.value) ||
                    (0x1F300 ... 0x1F5FF).contains(scalar.value) ||
                    (0x1F680 ... 0x1F6FF).contains(scalar.value) ||
                    (0x1F700 ... 0x1F77F).contains(scalar.value) ||
                    (0x1F780 ... 0x1F7FF).contains(scalar.value) ||
                    (0x1F800 ... 0x1F8FF).contains(scalar.value) ||
                    (0x1F900 ... 0x1F9FF).contains(scalar.value) ||
                    (0x1FA00 ... 0x1FA6F).contains(scalar.value) ||
                    (0x1FA70 ... 0x1FAFF).contains(scalar.value) ||
                    (0x2600 ... 0x26FF).contains(scalar.value) ||
                    (0x2700 ... 0x27BF).contains(scalar.value) ||
                    (0xFE00 ... 0xFE0F).contains(scalar.value) ||
                    (0x200D ... 0x200D).contains(scalar.value) ||
                    (0xE0020 ... 0xE007F).contains(scalar.value)
            )
        }.reduce(into: "") { $0 += String($1) }

        // Collapse multiple newlines
        result = result.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
