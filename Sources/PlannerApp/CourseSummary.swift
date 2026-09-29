import Foundation
import PlannerCore
import SwiftData

struct CourseAssessment: Codable, Identifiable, Equatable {
  var id = UUID()
  var title: String
  var deadline: Date?
  var notes = ""
  var completed = false
}
extension Course {
  var assessments: [CourseAssessment] {
    guard let assessmentData else { return [] }
    return (try? JSONDecoder().decode([CourseAssessment].self, from: assessmentData)) ?? []
  }
  func setAssessments(_ values: [CourseAssessment]) throws { assessmentData = try JSONEncoder().encode(values) }
}
struct CourseClass: Identifiable {
  var id: String
  var eventID: UUID
  var kind: String
  var start: Date
  var end: Date
  var location: String
}
struct CourseTimetablePattern: Identifiable {
  var id: String
  var kind: String
  var weekday: Int
  var minute: Int
  var count: Int
}
struct CourseNextAction {
  var title: String
  var reason: String
  var minutes: Int
  var sessionID: UUID?
  var before: Date?
}
struct CourseSummary {
  var classes: [CourseClass]
  var nextClass: CourseClass?
  var nextPractical: CourseClass?
  var patterns: [CourseTimetablePattern]
  var classesThisWeek: [String: Int]
  var studiesThisWeek: Int
  var pendingStudies: [Session]
  var plans: [Plan]
  var notes: [Note]
  var importedMaterial: [InboxItem]
  var assessments: [CourseAssessment]
  var focus: String
  var focusSource: String
  var gaps: [KnowledgeGap]
  var executionCount: Int
  var actualMinutes: Int
  var suggestedAction: CourseNextAction?
}

