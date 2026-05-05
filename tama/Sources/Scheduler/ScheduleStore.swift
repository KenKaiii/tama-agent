import Foundation
import os
import UserNotifications

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "scheduler"
)

/// Persisted scheduled job — reminders produce notifications, routines invoke the agent.
struct ScheduledJob: Codable, Identifiable {
    let id: UUID
    var name: String
    var jobType: JobType
    var scheduleType: ScheduleType
    var schedule: String?
    var runAt: Date?
    var intervalSeconds: Int?
    var prompt: String
    var nextRunAt: Date?
    var deleteAfterRun: Bool
    var enabled: Bool
    var createdAt: Date
    var runCount: Int

    enum JobType: String, Codable { case reminder, routine }
    enum ScheduleType: String, Codable { case at, every, cron }

    init(
        id: UUID,
        name: String,
        jobType: JobType,
        scheduleType: ScheduleType,
        schedule: String?,
        runAt: Date?,
        intervalSeconds: Int?,
        prompt: String,
        nextRunAt: Date?,
        deleteAfterRun: Bool,
        enabled: Bool,
        createdAt: Date,
        runCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.jobType = jobType
        self.scheduleType = scheduleType
        self.schedule = schedule
        self.runAt = runAt
        self.intervalSeconds = intervalSeconds
        self.prompt = prompt
        self.nextRunAt = nextRunAt
        self.deleteAfterRun = deleteAfterRun
        self.enabled = enabled
        self.createdAt = createdAt
        self.runCount = runCount
    }

    // Custom decoder to handle legacy schedules without runCount
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        jobType = try container.decode(JobType.self, forKey: .jobType)
        scheduleType = try container.decode(ScheduleType.self, forKey: .scheduleType)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        runAt = try container.decodeIfPresent(Date.self, forKey: .runAt)
        intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        prompt = try container.decode(String.self, forKey: .prompt)
        nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        deleteAfterRun = try container.decode(Bool.self, forKey: .deleteAfterRun)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
    }
}

/// Closure that actually runs the agent for a scheduled routine.
/// Returns the assistant’s final text. Tests inject a stub; production uses
/// `defaultRoutineRunner` which drives `AgentLoop`.
typealias RoutineRunner = @MainActor (ScheduledJob) async throws -> String

/// Production implementation of `RoutineRunner` — invokes `AgentLoop`.
@MainActor
func defaultRoutineRunner(_ job: ScheduledJob) async throws -> String {
    let agentLoop = AgentLoop()
    let messages: [[String: Any]] = [
        ["role": "user", "content": job.prompt],
    ]
    nonisolated(unsafe) var collectedText = ""
    _ = try await agentLoop.run(
        messages: messages,
        systemPrompt: "You are a helpful assistant running a scheduled routine. Be concise."
    ) { event in
        if case let .turnComplete(text) = event {
            collectedText = text
        }
    }
    return collectedText
}

/// Manages scheduled jobs: persistence, polling, and execution.
@MainActor
final class ScheduleStore {
    static let shared = ScheduleStore()

    private(set) var jobs: [ScheduledJob] = []
    private var pollTimer: Timer?

    /// IDs of routines currently executing (for shimmer effect *and* re-entrancy guard).
    /// A routine whose ID is in this set will not be re-fired by `checkDueJobs`
    /// even if its `nextRunAt` has elapsed — prevents duplicate runs of
    /// long-running routines that exceed the polling interval.
    private(set) var activeRoutineIDs: Set<UUID> = []

    /// Pluggable routine runner. Production uses `defaultRoutineRunner`; tests
    /// inject a stub via `makeForTesting(runner:)`.
    private let routineRunner: RoutineRunner

    /// When `false`, `executeRoutine` skips disk persistence, browser/session/
    /// notification side effects, and only runs the injected `routineRunner`
    /// while maintaining `activeRoutineIDs` and `runCount`. Used by unit tests.
    private let runsSideEffects: Bool

    private init(
        runner: @escaping RoutineRunner = defaultRoutineRunner,
        runsSideEffects: Bool = true,
        loadFromDisk shouldLoadFromDisk: Bool = true
    ) {
        routineRunner = runner
        self.runsSideEffects = runsSideEffects
        if shouldLoadFromDisk {
            loadFromDisk()
        }
    }

    /// Creates a hermetic store for unit tests: no disk I/O, no browser/session/
    /// notification side effects, and a swappable routine runner.
    static func makeForTesting(runner: @escaping RoutineRunner) -> ScheduleStore {
        ScheduleStore(runner: runner, runsSideEffects: false, loadFromDisk: false)
    }

