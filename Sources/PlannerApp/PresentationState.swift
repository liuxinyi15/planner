import Combine
import Foundation
import PlannerCore

/// Unconfirmed AI suggestions are presentation state, never calendar events or busy time.
@MainActor final class PlanningPreview: ObservableObject {
  @Published var destination: String?
  @Published var draft: DraftPlan?
  @Published var suggestions: [ScheduledSuggestion] = []
  var input = ""
  var area = "Study"
  var start = Date()
  var inboxID: UUID?
  var courseID: UUID?
  func clear() {
    draft = nil
    suggestions = []
    input = ""
    inboxID = nil
    courseID = nil
  }
}

enum PlanSection: String, CaseIterable {
  case active = "Active"
  case draft = "Drafts"
  case completed = "Completed"
  static func classify(_ sessions: [Session]) -> PlanSection {
    if !sessions.isEmpty && sessions.allSatisfy({ $0.status == "complete" || $0.status == "skip" })
    {
      return .completed
    }
    return sessions.contains { $0.start != nil } ? .active : .draft
  }
}

enum CalendarMode: String, CaseIterable {
  case agenda = "Agenda"
  case day = "Day"
  case week = "Week"
  var dayCount: Int { self == .day ? 1 : 7 }
}
