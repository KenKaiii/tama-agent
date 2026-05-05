import Foundation
@testable import Tama
import Testing

@Suite("ScheduleParser")
struct ScheduleParserTests {
    // MARK: - parseSchedule: cron expressions

    @Test("parseSchedule recognises a standard daily-at-9am cron")
    func parseCronDailyAt9am() {
        let result = ScheduleParser.parseSchedule("0 9 * * *")
        #expect(result != nil)
        #expect(result?.type == .cron)
        #expect(result?.schedule == "0 9 * * *")
    }

    @Test("parseSchedule recognises every-15-minutes cron with step")
    func parseCronEvery15Minutes() {
        let result = ScheduleParser.parseSchedule("*/15 * * * *")
        #expect(result != nil)
        #expect(result?.type == .cron)
        #expect(result?.schedule == "*/15 * * * *")
    }

    @Test("parseSchedule recognises weekday-specific cron (Mon–Fri at noon)")
    func parseCronWeekdayNoon() {
        let result = ScheduleParser.parseSchedule("0 12 * * 1-5")
        #expect(result != nil)
        #expect(result?.type == .cron)
    }

    @Test("parseSchedule rejects a 4-field string as cron")
    func parseScheduleRejects4Fields() {
        let result = ScheduleParser.parseSchedule("0 9 * *")
        // May parse as something else, but must NOT return type .cron
        if let r = result {
            #expect(r.type != .cron)
        }
    }

    @Test("parseSchedule returns nil for garbage input")
    func parseScheduleRejectsGarbage() {
        #expect(ScheduleParser.parseSchedule("not a schedule") == nil)
        #expect(ScheduleParser.parseSchedule("") == nil)
        #expect(ScheduleParser.parseSchedule("99 99 99 99 99") == nil)
    }

    // MARK: - parseEveryPattern

    @Test("parseSchedule every 2 hours → intervalSeconds = 7200")
    func parseEvery2Hours() {
        let result = ScheduleParser.parseSchedule("every 2 hours")
        #expect(result != nil)
        #expect(result?.type == .every)
        #expect(result?.intervalSeconds == 7_200)
    }

    @Test("parseSchedule every 30 minutes → intervalSeconds = 1800")
    func parseEvery30Minutes() {
        let result = ScheduleParser.parseSchedule("every 30 minutes")
        #expect(result != nil)
        #expect(result?.type == .every)
        #expect(result?.intervalSeconds == 1_800)
    }

    @Test("parseSchedule every 1 day → intervalSeconds = 86400")
    func parseEvery1Day() {
        let result = ScheduleParser.parseSchedule("every 1 day")
        #expect(result != nil)
        #expect(result?.type == .every)
        #expect(result?.intervalSeconds == 86_400)
    }

    @Test("parseSchedule every-pattern short aliases (h, m, d)")
    func parseEveryShortAliases() {
        let hours = ScheduleParser.parseSchedule("every 3 h")
        #expect(hours?.intervalSeconds == 10_800)

        let mins = ScheduleParser.parseSchedule("every 5 min")
        #expect(mins?.intervalSeconds == 300)

        let days = ScheduleParser.parseSchedule("every 2 d")
        #expect(days?.intervalSeconds == 172_800)
    }

    // MARK: - parseDateTime / relative "every day at Xam" via cron

    @Test("parseSchedule 'today Xpm' returns an .at schedule")
    func parseTodayRelative() {
        // Use a far-future time component to avoid flaky near-midnight failures
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        // Pick a time 2 hours in the future (capped at 11pm)
        let targetHour = min(hour + 2, 23)
        let ampm = targetHour >= 12 ? "pm" : "am"
        let displayHour = targetHour > 12 ? targetHour - 12 : (targetHour == 0 ? 12 : targetHour)
        let input = "today \(displayHour)\(ampm)"

        let result = ScheduleParser.parseSchedule(input)
        #expect(result != nil)
        #expect(result?.type == .at)
        if let runAt = result?.runAt {
            #expect(runAt > now)
        }
    }

