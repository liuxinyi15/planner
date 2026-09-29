import Foundation
import SwiftData

/// Additive capture model: existing tasks, notes and calendar data are never reclassified implicitly.
@Model final class InboxItem {
  var id: UUID = UUID()
  var title: String
  var note: String = ""
  var area: String = "Life"
  var status: String = "unprocessed"
  var kind: String = "intention"
  var created: Date = Date()
  var intakeData: Data?
  var intakeSource: String?
  var deadline: Date?
  var course: Course?
  var task: PlannerTask?
  var goal: Goal?
  var plan: Plan?

  init(title: String, note: String = "", area: String = "Life") {
    self.title = title
    self.note = note
    self.area = area
  }
}

@MainActor enum InboxActions {
  static func convertToTask(_ item: InboxItem, context: ModelContext) throws {
    if item.task == nil {
      let task = PlannerTask(item.title)
      task.deadline = item.deadline
      context.insert(task)
      item.task = task
    }
    item.kind = item.deadline == nil ? "task" : "deadline"
    item.status = "processed"
    try context.save()
  }
  static func convertToGoal(_ item: InboxItem, context: ModelContext) throws {
    if item.goal == nil {
      let areas = try context.fetch(FetchDescriptor<Area>())
      let area = areas.first { $0.name == item.area } ?? Area(item.area, symbol: "circle")
      if area.modelContext == nil { context.insert(area) }
      let goal = Goal(title: item.title, outcome: item.note, area: area)
      context.insert(goal)
      item.goal = goal
    }
    item.kind = "goal"
    item.status = "processed"
    try context.save()
  }
  static func makeDraftPlan(_ item: InboxItem, context: ModelContext) throws {
    if item.plan == nil {
      let plan = Plan(title: item.title, purpose: item.note, goal: item.goal)
      context.insert(plan)
      item.plan = plan
    }
    item.kind = "plan"
    item.status = "processed"
    try context.save()
  }
}
