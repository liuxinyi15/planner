import Foundation
import PlannerCore
import SwiftData

/// The only boundary from the planning workspace into persistent calendar data.
@MainActor enum DraftCommitter {
  @discardableResult static func commit(
    _ draft: DraftPlan, area: String, busy: [BusyInterval], context: ModelContext,
    inboxItem: InboxItem? = nil, course: Course? = nil, now: Date = Date(), preferences: SchedulingPreferences = .init(),
    calendar: Calendar = .current
  ) throws -> Plan {
    try draft.validate()
    for session in draft.sessions {
      let others =
        busy
        + draft.sessions.filter { $0.id != session.id }.compactMap { other -> BusyInterval? in
          guard let start = other.scheduledStart, let end = other.end else { return nil }
          return .init(
            start: start, end: end, bufferMinutes: other.scheduling?.bufferMinutes ?? 0,
            location: other.scheduling?.location ?? "", kind: .focus,
            courseID: other.scheduling?.courseID)
        }
      guard let start = session.scheduledStart,
        Scheduler().candidate(
          SchedulingTask(session), at: start, busy: others, from: now,
          deadline: draft.deadline, preferences: preferences, constraints: draft.constraints,
          calendar: calendar) != nil,
        session.dependencies.allSatisfy({ id in
          guard let end = draft.sessions.first(where: { $0.id == id })?.end else { return false }
          return end <= start
        })
      else {
        throw PlanningError.invalid(
          "A hard scheduling rule, calendar commitment or prerequisite changed. Replan before committing."
        )
      }
    }
    let linkedCourse = course ?? inboxItem?.course
    let knownCourses = try context.fetch(FetchDescriptor<Course>())
    let goal = Goal(title: draft.goal)
    let plan = Plan(title: draft.title, purpose: draft.goal, goal: goal, priority: draft.priority)
    plan.deadline = draft.deadline
    plan.course = linkedCourse
    context.insert(goal)
    context.insert(plan)
    for item in draft.sessions {
      let session = Session(
        title: item.title, purpose: item.purpose, minutes: item.duration,
        start: item.scheduledStart, area: area, definitionOfDone: item.definitionOfDone, plan: plan)
      session.course = linkedCourse ?? knownCourses.first { $0.id == item.scheduling?.courseID }
      session.energyRequirement = item.energyLevel
      session.actions = item.actions.map(Action.init)
      session.location = item.scheduling?.location ?? ""
      session.bufferMinutes = item.scheduling?.bufferMinutes ?? 0
      session.priority = ["high", "critical"].contains(draft.priority) ? "Must" : "Should"
      context.insert(session)
    }
    if let item = inboxItem {
      item.plan = plan
      item.kind = "plan"
      item.status = "processed"
    }
    do { try context.save() } catch {
      context.rollback()
      throw error
    }
    return plan
  }
}