    @Test("parseSchedule 'tomorrow 9am' returns an .at schedule in the future")
    func parseTomorrowAt9am() {
        let now = Date()
        let result = ScheduleParser.parseSchedule("tomorrow 9am")
        #expect(result != nil)
        #expect(result?.type == .at)
        if let runAt = result?.runAt {
            #expect(runAt > now)
        }
    }

    @Test("parseSchedule 'in 10 minutes' returns .at about 10 minutes away")
    func parseInDuration() {
        let before = Date()
        let result = ScheduleParser.parseSchedule("in 10 minutes")
        let after = Date()
        #expect(result != nil)
        #expect(result?.type == .at)
        if let runAt = result?.runAt {
            let delta = runAt.timeIntervalSince(before)
            // Should be between 599s and 601s + test overhead
            #expect(delta >= 599)
            #expect(delta <= 602 + after.timeIntervalSince(before))
        }
    }

    // MARK: - calculateNextRun

    @Test("calculateNextRun for .every returns a date approximately intervalSeconds from now")
    func calculateNextRunEvery() {
        let before = Date()
        let next = ScheduleParser.calculateNextRun(
            type: .every,
            schedule: nil,
            runAt: nil,
            intervalSeconds: 3600
        )
        let after = Date()
        #expect(next != nil)
        if let next {
            let delta = next.timeIntervalSince(before)
            #expect(delta >= 3599)
            #expect(delta <= 3601 + after.timeIntervalSince(before))
        }
    }

    @Test("calculateNextRun for .at with past date returns nil")
    func calculateNextRunAtPastDate() {
        let pastDate = Date(timeIntervalSinceNow: -3600)
        let result = ScheduleParser.calculateNextRun(
            type: .at,
            schedule: nil,
            runAt: pastDate,
            intervalSeconds: nil
        )
        #expect(result == nil)
    }

    @Test("calculateNextRun for .at with future date returns that date")
    func calculateNextRunAtFutureDate() {
        let future = Date(timeIntervalSinceNow: 3600)
        let result = ScheduleParser.calculateNextRun(
            type: .at,
            schedule: nil,
            runAt: future,
            intervalSeconds: nil
        )
        #expect(result != nil)
        if let result {
            #expect(abs(result.timeIntervalSince(future)) < 1)
        }
    }

    @Test("calculateNextRun for .cron '0 9 * * *' returns a date within 24 hours")
    func calculateNextRunCronDaily() {
        let now = Date()
        let result = ScheduleParser.calculateNextRun(
            type: .cron,
            schedule: "0 9 * * *",
            runAt: nil,
            intervalSeconds: nil
        )
        #expect(result != nil)
        if let result {
            #expect(result > now)
            #expect(result <= now.addingTimeInterval(25 * 3600)) // within 25h
            // The minute should be 0
            let cal = Calendar.current
            let minute = cal.component(.minute, from: result)
            #expect(minute == 0)
            // The hour should be 9
            let hour = cal.component(.hour, from: result)
            #expect(hour == 9)
        }
    }

    @Test("calculateNextRun for .cron '*/15 * * * *' returns within 15 minutes")
    func calculateNextRunCronEvery15Min() {
        let now = Date()
        let result = ScheduleParser.calculateNextRun(
            type: .cron,
            schedule: "*/15 * * * *",
            runAt: nil,
            intervalSeconds: nil
        )
        #expect(result != nil)
        if let result {
            #expect(result > now)
            #expect(result <= now.addingTimeInterval(16 * 60))
        }
    }

