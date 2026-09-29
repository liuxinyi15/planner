import Foundation
import PlannerCore
import SwiftData

@MainActor enum CourseDiscoveryRepository {
  static func candidates(events: [CalendarEvent], courses: [Course], ignored: [String], now: Date = Date()) -> [DetectedCourseCandidate] {
    let end = Calendar.current.date(byAdding: .day, value: 84, to: now)!
    let visible = events.filter { !$0.isDeleted && !$0.cancelled && $0.source?.visible != false }
    let expanded = Dictionary(grouping: events.filter { !$0.isDeleted && $0.source?.visible != false }, by: scope)
      .mapValues { CalendarRepository.expand($0, range: now..<end) }
    let inputs = visible.map { event in
      TimetableCourseEvent(id: event.id, sourceID: event.source?.id, title: event.title,
        upcomingCount: (expanded[scope(event)] ?? []).filter { $0.uid == event.remoteID }.count)
    }
    return CourseDetectionService.group(inputs).filter { candidate in
      guard !ignored.contains(candidate.id) else { return false }
      let scopes = Set(visible.filter { candidate.eventIDs.contains($0.id) }.map(scope))
      return !courses.contains { $0.timetableKey == candidate.id && scopes.isSubset(of: Set($0.timetableSourceIDs)) }
    }
  }

  @discardableResult static func accept(_ keys: Set<String>, context: ModelContext) throws -> [Course] {
    let events = try context.fetch(FetchDescriptor<CalendarEvent>())
    var courses = try context.fetch(FetchDescriptor<Course>())
    let profile = try context.fetch(FetchDescriptor<UserPlanningProfile>()).first
    let available = candidates(events: events, courses: courses, ignored: profile?.ignoredCourseKeys ?? [])
    var accepted: [Course] = []
    do {
      for candidate in available where keys.contains(candidate.id) {
        let matches = courses.filter {
          if !$0.moduleCode.isEmpty { return $0.moduleCode == candidate.moduleCode }
          return CourseDetectionService.normalizedName($0.title) == CourseDetectionService.normalizedName(candidate.name)
        }
        guard matches.count <= 1 else { throw PlanningError.invalid("More than one saved course matches this module. Resolve duplicate courses before accepting.") }
        let course: Course
        if let existing = matches.first { course = existing }
        else {
          course = Course(candidate.name)
          course.createdAutomatically = true
          context.insert(course)
          courses.append(course)
        }
        course.moduleCode = candidate.moduleCode ?? ""
        course.detectedFrom = "timetable"
        course.timetableKey = candidate.id
        let matching = events.filter { candidate.eventIDs.contains($0.id) }
        course.timetableSourceIDs = Array(Set(course.timetableSourceIDs + matching.map(scope))).sorted()
        accepted.append(course)
      }
      try reconcile(context: context)
      try context.save()
    } catch { context.rollback(); throw error }
    return accepted
  }
  static func ignore(_ key: String, context: ModelContext) throws {
    let profile = try context.fetch(FetchDescriptor<UserPlanningProfile>()).first ?? UserPlanningProfile()
    if profile.modelContext == nil { context.insert(profile) }
    if !profile.ignoredCourseKeys.contains(key) { profile.ignoredCourseKeys.append(key) }
    do { try context.save() } catch { context.rollback(); throw error }
  }
  /// Called inside the import/refresh transaction. Only accepted identities and source scopes auto-link.
  static func reconcile(context: ModelContext) throws {
    let courses = try context.fetch(FetchDescriptor<Course>()).filter { !$0.timetableKey.isEmpty }
    guard !courses.isEmpty else { return }
    let events = try context.fetch(FetchDescriptor<CalendarEvent>()).filter { !$0.isDeleted }
    let links = try context.fetch(FetchDescriptor<CourseSession>())
    func eligible(_ event: CalendarEvent, _ course: Course) -> Bool {
      guard !event.isDeleted, !event.cancelled, course.timetableSourceIDs.contains(scope(event)),
        let parsed = CourseDetectionService.parse(event.title) else { return false }
      return parsed.key == course.timetableKey
    }
    var pairs = Set<String>()
    for link in links {
      guard let course = link.course, let event = link.event else {
        if link.detectedAutomatically { context.delete(link) }
        continue
      }
      if link.detectedAutomatically && !eligible(event, course) { context.delete(link); continue }
      if link.detectedAutomatically, let parsed = CourseDetectionService.parse(event.title) { link.kind = parsed.sessionType }
      pairs.insert(course.id.uuidString + event.id.uuidString)
    }
    for event in events {
      // Ambiguous duplicate accepted courses are left for user review, never linked twice.
      let matches = courses.filter { eligible(event, $0) }
      guard matches.count == 1, let course = matches.first,
        let parsed = CourseDetectionService.parse(event.title) else { continue }
      let key = course.id.uuidString + event.id.uuidString
      guard !pairs.contains(key), !links.contains(where: { !$0.isDeleted && $0.event?.id == event.id && $0.course?.id != course.id }) else { continue }
      let link = CourseSession(course: course, event: event, kind: parsed.sessionType)
      link.detectedAutomatically = true
      context.insert(link)
      pairs.insert(key)
    }
  }
  static func scope(_ event: CalendarEvent) -> String { event.source?.id.uuidString ?? "local" }
}