/// Local, read-only academic context. No AI request and no synthetic tasks or course mutations.
@MainActor enum CourseSummaryService {
  static func build(course: Course, events: [CalendarEvent], links: [CourseSession], sessions: [Session],
    plans: [Plan], notes: [Note], inbox: [InboxItem], gaps: [KnowledgeGap], records: [ExecutionRecord],
    now: Date = Date(), calendar: Calendar = .current) -> CourseSummary {
    let historyStart = calendar.date(byAdding: .day, value: -28, to: now)!
    let horizon = calendar.date(byAdding: .day, value: 84, to: now)!
    let courseLinks = links.filter { $0.course?.id == course.id && $0.event != nil }
    let expandedSources = Dictionary(grouping: events, by: CourseDiscoveryRepository.scope).mapValues {
      CalendarRepository.expand($0, range: historyStart..<horizon)
    }
    var classes: [CourseClass] = []
    var seen = Set<String>()
    for link in courseLinks {
      guard let event = link.event, !event.isDeleted else { continue }
      // Include source siblings so overrides/cancellations suppress their recurrence masters.
      let occurrences = (expandedSources[CourseDiscoveryRepository.scope(event)] ?? []).filter { $0.uid == event.remoteID }
      for occurrence in occurrences {
        let key = (event.source?.id.uuidString ?? "local") + occurrence.id + occurrence.start.ISO8601Format()
        guard seen.insert(key).inserted else { continue }
        classes.append(.init(id: key, eventID: event.id, kind: link.kind, start: occurrence.start,
          end: occurrence.end, location: occurrence.location))
      }
    }
    classes.sort { ($0.start, $0.id) < ($1.start, $1.id) }
    let upcoming = classes.filter { $0.end > now }
    var patterns: [String: CourseTimetablePattern] = [:]
    for value in upcoming {
      let day = calendar.component(.weekday, from: value.start)
      let minute = calendar.component(.hour, from: value.start) * 60 + calendar.component(.minute, from: value.start)
      let key = "\(value.kind):\(day):\(minute)"
      var pattern = patterns[key] ?? .init(id: key, kind: value.kind, weekday: day, minute: minute, count: 0)
      pattern.count += 1
      patterns[key] = pattern
    }
    let startOfDay = calendar.startOfDay(for: now)
    let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: now) + 5) % 7), to: startOfDay)!
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: monday)!
    let thisWeek = classes.filter { $0.start >= monday && $0.start < weekEnd }
    let studies = sessions.filter { $0.course?.id == course.id || $0.plan?.course?.id == course.id }
    let pending = studies.filter { !["complete", "skip", "abandoned"].contains($0.status) }.sorted {
      ($0.start ?? .distantFuture, $0.id.uuidString) < ($1.start ?? .distantFuture, $1.id.uuidString)
    }
    let relatedPlanIDs = Set(studies.compactMap { $0.plan?.id })
    let relatedPlans = plans.filter { $0.course?.id == course.id || relatedPlanIDs.contains($0.id) }.sorted { $0.created > $1.created }
    let material = inbox.filter { $0.course?.id == course.id && $0.status != "archived" }.sorted { $0.created > $1.created }
    let unresolved = gaps.filter { $0.course?.id == course.id && $0.strength != "Strong" }.sorted { $0.title < $1.title }
    var assessments = course.assessments.filter { !$0.completed }
    if !course.assessment.isEmpty || course.deadline != nil {
      assessments.append(.init(id: course.id, title: course.assessment.isEmpty ? L("Course deadline") : course.assessment, deadline: course.deadline))
    }
    assessments += relatedPlans.filter { $0.deadline != nil }.map { .init(id: $0.id, title: $0.title, deadline: $0.deadline) }
    assessments += material.filter { $0.deadline != nil }.map { .init(id: $0.id, title: $0.title, deadline: $0.deadline) }
    assessments.sort { ($0.deadline ?? .distantFuture, $0.title) < ($1.deadline ?? .distantFuture, $1.title) }
    let focus: String
    let focusSource: String
    if !course.currentFocus.isEmpty { focus = course.currentFocus; focusSource = L("Your current focus") }
    else if !course.topic.isEmpty { focus = course.topic; focusSource = L("Previously saved topic") }
    else if let session = pending.first ?? studies.sorted(by: { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }).first {
      focus = session.title; focusSource = L("From linked study sessions")
    } else if let imported = material.compactMap({ item -> IntakeDocument? in
      guard let data = item.intakeData else { return nil }
      return try? IntakeDocument.decode(String(decoding: data, as: UTF8.self))
    }).first, let title = imported.sessions.first?.title {
      focus = title; focusSource = L("From imported study material")
    } else { focus = ""; focusSource = "" }
    let sessionIDs = Set(studies.map(\.id))
    let execution = records.filter { $0.courseID == course.id || sessionIDs.contains($0.sessionID) }
    let next = upcoming.first
    let action: CourseNextAction?
    if let study = pending.first {
      action = .init(title: study.title, reason: L("Continue the work already linked to this course."), minutes: study.minutes, sessionID: study.id,
        before: study.plan?.deadline)
    } else if let gap = unresolved.first {
      action = .init(title: L("Review: \(gap.title)"), reason: L("This topic still needs attention."), minutes: 40,
        before: assessments.compactMap(\.deadline).first(where: { $0 > now }))
    } else if let next {
      action = .init(title: L("Prepare for \(course.title)"), reason: L("Review your notes before the next class."), minutes: 30, before: next.start)
    } else { action = nil }
    return .init(classes: classes, nextClass: next, nextPractical: upcoming.first { ["tutorial", "lab"].contains($0.kind) },
      patterns: patterns.values.sorted { (($0.weekday + 5) % 7, $0.minute, $0.kind) < (($1.weekday + 5) % 7, $1.minute, $1.kind) },
      classesThisWeek: Dictionary(grouping: thisWeek, by: \.kind).mapValues(\.count),
      studiesThisWeek: studies.filter { $0.start.map { $0 >= monday && $0 < weekEnd } ?? false }.count,
      pendingStudies: pending, plans: relatedPlans,
      notes: notes.filter { $0.course?.id == course.id || $0.plan?.course?.id == course.id }.sorted { $0.updated > $1.updated },
      importedMaterial: material, assessments: assessments, focus: focus, focusSource: focusSource, gaps: unresolved,
      executionCount: execution.count, actualMinutes: execution.reduce(0) { $0 + $1.actual }, suggestedAction: action)
  }

  static func suggestedStart(action: CourseNextAction, course: Course, context: ModelContext, now: Date = Date()) throws -> Date {
    let situation = try CurrentSituationBuilder(context: context).build(now: now, days: 28)
    guard !situation.truncated else { throw PlanningError.invalid("Calendar context is incomplete. Reduce the planning scope before arranging.") }
    let events = try context.fetch(FetchDescriptor<CalendarEvent>())
    let sessions = try context.fetch(FetchDescriptor<Session>())
    let profile = try context.fetch(FetchDescriptor<UserPlanningProfile>()).first
    let preferences = planningPreferences(profile, area: "Study")
    let padding = Double(max(preferences.breakMinutes, events.map(\.bufferMinutes).max() ?? 0, sessions.map(\.bufferMinutes).max() ?? 0)) * 60
    let busy = CalendarRepository.expand(events, range: now.addingTimeInterval(-padding)..<now.addingTimeInterval(28 * 86400 + padding), busyOnly: true).map { value in
      BusyInterval(start: value.start, end: value.end,
        bufferMinutes: events.filter { $0.remoteID == value.uid }.map(\.bufferMinutes).max() ?? 0, location: value.location)
    } + sessions.filter { $0.id != action.sessionID && !["skip", "abandoned"].contains($0.status) }.compactMap { session -> BusyInterval? in
      guard let start = session.start, let end = session.end else { return nil }
      return .init(start: start, end: end, bufferMinutes: session.bufferMinutes, location: session.location,
        kind: session.area == "Training" ? .training : .focus, courseID: session.course?.id)
    }
    var draft = SessionDraft(title: action.title, purpose: action.reason, duration_minutes: action.minutes)
    draft.scheduling = .init(courseID: course.id)
    let proposed = Scheduler().suggest([draft], busy: busy, from: now, deadline: action.before, preferences: preferences).first
    guard let start = proposed?.start else { throw PlanningError.invalid("No available time fits this study suggestion. Adjust its duration or your availability.") }
    return start
  }
}