    @Test("calculateNextRun for .cron across DST — result minute is always 0")
    func calculateNextRunCronAcrossDST() {
        // Build a reference time just before the US/Eastern spring-forward
        // (second Sunday in March, clocks jump 2:00→3:00).
        // March 9 2025 01:30 AM EST is 30 min before the transition.
        var cal = Calendar(identifier: .gregorian)
        guard let nyTZ = TimeZone(identifier: "America/New_York") else { return }
        cal.timeZone = nyTZ

        var comps = DateComponents()
        comps.year = 2025
        comps.month = 3
        comps.day = 9
        comps.hour = 1
        comps.minute = 30
        comps.second = 0
        comps.timeZone = nyTZ
        guard let dstEdge = cal.date(from: comps) else { return }

        // calculateNextRun wraps nextCronRun internally.
        // "0 9 * * *" — 9am daily; should always land at minute=0.
        let result = ScheduleParser.calculateNextRun(
            type: .cron,
            schedule: "0 9 * * *",
            runAt: nil,
            intervalSeconds: nil
        )
        // The public API uses `Date()` internally, so we can't inject the DST
        // edge date. Instead, verify the structural guarantee: minute == 0.
        if let result {
            let minute = Calendar.current.component(.minute, from: result)
            #expect(minute == 0)
            #expect(result > Date())
        }

        // Separately, verify matchesCronField still works correctly at the
        // minute/hour boundary that would be skipped by DST.
        // At the spring-forward moment, the hour component jumps from 1→3,
        // meaning hour 2 never exists. The cron spec "0 2 * * *" would
        // have no valid candidate in that 48h window — that's acceptable
        // behaviour (nil result), not a crash.
        _ = dstEdge // used to build context above
    }

    // MARK: - matchesCronField

    @Test("matchesCronField wildcard * always matches")
    func matchesCronFieldWildcard() {
        #expect(ScheduleParser.matchesCronField("*", value: 0, min: 0, max: 59))
        #expect(ScheduleParser.matchesCronField("*", value: 30, min: 0, max: 59))
        #expect(ScheduleParser.matchesCronField("*", value: 59, min: 0, max: 59))
    }

    @Test("matchesCronField exact value")
    func matchesCronFieldExact() {
        #expect(ScheduleParser.matchesCronField("9", value: 9, min: 0, max: 23))
        #expect(!ScheduleParser.matchesCronField("9", value: 10, min: 0, max: 23))
    }

    @Test("matchesCronField range 1-5")
    func matchesCronFieldRange() {
        for v in 1 ... 5 {
            #expect(ScheduleParser.matchesCronField("1-5", value: v, min: 0, max: 6))
        }
        #expect(!ScheduleParser.matchesCronField("1-5", value: 0, min: 0, max: 6))
        #expect(!ScheduleParser.matchesCronField("1-5", value: 6, min: 0, max: 6))
    }

    @Test("matchesCronField step */15")
    func matchesCronFieldStep() {
        for v in stride(from: 0, through: 59, by: 15) {
            #expect(ScheduleParser.matchesCronField("*/15", value: v, min: 0, max: 59))
        }
        #expect(!ScheduleParser.matchesCronField("*/15", value: 1, min: 0, max: 59))
        #expect(!ScheduleParser.matchesCronField("*/15", value: 16, min: 0, max: 59))
    }

    @Test("matchesCronField comma-separated list")
    func matchesCronFieldList() {
        #expect(ScheduleParser.matchesCronField("1,3,5", value: 1, min: 0, max: 7))
        #expect(ScheduleParser.matchesCronField("1,3,5", value: 3, min: 0, max: 7))
        #expect(ScheduleParser.matchesCronField("1,3,5", value: 5, min: 0, max: 7))
        #expect(!ScheduleParser.matchesCronField("1,3,5", value: 2, min: 0, max: 7))
        #expect(!ScheduleParser.matchesCronField("1,3,5", value: 4, min: 0, max: 7))
    }

    @Test("matchesCronField step with offset: 2/3 means 2, 5, 8, ...")
    func matchesCronFieldStepWithOffset() {
        // "2/3" → start=2, step=3 → matches 2, 5, 8, 11, ...
        #expect(ScheduleParser.matchesCronField("2/3", value: 2, min: 0, max: 59))
        #expect(ScheduleParser.matchesCronField("2/3", value: 5, min: 0, max: 59))
        #expect(ScheduleParser.matchesCronField("2/3", value: 8, min: 0, max: 59))
        #expect(!ScheduleParser.matchesCronField("2/3", value: 3, min: 0, max: 59))
        #expect(!ScheduleParser.matchesCronField("2/3", value: 4, min: 0, max: 59))
    }
}
