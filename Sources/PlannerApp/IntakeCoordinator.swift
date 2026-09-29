import Foundation
import PlannerCore
import SwiftData

@MainActor enum IntakeCoordinator {
  /// Confirmation of intake persists source facts only. No Session or CalendarEvent is inserted.
  static func importOnly(_ document: IntakeDocument, source: String, area: String,
    context: ModelContext, targetCourse: Course? = nil) throws -> InboxItem {
    try document.validate()
    let data = try document.encoded()
    let batch = InboxItem(title: document.title, note: document.summary, area: area)
    batch.kind = "plan"
    batch.intakeData = data
    batch.intakeSource = source
    context.insert(batch)
    let savedCourses = try context.fetch(FetchDescriptor<Course>())
    var importedCourses: [Course] = []
    for entity in document.courses {
      let matches = savedCourses.filter { CourseDetectionService.normalizedName($0.title) == CourseDetectionService.normalizedName(entity.title) }
      let course = matches.count == 1 ? matches[0] : Course(entity.title)
      if course.modelContext == nil {
        course.detectedFrom = "import"
        course.deadline = entity.deadline
        context.insert(course)
      }
      importedCourses.append(course)
    }
    let linkedCourse = targetCourse ?? (importedCourses.count == 1 ? importedCourses.first : nil)
    batch.course = linkedCourse
    for kind in IntakeKind.allCases where kind != .sessions {
      for entity in document[kind] {
        let item = InboxItem(title: entity.title, note: entity.description, area: area)
        item.kind = kind.rawValue
        item.deadline = entity.deadline
        if kind == .ideas { item.status = "someday" }
        context.insert(item)
        item.course = linkedCourse
        if kind == .courses { item.status = "processed" }
      }
    }
    do { try context.save() } catch { context.rollback(); throw error }
    return batch
  }

  static func arrange(_ document: IntakeDocument, area: String, context: ModelContext,
    now: Date = Date(), calendar: Calendar = .current) throws -> DraftPlan {
    let draft = try document.makeDraft()
    let situation = try CurrentSituationBuilder(context: context, calendar: calendar).build(now: now, days: 28)
    guard !situation.truncated else { throw PlanningError.invalid("Calendar context is incomplete. Reduce the planning scope before arranging.") }
    let profile = try context.fetch(FetchDescriptor<UserPlanningProfile>()).first
    let preferences = planningPreferences(profile, area: area)
    // Use the full local busy set, including private sources, never send this snapshot to the interpreter.
    let events = try context.fetch(FetchDescriptor<CalendarEvent>())
    let sessions = try context.fetch(FetchDescriptor<Session>())
    let padding = Double(max(preferences.breakMinutes, events.map(\.bufferMinutes).max() ?? 0,
      sessions.map(\.bufferMinutes).max() ?? 0)) * 60
    let busy = CalendarRepository.expand(events,
      range: now.addingTimeInterval(-padding)..<now.addingTimeInterval(28 * 86400 + padding), busyOnly: true).map { value in
        BusyInterval(start: value.start, end: value.end,
          bufferMinutes: events.filter { $0.remoteID == value.uid }.map(\.bufferMinutes).max() ?? 0,
          location: value.location)
      } + sessions.filter { !["skip", "abandoned"].contains($0.status) }.compactMap { session -> BusyInterval? in
        guard let start = session.start, let end = session.end else { return nil }
        return BusyInterval(start: start, end: end, bufferMinutes: session.bufferMinutes,
          location: session.location, kind: session.area == "Training" ? .training : .focus, courseID: session.course?.id)
      }
    return try DraftEditor.schedule(draft, affected: Set(draft.sessions.map(\.id)), busy: busy,
      from: now, preferences: preferences, calendar: calendar)
  }
  static func open(_ draft: DraftPlan, item: InboxItem, preview: PlanningPreview, now: Date = Date()) {
    var linkedDraft = draft
    if let course = item.course {
      for index in linkedDraft.sessions.indices {
        var shape = linkedDraft.sessions[index].scheduling ?? .init()
        shape.courseID = course.id
        linkedDraft.sessions[index].scheduling = shape
      }
    }
    preview.draft = linkedDraft
    preview.suggestions = linkedDraft.suggestions
    preview.courseID = item.course?.id
    preview.inboxID = item.id
    preview.area = item.area
    preview.input = item.title
    preview.start = now
  }
}

@MainActor func planningPreferences(_ profile: UserPlanningProfile?, area: String) -> SchedulingPreferences {
  var value = SchedulingPreferences()
  if let p = profile {
    value.startHour = p.startHour; value.endHour = p.endHour
    value.dailyMinutes = p.dailyMinutes; value.maxSessionMinutes = p.maxSessionMinutes
    value.breakMinutes = p.breakMinutes; value.preferredDays = p.preferredWeekdays
    if let start = p.preferredStartHour, let end = p.preferredEndHour {
      value.preferredWindows = [.init(startMinute: start * 60, endMinute: end * 60)]
    }
    value.lateEveningStartsMinute = p.lateEveningStartsHour.map { $0 * 60 }
    value.postTrainingRecoveryMinutes = p.trainingRecoveryMinutes > 0 ? p.trainingRecoveryMinutes : nil
  }
  return profile?.executionProfile.adapting(value, area: area) ?? value
}
