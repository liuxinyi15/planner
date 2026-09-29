import XCTest

@testable import PlannerCore

final class DraftPlanningTests: XCTestCase {
  let from = ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!
  var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
  }
  func draft() throws -> DraftPlan {
    let source = try PlanDraft.decode(
      """
      {"intent_type":"study","title":"Study","goal":"Learn","priority":"medium","deadline":null,"estimated_total_minutes":180,"sessions":[{"title":"One","purpose":"Learn","duration_minutes":60,"actions":["Read"],"definition_of_done":"Notes","energy_level":"medium","preferred_time":null,"dependencies":[]},{"title":"Two","purpose":"Practice","duration_minutes":120,"actions":["Practice"],"definition_of_done":"Exercises","energy_level":"high","preferred_time":null,"dependencies":[]}],"notes":[],"clarification_needed":false,"clarification_question":null}
      """)
    let draft = DraftPlan(source)
    return try DraftEditor.schedule(
      draft, affected: Set(draft.sessions.map(\.id)), busy: [], from: from, calendar: calendar)
  }
  func apply(_ op: DraftOperation, _ draft: DraftPlan) throws -> DraftPatchResult {
    try DraftEditor.apply(
      .init(message: "Updated", operations: [op]), to: draft, busy: [], from: from,
      calendar: calendar)
  }
  func testTargetedUpdateDoesNotRegenerateDraft() throws {
    let d = try draft()
    let patch = try DraftPatch.decode(
      """
      {"message":"Updated title","operations":[{"type":"update_session","session_id":"\(d.sessions[1].id)","update":{"title":"Changed"}}]}
      """)
    let result = try DraftEditor.apply(patch, to: d, busy: [], from: from, calendar: calendar)
    XCTAssertEqual(result.draft.id, d.id)
    XCTAssertEqual(result.draft.sessions[0], d.sessions[0])
    XCTAssertEqual(result.draft.sessions[1].id, d.sessions[1].id)
    XCTAssertEqual(result.draft.sessions[1].scheduledStart, d.sessions[1].scheduledStart)
    XCTAssertEqual(result.changes.count, 1)
  }
  func testLockedSessionCannotMove() throws {
    let d = try draft()
    let locked = try apply(.init(type: .lock_session, session_id: d.sessions[0].id), d).draft
    var move = DraftOperation(type: .move_session, session_id: d.sessions[0].id)
    move.preferred_start = from.addingTimeInterval(86400)
    XCTAssertThrowsError(try apply(move, locked))
    let result = try apply(.init(type: .reschedule_plan), locked)
    XCTAssertEqual(result.draft.sessions[0], locked.sessions[0])
  }
  func testSplitProducesValidChildren() throws {
    let d = try draft()
    var op = DraftOperation(type: .split_session, session_id: d.sessions[1].id)
    var a = d.sessions[1]
    a.id = UUID()
    a.duration = 60
    a.scheduledStart = nil
    var b = a
    b.id = UUID()
    op.children = [a, b]
    let result = try apply(op, d)
    XCTAssertEqual(result.draft.sessions.count, 3)
    XCTAssertEqual(result.draft.estimatedWorkload, d.estimatedWorkload)
    XCTAssertEqual(result.draft.sessions[0], d.sessions[0])
    XCTAssertTrue(result.draft.sessions.allSatisfy { $0.scheduledStart != nil })
    op.children = [a, a]
    XCTAssertThrowsError(try apply(op, d))
    b.duration = 5
    op.children = [a, b]
    XCTAssertThrowsError(try apply(op, d))
  }
  func testMalformedOperationsRejected() throws {
    let d = try draft()
    XCTAssertThrowsError(
      try DraftPatch.decode("{\"message\":\"x\",\"operations\":[{\"type\":\"oops\"}]}"))
    XCTAssertThrowsError(try apply(.init(type: .move_session), d))
    XCTAssertThrowsError(try apply(.init(type: .remove_session, session_id: UUID()), d))
    var op = DraftOperation(type: .change_duration, session_id: d.sessions[0].id)
    op.duration = -5
    XCTAssertThrowsError(try apply(op, d))
  }
  func testRemovedSessionDisappears() throws {
    let d = try draft()
    let result = try apply(.init(type: .remove_session, session_id: d.sessions[1].id), d)
    XCTAssertEqual(result.draft.sessions, [d.sessions[0]])
    XCTAssertNil(result.changes[0].after)
  }
  func testMovePreservesContentAndOtherSession() throws {
    let d = try draft()
    var op = DraftOperation(type: .move_session, session_id: d.sessions[1].id)
    op.preferred_start = from.addingTimeInterval(86400)
    op.preferred_end = from.addingTimeInterval(86400 + 4 * 3600)
    let result = try apply(op, d)
    let s = result.draft.sessions[1]
    XCTAssertEqual(result.draft.sessions[0], d.sessions[0])
    XCTAssertEqual(s.actions, d.sessions[1].actions)
    XCTAssertEqual(s.purpose, d.sessions[1].purpose)
    XCTAssertEqual(s.definitionOfDone, d.sessions[1].definitionOfDone)
    XCTAssertEqual(s.duration, d.sessions[1].duration)
    XCTAssertEqual(s.scheduledStart, op.preferred_start)
  }
  func testDeadlineUpdatesBoundary() throws {
    let d = try draft()
    var op = DraftOperation(type: .change_deadline)
    op.deadline = from.addingTimeInterval(3600)
    let result = try apply(op, d)
    XCTAssertEqual(result.draft.deadline, op.deadline)
    XCTAssertNil(result.draft.sessions[1].scheduledStart)
    XCTAssertEqual(result.draft.sessions[0], d.sessions[0])
    let locked = try apply(.init(type: .lock_session, session_id: d.sessions[1].id), d).draft
    XCTAssertThrowsError(try apply(op, locked))
  }
  func testPatchIsAtomicAndExplicitUnlockWorks() throws {
    let d = try draft()
    let locked = try apply(.init(type: .lock_session, session_id: d.sessions[1].id), d).draft
    var move = DraftOperation(type: .move_session, session_id: d.sessions[1].id)
    move.preferred_start = from.addingTimeInterval(86400)
    let patch = DraftPatch(
      message: "Moved",
      operations: [.init(type: .unlock_session, session_id: d.sessions[1].id), move])
    let result = try DraftEditor.apply(patch, to: locked, busy: [], from: from, calendar: calendar)
    XCTAssertFalse(result.draft.sessions[1].locked)
    XCTAssertTrue(locked.sessions[1].locked)
  }
  func testConstraintsOnlyRescheduleViolatingSessions() throws {
    let d = try draft()
    var op = DraftOperation(type: .add_constraint)
    op.constraint = .init(text: "Avoid Thursday", excludedWeekdays: [5])
    let result = try apply(op, d)
    XCTAssertTrue(
      result.draft.sessions.allSatisfy {
        calendar.component(.weekday, from: $0.scheduledStart!) != 5
      })
    let locked = try apply(.init(type: .lock_session, session_id: d.sessions[0].id), d).draft
    XCTAssertThrowsError(try apply(op, locked))
    op.constraint = .init(text: "Bad hour", latestHour: Int.max)
    XCTAssertThrowsError(try apply(op, d))
  }
  func testMalformedAndOverflowingSplitIsRejected() throws {
    let d = try draft()
    var op = DraftOperation(type: .split_session, session_id: d.sessions[1].id)
    var child = d.sessions[1]
    child.id = UUID()
    child.duration = Int.max
    child.scheduledStart = nil
    op.children = [child, child]
    XCTAssertThrowsError(try apply(op, d))
    XCTAssertThrowsError(
      try DraftPatch.decode(
        """
        {"message":"x","operations":[{"type":"update_session","session_id":"\(d.sessions[0].id)","update":{"typo":"x"}}]}
        """))
  }
  func testDraftRoundTripIncludesWorkload() throws {
    let d = try draft()
    let data = try JSONEncoder().encode(d)
    XCTAssertEqual(try JSONDecoder().decode(DraftPlan.self, from: data), d)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["estimatedWorkload"] as? Int, 180)
  }

  func testShorterDurationRetainsValidSlot() throws {
    var d = try draft()
    d.sessions[1].scheduledStart = from.addingTimeInterval(86400)
    var op = DraftOperation(type: .change_duration, session_id: d.sessions[1].id)
    op.duration = 60
    let result = try apply(op, d)
    XCTAssertEqual(result.draft.sessions[1].scheduledStart, d.sessions[1].scheduledStart)
    XCTAssertEqual(result.draft.sessions[0], d.sessions[0])
  }

  func testSplitInheritsHardTimingBoundary() throws {
    var d = try draft()
    let earliest = from.addingTimeInterval(86400)
    d.sessions[1].scheduling = .init(
      earliestStart: earliest, latestEnd: earliest.addingTimeInterval(4 * 3600),
      location: "Library", bufferMinutes: 20)
    var op = DraftOperation(type: .split_session, session_id: d.sessions[1].id)
    var a = d.sessions[1]
    a.id = UUID()
    a.duration = 60
    a.scheduledStart = nil
    a.scheduling = nil
    var b = a
    b.id = UUID()
    op.children = [a, b]
    let result = try apply(op, d)
    for child in result.draft.sessions.dropFirst() {
      XCTAssertEqual(child.scheduling?.earliestStart, earliest)
      XCTAssertEqual(child.scheduling?.location, "Library")
      XCTAssertEqual(child.scheduling?.bufferMinutes, 20)
      XCTAssertGreaterThanOrEqual(child.scheduledStart!, earliest)
      XCTAssertLessThanOrEqual(child.end!, earliest.addingTimeInterval(4 * 3600))
    }
  }

}