    // swiftlint:disable identifier_name
    /// Test-only: append a fully-formed job without touching disk.
    func _appendJobForTesting(_ job: ScheduledJob) {
        precondition(!runsSideEffects, "_appendJobForTesting may only be used on a testing store")
        jobs.append(job)
    }

    /// Test-only: force a job's `nextRunAt` so the next `checkDueJobs` will
    /// consider it due. Returns true if the job was found.
    @discardableResult
    func _forceDueForTesting(id: UUID) -> Bool {
        precondition(!runsSideEffects, "_forceDueForTesting may only be used on a testing store")
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs[i].nextRunAt = Date(timeIntervalSinceNow: -1)
        return true
    }

    /// Test-only: insert into the active set to simulate an in-flight routine.
    func _markActiveForTesting(_ id: UUID) {
        precondition(!runsSideEffects, "_markActiveForTesting may only be used on a testing store")
        activeRoutineIDs.insert(id)
    }

    // swiftlint:enable identifier_name

    // MARK: - Public API

    func start() {
        let count = jobs.count
        logger.info("Starting scheduler with \(count) jobs")
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDueJobs()
            }
        }
        // Run once immediately
        checkDueJobs()
    }

    func stop() {
        logger.info("Stopping scheduler")
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func addJob(
        name: String,
        jobType: ScheduledJob.JobType,
        parsed: ParsedSchedule,
        prompt: String
    ) -> ScheduledJob {
        let job = ScheduledJob(
            id: UUID(),
            name: name,
            jobType: jobType,
            scheduleType: parsed.type.toJobScheduleType,
            schedule: parsed.schedule,
            runAt: parsed.runAt,
            intervalSeconds: parsed.intervalSeconds,
            prompt: prompt,
            nextRunAt: parsed.runAt ?? ScheduleParser.calculateNextRun(
                type: parsed.type,
                schedule: parsed.schedule,
                runAt: parsed.runAt,
                intervalSeconds: parsed.intervalSeconds
            ),
            deleteAfterRun: parsed.type == .at,
            enabled: true,
            createdAt: Date(),
            runCount: 0
        )
        jobs.append(job)
        saveToDisk()
        logger.info("Added job '\(name)' type=\(jobType.rawValue) scheduleType=\(parsed.type.rawValue)")
        return job
    }

    func deleteJob(named name: String) -> Bool {
        let before = jobs.count
        jobs.removeAll { $0.name.lowercased() == name.lowercased() }
        if jobs.count < before {
            saveToDisk()
            logger.info("Deleted job '\(name)'")
            return true
        }
        return false
    }

    func deleteJob(id: UUID) -> Bool {
        let before = jobs.count
        jobs.removeAll { $0.id == id }
        if jobs.count < before {
            saveToDisk()
            logger.info("Deleted job \(id.uuidString)")
            return true
        }
        return false
    }

    func runRoutineNow(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id && $0.jobType == .routine }) else {
            logger.warning("Routine \(id.uuidString) not found or not a routine")
            return
        }
        logger.info("Manually triggering routine '\(job.name)'")
        executeRoutine(job)
    }

    func listJobs() -> [ScheduledJob] {
        jobs.filter(\.enabled)
    }

    // MARK: - Polling

    /// Internal entry point used by both the timer and tests.
    /// Marked `internal` so the test target can drive the polling loop directly.
    func checkDueJobs() {
        let now = Date()
        var modified = false

        for i in jobs.indices.reversed() {
            guard jobs[i].enabled, let nextRun = jobs[i].nextRunAt, nextRun <= now else {
                continue
            }

            let job = jobs[i]

            // Skip routines that are still running from a previous tick.
            // Long-running routines (>30s) would otherwise be fired again on
            // every poll, double-charging API calls and re-running side effects.
            if job.jobType == .routine, activeRoutineIDs.contains(job.id) {
                logger.info("Skipping '\(job.name)' — previous run still in flight")
                continue
            }

            logger.info("Job '\(job.name)' is due — executing")

            switch job.jobType {
            case .reminder:
                fireReminderNotification(job)
            case .routine:
                executeRoutine(job)
            }

            if job.deleteAfterRun {
                jobs.remove(at: i)
                logger.info("Removed one-shot job '\(job.name)'")
            } else {
                // Calculate next run
                jobs[i].nextRunAt = ScheduleParser.calculateNextRun(
                    type: ParsedSchedule.ScheduleType(rawValue: job.scheduleType.rawValue) ?? .at,
                    schedule: job.schedule,
                    runAt: nil,
                    intervalSeconds: job.intervalSeconds
                )
                let nextRun = jobs[i].nextRunAt
                logger.info("Next run for '\(job.name)': \(String(describing: nextRun))")
            }
            modified = true
        }

        if modified {
            saveToDisk()
        }
    }

    // MARK: - Notification

    private func fireReminderNotification(_ job: ScheduledJob) {
        // Notch notification for visual flair when screen is active
        NotchNotificationPresenter.showReminder(name: job.name, message: job.prompt)

        // Persist as an individual reminder session
        let reminderMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: [.text("**\(job.name)**\n\n\(job.prompt)")],
            timestamp: Date()
        )
        let reminderSession = ChatSession(
            id: UUID(),
            title: job.name,
            messages: [reminderMessage],
            createdAt: Date(),
            updatedAt: Date(),
            moodIcon: "⏰",
            sessionType: .reminders
        )
        SessionStore.shared.save(session: reminderSession)
        SessionStore.shared.pruneExcess(type: .reminders, max: 25)

        // System notification for Notification Center history
        let content = UNMutableNotificationContent()
        content.title = "Tama Reminder"
        content.subtitle = job.name
        content.body = job.prompt
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: job.id.uuidString,
            content: content,
            trigger: nil
        )

        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Delivered reminder notification for '\(job.name)'")
            } catch {
                logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Routine Execution

    func executeRoutine(_ job: ScheduledJob) {
        // Mark as active *before* spawning the Task so a poll that fires while
        // the Task is still scheduling will see the in-flight ID and skip.
        // The 30s polling tick can otherwise race the Task hop and re-fire.
        activeRoutineIDs.insert(job.id)
        if runsSideEffects {
            NotchActivityIndicator.addProcess(id: job.id.uuidString, label: "Routine: \(job.name)")
        }

        // Increment run count synchronously so tests can observe the increment
        // without awaiting the routine’s async work to finish.
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].runCount += 1
            if runsSideEffects {
                saveToDisk()
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // `defer` runs on every exit path — success, thrown error, and
            // `AgentInterruptedError` alike — so the in-flight guard can never
            // leak.
            defer {
                activeRoutineIDs.remove(job.id)
                if runsSideEffects {
                    NotchActivityIndicator.removeProcess(id: job.id.uuidString)
                }
            }

            logger.info("Running routine '\(job.name)' with prompt: \(job.prompt.prefix(100))")

            let resultText: String
            do {
                resultText = try await routineRunner(job)
            } catch {
                logger
                    .error(
                        "Routine '\(job.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                    )
                resultText = "Routine failed: \(error.localizedDescription)"
            }

            guard runsSideEffects else { return }

            // Clean up any browser processes launched during the routine.
            BrowserManager.shared.disconnect()

            // Persist as an individual routine session
            let userMsg = ChatMessage(
                id: UUID(),
                role: .user,
                content: [.text(job.prompt)],
                timestamp: Date()
            )
            let assistantMsg = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: [.text("**\(job.name)**\n\n\(resultText)")],
                timestamp: Date()
            )
            let routineSession = ChatSession(
                id: UUID(),
                title: job.name,
                messages: [userMsg, assistantMsg],
                createdAt: Date(),
                updatedAt: Date(),
                moodIcon: "⚡",
                sessionType: .routines
            )
            SessionStore.shared.save(session: routineSession)
            SessionStore.shared.pruneExcess(type: .routines, max: 25)

            // Notch notification for visual flair when screen is active
            NotchNotificationPresenter.showRoutineResult(name: job.name, result: resultText)

            // System notification for Notification Center history
            let content = UNMutableNotificationContent()
            content.title = job.name
            content.body = String(resultText.prefix(256))
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "\(job.id.uuidString)-result",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Failed to deliver routine notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private static func storageURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Tama", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }

    private func loadFromDisk() {
        do {
            let url = try Self.storageURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.info("No schedules file found — starting fresh")
                return
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([ScheduledJob].self, from: data)
            let loadedCount = jobs.count
            logger.info("Loaded \(loadedCount) scheduled jobs from disk")
        } catch {
            logger.error("Failed to load schedules: \(error.localizedDescription)")
            jobs = []
        }
    }

    private func saveToDisk() {
        do {
            let url = try Self.storageURL()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(jobs)
            try data.write(to: url, options: .atomic)
            let savedCount = jobs.count
            logger.debug("Saved \(savedCount) scheduled jobs to disk")
        } catch {
            logger.error("Failed to save schedules: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

extension ParsedSchedule.ScheduleType {
    var toJobScheduleType: ScheduledJob.ScheduleType {
        switch self {
        case .at: .at
        case .every: .every
        case .cron: .cron
        }
    }
}
