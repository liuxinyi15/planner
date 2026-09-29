import Foundation

public enum ExecutionOutcome: String, Codable, CaseIterable, Sendable {
  case completed = "complete", partiallyCompleted = "partial", postponed, skipped = "skip", abandoned
}
public enum ExecutionReason: String, Codable, CaseIterable, Sendable {
  case noTime = "no time", tooTired = "too tired", tooLong = "too long"
  case unclearStart = "unclear how to start", priorityChanged = "priority changed"
  case conflict = "unexpected conflict", unimportant = "not important anymore", other
}
public struct ExecutionObservation: Sendable {
  public var sessionID: UUID
  public var date: Date
  public var scheduledStart: Date?
  public var localHour: Int?
  public var estimated: Int
  public var actual: Int
  public var outcome: ExecutionOutcome
  public var area: String
  public var energy: String
  public var reason: ExecutionReason?
  public init(sessionID: UUID = UUID(), date: Date = Date(), scheduledStart: Date? = nil,
              localHour: Int? = nil, estimated: Int, actual: Int, outcome: ExecutionOutcome,
              area: String, energy: String = "unknown", reason: ExecutionReason? = nil) {
    self.sessionID = sessionID; self.date = date; self.scheduledStart = scheduledStart
    self.localHour = localHour; self.estimated = estimated; self.actual = actual
    self.outcome = outcome; self.area = area; self.energy = energy; self.reason = reason
  }
  public var durationBucket: String {
    switch estimated { case ..<30: return "<30m"; case 30...50: return "30–50m"
    case 51..<90: return "51–89m"; default: return "90+m" }
  }
  public var timeBucket: String {
    guard let hour = localHour else { return "unknown" }
    switch hour { case 6..<12: return "morning"; case 12..<18: return "afternoon"
    case 18..<21: return "evening"; default: return "late night" }
  }
}
public struct ExecutionRate: Sendable {
  public var count: Int
  public var completed: Int
  public var rate: Double { Double(completed) / Double(max(1, count)) }
}
public struct ExecutionAdaptation: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case shorterSessions, durationBias, concreteStart, lowerEveningEnergy }
  public var kind: Kind
  public var area: String
  public var value: Double
  public var evidence: String
  public var proposal: String
  public var sampleCount: Int
  public var id: String { kind.rawValue + ":" + area }
  public init(kind: Kind, area: String, value: Double, evidence: String, proposal: String, sampleCount: Int) {
    self.kind = kind; self.area = area; self.value = value; self.evidence = evidence
    self.proposal = proposal; self.sampleCount = sampleCount
  }
}
/// Accepted adaptations are separate from explicit settings and derived observations.
public struct ExecutionProfile: Codable, Equatable, Sendable {
  public var accepted: [ExecutionAdaptation] = []
  public var ignored: [String] = []
  public init() {}
  public mutating func apply(_ suggestion: ExecutionAdaptation) {
    accepted.removeAll { $0.id == suggestion.id }; accepted.append(suggestion)
    ignored.removeAll { $0 == suggestion.id }
  }
  public mutating func ignore(_ suggestion: ExecutionAdaptation) {
    if !ignored.contains(suggestion.id) { ignored.append(suggestion.id) }
  }
  public func pending(_ suggestions: [ExecutionAdaptation]) -> [ExecutionAdaptation] {
    suggestions.filter { s in !ignored.contains(s.id) && !accepted.contains { $0.id == s.id } }
  }
}
public struct ExecutionLearning {
  public static let minimumSamples = 5
  public let observations: [ExecutionObservation]
  public init(_ observations: [ExecutionObservation]) { self.observations = observations }
  /// One latest outcome per distinct session avoids treating repeated postponements as independent failures.
  public var sessions: [ExecutionObservation] {
    Dictionary(grouping: observations, by: \.sessionID).values.compactMap { $0.max { $0.date < $1.date } }
  }
  public func rates(by key: KeyPath<ExecutionObservation, String>) -> [String: ExecutionRate] {
    Dictionary(grouping: sessions, by: { $0[keyPath: key] }).mapValues {
      .init(count: $0.count, completed: $0.filter { $0.outcome == .completed }.count)
    }
  }
  public var postponementFrequency: Double {
    Double(observations.filter { $0.outcome == .postponed }.count) / Double(max(1, sessions.count))
  }
  public func reasonCount(_ reason: ExecutionReason, area: String) -> Int {
    Set(observations.filter { $0.area == area && $0.reason == reason }.map(\.sessionID)).count
  }
  public func durationBias(area: String) -> Double? {
    let finished = sessions.filter { $0.area == area && $0.outcome == .completed && $0.estimated > 0 }
    // Sum partial attempts, but never add postponed/skipped minutes to productive duration.
    let pairs = finished.compactMap { last -> (Int, Int)? in
      let attempts = observations.filter { $0.sessionID == last.sessionID && [.completed, .partiallyCompleted].contains($0.outcome) }
      let actual = attempts.reduce(0) { $0 + $1.actual }
      return actual > 0 ? (last.estimated, actual) : nil
    }
    guard pairs.count >= Self.minimumSamples else { return nil }
    return Double(pairs.reduce(0) { $0 + $1.1 }) / Double(pairs.reduce(0) { $0 + $1.0 }) - 1
  }
  public var suggestions: [ExecutionAdaptation] {
    var result: [ExecutionAdaptation] = []
    for area in Set(sessions.map(\.area)).sorted() {
      let scoped = sessions.filter { $0.area == area }
      guard scoped.count >= Self.minimumSamples else { continue }
      let short = scoped.filter { (30...50).contains($0.estimated) }
      let long = scoped.filter { $0.estimated >= 90 }
      func rate(_ values: [ExecutionObservation]) -> Double {
        Double(values.filter { $0.outcome == .completed }.count) / Double(max(1, values.count))
      }
      let durationComparison = short.count >= Self.minimumSamples && long.count >= Self.minimumSamples && rate(short) >= 0.7 && rate(short) - rate(long) >= 0.25
      if durationComparison || reasonCount(.tooLong, area: area) >= 3 {
        result.append(.init(kind: .shorterSessions, area: area, value: 50,
          evidence: durationComparison
            ? "\(area): 30–50m sessions completed \(Int(rate(short)*100))% of the time (n=\(short.count)), versus \(Int(rate(long)*100))% for 90+m (n=\(long.count))."
            : "\(area): ‘too long’ was reported across \(reasonCount(.tooLong, area: area)) distinct sessions.",
          proposal: "Cap future \(area) sessions at 50 minutes?", sampleCount: scoped.count))
      }
      if let bias = durationBias(area: area), bias >= 0.15 {
        let percent = min(100, (bias * 100 / 5).rounded() * 5)
        result.append(.init(kind: .durationBias, area: area, value: 1 + percent / 100,
          evidence: "\(area) took \(Int((bias * 100).rounded()))% longer than estimated.",
          proposal: "Increase future \(area) estimates by \(Int(percent))%?", sampleCount: scoped.filter { $0.outcome == .completed }.count))
      }
      if reasonCount(.unclearStart, area: area) >= 3 {
        result.append(.init(kind: .concreteStart, area: area, value: 1,
          evidence: "\(area): unclear how to start was reported across at least three sessions.",
          proposal: "Include a concrete first action in future \(area) sessions?", sampleCount: scoped.count))
      }
      let late = scoped.filter { ($0.localHour ?? -1) >= 21 && $0.energy == "high" }
      if late.count >= Self.minimumSamples && rate(late) <= 0.4 {
        result.append(.init(kind: .lowerEveningEnergy, area: area, value: 21,
          evidence: "\(area): high-energy work after 21:00 completed in \(Int(rate(late)*100))% of \(late.count) sessions.",
          proposal: "Prefer lower-energy \(area) work after 21:00?", sampleCount: late.count))
      }
    }
    return result
  }
}

