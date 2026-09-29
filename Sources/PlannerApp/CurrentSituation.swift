import Foundation
import PlannerCore

struct SituationEvent: Codable, Identifiable, Sendable {
  var id: String
  var eventID: UUID
  var title: String
  var start: Date
  var end: Date
  var location: String
  var allDay: Bool
  var visible: Bool
  var useAsBusy: Bool
  var allowAI: Bool
  var bufferMinutes: Int
  var imported: ImportedEvent {
    .init(uid: id, title: title, start: start, end: end, location: location, allDay: allDay)
  }
}
struct SituationCourseSession: Codable, Sendable {
  var prepare: Bool = false
  var review: Bool = false
  var eventID: String
  var courseID: UUID
  var courseTitle: String
  var kind: String
  var topic: String
  var start: Date
  var end: Date
  var allowAI: Bool
}
struct SituationAction: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var completed: Bool
}
struct SituationSession: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var purpose: String
  var definitionOfDone: String
  var minutes: Int
  var start: Date?
  var status: String
  var area: String
  var startedAt: Date?
  var planID: UUID?
  var courseID: UUID?
  var actions: [SituationAction]
  var end: Date? { start?.addingTimeInterval(Double(minutes * 60)) }
}
struct SituationDeadline: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var date: Date
  var kind: String
  var allowAI: Bool
}
struct SituationTask: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var deadline: Date
}
struct SituationPlan: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var purpose: String
  var priority: String
}
struct SituationInbox: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var area: String
  var created: Date
}
struct SituationGap: Codable, Identifiable, Sendable {
  var id: UUID
  var courseID: UUID
  var title: String
  var strength: String
}
struct SituationWorkload: Codable, Sendable {
  var day: Date
  var fixedMinutes: Int
  var sessionMinutes: Int
  var freeMinutes: Int
}
struct SituationProfile: Codable, Sendable {
  var startHour: Int = 9
  var endHour: Int = 21
  var dailyMinutes: Int = 240
  var maxSessionMinutes: Int = 120
  var breakMinutes: Int = 15
  var acceptedExecutionInstructions: [String] = []
}

/// Read-only, bounded value snapshot. Never inserts courses, tasks or recommendations.
struct CurrentSituation: Sendable {
  var currentDate: Date
  var range: Range<Date>
  var historyStart: Date
  var timezone: String
  var upcomingEvents: [SituationEvent]
  var upcomingCourseSessions: [SituationCourseSession]
  var deadlines: [SituationDeadline]
  var unfinishedSessions: [SituationSession]
  var overdueTasks: [SituationTask]
  var recentlyPostponedSessions: [SituationSession]
  var activePlans: [SituationPlan]
  var freeWindows: [FreeWindow]
  var recentInbox: [SituationInbox]
  var knowledgeGaps: [SituationGap]
  var workload: [SituationWorkload]
  var profile: SituationProfile
  var truncated: Bool
  var recentlySkippedSessions: [SituationSession] = []
  var recentCourseSessions: [SituationCourseSession] = []
  var nextFixedCommitment: SituationEvent? { upcomingEvents.first { $0.visible } }
  var nextPlannedSession: SituationSession? {
    unfinishedSessions.first { $0.startedAt != nil }
      ?? unfinishedSessions.first { ($0.end ?? .distantPast) > currentDate }
  }
  var attentionCount: Int {
    recentInbox.count + overdueTasks.count
      + unfinishedSessions.filter { ($0.end ?? .distantFuture) <= currentDate }.count
  }
  var freeCapacityToday: Int {
    guard !truncated, let day = workload.first else { return 0 }
    return min(day.freeMinutes, max(0, profile.dailyMinutes - day.sessionMinutes))
  }
}
