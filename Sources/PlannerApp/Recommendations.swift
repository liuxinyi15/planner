import Foundation
import PlannerCore

enum PlanningStyle: String, CaseIterable, Codable {
  case quiet = "Quiet"
  case balanced = "Balanced"
  case proactive = "Proactive"
}
enum RecommendationType: String, Codable {
  case startNow = "start_now"
  case prepareForCourse = "prepare_for_course"
  case reviewAfterCourse = "review_after_course"
  case recoverMissedSession = "recover_missed_session"
  case splitOverlongSession = "split_overlong_session"
  case deadlineRisk = "deadline_risk"
  case useFreeWindow = "use_free_window"
  case lightenToday = "lighten_today"
  case moveHighEnergyWork = "move_high_energy_work"
  case processInboxItem = "process_inbox_item"
}
enum RecommendationAction: String, Codable { case start, move, plan, review, inbox, tasks, courses }
enum RecommendationUrgency: Int, Codable { case low, normal, important, urgent }
struct Recommendation: Identifiable, Codable {
  var id: String
  var type: RecommendationType
  var title: String
  var reason: String
  var suggestedAction: String
  var action: RecommendationAction
  var entityID: UUID?
  var urgency: RecommendationUrgency
  var expiration: Date
  var visibleAfter: Date
  var notifyAfter: Date?
  var minimumStyle: PlanningStyle?
  var alternatives: [Date] = []
  func notificationEligible(style: PlanningStyle) -> Bool {
    guard let minimumStyle, notifyAfter != nil else { return false }
    let rank: [PlanningStyle: Int] = [.quiet: 0, .balanced: 1, .proactive: 2]
    return rank[style, default: 0] >= rank[minimumStyle, default: 3]
  }
}

