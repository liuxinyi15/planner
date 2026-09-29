import Foundation

public enum BusyKind: String, Sendable { case commitment, focus, training }
public struct BusyInterval: Sendable {
  public var start: Date
  public var end: Date
  public var contentStart: Date
  public var contentEnd: Date
  public var bufferMinutes: Int
  public var location: String
  public var kind: BusyKind
  public var courseID: UUID?
  public init(
    start: Date, end: Date, bufferMinutes: Int = 0, location: String = "",
    kind: BusyKind = .commitment, courseID: UUID? = nil
  ) {
    contentStart = start
    contentEnd = end
    self.bufferMinutes = max(0, bufferMinutes)
    self.start = start.addingTimeInterval(-Double(max(0, bufferMinutes)) * 60)
    self.end = end.addingTimeInterval(Double(max(0, bufferMinutes)) * 60)
    self.location = location
    self.kind = kind
    self.courseID = courseID
  }
}
public struct SchedulingPreferences: Sendable {
  public var startHour = 9
  public var endHour = 21
  public var dailyMinutes = 240
  public var maxSessionMinutes = 120
  public var breakMinutes = 15
  public var availabilityWindows: [PlanningTimeWindow] = []
  public var preferredWindows: [PlanningTimeWindow] = []
  public var preferredDays: [Int] = []
  public var energyWindows: [EnergyWindow] = []
  public var lateEveningStartsMinute: Int?
  public var postTrainingRecoveryMinutes: Int?
  public var travelTimes: [TravelTime] = []
  public var historicalSuccess: [HistoricalSuccessWindow] = []
  public var weights = SchedulingWeights()
  public var policy = SchedulingPolicy()
  public init() {}
}
public struct ScheduledSuggestion: Identifiable, Sendable {
  public let id: Int
  public let session: SessionDraft
  public var start: Date?
  public var warning: String?
  public var reasons: [SchedulingReason] = []
  public var alternatives: [SchedulingCandidate] = []
  public var score: Double?
  public var end: Date? { start?.addingTimeInterval(Double(session.duration_minutes * 60)) }
}
public struct Scheduler {
  public init() {}
  /// Compatibility entry point; both this API and draft scheduling use the same ranked engine.
  public func suggest(
    _ sessions: [SessionDraft], busy: [BusyInterval], from: Date, deadline: Date? = nil,
    preferences: SchedulingPreferences = .init(), constraints: [PlanningConstraint] = [],
    calendar: Calendar = .current
  ) -> [ScheduledSuggestion] {
    let boundary = min(
      deadline ?? .distantFuture,
      calendar.date(
        byAdding: .day, value: max(1, min(28, preferences.policy.horizonDays)), to: from)!)
    var occupied = busy
    var results: [ScheduledSuggestion] = []
    for (index, session) in sessions.enumerated() {
      var result = ScheduledSuggestion(id: index, session: session, start: nil, warning: nil)
      guard session.dependencies.allSatisfy({ $0 >= 0 && $0 < index && results[$0].end != nil })
      else {
        result.warning = "A prerequisite has no available slot."
        result.reasons = [.init(.dependency, result.warning!)]
        results.append(result)
        continue
      }
      let task = SchedulingTask(session)
      let earliest = max(from, session.dependencies.compactMap { results[$0].end }.max() ?? from)
      let evaluation = rank(
        task, busy: occupied, from: earliest, deadline: boundary,
        preferences: preferences, constraints: constraints, calendar: calendar)
      result.start = evaluation.selected?.start
      result.score = evaluation.selected?.score
      result.reasons = evaluation.selected?.reasons ?? evaluation.reasons
      result.alternatives = evaluation.alternatives
      if let candidate = evaluation.selected {
        occupied.append(
          .init(
            start: candidate.start, end: candidate.end, bufferMinutes: task.bufferMinutes,
            location: task.location, kind: .focus, courseID: task.courseID))
      } else {
        result.warning = evaluation.reasons.map(\.detail).joined(separator: " ")
      }
      results.append(result)
    }
    return results
  }
  public static func conflicts(start: Date, end: Date, busy: [BusyInterval]) -> Bool {
    busy.contains { start < $0.end && end > $0.start }
  }
}
public struct ExecutionSample: Sendable {
  public let estimated: Int
  public let actual: Int
  public let status: String
  public let area: String
  public let date: Date
  public init(estimated: Int, actual: Int, status: String, area: String, date: Date) {
    self.estimated = estimated
    self.actual = actual
    self.status = status
    self.area = area
    self.date = date
  }
}
public struct ExecutionAnalytics {
  public let samples: [ExecutionSample]
  public init(samples: [ExecutionSample]) { self.samples = samples }
  public var completed: Int { samples.filter { $0.status == "complete" }.count }
  public var executionRate: Double {
    samples.isEmpty ? 0 : Double(completed) / Double(samples.count)
  }
  public var estimationBias: Double? {
    let finished = samples.filter { $0.status == "complete" && $0.actual > 0 }
    let estimated = finished.reduce(0) { $0 + $1.estimated }
    return estimated == 0
      ? nil : Double(finished.reduce(0) { $0 + $1.actual } - estimated) / Double(estimated)
  }
  public var allocation: [String: Int] {
    Dictionary(grouping: samples, by: \.area).mapValues { $0.reduce(0) { $0 + $1.actual } }
  }
}
