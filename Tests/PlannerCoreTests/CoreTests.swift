import Foundation

#if !CORE_STANDALONE
  import XCTest
  @testable import PlannerCore
#endif

final class CoreTests: XCTestCase {
  func testLanguageResolutionAndFallback() {
    XCTAssertEqual(
      AppLanguage.system.resolved(preferredLanguages: ["zh-CN", "en"]), .simplifiedChinese)
    XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-CN"]), .english)
    XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr"]), .english)
    XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]), .english)
    XCTAssertEqual(L10n.label("Study", language: .simplifiedChinese), "学习")
    XCTAssertEqual(
      L10n.label("Custom user content", language: .simplifiedChinese), "Custom user content")
  }
  func testLocalizedInterpolationPreservesUserContent() {
    let title = "Study {1} 100% 中文"
    let message: LocalizedMessage =
      "\(title) has been postponed \(3) times. Consider reducing scope or changing its time."
    XCTAssertEqual(
      L10n.render(message, language: .simplifiedChinese),
      "「Study {1} 100% 中文」已推迟 3 次，可以考虑缩小范围或调整时间。")
    XCTAssertEqual(
      L10n.render(message, language: .english),
      "Study {1} 100% 中文 has been postponed 3 times. Consider reducing scope or changing its time.")
  }
  func testTranslationPlaceholderParity() throws {
    let expression = try NSRegularExpression(pattern: #"\{\d+\}"#)
    func placeholders(_ text: String) -> [String] {
      expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        (text as NSString).substring(with: $0.range)
      }.sorted()
    }
    for (english, chinese) in L10n.chinese {
      XCTAssertEqual(placeholders(english), placeholders(chinese))
      XCTAssertFalse(chinese.isEmpty)
    }
  }
  func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  func testICSUnfoldingTimezoneAndRecurrence() throws {
    let source =
      "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:lecture-1\r\nDTSTART;TZID=Europe/London:20260928T140000\r\nDTEND;TZID=Europe/London:20260928T150000\r\nSUMMARY:Machine Learn\r\n ing\r\nDESCRIPTION:Review\\nPractice\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nEXDATE;TZID=Europe/London:20261005T140000\r\nEND:VEVENT\r\nEND:VCALENDAR"
    let result = try ICSParser().parse(source)
    XCTAssertEqual(result.events.count, 1)
    XCTAssertEqual(result.events[0].title, "Machine Learning")
    XCTAssertEqual(result.events[0].notes, "Review\nPractice")
    XCTAssertEqual(result.events[0].start, instant("2026-09-28T13:00:00Z"))
    let expanded = ICSParser().occurrences(
      result.events[0], in: instant("2026-09-01T00:00:00Z")..<instant("2026-10-20T00:00:00Z"))
    XCTAssertEqual(expanded.count, 2)
  }
  func testRecurrenceRetainsLocalTimeAcrossDST() throws {
    let result = try ICSParser().parse(
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:dst\nDTSTART;TZID=Europe/London:20261019T140000\nDTEND;TZID=Europe/London:20261019T150000\nRRULE:FREQ=WEEKLY;COUNT=2\nEND:VEVENT\nEND:VCALENDAR"
    )
    let expanded = ICSParser().occurrences(
      result.events[0], in: instant("2026-10-01T00:00:00Z")..<instant("2026-11-01T00:00:00Z"))
    XCTAssertEqual(expanded.count, 2)
    XCTAssertEqual(expanded[0].start, instant("2026-10-19T13:00:00Z"))
    XCTAssertEqual(expanded[1].start, instant("2026-10-26T14:00:00Z"))
  }
  func testUnsupportedRecurrenceReportsWarning() throws {
    let result = try ICSParser().parse(
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART:20260928T140000Z\nRRULE:FREQ=MONTHLY;BYDAY=MO\nEND:VEVENT\nEND:VCALENDAR"
    )
    XCTAssertEqual(result.warnings.count, 1)
  }
  func testInvalidICSRejected() { XCTAssertThrowsError(try ICSParser().parse("not a calendar")) }
  func testSchedulingAvoidsBusyTimeAndRespectsDependencies() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = instant("2026-09-28T09:00:00Z")
    let sessions = [
      SessionDraft(title: "First", duration_minutes: 60),
      SessionDraft(title: "Second", duration_minutes: 60, dependencies: [0]),
    ]
    let result = Scheduler().suggest(
      sessions, busy: [BusyInterval(start: start, end: start.addingTimeInterval(3600))],
      from: start, calendar: calendar)
    // Best feasible slot can be on a lighter later day, rather than immediately after the event.
    XCTAssertGreaterThan(result[0].start!, start.addingTimeInterval(3600))
    XCTAssertGreaterThan(result[1].start!, result[0].end!)
    XCTAssertFalse(
      Scheduler.conflicts(
        start: result[0].start!, end: result[0].end!,
        busy: [BusyInterval(start: start, end: start.addingTimeInterval(3600))]))
  }
  func testDeadlineAndOversizedSessionRemainUnscheduled() {
    let now = Date()
    let result = Scheduler().suggest(
      [SessionDraft(title: "Too long", duration_minutes: 240)], busy: [], from: now,
      deadline: now.addingTimeInterval(60))
    XCTAssertNil(result[0].start)
    XCTAssertNotNil(result[0].warning)
  }
  func testCapacityMovesToNextDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = instant("2026-09-28T09:00:00Z")
    var preferences = SchedulingPreferences()
    preferences.dailyMinutes = 60
    let result = Scheduler().suggest(
      [
        SessionDraft(title: "A", duration_minutes: 60),
        SessionDraft(title: "B", duration_minutes: 60),
      ], busy: [], from: start, preferences: preferences, calendar: calendar)
    XCTAssertFalse(calendar.isDate(result[0].start!, inSameDayAs: result[1].start!))
  }
  func testPlanValidationAndResponsePath() throws {
    let json =
      #"{"intent_type":"study plan","title":"Learn","goal":"Understand","priority":"medium","deadline":null,"estimated_total_minutes":60,"sessions":[{"title":"Practice","purpose":"Learn","duration_minutes":60,"actions":["Solve exercise"],"definition_of_done":"Solution checked","energy_level":"medium","preferred_time":null,"dependencies":[]}],"notes":[],"clarification_needed":false,"clarification_question":null}"#
    XCTAssertEqual(try PlanDraft.decode(json).sessions.count, 1)
    XCTAssertThrowsError(
      try PlanDraft.decode(
        json.replacingOccurrences(
          of: "\"estimated_total_minutes\":60", with: "\"estimated_total_minutes\":90")))
    XCTAssertThrowsError(try PlanDraft.decode("{\"title\":"))
    let response = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": json]]]
    ])
    XCTAssertEqual(try AIService.extract(data: response, path: "choices.0.message.content"), json)
    XCTAssertThrowsError(try AIService.extract(data: response, path: "wrong.path"))
  }
  func testAnalyticsUsesActualCompletedTime() {
    let analytics = ExecutionAnalytics(samples: [
      .init(estimated: 60, actual: 90, status: "complete", area: "Study", date: Date()),
      .init(estimated: 60, actual: 0, status: "skip", area: "Study", date: Date()),
    ])
    XCTAssertEqual(analytics.executionRate, 0.5)
    XCTAssertEqual(analytics.estimationBias, 0.5)
    XCTAssertEqual(analytics.allocation["Study"], 90)
  }
}