extension ExecutionProfile {
  public func adapting(_ preferences: SchedulingPreferences, area: String) -> SchedulingPreferences {
    var result = preferences
    for adaptation in accepted where adaptation.area == area {
      switch adaptation.kind {
      case .shorterSessions:
        result.maxSessionMinutes = min(result.maxSessionMinutes, max(5, Int(adaptation.value)))
      case .lowerEveningEnergy:
        result.energyWindows += [
          .init(window: .init(startMinute: 0, endMinute: 21 * 60), energy: "high"),
          .init(window: .init(startMinute: 21 * 60, endMinute: 1440), energy: "low")]
      default: break
      }
    }
    return result
  }
  public var planningInstructions: [String] {
    accepted.map { adaptation in
      let prefix = "User-accepted adaptation for area \(adaptation.area): "
      switch adaptation.kind {
      case .shorterSessions: return prefix + "Shape sessions to at most \(Int(adaptation.value)) minutes; preserve remaining work in additional sessions."
      case .durationBias: return prefix + "Multiply new baseline duration estimates by \(adaptation.value) once. Do not inflate existing or already adapted estimates."
      case .concreteStart: return prefix + "Give a specific executable first action, including what to open or do first."
      case .lowerEveningEnergy: return prefix + "Prefer low-energy work after 21:00 and high-energy work earlier."
      }
    }
  }
}
