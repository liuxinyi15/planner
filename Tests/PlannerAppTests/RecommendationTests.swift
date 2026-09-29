import PlannerCore
import SwiftData
import XCTest

@testable import PlannerApp

final class RecommendationTests: XCTestCase {
  let now = ISO8601DateFormatter().date(from: "2026-09-28T10:00:00Z")!
  var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
  }
  func situation() -> CurrentSituation {
    .init(
      currentDate: now, range: now..<now.addingTimeInterval(7 * 86400),
      historyStart: now.addingTimeInterval(-7 * 86400),
      timezone: "UTC", upcomingEvents: [], upcomingCourseSessions: [], deadlines: [],
      unfinishedSessions: [], overdueTasks: [],
      recentlyPostponedSessions: [], activePlans: [],
      freeWindows: [.init(start: now, end: now.addingTimeInterval(3600))],
      recentInbox: [], knowledgeGaps: [], workload: [], profile: .init(), truncated: false)
  }
  func session(start: Date?, status: String = "planned") -> SituationSession {
    .init(
      id: UUID(), title: "ML Review", purpose: "Practice", definitionOfDone: "Run experiment",
      minutes: 45,
      start: start, status: status, area: "Study", startedAt: nil, planID: nil, courseID: nil,
      actions: [])
  }
  func recommendation(
    _ style: PlanningStyle? = .balanced, id: String = UUID().uuidString,
    due: Date? = nil, urgency: RecommendationUrgency = .important
  ) -> Recommendation {
    .init(
      id: id, type: .recoverMissedSession, title: "Recover", reason: "Missed session",
      suggestedAction: "Move",
      action: .move, urgency: urgency, expiration: now.addingTimeInterval(86400), visibleAfter: now,
      notifyAfter: due ?? now, minimumStyle: style)
  }
  func selected(
    _ recs: [Recommendation], style: PlanningStyle = .balanced,
    history: RecommendationNotificationHistory = .init(), enabled: Bool = true,
    authorized: Bool = true,
    time: Date? = nil
  ) -> [(Recommendation, Date)] {
    RecommendationNotificationPolicy().select(
      recs, style: style, enabled: enabled, authorized: authorized,
      history: history, now: time ?? now, calendar: calendar)
  }
  func testPlanningStyleEligibility() {
    let essential = recommendation(.quiet)
    let balanced = recommendation(.balanced)
    let proactive = recommendation(.proactive)
    XCTAssertEqual(selected([essential], style: .quiet).count, 1)
    XCTAssertTrue(selected([balanced], style: .quiet).isEmpty)
    XCTAssertEqual(selected([balanced], style: .balanced).count, 1)
    XCTAssertTrue(selected([proactive], style: .balanced).isEmpty)
    XCTAssertEqual(selected([proactive], style: .proactive).count, 1)
  }
  func testDuplicateSuppressionAcrossRefreshes() {
    let rec = recommendation()
    var history = RecommendationNotificationHistory()
    history.sent[rec.id] = now.addingTimeInterval(-4 * 3600)
    XCTAssertTrue(selected([rec], history: history).isEmpty)
    XCTAssertEqual(selected([rec, rec]).count, 1)
  }
  func testCooldownAndDailyLimit() {
    var history = RecommendationNotificationHistory()
    history.sent["previous"] = now.addingTimeInterval(-2 * 3600)
    XCTAssertTrue(selected([recommendation()], history: history).isEmpty)
    XCTAssertEqual(selected([recommendation()], style: .proactive, history: history).count, 1)
    history.sent = [
      "a": now.addingTimeInterval(-8 * 3600), "b": now.addingTimeInterval(-5 * 3600),
      "c": now.addingTimeInterval(-3 * 3600),
    ]
    XCTAssertTrue(selected([recommendation()], history: history).isEmpty)
  }
  func testExpiredRecommendationAndNoPermission() {
    var rec = recommendation()
    rec.expiration = now
    XCTAssertTrue(selected([rec]).isEmpty)
    XCTAssertTrue(RecommendationNotificationHistory().visible([rec], now: now).isEmpty)
    XCTAssertTrue(selected([recommendation()], enabled: false).isEmpty)
    XCTAssertTrue(selected([recommendation()], authorized: false).isEmpty)
  }
  func testNonessentialQuietHours() {
    let late = now.addingTimeInterval(12 * 3600)
    XCTAssertTrue(selected([recommendation(due: late)], time: late).isEmpty)
    XCTAssertEqual(selected([recommendation(.quiet, due: late)], time: late).count, 1)
  }
  func testMissedAndSkippedSessionRecoveryHasRealAlternatives() {
    var s = situation()
    let missed = session(start: now.addingTimeInterval(-3600))
    let skipped = session(start: now.addingTimeInterval(-7200), status: "skip")
    s.unfinishedSessions = [missed]
    s.recentlySkippedSessions = [skipped]
    let recs = RecommendationEngine().recommendations(situation: s, execution: .init())
    XCTAssertEqual(recs.filter { $0.type == .recoverMissedSession }.count, 2)
    XCTAssertEqual(recs.first?.alternatives.first, now)
    XCTAssertTrue(
      recs.contains { $0.reason == L("You skipped this session. These windows fit its duration.") })
    s.truncated = true
    XCTAssertFalse(
      RecommendationEngine().recommendations(situation: s, execution: .init()).contains {
        $0.type == .recoverMissedSession
      })
  }
  func testUpcomingCoursePreparationAndOptOut() {
    var s = situation()
    let course = UUID()
    s.upcomingCourseSessions = [
      .init(
        prepare: true, eventID: "occurrence", courseID: course, courseTitle: "Neural Computation",
        kind: "lecture", topic: "Backpropagation", start: now.addingTimeInterval(86400),
        end: now.addingTimeInterval(90000), allowAI: false)
    ]
    s.knowledgeGaps = [
      .init(id: UUID(), courseID: course, title: "Backpropagation", strength: "Developing")
    ]
    let recs = RecommendationEngine().recommendations(situation: s, execution: .init())
    XCTAssertEqual(recs.first?.type, .prepareForCourse)
    XCTAssertTrue(recs.first?.reason.contains("Backpropagation") == true)
    XCTAssertEqual(selected(recs).count, 1)
    s.upcomingCourseSessions[0].prepare = false
    XCTAssertTrue(RecommendationEngine().recommendations(situation: s, execution: .init()).isEmpty)
  }
  func testLowValueSuggestionStaysInTodayWithoutNotification() {
    var s = situation()
    s.recentInbox = [.init(id: UUID(), title: "Learn something", area: "Study", created: now)]
    let recs = RecommendationEngine().recommendations(situation: s, execution: .init())
    XCTAssertEqual(recs.first?.type, .processInboxItem)
    XCTAssertTrue(selected(recs, style: .proactive).isEmpty)
    XCTAssertEqual(RecommendationNotificationHistory().visible(recs, now: now).count, 1)
    XCTAssertTrue(selected([recommendation(.proactive, urgency: .low)], style: .proactive).isEmpty)
  }
  func testSnoozeDoesNotSuppressOtherSuggestions() {
    let rec = recommendation()
    let other = recommendation()
    var history = RecommendationNotificationHistory()
    history.dismissedUntil[rec.id] = now.addingTimeInterval(3600)
    XCTAssertEqual(history.visible([rec, other], now: now).map(\.id), [other.id])
    XCTAssertTrue(selected([rec], history: history).isEmpty)
    XCTAssertEqual(history.visible([rec], now: now.addingTimeInterval(3600)).count, 1)
  }
  func testStartReminderIsStableAndStopsWhenSessionStarted() {
    var s = situation()
    s.unfinishedSessions = [session(start: now.addingTimeInterval(300))]
    let engine = RecommendationEngine()
    let first = engine.recommendations(situation: s, execution: .init())
    XCTAssertEqual(first.first?.type, .startNow)
    s.currentDate = now.addingTimeInterval(60)
    XCTAssertEqual(
      engine.recommendations(situation: s, execution: .init()).first?.id, first.first?.id)
    s.unfinishedSessions[0].startedAt = now
    XCTAssertFalse(
      engine.recommendations(situation: s, execution: .init()).contains { $0.type == .startNow })
  }
  func testConflictSuppressesStartReminder() {
    var s = situation()
    s.unfinishedSessions = [session(start: now)]
    s.upcomingEvents = [
      .init(
        id: "busy", eventID: UUID(), title: "Busy", start: now, end: now.addingTimeInterval(3600),
        location: "", allDay: false, visible: true, useAsBusy: true, allowAI: false,
        bufferMinutes: 0)
    ]
    XCTAssertFalse(
      RecommendationEngine().recommendations(situation: s, execution: .init()).contains {
        $0.type == .startNow
      })
  }
  func testQuietRecoveryStillVisibleInToday() {
    var s = situation()
    s.recentlySkippedSessions = [session(start: now.addingTimeInterval(-3600), status: "skip")]
    let recs = RecommendationEngine().recommendations(situation: s, execution: .init())
    XCTAssertTrue(selected(recs, style: .quiet).isEmpty)
    XCTAssertEqual(
      RecommendationNotificationHistory().visible(recs, now: now).first?.type, .recoverMissedSession
    )
  }
  func testAdaptationRequiresEvidenceAndAcceptanceRemovesProposal() {
    let s = situation()
    var pattern = ExecutionAdaptation(
      kind: .lowerEveningEnergy, area: "Study", value: 21,
      evidence: "Five late sessions", proposal: "Move earlier?", sampleCount: 1)
    XCTAssertTrue(
      RecommendationEngine().recommendations(situation: s, execution: .init(), patterns: [pattern])
        .isEmpty)
    pattern.sampleCount = 5
    XCTAssertEqual(
      RecommendationEngine().recommendations(situation: s, execution: .init(), patterns: [pattern])
        .first?.type, .moveHighEnergyWork)
    var profile = ExecutionProfile()
    profile.apply(pattern)
    XCTAssertTrue(
      RecommendationEngine().recommendations(situation: s, execution: profile, patterns: [pattern])
        .isEmpty)
  }
  func testDeadlineActionRoutesToItsSource() {
    var s = situation()
    s.deadlines = [
      .init(
        id: UUID(), title: "Assignment", date: now.addingTimeInterval(3600), kind: "task",
        allowAI: true)
    ]
    let rec = RecommendationEngine().recommendations(situation: s, execution: .init()).first!
    XCTAssertEqual(rec.type, .deadlineRisk)
    XCTAssertEqual(rec.action, .tasks)
    XCTAssertEqual(selected([rec], style: .quiet).count, 1)
  }
  func testPreparationAlreadyScheduledDoesNotNag() {
    var s = situation()
    let course = UUID()
    s.upcomingCourseSessions = [
      .init(
        prepare: true, eventID: "occurrence", courseID: course,
        courseTitle: "ML", kind: "lecture", topic: "", start: now.addingTimeInterval(86400),
        end: now.addingTimeInterval(90000), allowAI: false)
    ]
    s.knowledgeGaps = [.init(id: UUID(), courseID: course, title: "Review", strength: "Developing")]
    var prepared = session(start: now.addingTimeInterval(7200))
    prepared.courseID = course
    s.unfinishedSessions = [prepared]
    XCTAssertFalse(
      RecommendationEngine().recommendations(situation: s, execution: .init()).contains {
        $0.type == .prepareForCourse
      })
  }
  func testRecommendationsFollowLanguageWithoutChangingIdentity() {
    let previous = UserDefaults.standard.object(forKey: "appLanguage")
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: "appLanguage")
      } else {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
      }
    }
    var s = situation()
    s.recentInbox = [.init(id: UUID(), title: "My original title", area: "Study", created: now)]
    UserDefaults.standard.set("en", forKey: "appLanguage")
    let english = RecommendationEngine().recommendations(situation: s, execution: .init()).first!
    UserDefaults.standard.set("zh-Hans", forKey: "appLanguage")
    let chinese = RecommendationEngine().recommendations(situation: s, execution: .init()).first!
    XCTAssertEqual(english.id, chinese.id)
    XCTAssertNotEqual(english.title, chinese.title)
    XCTAssertTrue(chinese.title.contains("My original title"))
    XCTAssertEqual(chinese.suggestedAction, "打开收件箱")
    XCTAssertEqual(english.suggestedAction, "Open Inbox")
    XCTAssertEqual(s.recentInbox.first?.area, "Study")
  }
  func testQueuedReminderRemovedWhenWindowMovesOrEligibilityChanges() {
    let policy = RecommendationNotificationPolicy()
    let original = recommendation(due: now.addingTimeInterval(3600))
    let pending = [original.id: original.notifyAfter!]
    XCTAssertTrue(
      policy.invalidPendingIDs(
        pending, recommendations: [original], style: .balanced,
        history: .init(), now: now
      ).isEmpty)
    var moved = original
    moved.notifyAfter = now.addingTimeInterval(7200)
    XCTAssertEqual(
      policy.invalidPendingIDs(
        pending, recommendations: [moved], style: .balanced,
        history: .init(), now: now), [original.id])
    XCTAssertEqual(
      policy.invalidPendingIDs(
        pending, recommendations: [original], style: .quiet,
        history: .init(), now: now), [original.id])
    XCTAssertEqual(
      policy.invalidPendingIDs(
        pending, recommendations: [], style: .balanced,
        history: .init(), now: now), [original.id])
    var expired = original
    expired.expiration = now.addingTimeInterval(1800)
    XCTAssertEqual(
      policy.invalidPendingIDs(
        pending, recommendations: [expired], style: .balanced,
        history: .init(), now: now), [original.id])
  }
  @MainActor func testPreferencesAndNotificationHistoryPersist() throws {
    let store = try ModelContainer(
      for: UserPlanningProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let profile = UserPlanningProfile()
    XCTAssertEqual(profile.planningStyleRaw, "Balanced")
    XCTAssertFalse(profile.remindersEnabled)
    store.mainContext.insert(profile)
    profile.planningStyleRaw = "Quiet"
    try store.mainContext.save()
    XCTAssertEqual(
      try ModelContext(store).fetch(FetchDescriptor<UserPlanningProfile>()).first?.planningStyleRaw,
      "Quiet")
    let name = "intent-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let service = RecommendationNotificationService(defaults: defaults)
    var state = RecommendationNotificationHistory()
    state.sent["stable"] = now
    service.history = state
    XCTAssertEqual(
      RecommendationNotificationService(defaults: defaults).history.sent["stable"], now)
  }
  @MainActor func testBuilderIncludesSkippedAndUnscheduledWork() throws {
    let store = try ModelContainer(
      for: Session.self, CalendarEvent.self, ExecutionRecord.self, UserPlanningProfile.self,
      InboxItem.self, KnowledgeGap.self, CourseSession.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = store.mainContext
    let skipped = Session(title: "Skipped", start: now.addingTimeInterval(-3600))
    skipped.status = "skip"
    context.insert(skipped)
    let record = ExecutionRecord(session: skipped, actual: 0, status: "skip")
    record.date = now
    context.insert(record)
    let unscheduled = Session(title: "Unscheduled", minutes: 30)
    context.insert(unscheduled)
    try context.save()
    let s = try CurrentSituationBuilder(context: context, calendar: calendar).build(now: now)
    XCTAssertEqual(s.recentlySkippedSessions.map(\.id), [skipped.id])
    XCTAssertTrue(s.unfinishedSessions.contains { $0.id == unscheduled.id })
  }
}
