import SwiftData
import XCTest

@testable import PlannerApp

final class WorkflowTests: XCTestCase {
  private var originalTypes: [any PersistentModel.Type] {
    [
      Area.self, Goal.self, Plan.self, Session.self, Action.self, PlannerTask.self, Note.self,
      CalendarSource.self, CalendarEvent.self, Course.self, CourseSession.self, KnowledgeGap.self,
      ExecutionRecord.self, UserPlanningProfile.self, WeeklyReview.self,
    ]
  }
  @MainActor func testInboxConversionIsIdempotentAndRetainsCapture() throws {
    let schema = Schema(originalTypes + [InboxItem.self])
    let store = try ModelContainer(
      for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let context = store.mainContext
    let item = InboxItem(title: "Buy detergent", note: "Unscented", area: "Life")
    item.deadline = Date(timeIntervalSince1970: 1_800_000_000)
    context.insert(item)
    try InboxActions.convertToTask(item, context: context)
    try InboxActions.convertToTask(item, context: context)
    XCTAssertEqual(try context.fetch(FetchDescriptor<PlannerTask>()).count, 1)
    XCTAssertEqual(item.task?.title, "Buy detergent")
    XCTAssertEqual(item.task?.deadline, item.deadline)
    XCTAssertEqual(item.note, "Unscented")
    XCTAssertEqual(item.status, "processed")
    item.status = "archived"
    try context.save()
    XCTAssertEqual(try context.fetch(FetchDescriptor<PlannerTask>()).count, 1)
    try InboxActions.convertToGoal(item, context: context)
    try InboxActions.makeDraftPlan(item, context: context)
    XCTAssertEqual(item.plan?.goal?.id, item.goal?.id)
    XCTAssertEqual(item.goal?.area?.name, "Life")
  }
  @MainActor func testPlanSectionsDoNotMutateSessionState() {
    XCTAssertEqual(PlanSection.classify([]), .draft)
    let session = Session(title: "Review", minutes: 30)
    XCTAssertEqual(PlanSection.classify([session]), .draft)
    session.start = Date()
    XCTAssertEqual(PlanSection.classify([session]), .active)
    session.status = "complete"
    XCTAssertEqual(PlanSection.classify([session]), .completed)
    XCTAssertEqual(session.status, "complete")
  }
  @MainActor func testAddingInboxPreservesExistingDiskStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("planner.store")
    var original: ModelContainer? = try ModelContainer(
      for: Schema(originalTypes), configurations: [ModelConfiguration(url: url)])
    let plan = Plan(title: "Existing plan", purpose: "Keep this")
    let session = Session(title: "Existing session", area: "Travel", plan: plan)
    original!.mainContext.insert(plan)
    original!.mainContext.insert(session)
    original!.mainContext.insert(Note(title: "Existing note", body: "Do not reclassify"))
    try original!.mainContext.save()
    original = nil
    let updated = try ModelContainer(
      for: Schema(originalTypes + [InboxItem.self]), configurations: [ModelConfiguration(url: url)])
    let existing = try updated.mainContext.fetch(FetchDescriptor<Session>())
    XCTAssertEqual(existing.count, 1)
    XCTAssertEqual(existing.first?.area, "Travel")
    XCTAssertEqual(existing.first?.plan?.title, "Existing plan")
    XCTAssertEqual(
      try updated.mainContext.fetch(FetchDescriptor<Note>()).first?.body, "Do not reclassify")
    XCTAssertEqual(try updated.mainContext.fetch(FetchDescriptor<InboxItem>()).count, 0)
    updated.mainContext.insert(InboxItem(title: "New capture"))
    try updated.mainContext.save()
  }
}
