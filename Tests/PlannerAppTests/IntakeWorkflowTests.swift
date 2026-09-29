import Foundation
import PlannerCore
import SwiftData
import XCTest
@testable import PlannerApp

final class IntakeWorkflowTests: XCTestCase {
  @MainActor private func store() throws -> ModelContainer {
    try ModelContainer(for: Schema([
      Area.self, Goal.self, Plan.self, Session.self, Action.self, PlannerTask.self, Note.self,
      CalendarSource.self, CalendarEvent.self, Course.self, CourseSession.self, KnowledgeGap.self,
      ExecutionRecord.self, UserPlanningProfile.self, WeeklyReview.self, InboxItem.self,
    ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
  }
  private func document() throws -> IntakeDocument {
    try IntakeDocument.decode("""
    {"detected_type":"study_plan","title":"ML Plan","summary":"Review lectures","courses":[{"title":"Machine Learning","details":"Weeks 1–3"}],"goals":[{"title":"Review Weeks 1–3"}],"deadlines":[],"events":[{"title":"Seminar","fixed_start":"2030-10-02T13:00:00Z","flexibility":"fixed"}],"sessions":[{"title":"Review","duration_minutes":45,"preferred_day":"Tuesday","actions":["Read lecture notes"]}],"tasks":[],"constraints":[],"notes":[{"title":"Reference notes","details":"Keep this"}],"ideas":[{"title":"Later project"}]}
    """)
  }
  @MainActor func testImportOnlyPersistsStructuredFactsWithoutScheduling() throws {
    let store = try store(); let context = store.mainContext
    let doc = try document()
    let batch = try IntakeCoordinator.importOnly(doc, source: "Original source", area: "Study", context: context)
    XCTAssertEqual(batch.intakeSource, "Original source")
    let restored = try IntakeDocument.decode(String(decoding: XCTUnwrap(batch.intakeData), as: UTF8.self))
    XCTAssertEqual(restored.sessions.first?.duration_minutes, 45)
    XCTAssertEqual(restored.events.first?.title, "Seminar")
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 1)
    XCTAssertTrue(try context.fetch(FetchDescriptor<InboxItem>()).contains { $0.status == "someday" && $0.title == "Later project" })
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CalendarEvent>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Plan>()), 0)
  }
  @MainActor func testArrangeCreatesDraftRespectsPrivateCalendarAndRequiresFinalCommit() throws {
    let store = try store(); let context = store.mainContext
    let now = ISO8601DateFormatter().date(from: "2030-10-01T09:00:00Z")!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let source = CalendarSource(name: "Private"); source.allowAI = false
    context.insert(source)
    let event = CalendarEvent(remoteID: "private", title: "Private event", start: now,
      end: now.addingTimeInterval(3600), source: source)
    context.insert(event); try context.save()
    let doc = try document()
    let draft = try IntakeCoordinator.arrange(doc, area: "Study", context: context, now: now, calendar: calendar)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<InboxItem>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Plan>()), 0)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(draft.sessions.first?.scheduledStart), event.end)
    let batch = try IntakeCoordinator.importOnly(doc, source: "Source", area: "Study", context: context)
    let preview = PlanningPreview()
    IntakeCoordinator.open(draft, item: batch, preview: preview, now: now)
    XCTAssertEqual(preview.inboxID, batch.id)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CalendarEvent>()), 1)
    let plan = try DraftCommitter.commit(draft, area: "Study", busy: [.init(start: event.start, end: event.end)],
      context: context, inboxItem: batch, now: now, calendar: calendar)
    XCTAssertEqual(batch.plan?.id, plan.id)
    XCTAssertEqual(batch.status, "processed")
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 1)
  }
  @MainActor func testDeselectedEntitiesNeverPersist() throws {
    let store = try store(); let context = store.mainContext
    let doc = try document()
    _ = try IntakeCoordinator.importOnly(doc.selecting([doc.sessions[0].id]), source: "Source", area: "Study", context: context)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<InboxItem>()), 1)
  }
}
