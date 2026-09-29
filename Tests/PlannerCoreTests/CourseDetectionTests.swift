import XCTest
@testable import PlannerCore

final class CourseDetectionTests: XCTestCase {
  func testModuleNameCodeAndSessionType() throws {
    let value = try XCTUnwrap(CourseDetectionService.parse("LC Machine Learning (14934)/Tutorial"))
    XCTAssertEqual(value.courseName, "Machine Learning")
    XCTAssertEqual(value.moduleCode, "14934")
    XCTAssertEqual(value.sessionType, "tutorial")
    XCTAssertEqual(value.key, "code:14934")
  }
  func testLectureTutorialAndLabTypes() {
    for (title, kind) in [("LH Neural Computation (13716)/Lecture", "lecture"),
      ("Machine Learning (CS101) - Laboratory", "lab"), ("Lab: Robotics", "lab"),
      ("Human Computer Interaction / Tutorial", "tutorial")] {
      XCTAssertEqual(CourseDetectionService.parse(title)?.sessionType, kind)
    }
  }
  func testNameFallbackWithoutCodesIsConservative() throws {
    let a = try XCTUnwrap(CourseDetectionService.parse("Machine Learning / Lecture"))
    let b = try XCTUnwrap(CourseDetectionService.parse("machine learning - Tutorial"))
    XCTAssertNil(a.moduleCode)
    XCTAssertEqual(a.key, b.key)
    for title in ["Lunch with Alex", "Dentist", "Project meeting", "Lecture", "Workshop", "Birthday (2026)"] {
      XCTAssertNil(CourseDetectionService.parse(title))
    }
    XCTAssertFalse(CourseDetectionService.matches(a, moduleCode: "13716", name: "Machine Learning"))
  }
  func testSameCodeGroupedAndOtherModulesKeptSeparate() {
    let events = ["LH Machine Learning (14934)/Lecture", "LC Machine Learning (14934)/Tutorial",
      "LH Neural Computation (13716)/Lecture", "Lunch"].map { TimetableCourseEvent(id: UUID(), title: $0) }
    let result = CourseDetectionService.group(events)
    XCTAssertEqual(result.count, 2)
    let ml = result.first { $0.moduleCode == "14934" }
    XCTAssertEqual(ml?.eventIDs.count, 2)
    XCTAssertEqual(ml?.counts, ["lecture": 1, "tutorial": 1])
  }
  func testDistinctCodesWithSameNameAreNotMerged() {
    let result = CourseDetectionService.group(["Statistics (10001)/Lecture", "Statistics (20002)/Lecture"].map {
      TimetableCourseEvent(id: UUID(), title: $0)
    })
    XCTAssertEqual(result.count, 2)
  }
  func testDuplicateInputIDDoesNotInflateCandidate() {
    let event = TimetableCourseEvent(id: UUID(), title: "ML (14934)/Lecture", upcomingCount: 7)
    let result = CourseDetectionService.group([event, event])
    XCTAssertEqual(result.first?.eventIDs.count, 1)
    XCTAssertEqual(result.first?.counts["lecture"], 7)
  }
}
