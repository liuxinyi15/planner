import PlannerCore
import SwiftData
import XCTest

@testable import PlannerApp

final class DraftWorkflowTests: XCTestCase {
  @MainActor func testCollaborativeDraftOnlyPersistsAtFinalCommit() throws {
    let store = try ModelContainer(
      for: Plan.self, Session.self, InboxItem.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = store.mainContext
    let from = ISO8601DateFormatter().date(from: "2030-10-01T09:00:00Z")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let generated = try PlanDraft.decode(
      """
      {"intent_type":"study","title":"Study","goal":"Learn","priority":"medium","deadline":"2030-10-07T21:00:00Z","estimated_total_minutes":180,"sessions":[{"title":"One","purpose":"Learn","duration_minutes":60,"actions":["Read"],"definition_of_done":"Notes","energy_level":"medium","preferred_time":null,"dependencies":[]},{"title":"Two","purpose":"Practice","duration_minutes":120,"actions":["Practice"],"definition_of_done":"Exercises","energy_level":"high","preferred_time":null,"dependencies":[]}],"notes":[],"clarification_needed":false,"clarification_question":null}
      """)
    let initial = DraftPlan(generated)
    var draft = try DraftEditor.schedule(
      initial, affected: Set(initial.sessions.map(\.id)), busy: [], from: from, calendar: calendar)
    func apply(_ operations: [DraftOperation]) throws {
      draft = try DraftEditor.apply(
        .init(message: "Applied", operations: operations), to: draft, busy: [], from: from,
        calendar: calendar
      ).draft
    }
    try apply([.init(type: .lock_session, session_id: draft.sessions[0].id)])
    let locked = draft.sessions[0]
    var move = DraftOperation(type: .move_session, session_id: draft.sessions[1].id)
    move.preferred_start = from.addingTimeInterval(86400)
    try apply([move])
    var split = DraftOperation(type: .split_session, session_id: draft.sessions[1].id)
    var child = draft.sessions[1]
    child.id = UUID()
    child.duration = 60
    child.scheduledStart = nil
    var second = child
    second.id = UUID()
    split.children = [child, second]
    try apply([split])
    var priority = DraftOperation(type: .change_priority)
    priority.priority = "high"
    try apply([priority])
    XCTAssertEqual(draft.sessions[0], locked)
    XCTAssertEqual(draft.assistantMessages.count, 4)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Plan>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    let preview = PlanningPreview()
    preview.draft = draft
    preview.suggestions = draft.suggestions
    XCTAssertEqual(preview.draft?.id, initial.id)
    XCTAssertThrowsError(
      try DraftCommitter.commit(
        draft, area: "Study", busy: [.init(start: locked.scheduledStart!, end: locked.end!)],
        context: context, now: from))
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Plan>()), 0)
    var forbidden = draft
    forbidden.constraints = [
      .init(
        type: .hard, key: .excludedWeekdays, value: .init(weekdays: [1, 2, 3, 4, 5, 6, 7]),
        text: "No work this week")
    ]
    XCTAssertThrowsError(
      try DraftCommitter.commit(forbidden, area: "Study", busy: [], context: context, now: from))
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Plan>()), 0)
    let plan = try DraftCommitter.commit(
      draft, area: "Study", busy: [], context: context, now: from)
    XCTAssertEqual(plan.deadline, draft.deadline)
    XCTAssertEqual(plan.priority, "high")
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Plan>()), 1)
    let saved = try context.fetch(FetchDescriptor<Session>())
    XCTAssertEqual(saved.count, 3)
    XCTAssertEqual(saved.reduce(0) { $0 + $1.minutes }, 180)
    XCTAssertEqual(saved.first { $0.title == locked.title }?.start, locked.scheduledStart)
    XCTAssertTrue(saved.allSatisfy { $0.plan?.id == plan.id && !$0.actions.isEmpty })
  }
}