/// Pure rules over observed state. Never calls the LLM or mutates a plan.
struct RecommendationEngine {
  func recommendations(
    situation s: CurrentSituation, execution: ExecutionProfile,
    patterns: [ExecutionAdaptation] = []
  ) -> [Recommendation] {
    let now = s.currentDate
    var calendar = Calendar.current
    calendar.timeZone = TimeZone(identifier: s.timezone) ?? .current
    let day = calendar.startOfDay(for: now)
    var result: [Recommendation] = []
    func add(
      _ type: RecommendationType, key: String, title: String, reason: String,
      action: RecommendationAction, label: String, entity: UUID? = nil,
      urgency: RecommendationUrgency = .normal, expires: Date,
      visible: Date? = nil, notify: Date? = nil, style: PlanningStyle? = nil,
      alternatives: [Date] = []
    ) {
      guard expires > now else { return }
      result.append(
        .init(
          id: type.rawValue + ":" + key, type: type, title: title,
          reason: reason, suggestedAction: label, action: action, entityID: entity,
          urgency: urgency, expiration: expires, visibleAfter: visible ?? now,
          notifyAfter: notify, minimumStyle: style, alternatives: alternatives))
    }
    func slots(minutes: Int, before: Date? = nil) -> [Date] {
      guard !s.truncated else { return [] }
      return s.freeWindows.compactMap { window in
        let start = max(now, window.start)
        return min(window.end, before ?? window.end).timeIntervalSince(start)
          >= Double(minutes * 60) ? start : nil
      }
    }
    for session in s.unfinishedSessions where session.startedAt == nil {
      let key = session.id.uuidString
      if let start = session.start, let end = session.end,
        start <= now.addingTimeInterval(86400), end > now,
        !s.truncated,
        !s.upcomingEvents.contains(where: {
          $0.useAsBusy && $0.start < end
            && $0.end.addingTimeInterval(Double($0.bufferMinutes * 60)) > max(start, now)
        }),
        !s.unfinishedSessions.contains(where: {
          $0.id != session.id && ($0.start ?? .distantFuture) < end
            && ($0.end ?? .distantPast) > max(start, now)
        })
      {
        add(
          .startNow, key: key + ":" + start.ISO8601Format(), title: session.title,
          reason:
            L(
              "Your planned \(session.minutes)-minute session starts at \(start.plannerFormatted(date: .omitted, time: .shortened))."
            ),
          action: .start, label: L("Start"), entity: session.id, urgency: .important,
          expires: min(end, start.addingTimeInterval(15 * 60)),
          visible: start.addingTimeInterval(-15 * 60),
          notify: max(now, start.addingTimeInterval(-5 * 60)), style: .quiet)
      }
      let cap =
        execution.accepted.first { $0.area == session.area && $0.kind == .shorterSessions }.map {
          Int($0.value)
        } ?? s.profile.maxSessionMinutes
      if session.minutes > cap {
        add(
          .splitOverlongSession, key: key, title: L("Make \(session.title) easier to start"),
          reason:
            L("This is \(session.minutes) minutes; your current session limit is \(cap) minutes."),
          action: .move, label: L("Review session"), entity: session.id,
          expires: now.addingTimeInterval(86400))
      }
      if session.start == nil, let slot = slots(minutes: session.minutes).first,
        slot <= now.addingTimeInterval(15 * 60), session.minutes <= cap
      {
        add(
          .useFreeWindow, key: key + ":" + day.ISO8601Format(),
          title: L("A window for \(session.title)"),
          reason:
            L("There is room for this \(session.minutes)-minute session in your available time."),
          action: .move, label: L("Schedule"), entity: session.id,
          expires: slot.addingTimeInterval(15 * 60),
          notify: slot, style: .proactive, alternatives: [slot])
      }
    }
    let missed =
      s.unfinishedSessions.filter { $0.startedAt == nil && ($0.end ?? .distantFuture) <= now }
      + s.recentlySkippedSessions
    for session in missed {
      let options = Array(slots(minutes: session.minutes).prefix(2))
      guard !options.isEmpty else { continue }
      add(
        .recoverMissedSession,
        key: session.id.uuidString + ":" + (session.start?.ISO8601Format() ?? "unscheduled"),
        title: L("Find a new time for \(session.title)"),
        reason: session.status == "skip"
          ? L("You skipped this session. These windows fit its duration.")
          : L("The planned time passed without completion. These windows fit its duration."),
        action: .move, label: L("Move"), entity: session.id, urgency: .important,
        expires: min(now.addingTimeInterval(86400), options[0].addingTimeInterval(15 * 60)),
        notify: now,
        style: .balanced, alternatives: options)
    }
    for course in s.upcomingCourseSessions
    where course.prepare && course.start > now && course.start <= now.addingTimeInterval(36 * 3600)
    {
      guard
        !s.unfinishedSessions.contains(where: {
          $0.courseID == course.courseID && ($0.start ?? .distantFuture) >= now
            && ($0.end ?? .distantFuture) <= course.start
        }),
        let gap = s.knowledgeGaps.first(where: { $0.courseID == course.courseID }),
        let slot = slots(minutes: 30, before: course.start).first
      else { continue }
      add(
        .prepareForCourse, key: course.eventID, title: L("Prepare for \(course.courseTitle)"),
        reason:
          L(
            "\(course.courseTitle) is at \(course.start.plannerFormatted(date: .abbreviated, time: .shortened)). \(gap.title) is marked \(L10n.label(gap.strength).lowercased())."
          ),
        action: .plan, label: L("Plan a 30-minute review"), entity: course.courseID,
        urgency: .important,
        expires: course.start, notify: max(now, slot.addingTimeInterval(-5 * 60)), style: .balanced,
        alternatives: [slot])
    }
    for course in s.recentCourseSessions
    where course.review && course.end <= now && course.end > now.addingTimeInterval(-86400) {
      add(
        .reviewAfterCourse, key: course.eventID, title: L("Review \(course.courseTitle)"),
        reason: L("This linked course session has finished. Capture what needs another look."),
        action: .plan, label: L("Plan a review"), entity: course.courseID,
        expires: course.end.addingTimeInterval(86400))
    }
    for deadline in s.deadlines where deadline.date <= now.addingTimeInterval(48 * 3600) {
      let urgent = deadline.date <= now.addingTimeInterval(6 * 3600)
      add(
        .deadlineRisk, key: deadline.id.uuidString + ":" + deadline.date.ISO8601Format(),
        title: L("Deadline: \(deadline.title)"),
        reason:
          L(
            "Due \(deadline.date.plannerFormatted(date: .abbreviated, time: .shortened)). Check that the remaining work has time allocated."
          ),
        action: deadline.kind == "course" ? .courses : (deadline.kind == "task" ? .tasks : .inbox),
        label: L("Review obligation"), entity: deadline.id, urgency: urgent ? .urgent : .important,
        expires: deadline.date.addingTimeInterval(86400),
        notify: max(now, deadline.date.addingTimeInterval(-86400)), style: .quiet)
    }
    if let load = s.workload.first, load.sessionMinutes > s.profile.dailyMinutes {
      add(
        .lightenToday, key: day.ISO8601Format(), title: L("Today exceeds your capacity"),
        reason:
          L(
            "\(load.sessionMinutes) planned minutes exceed your \(s.profile.dailyMinutes)-minute daily limit."
          ),
        action: .review, label: L("Review today"), urgency: .important,
        expires: day.addingTimeInterval(86400), notify: now, style: .proactive)
    }
    for pattern in execution.pending(patterns)
    where pattern.kind == .lowerEveningEnergy
      && pattern.sampleCount >= ExecutionLearning.minimumSamples
    {
      add(
        .moveHighEnergyWork, key: pattern.id, title: L("Try difficult work earlier"),
        reason: L10n.systemText(pattern.evidence), action: .review, label: L("Review adaptation"),
        urgency: .important,
        expires: now.addingTimeInterval(86400), notify: now, style: .balanced)
    }
    if let item = s.recentInbox.first {
      add(
        .processInboxItem, key: item.id.uuidString, title: L("Make \(item.title) actionable"),
        reason: L("This Inbox item has not yet become an executable next step."), action: .inbox,
        label: L("Open Inbox"), entity: item.id, urgency: .low,
        expires: now.addingTimeInterval(86400))
    }
    return result.sorted {
      if $0.urgency != $1.urgency { return $0.urgency.rawValue > $1.urgency.rawValue }
      if $0.expiration != $1.expiration { return $0.expiration < $1.expiration }
      return $0.id < $1.id
    }
  }
}

