import Foundation
import PlannerCore
import SwiftData
import XCTest
@testable import PlannerApp

final class CourseWorkflowTests: XCTestCase {
  @MainActor private func store() throws -> ModelContainer {
    try ModelContainer(for: Schema([Area.self, Goal.self, Plan.self, Session.self, Action.self,
      PlannerTask.self, Note.self, CalendarSource.self, CalendarEvent.self, Course.self,
      CourseSession.self, KnowledgeGap.self, ExecutionRecord.self, UserPlanningProfile.self,
      WeeklyReview.self, InboxItem.self]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private var now: Date { date("2030-10-01T09:00:00Z") }
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
  }
  @MainActor private func fixture(_ context: ModelContext) throws -> CalendarSource {
    let source = CalendarSource(name: "Synthetic timetable")
    context.insert(source)
    try CalendarRepository.upsert([
      .init(uid: "ml-lecture", title: "LH Machine Learning (14934)/Lecture", start: date("2030-10-01T16:00:00Z"), end: date("2030-10-01T17:00:00Z"), rule: "FREQ=WEEKLY;COUNT=7", timeZoneID: "UTC"),
      .init(uid: "ml-tutorial", title: "LC Machine Learning (14934)/Tutorial", start: date("2030-10-04T11:00:00Z"), end: date("2030-10-04T12:00:00Z"), rule: "FREQ=WEEKLY;COUNT=4", timeZoneID: "UTC"),
      .init(uid: "nc", title: "LH Neural Computation (13716)/Lecture", start: date("2030-10-02T11:00:00Z"), end: date("2030-10-02T12:00:00Z")),
      .init(uid: "hci", title: "LH Human Computer Interaction (11939)/Lecture", start: date("2030-10-03T11:00:00Z"), end: date("2030-10-03T12:00:00Z")),
      .init(uid: "lunch", title: "Lunch", start: date("2030-10-03T12:00:00Z"), end: date("2030-10-03T13:00:00Z")),
    ], source: source, context: context)
    return source
  }
  @MainActor func testDiscoveryDoesNotCreateCoursesUntilAccepted() throws {
    let store = try store(); let context = store.mainContext
    _ = try fixture(context)
    let candidates = CourseDiscoveryRepository.candidates(events: try context.fetch(FetchDescriptor<CalendarEvent>()), courses: [], ignored: [], now: now)
    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(candidates.first { $0.moduleCode == "14934" }?.counts, ["lecture": 7, "tutorial": 4])
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 0)
    let accepted = try CourseDiscoveryRepository.accept(["code:14934"], context: context)
    XCTAssertEqual(accepted.count, 1)
    XCTAssertEqual(accepted.first?.moduleCode, "14934")
    XCTAssertEqual(accepted.first?.createdAutomatically, true)
    let links = try context.fetch(FetchDescriptor<CourseSession>())
    XCTAssertEqual(links.count, 2)
    XCTAssertEqual(Set(links.map(\.kind)), ["lecture", "tutorial"])
    XCTAssertTrue(links.allSatisfy { $0.event?.title.contains("14934") == true })
  }
  @MainActor func testAcceptanceIsIdempotentAndPreservesExistingCourse() throws {
    let store = try store(); let context = store.mainContext
    _ = try fixture(context)
    let old = Course("Machine Learning"); old.topic = "Old focus"; old.assessment = "Essay"; old.deadline = now
    context.insert(old); try context.save()
    _ = try CourseDiscoveryRepository.accept(["code:14934"], context: context)
    _ = try CourseDiscoveryRepository.accept(["code:14934"], context: context)
    try CourseDiscoveryRepository.reconcile(context: context); try context.save()
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 2)
    XCTAssertEqual(old.topic, "Old focus")
    XCTAssertEqual(old.assessment, "Essay")
    XCTAssertEqual(old.deadline, now)
    XCTAssertFalse(old.createdAutomatically)
  }
  @MainActor func testRefreshLinksOnlyAcceptedModulesAndSources() throws {
    let store = try store(); let context = store.mainContext
    let source = try fixture(context)
    _ = try CourseDiscoveryRepository.accept(["code:14934"], context: context)
    let extra = ImportedEvent(uid: "ml-lab", title: "Machine Learning (14934)/Lab", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(10800))
    try CalendarRepository.upsert([extra], source: source, context: context)
    try CalendarRepository.upsert([extra], source: source, context: context)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 3)
    let other = CalendarSource(name: "Unaccepted source"); context.insert(other)
    try CalendarRepository.upsert([extra], source: other, context: context)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 3)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 1)
    let pending = CourseDiscoveryRepository.candidates(events: try context.fetch(FetchDescriptor<CalendarEvent>()), courses: try context.fetch(FetchDescriptor<Course>()), ignored: [])
    XCTAssertTrue(pending.contains { $0.id == "code:14934" })
  }
  @MainActor func testIgnoredCodeStaysHiddenAcrossNewEvents() throws {
    let store = try store(); let context = store.mainContext
    let source = try fixture(context)
    try CourseDiscoveryRepository.ignore("code:13716", context: context)
    try CalendarRepository.upsert([.init(uid: "new-nc", title: "Neural Computation (13716)/Tutorial", start: now, end: now.addingTimeInterval(3600))], source: source, context: context)
    let ignored = try XCTUnwrap(context.fetch(FetchDescriptor<UserPlanningProfile>()).first).ignoredCourseKeys
    let candidates = CourseDiscoveryRepository.candidates(events: try context.fetch(FetchDescriptor<CalendarEvent>()), courses: [], ignored: ignored)
    XCTAssertFalse(candidates.contains { $0.id == "code:13716" })
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 0)
  }
  @MainActor func testChangedOrRemovedEventsLoseAutomaticLinkOnly() throws {
    let store = try store(); let context = store.mainContext
    let source = try fixture(context)
    _ = try CourseDiscoveryRepository.accept(["code:14934"], context: context)
    try CalendarRepository.upsert([.init(uid: "ml-lecture", title: "Unrelated meeting", start: now, end: now.addingTimeInterval(3600))], source: source, context: context)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 1)
    try CalendarRepository.upsert([], source: source, context: context, replace: true)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Course>()), 1)
  }
  @MainActor func testGroupedTimetableNextClassAndReadOnlyLearningSummary() throws {
    let store = try store(); let context = store.mainContext
    _ = try fixture(context)
    let course = try XCTUnwrap(CourseDiscoveryRepository.accept(["code:14934"], context: context).first)
    let plan = Plan(title: "Week 3 review", purpose: "Practice"); plan.course = course; plan.deadline = date("2030-10-18T17:00:00Z")
    context.insert(plan)
    let study = Session(title: "Logistic Regression", minutes: 40, start: now.addingTimeInterval(3600), plan: plan)
    context.insert(study)
    let gap = KnowledgeGap("Regularization", course: course); context.insert(gap)
    let note = Note(title: "Study notes"); note.course = course; context.insert(note)
    let record = ExecutionRecord(session: study, actual: 20, status: "partial"); context.insert(record)
    try course.setAssessments([.init(title: "Coursework", deadline: date("2030-10-18T12:00:00Z"))]); try context.save()
    let summary = CourseSummaryService.build(course: course, events: try context.fetch(FetchDescriptor<CalendarEvent>()),
      links: try context.fetch(FetchDescriptor<CourseSession>()), sessions: [study], plans: [plan], notes: [note], inbox: [], gaps: [gap], records: [record], now: now, calendar: calendar)
    XCTAssertEqual(summary.nextClass?.start, date("2030-10-01T16:00:00Z"))
    XCTAssertEqual(summary.nextPractical?.kind, "tutorial")
    XCTAssertEqual(summary.patterns.count, 2)
    XCTAssertEqual(summary.patterns.first { $0.kind == "lecture" }?.count, 7)
    XCTAssertEqual(summary.patterns.first { $0.kind == "tutorial" }?.count, 4)
    XCTAssertEqual(summary.classesThisWeek, ["lecture": 1, "tutorial": 1])
    XCTAssertEqual(summary.studiesThisWeek, 1)
    XCTAssertEqual(summary.focus, "Logistic Regression")
    XCTAssertEqual(summary.pendingStudies.count, 1)
    XCTAssertEqual(summary.assessments.count, 2)
    XCTAssertEqual(summary.gaps.count, 1)
    XCTAssertEqual(summary.notes.count, 1)
    XCTAssertEqual(summary.plans.count, 1)
    XCTAssertEqual(record.courseID, course.id)
    XCTAssertEqual(summary.actualMinutes, 20)
    XCTAssertEqual(summary.suggestedAction?.sessionID, study.id)
    XCTAssertFalse(context.hasChanges)
  }
  @MainActor func testExplicitFocusWinsAndCompletedStudyIsNotPending() throws {
    let store = try store(); let context = store.mainContext
    let course = Course("ML"); course.currentFocus = "User correction"; course.topic = "Legacy topic"
    context.insert(course)
    let session = Session(title: "Different topic"); session.course = course; session.status = "complete"; context.insert(session)
    let summary = CourseSummaryService.build(course: course, events: [], links: [], sessions: [session], plans: [], notes: [], inbox: [], gaps: [], records: [], now: now)
    XCTAssertEqual(summary.focus, "User correction")
    XCTAssertTrue(summary.pendingStudies.isEmpty)
    XCTAssertNil(summary.suggestedAction)
  }
  @MainActor func testImportIntoCoursePreservesContextThroughDraftCommit() throws {
    let store = try store(); let context = store.mainContext
    let course = Course("ML"); context.insert(course); try context.save()
    let doc = try IntakeDocument.decode("""
    {"detected_type":"study_plan","title":"Review","summary":"Practice","courses":[],"goals":[],"deadlines":[],"events":[],"sessions":[{"title":"Exercises","duration_minutes":40,"actions":["Solve questions"]}],"tasks":[],"constraints":[],"notes":[{"title":"Notes","details":"From syllabus"}]}
    """)
    let item = try IntakeCoordinator.importOnly(doc, source: "Synthetic study outline", area: "Study", context: context, targetCourse: course)
    let draft = try IntakeCoordinator.arrange(doc, area: "Study", context: context, now: now, calendar: calendar)
    let preview = PlanningPreview(); IntakeCoordinator.open(draft, item: item, preview: preview, now: now)
    XCTAssertEqual(preview.courseID, course.id)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    let plan = try DraftCommitter.commit(try XCTUnwrap(preview.draft), area: "Study", busy: [], context: context, inboxItem: item, now: now, calendar: calendar)
    XCTAssertEqual(plan.course?.id, course.id)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Session>()).first?.course?.id, course.id)
    XCTAssertTrue(try context.fetch(FetchDescriptor<InboxItem>()).allSatisfy { $0.course?.id == course.id })
  }
  @MainActor func testNameOnlyMatchingDoesNotAbsorbAnotherNumberedModule() throws {
    let store = try store(); let context = store.mainContext
    let source = CalendarSource(name: "No codes"); context.insert(source)
    try CalendarRepository.upsert([.init(uid: "one", title: "Robotics / Lecture", start: now, end: now.addingTimeInterval(3600))], source: source, context: context)
    _ = try CourseDiscoveryRepository.accept(["name:robotics"], context: context)
    try CalendarRepository.upsert([.init(uid: "two", title: "Robotics (99999)/Lab", start: now, end: now.addingTimeInterval(3600))], source: source, context: context)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseSession>()), 1)
  }
}
