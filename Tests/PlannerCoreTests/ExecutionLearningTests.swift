import XCTest
@testable import PlannerCore

final class ExecutionLearningTests: XCTestCase {
  func sample(_ outcome: ExecutionOutcome = .completed, duration: Int = 40, actual: Int = 48,
              hour: Int? = 9, reason: ExecutionReason? = nil, id: UUID = UUID(), date: Date = Date()) -> ExecutionObservation {
    .init(sessionID: id, date: date, localHour: hour, estimated: duration, actual: actual,
          outcome: outcome, area: "Study", energy: "high", reason: reason)
  }
  func testMinimumThresholdAndSingleFailure() {
    XCTAssertTrue(ExecutionLearning([sample(.skipped, reason: .tooLong)]).suggestions.isEmpty)
    XCTAssertTrue(ExecutionLearning((0..<4).map { _ in sample(.skipped, reason: .tooLong) }).suggestions.isEmpty)
    XCTAssertFalse(ExecutionLearning((0..<5).map { _ in sample(.skipped, reason: .tooLong) }).suggestions.isEmpty)
  }
  func testRepeatedEventsAreNotIndependentSamples() {
    let id = UUID()
    let model = ExecutionLearning((0..<10).map { _ in sample(.postponed, reason: .tooLong, id: id) })
    XCTAssertEqual(model.sessions.count, 1)
    XCTAssertEqual(model.reasonCount(.tooLong, area: "Study"), 1)
    XCTAssertEqual(model.postponementFrequency, 10)
    XCTAssertTrue(model.suggestions.isEmpty)
  }
  func testDurationBucketsAndComparison() {
    let samples = (0..<5).map { _ in sample() } + (0..<5).map { _ in sample(.skipped, duration: 90) }
    let model = ExecutionLearning(samples)
    XCTAssertEqual(model.rates(by: \.durationBucket)["30–50m"]?.rate, 1)
    XCTAssertEqual(model.rates(by: \.durationBucket)["90+m"]?.rate, 0)
    XCTAssertTrue(model.suggestions.contains { $0.kind == .shorterSessions })
    XCTAssertEqual(sample(duration: 29).durationBucket, "<30m")
    XCTAssertEqual(sample(duration: 50).durationBucket, "30–50m")
    XCTAssertEqual(sample(duration: 89).durationBucket, "51–89m")
  }
  func testTimeAreaEnergyAndUnknownTime() {
    let model = ExecutionLearning((0..<5).map { _ in sample(.postponed, hour: 22, reason: .tooTired) } + [sample(hour: nil)])
    XCTAssertEqual(model.rates(by: \.timeBucket)["late night"]?.rate, 0)
    XCTAssertEqual(model.rates(by: \.timeBucket)["unknown"]?.count, 1)
    XCTAssertEqual(model.rates(by: \.area)["Study"]?.count, 6)
    XCTAssertEqual(model.rates(by: \.energy)["high"]?.count, 6)
    XCTAssertTrue(model.suggestions.contains { $0.kind == .lowerEveningEnergy })
  }
  func testEstimatedActualBiasIncludesPartialEffort() {
    let now = Date()
    let values = (0..<5).flatMap { _ -> [ExecutionObservation] in
      let id = UUID()
      return [sample(.partiallyCompleted, actual: 20, id: id, date: now.addingTimeInterval(-60)),
              sample(actual: 28, id: id, date: now)]
    }
    XCTAssertEqual(ExecutionLearning(values).durationBias(area: "Study")!, 0.2, accuracy: 0.001)
    XCTAssertNil(ExecutionLearning(Array(values.prefix(8))).durationBias(area: "Study"))
  }
  func testAcceptedAndIgnoredAdaptations() throws {
    let suggestion = ExecutionLearning((0..<5).map { _ in sample(.skipped, reason: .tooLong) }).suggestions.first!
    var profile = ExecutionProfile()
    let explicit = SchedulingPreferences()
    profile.ignore(suggestion)
    XCTAssertEqual(profile.adapting(explicit, area: "Study").maxSessionMinutes, explicit.maxSessionMinutes)
    XCTAssertTrue(profile.planningInstructions.isEmpty)
    XCTAssertTrue(profile.pending([suggestion]).isEmpty)
    profile.apply(suggestion)
    profile.apply(suggestion)
    XCTAssertEqual(profile.accepted.count, 1)
    XCTAssertEqual(profile.adapting(explicit, area: "Study").maxSessionMinutes, 50)
    XCTAssertEqual(profile.adapting(explicit, area: "Life").maxSessionMinutes, explicit.maxSessionMinutes)
    XCTAssertEqual(explicit.maxSessionMinutes, 120)
    XCTAssertEqual(try JSONDecoder().decode(ExecutionProfile.self, from: JSONEncoder().encode(profile)), profile)
  }
  func testConcreteFirstActionRequiresRepeatedExplicitFeedback() {
    let model = ExecutionLearning((0..<5).map { sample(.partiallyCompleted, reason: $0 < 3 ? .unclearStart : nil) })
    let suggestion = model.suggestions.first { $0.kind == .concreteStart }!
    var profile = ExecutionProfile()
    XCTAssertTrue(profile.planningInstructions.isEmpty)
    profile.apply(suggestion)
    XCTAssertTrue(profile.planningInstructions[0].contains("specific executable first action"))
  }
}
