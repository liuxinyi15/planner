import SwiftData
import XCTest
import PlannerCore
@testable import PlannerApp

final class ExecutionPersistenceTests: XCTestCase {
  @MainActor func testFeedbackAndActionSnapshotsPersist() throws {
    let container = try ModelContainer(for: Session.self, ExecutionRecord.self, UserPlanningProfile.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let session = Session(title: "ML", minutes: 40, start: Date(), area: "Study")
    session.energyRequirement = "high"
    session.actions = [Action("Open notebook"), Action("Run experiment")]
    session.actions[0].completed = true
    context.insert(session)
    let record = ExecutionRecord(session: session, actual: 20, status: "partial")
    record.feedbackReason = ExecutionReason.unclearStart.rawValue
    record.feedbackDetail = ""
    context.insert(record)
    try context.save()
    session.actions[1].completed = true
    try context.save()
    let fresh = ModelContext(container)
    let saved = try fresh.fetch(FetchDescriptor<ExecutionRecord>()).first!
    XCTAssertEqual(saved.completedActions, ["Open notebook"])
    XCTAssertEqual(saved.remainingActions, ["Run experiment"])
    XCTAssertEqual(saved.observation?.reason, .unclearStart)
    XCTAssertEqual(saved.energyRequirement, "high")
    XCTAssertNotNil(saved.localHour)
    XCTAssertTrue(saved.offersFeedback)
  }
  @MainActor func testAcceptedPreferencePersistsWithoutOverwritingExplicitPreference() throws {
    let container = try ModelContainer(for: UserPlanningProfile.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let profile = UserPlanningProfile()
    profile.maxSessionMinutes = 90
    let suggestion = ExecutionAdaptation(kind: .shorterSessions, area: "Study", value: 50,
      evidence: "Five sessions", proposal: "Cap at 50?", sampleCount: 5)
    var execution = profile.executionProfile
    execution.apply(suggestion)
    profile.executionProfile = execution
    context.insert(profile)
    try context.save()
    let fresh = ModelContext(container)
    let saved = try fresh.fetch(FetchDescriptor<UserPlanningProfile>()).first!
    XCTAssertEqual(saved.maxSessionMinutes, 90)
    XCTAssertEqual(saved.executionProfile.accepted, [suggestion])
    let situation = try CurrentSituationBuilder(context: context).build()
    XCTAssertTrue(try ContextBuilder.build(situation: situation).serialized().contains("User-accepted adaptation"))
  }
  @MainActor func testOptionalFeedbackTriggersAndOutcomes() {
    let session = Session(title: "Test", minutes: 40)
    XCTAssertFalse(ExecutionRecord(session: session, actual: 45, status: "complete").offersFeedback)
    XCTAssertTrue(ExecutionRecord(session: session, actual: 50, status: "complete").offersFeedback)
    XCTAssertTrue(ExecutionRecord(session: session, actual: 0, status: "skip").offersFeedback)
    XCTAssertFalse(ExecutionRecord(session: session, actual: 0, status: "postponed").offersFeedback)
    session.postponedCount = 1
    XCTAssertTrue(ExecutionRecord(session: session, actual: 0, status: "postponed").offersFeedback)
    for outcome in ExecutionOutcome.allCases {
      XCTAssertEqual(ExecutionRecord(session: session, actual: 0, status: outcome.rawValue).observation?.outcome, outcome)
    }
  }
}
