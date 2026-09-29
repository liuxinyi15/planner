import XCTest

@testable import PlannerCore

final class WeekGridTests: XCTestCase {
  func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
  var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/London")!
    return c
  }
  func testWeekStartsMondayAcrossMonthBoundary() {
    XCTAssertEqual(
      WeekGridLayout.weekStart(containing: date("2026-10-04T10:00:00Z"), calendar: calendar),
      date("2026-09-27T23:00:00Z"))
  }
  func testOverlapsUseSeparateLanesAndAdjacentEventsReuseWidth() {
    let day = date("2026-09-28T00:00:00Z")
    let intervals = [
      WeekGridInterval(
        id: "a", start: date("2026-09-28T08:00:00Z"), end: date("2026-09-28T10:00:00Z")),
      WeekGridInterval(
        id: "b", start: date("2026-09-28T09:00:00Z"), end: date("2026-09-28T11:00:00Z")),
      WeekGridInterval(
        id: "c", start: date("2026-09-28T11:00:00Z"), end: date("2026-09-28T12:00:00Z")),
    ]
    let result = WeekGridLayout.placements(intervals, on: day, calendar: calendar)
    XCTAssertEqual(result.map(\.laneCount), [2, 2, 1])
    XCTAssertEqual(result.map(\.lane), [0, 1, 0])
    XCTAssertEqual(result.first?.startMinute, 540)
  }
  func testCrossMidnightClipsIntoBothDaysAndMidnightEndDoesNotRepeat() {
    let interval = WeekGridInterval(
      id: "overnight", start: date("2026-09-28T22:30:00Z"), end: date("2026-09-29T00:00:00Z"))
    let first = WeekGridLayout.placements(
      [interval], on: date("2026-09-28T12:00:00Z"), calendar: calendar)
    let next = WeekGridLayout.placements(
      [interval], on: date("2026-09-29T12:00:00Z"), calendar: calendar)
    XCTAssertEqual(first.first?.startMinute, 1410)
    XCTAssertEqual(first.first?.endMinute, 1440)
    XCTAssertEqual(next.first?.startMinute, 0)
    XCTAssertEqual(next.first?.endMinute, 60)
    let midnight = WeekGridInterval(
      id: "midnight", start: interval.start, end: date("2026-09-28T23:00:00Z"))
    XCTAssertTrue(
      WeekGridLayout.placements([midnight], on: date("2026-09-29T12:00:00Z"), calendar: calendar)
        .isEmpty)
  }
  func testAllDaySeparateAndDSTUsesLocalClock() {
    let day = date("2026-10-25T12:00:00Z")
    let intervals = [
      WeekGridInterval(
        id: "all", start: date("2026-10-24T23:00:00Z"), end: date("2026-10-26T00:00:00Z"),
        allDay: true),
      WeekGridInterval(
        id: "afterDST", start: date("2026-10-25T09:00:00Z"), end: date("2026-10-25T10:00:00Z")),
    ]
    let result = WeekGridLayout.placements(intervals, on: day, calendar: calendar)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.startMinute, 540)
    XCTAssertEqual(result.first?.endMinute, 600)
  }
  func testMinimumHeightParticipatesInOverlapLayout() {
    let start = date("2026-09-28T08:00:00Z")
    let result = WeekGridLayout.placements(
      [
        .init(id: "a", start: start, end: start.addingTimeInterval(60)),
        .init(id: "b", start: start.addingTimeInterval(300), end: start.addingTimeInterval(360)),
      ], on: start, calendar: calendar)
    XCTAssertEqual(result.map(\.laneCount), [2, 2])
    XCTAssertEqual(result.first!.endMinute - result.first!.startMinute, 20)
  }
  func testNewUIKeysAndPersistedEvidenceAreLocalized() {
    for key in [
      "Planning Workspace", "Planning Style", "Quiet", "Balanced", "Proactive",
      "Energy requirement", "Save feedback", "All day", "Apply all", "Week", "abandoned", "low",
      "high",
    ] {
      XCTAssertNotEqual(L10n.label(key, language: .simplifiedChinese), key)
    }
    XCTAssertEqual(
      L10n.systemText(
        "Study: ‘too long’ was reported across 3 distinct sessions.", language: .simplifiedChinese),
      "学习：在 3 个不同时段中反馈了“时长太长”。")
    XCTAssertEqual(
      L10n.systemText("Increase future Study estimates by 20%?", language: .simplifiedChinese),
      "将以后的学习预计时长增加 20%？")
    XCTAssertEqual(
      L10n.systemText("Inside your available hours.", language: .simplifiedChinese), "位于你的可用时间内。")
    XCTAssertEqual(
      L10n.systemText("Some user text", language: .simplifiedChinese), "Some user text")
    XCTAssertEqual(
      L10n.systemText("Cap future Study sessions at 50 minutes?", language: .english),
      "Cap future Study sessions at 50 minutes?")
  }
}
