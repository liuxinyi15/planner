import Foundation
import PlannerCore
import SwiftData

@MainActor struct CurrentSituationBuilder {
  let context: ModelContext
  var calendar: Calendar = .current
  /// Each fetch is bounded. If safety limits are reached availability is unknown, never guessed free.
  var fetchLimit = 500

  func build(now: Date = Date(), days: Int = 7) throws -> CurrentSituation {
    let start = calendar.startOfDay(for: now)
    let end = calendar.date(byAdding: .day, value: min(28, max(1, days)), to: start)!
    let history = calendar.date(byAdding: .day, value: -7, to: now)!
    var truncated = false
    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
      var query = descriptor
      query.fetchLimit = fetchLimit + 1
      let values = try context.fetch(query)
      if values.count > fetchLimit { truncated = true }
      return Array(values.prefix(fetchLimit))
    }
    var profileQuery = FetchDescriptor<UserPlanningProfile>()
    profileQuery.fetchLimit = 1
    let savedProfile = try context.fetch(profileQuery).first
    let profile =
      savedProfile.map {
        SituationProfile(
          startHour: $0.startHour, endHour: $0.endHour, dailyMinutes: $0.dailyMinutes,
          maxSessionMinutes: $0.maxSessionMinutes, breakMinutes: $0.breakMinutes,
          acceptedExecutionInstructions: $0.executionProfile.planningInstructions)
      } ?? SituationProfile()
    // Fetch only maxima so even long commitments/buffers crossing the horizon constrain gaps.
    var eventBufferQuery = FetchDescriptor<CalendarEvent>(sortBy: [
      SortDescriptor(\.bufferMinutes, order: .reverse)
    ])
    eventBufferQuery.fetchLimit = 1
    var sessionBufferQuery = FetchDescriptor<Session>(sortBy: [
      SortDescriptor(\.bufferMinutes, order: .reverse)
    ])
    sessionBufferQuery.fetchLimit = 1
    var durationQuery = FetchDescriptor<Session>(sortBy: [
      SortDescriptor(\.minutes, order: .reverse)
    ])
    durationQuery.fetchLimit = 1
    let eventBuffer = max(0, try context.fetch(eventBufferQuery).first?.bufferMinutes ?? 0)
    let sessionBuffer = max(
      max(0, profile.breakMinutes), try context.fetch(sessionBufferQuery).first?.bufferMinutes ?? 0)
    let duration = max(0, try context.fetch(durationQuery).first?.minutes ?? 0)
    let padding = Double(max(eventBuffer, sessionBuffer)) * 60
    let paddedStart = start.addingTimeInterval(-max(padding, 86400))
    let paddedEnd = end.addingTimeInterval(padding)
    let sessionLowerBound = min(history, paddedStart.addingTimeInterval(-Double(duration) * 60))
    // Old recurrence masters must be fetched to expand occurrences in the requested range.
    let masters = try fetch(
      FetchDescriptor<CalendarEvent>(
        predicate: #Predicate { event in
          event.start < paddedEnd && (event.end > paddedStart || event.rule != nil)
        }, sortBy: [SortDescriptor(\.start)]))
    var occurrences: [SituationEvent] = []
    let parser = ICSParser()
    for event in masters {
      let imported = ImportedEvent(
        uid: event.remoteID, title: event.title, start: event.start, end: event.end,
        location: event.location, rule: event.rule, recurrenceID: event.recurrenceID,
        excluded: event.excluded, allDay: event.allDay, cancelled: event.cancelled,
        timeZoneID: event.timeZoneID)
      let expanded = parser.occurrences(
        imported, in: paddedStart..<paddedEnd, limit: fetchLimit + 1)
      if expanded.count > fetchLimit { truncated = true }
      for occurrence in expanded.prefix(fetchLimit) {
        let overridden =
          event.recurrenceID == nil
          && masters.contains { other in
            other.source?.id == event.source?.id
              && other.remoteID.components(separatedBy: "|").first
                == event.remoteID.components(separatedBy: "|").first
              && other.recurrenceID != nil && other.recurrenceID == occurrence.recurrenceID
          }
        guard !overridden else { continue }
        occurrences.append(
          SituationEvent(
            id: event.id.uuidString + ":" + occurrence.start.ISO8601Format(), eventID: event.id,
            title: occurrence.title, start: occurrence.start, end: occurrence.end,
            location: occurrence.location, allDay: occurrence.allDay,
            visible: event.source?.visible ?? true, useAsBusy: event.source?.useAsBusy ?? true,
            allowAI: event.source?.allowAI == true, bufferMinutes: max(0, event.bufferMinutes)))
      }
    }
    if occurrences.count > fetchLimit {
      truncated = true
      occurrences = Array(occurrences.prefix(fetchLimit))
    }
    let upcoming = occurrences.filter { $0.start < end && $0.end > now }.sorted {
      $0.start < $1.start
    }
    let scheduled = try fetch(
      FetchDescriptor<Session>(
        predicate: #Predicate { session in
          session.start != nil && (session.start ?? sessionLowerBound) >= sessionLowerBound
            && (session.start ?? paddedEnd) < paddedEnd
        }, sortBy: [SortDescriptor(\.start)]))
    let records = try fetch(
      FetchDescriptor<ExecutionRecord>(
        predicate: #Predicate { record in
          record.date >= history && record.date <= now && (record.status == "postponed" || record.status == "skip")
        }, sortBy: [SortDescriptor(\.date, order: .reverse)]))
    var relevantSessions = scheduled.filter {
      ($0.start ?? .distantFuture) < end && ($0.end ?? .distantPast) >= history
    }
    // A recent postponement is a deterministic relevance signal even when it moved beyond the horizon.
    for id in Set(records.map(\.sessionID)) where !relevantSessions.contains(where: { $0.id == id })
    {
      if let session = try fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == id }))
        .first
      {
        relevantSessions.append(session)
      }
    }
    let recentPlans = try fetch(
      FetchDescriptor<Plan>(
        predicate: #Predicate { $0.created >= history && $0.created <= now },
        sortBy: [SortDescriptor(\.created, order: .reverse)]))
    if recentPlans.count > 30 { truncated = true }
    for plan in recentPlans.prefix(30) {
      if relevantSessions.count >= fetchLimit {
        truncated = true
        break
      }
      let id = plan.id
      let unscheduled = try fetch(
        FetchDescriptor<Session>(
          predicate: #Predicate {
            $0.plan?.id == id && $0.start == nil
              && ($0.status == "planned" || $0.status == "partial")
          }))
      for session in unscheduled where !relevantSessions.contains(where: { $0.id == session.id }) {
        relevantSessions.append(session)
      }
    }
    let unscheduledSessions = try fetch(FetchDescriptor<Session>(predicate: #Predicate {
      $0.start == nil && ($0.status == "planned" || $0.status == "partial")
    }))
    for session in unscheduledSessions where !relevantSessions.contains(where: { $0.id == session.id }) {
      relevantSessions.append(session)
    }
    if relevantSessions.count > fetchLimit {
      truncated = true
      relevantSessions = Array(relevantSessions.prefix(fetchLimit))
    }
    let unfinished = relevantSessions.filter { $0.status == "planned" || $0.status == "partial" }
      .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    let tasks = try fetch(
      FetchDescriptor<PlannerTask>(
        predicate: #Predicate { task in
          !task.done && task.deadline != nil && (task.deadline ?? history) >= history
            && (task.deadline ?? end) < end
        }, sortBy: [SortDescriptor(\.deadline)]))
    let inbox = try fetch(
      FetchDescriptor<InboxItem>(
        predicate: #Predicate { item in
          item.status == "unprocessed" && item.created >= history && item.created <= now
        }, sortBy: [SortDescriptor(\.created, order: .reverse)]))
    let inboxDeadlines = try fetch(
      FetchDescriptor<InboxItem>(
        predicate: #Predicate { item in
          item.status != "archived" && item.status != "processed" && item.deadline != nil
            && (item.deadline ?? history) >= history && (item.deadline ?? end) < end
        }, sortBy: [SortDescriptor(\.deadline)]))
    let deadlineCourses = try fetch(
      FetchDescriptor<Course>(
        predicate: #Predicate { course in
          course.deadline != nil && (course.deadline ?? history) >= history
            && (course.deadline ?? end) < end
        }, sortBy: [SortDescriptor(\.deadline)]))
    var courseSessions: [SituationCourseSession] = []
    let courseOccurrences = occurrences.filter { $0.end > now.addingTimeInterval(-86400) && $0.start < end }
    for eventID in Set(courseOccurrences.map(\.eventID)).sorted(by: { $0.uuidString < $1.uuidString }) {
      if courseSessions.count >= fetchLimit {
        truncated = true
        break
      }
      let links = try fetch(
        FetchDescriptor<CourseSession>(predicate: #Predicate { $0.event?.id == eventID }))
      for link in links {
        guard let course = link.course else { continue }
        for occurrence in courseOccurrences where occurrence.eventID == eventID {
          courseSessions.append(
            .init(
              prepare: occurrence.visible && (link.event?.source?.prepare ?? false), review: occurrence.visible && (link.event?.source?.review ?? false),
              eventID: occurrence.id, courseID: course.id, courseTitle: course.title,
              kind: link.kind, topic: link.topic, start: occurrence.start, end: occurrence.end,
              allowAI: occurrence.allowAI))
        }
      }
    }
    if courseSessions.count > fetchLimit {
      truncated = true
      courseSessions = Array(courseSessions.prefix(fetchLimit))
    }
    var deadlines = tasks.map {
      SituationDeadline(id: $0.id, title: $0.title, date: $0.deadline!, kind: "task", allowAI: true)
    }
    deadlines += inboxDeadlines.map {
      SituationDeadline(
        id: $0.id, title: $0.title, date: $0.deadline!, kind: "inbox", allowAI: true)
    }
    deadlines += deadlineCourses.map {
      SituationDeadline(
        id: $0.id, title: $0.title, date: $0.deadline!, kind: "course", allowAI: true)
    }
    let courseIDs = Set(
      courseSessions.map(\.courseID) + unfinished.compactMap { $0.course?.id }
        + deadlineCourses.map(\.id))
    var gaps: [SituationGap] = []
    for courseID in courseIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      if gaps.count >= fetchLimit {
        truncated = true
        break
      }
      let matching = try fetch(
        FetchDescriptor<KnowledgeGap>(
          predicate: #Predicate { $0.course?.id == courseID && $0.strength != "Strong" }))
      gaps += matching.map {
        SituationGap(id: $0.id, courseID: courseID, title: $0.title, strength: $0.strength)
      }
    }
    if gaps.count > fetchLimit {
      truncated = true
      gaps = Array(gaps.prefix(fetchLimit))
    }
    var plans: [SituationPlan] = []
    var seen = Set<UUID>()
    for session in unfinished {
      if let plan = session.plan, seen.insert(plan.id).inserted {
        plans.append(
          .init(id: plan.id, title: plan.title, purpose: plan.purpose, priority: plan.priority))
      }
    }
    let eventBusy = occurrences.filter(\.useAsBusy).map {
      BusyInterval(start: $0.start, end: $0.end, bufferMinutes: $0.bufferMinutes)
    }
    let sessionBusy = scheduled.filter { !["skip", "abandoned"].contains($0.status) }.compactMap { s -> BusyInterval? in
      guard let start = s.start, let end = s.end else { return nil }
      return BusyInterval(
        start: start, end: end, bufferMinutes: max(max(0, profile.breakMinutes), s.bufferMinutes))
    }
    let free =
      truncated
      ? []
      : AvailabilityWindows.find(
        in: now..<end, busy: eventBusy + sessionBusy, startHour: profile.startHour,
        endHour: profile.endHour, calendar: calendar)
    var workload: [SituationWorkload] = []
    var day = start
    func overlap(_ a: Date, _ b: Date, _ lower: Date, _ upper: Date) -> Int {
      max(0, Int(min(b, upper).timeIntervalSince(max(a, lower)) / 60))
    }
    while day < end {
      let next = calendar.date(byAdding: .day, value: 1, to: day)!
      workload.append(
        .init(
          day: day,
          fixedMinutes: occurrences.filter(\.useAsBusy).reduce(0) {
            $0 + overlap($1.start, $1.end, day, next)
          },
          sessionMinutes: scheduled.filter { !["skip", "abandoned"].contains($0.status) }.reduce(0) {
            $0 + overlap($1.start!, $1.end!, day, next)
          }, freeMinutes: free.reduce(0) { $0 + overlap($1.start, $1.end, day, next) }))
      day = next
    }
    return CurrentSituation(
      currentDate: now, range: now..<end, historyStart: history,
      timezone: calendar.timeZone.identifier,
      upcomingEvents: upcoming,
      upcomingCourseSessions: courseSessions.filter { $0.end > now }.sorted { $0.start < $1.start },
      deadlines: deadlines.sorted { $0.date < $1.date },
      unfinishedSessions: unfinished.map(snapshot),
      overdueTasks: tasks.filter { $0.deadline! < now }.map {
        .init(id: $0.id, title: $0.title, deadline: $0.deadline!)
      },
      recentlyPostponedSessions: unfinished.filter { session in
        records.contains { $0.sessionID == session.id && $0.status == "postponed" }
      }.map(snapshot), activePlans: plans, freeWindows: free,
      recentInbox: inbox.map {
        .init(id: $0.id, title: $0.title, area: $0.area, created: $0.created)
      }, knowledgeGaps: gaps, workload: workload, profile: profile, truncated: truncated,
      recentlySkippedSessions: relevantSessions.filter { session in
        session.status == "skip" && records.contains { $0.sessionID == session.id && $0.status == "skip" }
      }.map(snapshot),
      recentCourseSessions: courseSessions.filter { $0.end <= now }.sorted { $0.end > $1.end })
  }
  private func snapshot(_ session: Session) -> SituationSession {
    .init(
      id: session.id, title: session.title, purpose: session.purpose,
      definitionOfDone: session.definitionOfDone, minutes: session.minutes, start: session.start,
      status: session.status, area: session.area, startedAt: session.startedAt,
      planID: session.plan?.id, courseID: session.course?.id ?? session.plan?.course?.id,
      actions: session.actions.map { .init(id: $0.id, title: $0.title, completed: $0.completed) })
  }
}
