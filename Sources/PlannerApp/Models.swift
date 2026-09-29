import Foundation
import PlannerCore
import SwiftData

@Model final class Area {
  var id: UUID = UUID()
  var name: String
  var symbol: String
  init(_ name: String, symbol: String) {
    self.name = name
    self.symbol = symbol
  }
}
@Model final class Goal {
  var id: UUID = UUID()
  var title: String
  var area: Area?
  var outcome: String
  init(title: String, outcome: String = "", area: Area? = nil) {
    self.title = title
    self.outcome = outcome
    self.area = area
  }
}
@Model final class Plan {
  var id: UUID = UUID()
  var title: String
  var purpose: String
  var created: Date = Date()
  var deadline: Date?
  var goal: Goal?
  var priority: String
  var course: Course?
  init(title: String, purpose: String, goal: Goal? = nil, priority: String = "medium") {
    self.title = title
    self.purpose = purpose
    self.goal = goal
    self.priority = priority
  }
}
@Model final class Session {
  var id: UUID = UUID()
  var title: String
  var purpose: String
  var definitionOfDone: String
  var minutes: Int
  var start: Date?
  var status: String = "planned"
  var area: String
  var priority: String = "Should"
  var plan: Plan?
  var course: Course?
  var location: String = ""
  var bufferMinutes: Int = 0
  var energyRequirement: String = "unknown"
  var postponedCount: Int = 0
  var startedAt: Date?
  @Relationship(deleteRule: .cascade) var actions: [Action] = []
  init(
    title: String, purpose: String = "", minutes: Int = 60, start: Date? = nil,
    area: String = "Life", definitionOfDone: String = "", plan: Plan? = nil
  ) {
    self.title = title
    self.purpose = purpose
    self.minutes = minutes
    self.start = start
    self.area = area
    self.definitionOfDone = definitionOfDone
    self.plan = plan
  }
  var end: Date? { start?.addingTimeInterval(Double(minutes * 60)) }
}
@Model final class Action {
  var id: UUID = UUID()
  var title: String
  var completed: Bool = false
  init(_ title: String) { self.title = title }
}
@Model final class PlannerTask {
  var id: UUID = UUID()
  var title: String
  var done: Bool = false
  var deadline: Date?
  var plan: Plan?
  var session: Session?
  init(_ title: String) { self.title = title }
}
@Model final class Note {
  var id: UUID = UUID()
  var title: String
  var body: String
  var updated: Date = Date()
  var course: Course?
  var plan: Plan?
  var session: Session?
  var goal: Goal?
  init(title: String, body: String = "") {
    self.title = title
    self.body = body
  }
}
@Model final class CalendarSource {
  var id: UUID = UUID()
  var name: String
  var url: String
  var visible: Bool = true
  var useAsBusy: Bool = true
  var allowAI: Bool = false
  var prepare: Bool = false
  var review: Bool = false
  var lastSync: Date?
  var refreshHours: Int = 12
  init(name: String, url: String = "") {
    self.name = name
    self.url = url
  }
}
@Model final class CalendarEvent {
  var id: UUID = UUID()
  var timeZoneID: String = TimeZone.current.identifier
  var remoteID: String
  var title: String
  var start: Date
  var end: Date
  var details: String
  var location: String
  var source: CalendarSource?
  var rule: String?
  var recurrenceID: String?
  var excluded: [Date] = []
  var allDay: Bool = false
  var cancelled: Bool = false
  var url: String = ""
  var bufferMinutes: Int = 0
  init(
    remoteID: String, title: String, start: Date, end: Date, details: String = "",
    location: String = "", source: CalendarSource? = nil
  ) {
    self.remoteID = remoteID
    self.title = title
    self.start = start
    self.end = end
    self.details = details
    self.location = location
    self.source = source
  }
}
@Model final class Course {
  var id: UUID = UUID()
  var title: String
  var topic: String = ""
  var moduleCode: String = ""
  var detectedFrom: String = "manual"
  var createdAutomatically: Bool = false
  var currentFocus: String = ""
  var timetableKey: String = ""
  var timetableSourceIDs: [String] = []
  var assessmentData: Data?
  var assessment: String = ""
  var deadline: Date?
  init(_ title: String) { self.title = title }
}
@Model final class CourseSession {
  var id: UUID = UUID()
  var course: Course?
  var event: CalendarEvent?
  var kind: String
  var detectedAutomatically: Bool = false
  var topic: String = ""
  init(course: Course, event: CalendarEvent, kind: String = "lecture") {
    self.course = course
    self.event = event
    self.kind = kind
  }
}
@Model final class KnowledgeGap {
  var id: UUID = UUID()
  var title: String
  var strength: String = "Developing"
  var course: Course?
  init(_ title: String, course: Course? = nil) {
    self.title = title
    self.course = course
  }
}
@Model final class ExecutionRecord {
  var id: UUID = UUID()
  var scheduledStart: Date?
  var localHour: Int?
  var energyRequirement: String = "unknown"
  var postponementOrdinal: Int = 0
  var feedbackReason: String?
  var feedbackDetail: String = ""
  var completedActions: [String] = []
  var remainingActions: [String] = []
  var sessionID: UUID
  var courseID: UUID?
  var title: String
  var date: Date = Date()
  var estimated: Int
  var actual: Int
  var status: String
  var area: String
  var notes: String
  init(session: Session, actual: Int, status: String, notes: String = "") {
    postponementOrdinal = session.postponedCount + (status == "postponed" ? 1 : 0)
    scheduledStart = session.startedAt ?? session.start
    localHour = (session.startedAt ?? session.start).map { Calendar.current.component(.hour, from: $0) }
    energyRequirement = session.energyRequirement
    completedActions = session.actions.filter(\.completed).map(\.title)
    remainingActions = session.actions.filter { !$0.completed }.map(\.title)
    sessionID = session.id
    courseID = session.course?.id ?? session.plan?.course?.id
    title = session.title
    estimated = session.minutes
    area = session.area
    self.actual = actual
    self.status = status
    self.notes = notes
  }
}
@Model final class UserPlanningProfile {
  var ignoredCourseKeys: [String] = []
  var id: UUID = UUID()
  var planningStyleRaw: String = "Balanced"
  var remindersEnabled: Bool = false
  var executionProfileData: Data?
  var executionProfile: ExecutionProfile {
    get { executionProfileData.flatMap { try? JSONDecoder().decode(ExecutionProfile.self, from: $0) } ?? ExecutionProfile() }
    set { executionProfileData = try? JSONEncoder().encode(newValue) }
  }
  var startHour: Int = 9
  var endHour: Int = 21
  var dailyMinutes: Int = 240
  var maxSessionMinutes: Int = 120
  var breakMinutes: Int = 15
  var preferredStartHour: Int?
  var preferredEndHour: Int?
  var preferredWeekdays: [Int] = []
  var lateEveningStartsHour: Int?
  var trainingRecoveryMinutes: Int = 0
  init() {}
}
@Model final class WeeklyReview {
  var id: UUID = UUID()
  var date: Date = Date()
  var reflection: String
  init(_ reflection: String) { self.reflection = reflection }
}
struct WidgetSnapshot: Codable {
  var generatedAt: Date
  var completed: Int
  var total: Int
  var sessions: [Entry]
  struct Entry: Codable {
    var title: String
    var start: Date?
    var minutes: Int
  }
}
