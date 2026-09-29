import Foundation
import PlannerCore
import SwiftData
import XCTest

@testable import PlannerApp

final class SituationTests: XCTestCase {
  private var calendar: Calendar {
    var result = Calendar(identifier: .gregorian)
    result.timeZone = TimeZone(secondsFromGMT: 0)!
    return result
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private var now: Date { date("2026-09-27T09:00:00Z") }
  @MainActor private func store() throws -> ModelContainer {
    try ModelContainer(
      for: Schema([
        Area.self, Goal.self, Plan.self, Session.self, Action.self, PlannerTask.self, Note.self,
        CalendarSource.self, CalendarEvent.self, Course.self, CourseSession.self, KnowledgeGap.self,
        ExecutionRecord.self, UserPlanningProfile.self, WeeklyReview.self, InboxItem.self,
      ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
  }
  private func event(_ title: String, _ start: String, _ end: String, source: CalendarSource? = nil)
    -> CalendarEvent
  {
    CalendarEvent(
      remoteID: UUID().uuidString, title: title, start: date(start), end: date(end), source: source)
  }
  @MainActor func testBoundedUpcomingEventsAndRecurrences() throws {
    let container = try store()
    let context = container.mainContext
    let ongoing = event("Ongoing", "2026-09-26T23:00:00Z", "2026-09-27T10:00:00Z")
    let upcoming = event("Upcoming", "2026-09-28T10:00:00Z", "2026-09-28T11:00:00Z")
    let old = event("Old", "2020-01-01T10:00:00Z", "2020-01-01T11:00:00Z")
    let future = event("Outside", "2026-10-04T00:00:00Z", "2026-10-04T01:00:00Z")
    let cancelled = event("Cancelled", "2026-09-28T10:00:00Z", "2026-09-28T11:00:00Z")
    cancelled.cancelled = true
    let recurring = event("Recurring", "2026-01-01T12:00:00Z", "2026-01-01T13:00:00Z")
    recurring.rule = "FREQ=DAILY"
    recurring.timeZoneID = "UTC"
    [ongoing, upcoming, old, future, cancelled, recurring].forEach { context.insert($0) }
    try context.save()
    let result = try CurrentSituationBuilder(context: context, calendar: calendar).build(now: now)
    XCTAssertEqual(result.range, now..<date("2026-10-04T00:00:00Z"))
    XCTAssertEqual(result.workload.count, 7)
    XCTAssertEqual(result.upcomingEvents.count, 9)
    XCTAssertEqual(result.upcomingEvents.first?.title, "Ongoing")
    XCTAssertTrue(
      result.upcomingEvents.allSatisfy { $0.end > now && $0.start < result.range.upperBound })
    XCTAssertFalse(
      result.upcomingEvents.contains { ["Old", "Outside", "Cancelled"].contains($0.title) })
    XCTAssertEqual(result.upcomingEvents.filter { $0.title == "Recurring" }.count, 7)
    XCTAssertFalse(context.hasChanges)
  }
  func testFreeWindowsMergeOverlapRespectBuffersAndMinimumLength() {
    let result = AvailabilityWindows.find(
      in: now..<date("2026-09-28T00:00:00Z"),
      busy: [
        BusyInterval(
          start: date("2026-09-27T10:00:00Z"), end: date("2026-09-27T11:00:00Z"), bufferMinutes: 15),
        BusyInterval(start: date("2026-09-27T10:30:00Z"), end: date("2026-09-27T12:00:00Z")),
        BusyInterval(start: date("2026-09-27T12:10:00Z"), end: date("2026-09-27T13:00:00Z")),
      ], startHour: 9, endHour: 17, calendar: calendar)
    XCTAssertEqual(
      result,
      [
        FreeWindow(start: now, end: date("2026-09-27T09:45:00Z")),
        FreeWindow(start: date("2026-09-27T13:00:00Z"), end: date("2026-09-27T17:00:00Z")),
      ])
  }
  func testAvailabilityUsesLocalDayAcrossDST() {
    var london = calendar
    london.timeZone = TimeZone(identifier: "Europe/London")!
    let result = AvailabilityWindows.find(
      in: date("2026-10-24T23:00:00Z")..<date("2026-10-26T00:00:00Z"), busy: [],
      startHour: 0, endHour: 24, calendar: london)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.minutes, 25 * 60)
  }
  @MainActor func testPrivacyAndPrivateBusyCalendarStillConstrainAvailability() throws {
    let container = try store()
    let context = container.mainContext
    let privateSource = CalendarSource(name: "SECRET_SOURCE")
    privateSource.visible = false
    let publicSource = CalendarSource(name: "Public")
    publicSource.allowAI = true
    publicSource.useAsBusy = false
    let privateEvent = event(
      "SECRET_EVENT", "2026-09-27T10:00:00Z", "2026-09-27T11:00:00Z", source: privateSource)
    privateEvent.location = "SECRET_LOCATION"
    privateEvent.bufferMinutes = 15
    let publicEvent = event(
      "Public lecture", "2026-09-27T12:00:00Z", "2026-09-27T13:00:00Z", source: publicSource)
    let generic = event(
      "Machine Learning lecture", "2026-09-27T14:00:00Z", "2026-09-27T15:00:00Z",
      source: publicSource)
    let privateCourse = Course("SECRET_COURSE")
    let publicCourse = Course("Public course")
    let privateLink = CourseSession(course: privateCourse, event: privateEvent)
    privateLink.topic = "SECRET_TOPIC"
    let publicLink = CourseSession(course: publicCourse, event: publicEvent)
    let privateGap = KnowledgeGap("SECRET_GAP", course: privateCourse)
    let publicGap = KnowledgeGap("Public gap", course: publicCourse)
    context.insert(privateSource)
    context.insert(publicSource)
    [privateEvent, publicEvent, generic].forEach { context.insert($0) }
    context.insert(privateCourse)
    context.insert(publicCourse)
    context.insert(privateLink)
    context.insert(publicLink)
    context.insert(privateGap)
    context.insert(publicGap)
    let session = Session(title: "Confirmed", minutes: 60, start: date("2026-09-27T16:00:00Z"))
    session.bufferMinutes = 30
    context.insert(session)
    try context.save()
    let situation = try CurrentSituationBuilder(context: context, calendar: calendar).build(
      now: now, days: 1)
    XCTAssertEqual(situation.upcomingCourseSessions.count, 2)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 2)
    XCTAssertEqual(
      situation.freeWindows,
      [
        FreeWindow(start: now, end: date("2026-09-27T09:45:00Z")),
        FreeWindow(start: date("2026-09-27T11:15:00Z"), end: date("2026-09-27T15:30:00Z")),
        FreeWindow(start: date("2026-09-27T17:30:00Z"), end: date("2026-09-27T21:00:00Z")),
      ])
    let planning = ContextBuilder.build(situation: situation)
    let json = try planning.serialized()
    XCTAssertFalse(json.contains("SECRET"))
    XCTAssertTrue(json.contains("Public lecture"))
    XCTAssertTrue(json.contains("Public gap"))
    XCTAssertEqual(planning.upcomingCourseSessions.count, 1)
    XCTAssertEqual(planning.freeWindows, situation.freeWindows)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode(PlanningContext.self, from: Data(json.utf8)).currentDate, now)
    XCTAssertFalse(context.hasChanges)
  }
  @MainActor func testOldUnrelatedDataExcludedAndRecentSignalsIncluded() throws {
    let container = try store()
    let context = container.mainContext
    let oldPlan = Plan(title: "UNRELATED_PLAN", purpose: "Old")
    oldPlan.created = date("2020-01-01T00:00:00Z")
    let oldSession = Session(
      title: "UNRELATED_SESSION", start: date("2020-01-01T12:00:00Z"), plan: oldPlan)
    let oldTask = PlannerTask("UNRELATED_TASK")
    oldTask.deadline = date("2020-01-01T12:00:00Z")
    let oldInbox = InboxItem(title: "UNRELATED_INBOX")
    oldInbox.created = date("2020-01-01T12:00:00Z")
    let course = Course("UNRELATED_COURSE")
    context.insert(oldPlan)
    context.insert(oldSession)
    context.insert(oldTask)
    context.insert(oldInbox)
    context.insert(course)
    context.insert(KnowledgeGap("UNRELATED_GAP", course: course))
    context.insert(Note(title: "UNRELATED_NOTE", body: "Never automatically shared"))
    let overdue = PlannerTask("Recent overdue")
    overdue.deadline = now.addingTimeInterval(-3600)
    let inbox = InboxItem(title: "Recent capture")
    inbox.created = now.addingTimeInterval(-3600)
    let plan = Plan(title: "Active", purpose: "Finish")
    plan.created = now
    let session = Session(title: "Postponed", start: now.addingTimeInterval(86400), plan: plan)
    let record = ExecutionRecord(session: session, actual: 0, status: "postponed")
    record.date = now.addingTimeInterval(-3600)
    context.insert(overdue)
    context.insert(inbox)
    context.insert(plan)
    context.insert(session)
    context.insert(record)
    try context.save()
    let situation = try CurrentSituationBuilder(context: context, calendar: calendar).build(
      now: now)
    XCTAssertEqual(situation.overdueTasks.map(\.title), ["Recent overdue"])
    XCTAssertEqual(situation.recentInbox.map(\.title), ["Recent capture"])
    XCTAssertEqual(situation.activePlans.map(\.title), ["Active"])
    XCTAssertEqual(situation.recentlyPostponedSessions.map(\.title), ["Postponed"])
    XCTAssertFalse(
      try ContextBuilder.build(situation: situation).serialized().contains("UNRELATED"))
  }
  @MainActor func testBuffersOutsideHorizonAndLongSessionStillBlock() throws {
    let container = try store()
    let context = container.mainContext
    let next = event("Tomorrow", "2026-09-28T00:30:00Z", "2026-09-28T01:00:00Z")
    next.bufferMinutes = 240
    context.insert(next)
    let long = Session(title: "Ongoing", minutes: 10 * 24 * 60, start: date("2026-09-18T12:00:00Z"))
    context.insert(long)
    try context.save()
    let situation = try CurrentSituationBuilder(context: context, calendar: calendar).build(
      now: now, days: 1)
    XCTAssertTrue(situation.freeWindows.isEmpty)
    XCTAssertTrue(situation.upcomingEvents.isEmpty)
    XCTAssertEqual(situation.unfinishedSessions.map(\.title), ["Ongoing"])
    long.status = "skip"
    try context.save()
    let updated = try CurrentSituationBuilder(context: context, calendar: calendar).build(
      now: now, days: 1)
    XCTAssertEqual(updated.freeWindows.last?.end, date("2026-09-27T20:30:00Z"))
  }
  @MainActor func testTruncationDoesNotClaimFreeTime() throws {
    let container = try store()
    let context = container.mainContext
    for hour in [10, 12] {
      context.insert(event("Busy", "2026-09-27T\(hour):00:00Z", "2026-09-27T\(hour + 1):00:00Z"))
    }
    try context.save()
    let result = try CurrentSituationBuilder(context: context, calendar: calendar, fetchLimit: 1)
      .build(now: now)
    XCTAssertTrue(result.truncated)
    XCTAssertTrue(result.freeWindows.isEmpty)
    XCTAssertEqual(result.freeCapacityToday, 0)
    XCTAssertTrue(
      ContextBuilder.build(situation: result).relevantConstraints.contains {
        $0.contains("unknown")
      })
  }
}
