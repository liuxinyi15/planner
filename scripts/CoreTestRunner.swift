import Foundation

// Minimal assertions let the identical XCTest cases run on CLT-only Macs.
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(
  _ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T
) {
  do {
    let a = try left()
    let b = try right()
    precondition(a == b, "Expected \(a) == \(b)")
  } catch { fatalError("Unexpected error: \(error)") }
}
func XCTAssertGreaterThan<T: Comparable>(_ left: T, _ right: T) { precondition(left > right) }
func XCTAssertFalse(_ value: Bool) { precondition(!value) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
  do { _ = try expression() } catch { return }
  fatalError("Expected an error")
}
@main struct CoreTestRunner {
  static func main() throws {
    let suite = CoreTests()
    try suite.testICSUnfoldingTimezoneAndRecurrence()
    try suite.testRecurrenceRetainsLocalTimeAcrossDST()
    try suite.testUnsupportedRecurrenceReportsWarning()
    suite.testInvalidICSRejected()
    suite.testSchedulingAvoidsBusyTimeAndRespectsDependencies()
    suite.testDeadlineAndOversizedSessionRemainUnscheduled()
    suite.testCapacityMovesToNextDay()
    try suite.testPlanValidationAndResponsePath()
    suite.testAnalyticsUsesActualCompletedTime()
    suite.testLanguageResolutionAndFallback()
    suite.testLocalizedInterpolationPreservesUserContent()
    try suite.testTranslationPlaceholderParity()
    print("PASS: 12 test cases (localization, ICS, recurrence, scheduling, JSON, analytics)")
  }
}
