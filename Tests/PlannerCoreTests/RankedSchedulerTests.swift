import XCTest

@testable import PlannerCore

final class RankedSchedulerTests: XCTestCase {
  let scheduler = Scheduler()
  func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  var calendar: Calendar {
    var result = Calendar(identifier: .gregorian)
    result.timeZone = TimeZone(secondsFromGMT: 0)!
    return result
  }
  var from: Date { date("2026-09-28T09:00:00Z") }  // Monday
  var deadline: Date { date("2026-10-05T00:00:00Z") }
  func ranked(
    _ task: SchedulingTask = .init(duration: 60), busy: [BusyInterval] = [],
    preferences: SchedulingPreferences = .init(), constraints: [PlanningConstraint] = []
  ) -> SchedulingEvaluation {
    scheduler.rank(
      task, busy: busy, from: from, deadline: deadline, preferences: preferences,
      constraints: constraints, calendar: calendar)
  }
  func testHardRulesAreNeverTradedForHighSoftScores() throws {
    var task = SchedulingTask(duration: 60)
    task.preferredDays = [4]  // Wednesday forbidden despite preference
    task.latestEnd = date("2026-10-02T12:00:00Z")
    var p = SchedulingPreferences()
    p.weights.preferredDay = 100
    p.availabilityWindows = [.init(weekdays: [2, 3, 4, 5, 6], startMinute: 600, endMinute: 720)]
    let rule = PlanningConstraint(
      type: .hard, key: .excludedWeekdays, value: .init(weekdays: [4]), text: "No Wednesday")
    let busy = [
      BusyInterval(start: date("2026-09-29T10:00:00Z"), end: date("2026-09-29T12:00:00Z"))
    ]
    let result = ranked(task, busy: busy, preferences: p, constraints: [rule])
    let best = try XCTUnwrap(result.selected)
    for candidate in [best] + result.alternatives {
      XCTAssertNotEqual(calendar.component(.weekday, from: candidate.start), 4)
      XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: candidate.start), 10)
      XCTAssertLessThanOrEqual(calendar.component(.hour, from: candidate.end), 12)
      XCTAssertLessThanOrEqual(candidate.end, task.latestEnd!)
      XCTAssertFalse(Scheduler.conflicts(start: candidate.start, end: candidate.end, busy: busy))
    }
    var oversized = task
    oversized.duration = 180
    XCTAssertNil(ranked(oversized, preferences: p).selected)
    oversized.splittable = true  // no silent duration reduction
    XCTAssertNil(ranked(oversized, preferences: p).selected)
  }
  func testLockedSessionNeverMovedAndConflictsAreReported() throws {
    var task = SchedulingTask(duration: 60)
    task.locked = true
    task.scheduledStart = date("2026-09-30T14:00:00Z")
    task.preferredDays = [6]
    XCTAssertEqual(ranked(task).selected?.start, task.scheduledStart)
    let busy = [
      BusyInterval(start: task.scheduledStart!, end: task.scheduledStart!.addingTimeInterval(3600))
    ]
    let failure = ranked(task, busy: busy)
    XCTAssertNil(failure.selected)
    XCTAssertTrue(failure.alternatives.isEmpty)
    XCTAssertEqual(failure.reasons.first?.code, .noFeasibleSlot)
  }
  func testPreferredWindowImprovesScoreAndLaterSlotWins() throws {
    var task = SchedulingTask(duration: 60)
    task.preferredWindows = [.init(weekdays: [2], startMinute: 1020, endMinute: 1140)]
    let earlier = try XCTUnwrap(
      scheduler.candidate(
        task, at: from, busy: [], from: from, deadline: deadline, calendar: calendar))
    let later = try XCTUnwrap(
      scheduler.candidate(
        task, at: date("2026-09-28T17:00:00Z"), busy: [], from: from, deadline: deadline,
        calendar: calendar))
    XCTAssertGreaterThan(later.score, earlier.score)
    let result = try XCTUnwrap(ranked(task).selected)
    XCTAssertGreaterThan(result.start, from)
    XCTAssertTrue(result.reasons.contains { $0.code == .preferredTime })
    XCTAssertEqual(calendar.component(.weekday, from: result.start), 2)
    XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: result.start), 17)
  }
  func testOverloadedDayIsPenalized() throws {
    let busy = [
      BusyInterval(start: from.addingTimeInterval(4 * 3600), end: from.addingTimeInterval(6 * 3600))
    ]
    let task = SchedulingTask(duration: 60)
    let monday = try XCTUnwrap(
      scheduler.candidate(
        task, at: from, busy: busy, from: from, deadline: deadline, calendar: calendar))
    let tuesday = try XCTUnwrap(
      scheduler.candidate(
        task, at: from.addingTimeInterval(86400), busy: busy, from: from, deadline: deadline,
        calendar: calendar))
    XCTAssertLessThan(monday.score, tuesday.score)
    XCTAssertEqual(ranked(task, busy: busy).selected?.start, from.addingTimeInterval(86400))
    XCTAssertEqual(monday.contributions.first { $0.factor == .workloadBalance }?.feature, -0.5)
  }
  func testAlternativesAreRankedAndFeasible() throws {
    var task = SchedulingTask(duration: 60)
    task.preferredDays = [6]
    let result = ranked(task)
    let best = try XCTUnwrap(result.selected)
    XCTAssertEqual(result.alternatives.count, 3)
    let all = [best] + result.alternatives
    for i in 1..<all.count {
      XCTAssertGreaterThanOrEqual(all[i - 1].score, all[i].score)
      if all[i - 1].score == all[i].score { XCTAssertLessThan(all[i - 1].start, all[i].start) }
      XCTAssertNotNil(
        scheduler.candidate(
          task, at: all[i].start, busy: [], from: from, deadline: deadline, calendar: calendar))
    }
    XCTAssertEqual(Set(all.map(\.start)).count, all.count)
  }
  func testExpiredTemporaryConstraintIgnored() {
    let expired = PlanningConstraint(
      type: .hard, key: .excludedWeekdays,
      value: .init(weekdays: [1, 2, 3, 4, 5, 6, 7]), source: .temporary,
      startDate: from.addingTimeInterval(-86400), expiration: from, text: "Yesterday off")
    XCTAssertEqual(ranked(constraints: [expired]).selected, ranked().selected)
    var inactive = expired
    inactive.expiration = deadline
    inactive.active = false
    XCTAssertEqual(ranked(constraints: [inactive]).selected, ranked().selected)
  }
  func testConstraintStartsAndExpiresWithinHorizon() throws {
    let rule = PlanningConstraint(
      type: .hard, key: .excludedWeekdays, value: .init(weekdays: [2]),
      source: .temporary, startDate: from, expiration: from.addingTimeInterval(3600),
      text: "Busy for an hour")
    let result = try XCTUnwrap(ranked(constraints: [rule]).selected)
    XCTAssertGreaterThanOrEqual(result.start, rule.expiration!)
    XCTAssertNotNil(
      scheduler.candidate(
        .init(duration: 60), at: from.addingTimeInterval(3600), busy: [], from: from,
        deadline: deadline, constraints: [rule], calendar: calendar))
  }
  func testDeterministicWithSameInputsAndReorderedBusyIntervals() {
    var task = SchedulingTask(duration: 60)
    task.preferredDays = [3, 5]
    let busy = [
      BusyInterval(start: from, end: from.addingTimeInterval(3600)),
      BusyInterval(
        start: from.addingTimeInterval(4 * 3600), end: from.addingTimeInterval(5 * 3600)),
    ]
    let first = ranked(task, busy: busy)
    for _ in 0..<3 {
      XCTAssertEqual(ranked(task, busy: busy).selected, first.selected)
      XCTAssertEqual(ranked(task, busy: busy.reversed()).alternatives, first.alternatives)
    }
  }
  func testExplicitEnergyWindowsOnly() throws {
    var task = SchedulingTask(duration: 60)
    task.energyRequirement = "high"
    XCTAssertEqual(
      ranked(task).selected?.contributions.first { $0.factor == .energyMatch }?.feature, 0)
    var p = SchedulingPreferences()
    p.energyWindows = [.init(window: .init(startMinute: 1020, endMinute: 1140), energy: "high")]
    let best = try XCTUnwrap(ranked(task, preferences: p).selected)
    XCTAssertTrue(best.reasons.contains { $0.code == .energyMatch })
    XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: best.start), 17)
  }
  func testHardDailyLimitAndEnergyRule() {
    let rules: [PlanningConstraint] = [
      .init(
        type: .hard, key: .dailyWorkLimit, value: .init(weekdays: [2], minutes: 60),
        text: "Max Monday 60m"),
      .init(
        type: .hard, key: .energyLimit,
        value: .init(startMinute: 1260, endMinute: 1440, energy: "high"),
        text: "No heavy work after 21"),
    ]
    let busy = [BusyInterval(start: from, end: from.addingTimeInterval(3600))]
    var p = SchedulingPreferences()
    p.endHour = 24
    var task = SchedulingTask(duration: 60)
    task.energyRequirement = "high"
    XCTAssertNil(
      scheduler.candidate(
        task, at: from.addingTimeInterval(2 * 3600), busy: busy, from: from, deadline: deadline,
        preferences: p, constraints: rules, calendar: calendar))
    XCTAssertNil(
      scheduler.candidate(
        task, at: date("2026-09-29T21:00:00Z"), busy: [], from: from, deadline: deadline,
        preferences: p, constraints: rules, calendar: calendar))
    task.energyRequirement = "low"
    XCTAssertNotNil(
      scheduler.candidate(
        task, at: date("2026-09-29T21:00:00Z"), busy: [], from: from, deadline: deadline,
        preferences: p, constraints: rules, calendar: calendar))
  }
  func testTravelAndBufferImpossibilityRejected() {
    var task = SchedulingTask(duration: 60)
    task.location = "Campus"
    task.bufferMinutes = 30
    var p = SchedulingPreferences()
    p.travelTimes = [.init(from: "Gym", to: "Campus", minutes: 60)]
    let busy = [
      BusyInterval(
        start: from, end: from.addingTimeInterval(3600), location: "Gym", kind: .training)
    ]
    XCTAssertNil(
      scheduler.candidate(
        task, at: from.addingTimeInterval(5400), busy: busy, from: from, deadline: deadline,
        preferences: p, calendar: calendar))
    XCTAssertNotNil(
      scheduler.candidate(
        task, at: from.addingTimeInterval(7200), busy: busy, from: from, deadline: deadline,
        preferences: p, calendar: calendar))
  }
  func testTrainingPenaltyRequiresExplicitPreferenceAndMetadata() throws {
    var task = SchedulingTask(duration: 60)
    task.energyRequirement = "high"
    let busy = [BusyInterval(start: from, end: from.addingTimeInterval(3600), kind: .training)]
    let at = from.addingTimeInterval(4500)
    let neutral = try XCTUnwrap(
      scheduler.candidate(
        task, at: at, busy: busy, from: from, deadline: deadline, calendar: calendar))
    XCTAssertEqual(neutral.contributions.first { $0.factor == .postTrainingPenalty }?.feature, 0)
    var p = SchedulingPreferences()
    p.postTrainingRecoveryMinutes = 120
    let penalty = try XCTUnwrap(
      scheduler.candidate(
        task, at: at, busy: busy, from: from, deadline: deadline, preferences: p, calendar: calendar
      ))
    XCTAssertLessThan(penalty.score, neutral.score)
  }
  func testSoftRuleCanLoseWithoutViolatingHardRule() throws {
    let hard = PlanningConstraint(
      type: .hard, key: .preferredDays, value: .init(weekdays: [4]), text: "Only Wednesday")
    let soft = PlanningConstraint(
      type: .soft, key: .lightDay, value: .init(weekdays: [4], minutes: 30),
      text: "Prefer Wednesday light")
    let result = try XCTUnwrap(ranked(constraints: [hard, soft]).selected)
    XCTAssertEqual(calendar.component(.weekday, from: result.start), 4)
    XCTAssertTrue(result.reasons.contains { $0.code == .lightDay })
    XCTAssertLessThan(result.contributions.first { $0.factor == .softConstraint }!.feature, 0)
  }
  func testNoFeasibleSlotNeverReturnsHardViolatingAlternatives() {
    let rule = PlanningConstraint(
      type: .hard, key: .excludedWeekdays, value: .init(weekdays: [1, 2, 3, 4, 5, 6, 7]),
      text: "No days")
    let result = ranked(constraints: [rule])
    XCTAssertNil(result.selected)
    XCTAssertTrue(result.alternatives.isEmpty)
    XCTAssertTrue(result.isWeak)
    XCTAssertEqual(result.feasibleCandidateCount, 0)
  }
  func testWorkloadUnionsOverlappingEvents() throws {
    let first = BusyInterval(start: from, end: from.addingTimeInterval(3600))
    let second = BusyInterval(
      start: from.addingTimeInterval(1800), end: from.addingTimeInterval(5400))
    let candidate = try XCTUnwrap(
      scheduler.candidate(
        .init(duration: 60), at: from.addingTimeInterval(7200), busy: [first, second], from: from,
        deadline: deadline, calendar: calendar))
    XCTAssertEqual(
      candidate.contributions.first { $0.factor == .workloadBalance }?.feature, -90.0 / 240)
  }
  func testCandidateBoundAndScoreBreakdown() throws {
    let result = ranked()
    XCTAssertLessThanOrEqual(result.feasibleCandidateCount, 7 * 96)
    let selected = try XCTUnwrap(result.selected)
    XCTAssertEqual(selected.score, selected.contributions.reduce(0) { $0 + $1.contribution })
    XCTAssertEqual(selected.contributions.map(\.factor), SchedulingFactor.allCases)
  }
  func testCourseAndHistoricalSignalsRequireSuppliedData() throws {
    let course = UUID()
    var task = SchedulingTask(duration: 60)
    task.courseID = course
    let busy = [BusyInterval(start: from, end: from.addingTimeInterval(3600), courseID: course)]
    var p = SchedulingPreferences()
    p.historicalSuccess = [
      .init(
        window: .init(weekdays: [2], startMinute: 600, endMinute: 720), successRate: 0.9,
        sampleCount: 20)
    ]
    let near = try XCTUnwrap(
      scheduler.candidate(
        task, at: from.addingTimeInterval(4500), busy: busy, from: from, deadline: deadline,
        preferences: p, calendar: calendar))
    XCTAssertGreaterThan(near.contributions.first { $0.factor == .courseProximity }!.feature, 0)
    XCTAssertEqual(near.contributions.first { $0.factor == .historicalSuccess }!.feature, 0.8)
    task.courseID = nil
    let unlinked = try XCTUnwrap(
      scheduler.candidate(
        task, at: from.addingTimeInterval(4500), busy: busy, from: from, deadline: deadline,
        calendar: calendar))
    XCTAssertEqual(unlinked.contributions.first { $0.factor == .courseProximity }!.feature, 0)
    XCTAssertEqual(unlinked.contributions.first { $0.factor == .historicalSuccess }!.feature, 0)
  }
  func testBuffersAreSymmetricWhenValidatingFinalSchedule() {
    var p = SchedulingPreferences()
    p.breakMinutes = 15
    let aStart = from
    let aEnd = from.addingTimeInterval(3600)
    let bStart = aEnd.addingTimeInterval(30 * 60)
    let bEnd = bStart.addingTimeInterval(3600)
    var a = SchedulingTask(duration: 60)
    var b = SchedulingTask(duration: 60)
    a.bufferMinutes = 0
    b.bufferMinutes = 30
    XCTAssertNotNil(
      scheduler.candidate(
        a, at: aStart, busy: [.init(start: bStart, end: bEnd, bufferMinutes: b.bufferMinutes)],
        from: from, deadline: deadline, preferences: p, calendar: calendar))
    XCTAssertNotNil(
      scheduler.candidate(
        b, at: bStart, busy: [.init(start: aStart, end: aEnd, bufferMinutes: a.bufferMinutes)],
        from: from, deadline: deadline, preferences: p, calendar: calendar))
  }
  func testDependencyChainCannotExtendSearchHorizon() {
    var p = SchedulingPreferences()
    p.policy.horizonDays = 2
    p.dailyMinutes = 60
    let sessions = (0..<3).map {
      SessionDraft(title: "Step \($0)", duration_minutes: 60, dependencies: $0 == 0 ? [] : [$0 - 1])
    }
    let result = scheduler.suggest(
      sessions, busy: [], from: from, preferences: p, calendar: calendar)
    XCTAssertNotNil(result[0].start)
    XCTAssertNotNil(result[1].start)
    XCTAssertNil(result[2].start)
  }
  func testConstraintAndTaskShapeDecodeAndRejectUnusedFields() throws {
    let patch = try DraftPatch.decode(
      """
      {"message":"Light Wednesday","operations":[{"type":"add_constraint","constraint":{"id":"00000000-0000-0000-0000-000000000001","type":"soft","key":"light_day","value":{"weekdays":[4],"minutes":60},"source":"temporary","startDate":"2026-09-28T00:00:00Z","expiration":"2026-10-05T00:00:00Z","active":true,"text":"Light Wednesday"}}]}
      """)
    XCTAssertEqual(patch.operations.first?.constraint?.type, .soft)
    let invalid = PlanningConstraint(
      type: .hard, key: .excludedWeekdays, value: .init(weekdays: [4], minutes: 60),
      text: "Ambiguous rule")
    XCTAssertFalse(invalid.isValid)
  }
  func testAvailabilityFollowsLocalClockAcrossDST() throws {
    var london = Calendar(identifier: .gregorian)
    london.timeZone = TimeZone(identifier: "Europe/London")!
    let start = date("2026-10-24T00:00:00Z")
    var task = SchedulingTask(duration: 60)
    task.preferredDays = [1]  // Sunday, after the clock change
    let result = scheduler.rank(
      task, busy: [], from: start, deadline: date("2026-10-26T00:00:00Z"), calendar: london)
    let selected = try XCTUnwrap(result.selected)
    XCTAssertEqual(london.component(.weekday, from: selected.start), 1)
    XCTAssertEqual(london.component(.hour, from: selected.start), 9)
    XCTAssertEqual(selected.start, date("2026-10-25T09:00:00Z"))
  }

}
