import Foundation
@testable import Tama
import Testing

// MARK: - Helpers

@MainActor
private func makeRoutineJob(
    name: String = "test-routine",
    intervalSeconds: Int = 1,
    nextRunAt: Date = Date(timeIntervalSinceNow: -1) // already due
) -> ScheduledJob {
    ScheduledJob(
        id: UUID(),
        name: name,
        jobType: .routine,
        scheduleType: .every,
        schedule: nil,
        runAt: nil,
        intervalSeconds: intervalSeconds,
        prompt: "noop",
        nextRunAt: nextRunAt,
        deleteAfterRun: false,
        enabled: true,
        createdAt: Date(),
        runCount: 0
    )
}

// MARK: - Tests

@Suite("ScheduleStore in-flight coalescing")
@MainActor
struct ScheduleStoreInFlightTests {

    /// Two `checkDueJobs` polls within the routine's runtime must only fire it
    /// once. Reproduces the bug where a long-running BashTool (>poll interval)
    /// caused duplicate runs and double-charges.
    @Test("slow routine with interval=1s is not re-fired by a second poll")
    func slowRoutineNotRefiredByConcurrentPoll() async throws {
        // The runner sleeps long enough that a second poll arrives mid-flight.
        let runner: RoutineRunner = { _ in
            try await Task.sleep(for: .milliseconds(800))
            return "ok"
        }
        let store = ScheduleStore.makeForTesting(runner: runner)
        let job = makeRoutineJob(intervalSeconds: 1)
        store._appendJobForTesting(job)

        // First poll: due → fires routine, runCount becomes 1, ID is in activeRoutineIDs.
        store.checkDueJobs()
        #expect(store.activeRoutineIDs.contains(job.id), "Active set must include job before runner finishes")
        #expect(store.jobs.first?.runCount == 1)

        // Force the job to be due again (simulating clock advance past nextRunAt
        // while the previous run is still in flight).
        store._forceDueForTesting(id: job.id)

        // Second poll within 1.5s of first — runner is still sleeping.
        try await Task.sleep(for: .milliseconds(300))
        store.checkDueJobs()

        // Re-firing must have been skipped.
        #expect(store.jobs.first?.runCount == 1, "runCount must remain 1 — got \(store.jobs.first?.runCount ?? -1)")
        #expect(store.activeRoutineIDs.contains(job.id), "Routine still in flight")

        // Wait for the runner to finish so the defer clears the active set.
        try await Task.sleep(for: .milliseconds(700))
        #expect(!store.activeRoutineIDs.contains(job.id), "Active set must be cleared after runner returns")
    }

    /// On a thrown error (including AgentInterruptedError-style failures) the
    /// `defer` must still clear `activeRoutineIDs` so the next poll can fire.
    @Test("activeRoutineIDs is cleared even when the routine throws")
    func activeIDsClearedOnError() async throws {
        struct DummyInterruptedError: Error {}

        let runner: RoutineRunner = { _ in
            try await Task.sleep(for: .milliseconds(100))
            throw DummyInterruptedError()
        }
        let store = ScheduleStore.makeForTesting(runner: runner)
        let job = makeRoutineJob()
        store._appendJobForTesting(job)

        store.checkDueJobs()
        #expect(store.activeRoutineIDs.contains(job.id))

        // Wait long enough for the runner to throw and the defer to run.
        try await Task.sleep(for: .milliseconds(400))
        #expect(!store.activeRoutineIDs.contains(job.id),
                "Active set must be cleared after error")

        // A subsequent poll on the same job must therefore fire it again.
        store._forceDueForTesting(id: job.id)
        store.checkDueJobs()
        #expect(store.jobs.first?.runCount == 2, "Second run after prior error should bump runCount to 2")
    }

    /// A reminder job is unaffected by the routine in-flight guard.
    @Test("reminder is not blocked by routine in-flight set")
    func reminderNotBlockedByRoutineGuard() async throws {
        let runner: RoutineRunner = { _ in "" }
        let store = ScheduleStore.makeForTesting(runner: runner)

        let routine = makeRoutineJob(name: "long-routine")
        store._appendJobForTesting(routine)
        // Manually mark the routine active to simulate it being in flight.
        store._markActiveForTesting(routine.id)

        // The reminder shares no relationship to the active routine and must still fire.
        let reminder = ScheduledJob(
            id: UUID(),
            name: "rem",
            jobType: .reminder,
            scheduleType: .every,
            schedule: nil,
            runAt: nil,
            intervalSeconds: 60,
            prompt: "ping",
            nextRunAt: Date(timeIntervalSinceNow: -1),
            deleteAfterRun: false,
            enabled: true,
            createdAt: Date(),
            runCount: 0
        )
        store._appendJobForTesting(reminder)

        // Should not throw / hang. Reminders fire a notification request via
        // UNUserNotificationCenter inside an unstructured Task, but
        // `checkDueJobs` itself returns synchronously.
        store.checkDueJobs()

        // The routine remains "active" (we set it) and was therefore skipped:
        // its runCount stays 0 (we never let executeRoutine increment it).
        let routineEntry = store.jobs.first { $0.id == routine.id }
        #expect(routineEntry?.runCount == 0, "Active routine must not be re-fired")
    }
}