struct RecommendationNotificationHistory: Codable {
  var sent: [String: Date] = [:]
  var dismissedUntil: [String: Date] = [:]
  func visible(_ recommendations: [Recommendation], now: Date) -> [Recommendation] {
    recommendations.filter {
      $0.expiration > now && $0.visibleAfter <= now
        && (dismissedUntil[$0.id] ?? .distantPast) <= now
    }
  }
}
struct RecommendationNotificationPolicy {
  /// Cancel queued decisions whose useful window or eligibility changed. Delivery history
  /// remains separate; only cancelled reservations can be reconsidered.
  func invalidPendingIDs(
    _ pending: [String: Date], recommendations: [Recommendation],
    style: PlanningStyle, history: RecommendationNotificationHistory,
    now: Date
  ) -> [String] {
    pending.compactMap { id, delivery in
      guard let rec = recommendations.first(where: { $0.id == id }),
        rec.expiration > max(now, delivery), rec.notificationEligible(style: style),
        (history.dismissedUntil[id] ?? .distantPast) <= now, let due = rec.notifyAfter
      else { return id }
      // Account for the OS's one-second minimum trigger without rebuilding unchanged requests.
      return abs(max(now, due).timeIntervalSince(delivery)) > 60 ? id : nil
    }.sorted()
  }
  func select(
    _ recommendations: [Recommendation], style: PlanningStyle, enabled: Bool,
    authorized: Bool, history: RecommendationNotificationHistory, now: Date,
    calendar: Calendar = .current
  ) -> [(Recommendation, Date)] {
    guard enabled && authorized else { return [] }
    let cooldown: TimeInterval = style == .proactive ? 3600 : 3 * 3600
    let limit = style == .quiet ? 2 : (style == .balanced ? 3 : 5)
    var reserved = Array(history.sent.values)
    var selectedIDs = Set<String>()
    var result: [(Recommendation, Date)] = []
    for rec in recommendations {
      guard rec.expiration > now, rec.notificationEligible(style: style),
        history.sent[rec.id] == nil, !selectedIDs.contains(rec.id),
        (history.dismissedUntil[rec.id] ?? .distantPast) <= now, let due = rec.notifyAfter,
        rec.urgency != .low
      else { continue }
      let delivery = max(now, due)
      let hour = calendar.component(.hour, from: delivery)
      guard rec.minimumStyle == .quiet || (9..<21).contains(hour) else { continue }
      guard delivery < rec.expiration, delivery <= now.addingTimeInterval(86400),
        !reserved.contains(where: { abs($0.timeIntervalSince(delivery)) < cooldown }),
        reserved.filter({ calendar.isDate($0, inSameDayAs: delivery) }).count < limit
      else { continue }
      result.append((rec, delivery))
      reserved.append(delivery)
      selectedIDs.insert(rec.id)
    }
    return result
  }
}
