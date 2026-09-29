import XCTest
@testable import PlannerCore

final class PlanIntakeTests: XCTestCase {
  private let fixture = """
  {"detected_type":"study_plan","title":"Machine Learning","summary":"Review Weeks 1–3","courses":[{"title":"Machine Learning"}],"goals":[{"title":"Review Weeks 1–3"}],"deadlines":[{"title":"Finish Weeks 1–3","deadline":"2030-10-06T21:00:00Z","date_text":"Sunday"}],"events":[],"sessions":[{"title":"Linear Regression Review","purpose":"Review Lecture 1","duration_minutes":90,"preferred_day":"Monday","preferred_time":null,"fixed_start":null,"flexibility":"flexible","actions":["Review Lecture 1","Linear Regression exercises"]},{"title":"Logistic Regression","duration_minutes":60,"preferred_day":"Wednesday","flexibility":"flexible"},{"title":"Decision Trees","duration_minutes":90,"preferred_day":"Saturday","actions":["Practice"]}],"tasks":[],"constraints":[],"notes":[{"title":"Keep lecture notes"}]}
  """
  func testStudyPlanResponsePreservesSourceEntitiesAndActions() throws {
    XCTAssertNil(try ImportInterpreter.localDocument("Machine Learning\nMonday: Review Lecture 1, 90 minutes."))
    let result = try IntakeDocument.decode(fixture)
    XCTAssertEqual(result.courses.first?.title, "Machine Learning")
    XCTAssertEqual(result.goals.first?.title, "Review Weeks 1–3")
    XCTAssertEqual(result.deadlines.first?.date_text, "Sunday")
    XCTAssertEqual(result.sessions.map(\.duration_minutes), [90, 60, 90])
    XCTAssertEqual(result.sessions.first?.actions?.count, 2)
    XCTAssertEqual(result.notes.count, 1)
  }
  func testStructuredJSONBypassesAIWithNoCredentials() async throws {
    let result = try await ImportInterpreter().interpret(fixture, configuration: .init(key: "", responseTextPath: ""))
    XCTAssertEqual(result.sessions.count, 3)
    XCTAssertNotNil(try ImportInterpreter.localDocument("```json\n" + fixture + "\n```"))
  }
  func testPlainTextUsesDedicatedInterpreterWithOnlySourceAndCorrection() async throws {
    let source = "Machine Learning\nMonday: Review Lecture 1, 90 minutes."
    let response = fixture
    let service = ImportInterpreter(completion: { input, context, language, _ in
      XCTAssertEqual(input, source)
      XCTAssertTrue(context.contains("One study plan"))
      XCTAssertTrue(context.contains("timezone: UTC"))
      XCTAssertFalse(context.contains("upcomingEvents"))
      XCTAssertEqual(language, "English")
      return response
    })
    let result = try await service.interpret(source, correction: "One study plan",
      configuration: .init(key: "test", responseTextPath: "test"), timezone: "UTC")
    XCTAssertEqual(result.sessions.count, 3)
    XCTAssertTrue(ImportInterpreter.prompt.contains("NOT the Planning Agent"))
  }
  func testConstraintRulesStayInDraftAndUnknownRuleFieldsAreRejected() throws {
    var doc = try IntakeDocument.decode(fixture)
    var constraint = IntakeEntity(title: "Keep weekends free")
    constraint.rule = .init(type: .hard, key: .excludedWeekdays,
      value: .init(weekdays: [1, 7]), text: "Keep weekends free")
    doc.constraints = [constraint]
    let encoded = String(decoding: try doc.encoded(), as: UTF8.self)
    let restored = try IntakeDocument.decode(encoded)
    XCTAssertEqual(try restored.makeDraft().constraints.count, 1)
    XCTAssertThrowsError(try IntakeDocument.decode(encoded.replacingOccurrences(of: "\"weekdays\"", with: "\"days\"")))
    doc.constraints[0].rule = nil
    XCTAssertThrowsError(try doc.makeDraft())
  }
  func testWeekdayAndTimeRemainSoft() throws {
    var doc = try IntakeDocument.decode(fixture)
    doc.sessions[0].preferred_time = "18:30"
    let draft = try doc.makeDraft()
    XCTAssertEqual(draft.sessions[0].scheduling?.preferredDays, [2])
    XCTAssertEqual(draft.sessions[0].scheduling?.preferredWindows?.first?.startMinute, 1110)
    XCTAssertNil(draft.sessions[0].scheduling?.earliestStart)
    XCTAssertNil(draft.sessions[0].scheduledStart)
    XCTAssertEqual(draft.sessions[0].flexibility, "flexible")
    XCTAssertTrue(draft.sessions.allSatisfy { !$0.locked && $0.scheduledStart == nil })
  }
  func testMalformedAndUnknownFieldsRejectedWithoutAI() throws {
    for text in ["{", "[]", "{}", fixture.replacingOccurrences(of: "90", with: "-90"),
                 fixture.replacingOccurrences(of: "preferred_day", with: "preferred_date"),
                 fixture.replacingOccurrences(of: "Monday", with: "Someday"),
                 fixture.replacingOccurrences(of: "\"fixed_start\":null", with: "\"fixed_start\":\"2030-10-01T09:00:00Z\"")] {
      XCTAssertThrowsError(try ImportInterpreter.localDocument(text))
    }
  }
  func testDeselectionRemovesOnlyChosenEntities() throws {
    let doc = try IntakeDocument.decode(fixture)
    let selected = doc.selecting([doc.sessions[1].id, doc.goals[0].id])
    XCTAssertEqual(selected.entities.count, 2)
    XCTAssertTrue(selected.courses.isEmpty)
    XCTAssertEqual(try selected.makeDraft().sessions.map(\.title), ["Logistic Regression"])
    XCTAssertTrue(try IntakeDocument.decode(String(decoding: selected.encoded(), as: UTF8.self)).courses.isEmpty)
  }
  func testMissingFactsCanBeStoredButMustBeResolvedBeforeScheduling() throws {
    var doc = try IntakeDocument.decode(fixture)
    doc.sessions[0].duration_minutes = nil
    try doc.validate()
    XCTAssertThrowsError(try doc.makeDraft())
    doc.sessions[0].duration_minutes = 90
    doc.deadlines[0].deadline = nil
    XCTAssertThrowsError(try doc.makeDraft())
  }
  func testFixedAppointmentRetainsExplicitBounds() throws {
    var doc = try IntakeDocument.decode(fixture)
    let fixed = ISO8601DateFormatter().date(from: "2030-10-01T09:00:00Z")!
    doc.sessions[0].fixed_start = fixed
    doc.sessions[0].flexibility = "fixed"
    let session = try doc.makeDraft().sessions[0]
    XCTAssertEqual(session.scheduling?.earliestStart, fixed)
    XCTAssertEqual(session.scheduling?.latestEnd, fixed.addingTimeInterval(5400))
    XCTAssertNil(session.scheduledStart)
  }
  func testFileBoundaryRejectsUnsupportedTypes() throws {
    XCTAssertThrowsError(try IntakeFile.read(URL(fileURLWithPath: "/tmp/plan.pdf")))
  }
}
