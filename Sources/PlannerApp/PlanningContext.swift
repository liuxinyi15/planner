import Foundation
import PlannerCore

struct PlanningContext: Codable, Sendable {
  struct Event: Codable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var location: String
  }
  struct CourseSession: Codable, Sendable {
    var courseID: UUID?
    var course: String
    var kind: String
    var topic: String
    var start: Date
    var end: Date
  }
  struct Selection: Codable, Sendable {
    var kind: String
    var id: UUID?
    var text: String
  }
  var currentDate: Date
  var timezone: String
  var rangeEnd: Date
  var historyStart: Date
  var upcomingEvents: [Event]
  var upcomingCourseSessions: [CourseSession]
  var activePlans: [SituationPlan]
  var pendingSessions: [SituationSession]
  var deadlines: [SituationDeadline]
  var overdueTasks: [SituationTask]
  var recentlyPostponedSessions: [SituationSession]
  var recentInbox: [SituationInbox]
  var knowledgeGaps: [SituationGap]
  var freeWindows: [FreeWindow]
  var profile: SituationProfile
  var relevantConstraints: [String]
  var selectedEntity: Selection?
  func serialized() throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}

enum ContextBuilder {
  /// Explicit allow-list projection. Private event/course metadata never enters this DTO.
  static func build(situation: CurrentSituation, selectedEntity: PlanningContext.Selection? = nil)
    -> PlanningContext
  {
    let allowedCourses = Set(
      situation.upcomingCourseSessions.filter(\.allowAI).map(\.courseID)
        + situation.unfinishedSessions.compactMap(\.courseID)
        + situation.deadlines.filter { $0.kind == "course" && $0.allowAI }.map(\.id))
    return PlanningContext(
      currentDate: situation.currentDate, timezone: situation.timezone,
      rangeEnd: situation.range.upperBound, historyStart: situation.historyStart,
      upcomingEvents: situation.upcomingEvents.filter(\.allowAI).prefix(40).map {
        .init(title: $0.title, start: $0.start, end: $0.end, location: $0.location)
      },
      upcomingCourseSessions: situation.upcomingCourseSessions.filter(\.allowAI).prefix(30).map {
        .init(
          courseID: $0.courseID, course: $0.courseTitle, kind: $0.kind, topic: $0.topic,
          start: $0.start, end: $0.end)
      },
      activePlans: Array(situation.activePlans.prefix(20)),
      pendingSessions: Array(situation.unfinishedSessions.prefix(40)),
      deadlines: Array(situation.deadlines.filter(\.allowAI).prefix(40)),
      overdueTasks: Array(situation.overdueTasks.prefix(20)),
      recentlyPostponedSessions: Array(situation.recentlyPostponedSessions.prefix(20)),
      recentInbox: Array(situation.recentInbox.prefix(20)),
      knowledgeGaps: Array(
        situation.knowledgeGaps.filter { allowedCourses.contains($0.courseID) }.prefix(30)),
      freeWindows: Array(situation.freeWindows.prefix(80)), profile: situation.profile,
      relevantConstraints: [
        "Free windows include local busy commitments; their private details are omitted.",
        "Do not infer courses from event names. Only explicit course links are provided.",
        "Availability is not a schedule. All proposed changes require confirmation.",
      ] + situation.profile.acceptedExecutionInstructions
        + (situation.truncated
          ? [
            "Source limits reached. Availability is unknown; do not assume any unlisted time is free."
          ] : []),
      selectedEntity: selectedEntity)
  }
}
