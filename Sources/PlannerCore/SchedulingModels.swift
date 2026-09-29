import Foundation

/// Recurring local-clock window. Empty weekdays means every day; Sunday = 1.
public struct PlanningTimeWindow: Codable, Equatable, Sendable {
  public var weekdays: [Int]
  public var startMinute: Int
  public var endMinute: Int
  public init(weekdays: [Int] = [], startMinute: Int, endMinute: Int) {
    self.weekdays = weekdays
    self.startMinute = startMinute
    self.endMinute = endMinute
  }
  public var isValid: Bool {
    weekdays.allSatisfy { (1...7).contains($0) } && (0..<1440).contains(startMinute)
      && endMinute > startMinute && endMinute <= 1440
  }
}
public struct EnergyWindow: Codable, Equatable, Sendable {
  public var window: PlanningTimeWindow
  public var energy: String
  public init(window: PlanningTimeWindow, energy: String) {
    self.window = window
    self.energy = energy
  }
}
public struct TravelTime: Codable, Equatable, Sendable {
  public var from: String
  public var to: String
  public var minutes: Int
  public init(from: String, to: String, minutes: Int) {
    self.from = from
    self.to = to
    self.minutes = minutes
  }
}
/// Optional, supplied evidence only. The scheduler neither infers nor learns a pattern.
public struct HistoricalSuccessWindow: Codable, Equatable, Sendable {
  public var window: PlanningTimeWindow
  public var successRate: Double
  public var sampleCount: Int
  public init(window: PlanningTimeWindow, successRate: Double, sampleCount: Int) {
    self.window = window
    self.successRate = successRate
    self.sampleCount = sampleCount
  }
}
public struct SessionSchedulingProperties: Codable, Equatable, Sendable {
  public var earliestStart: Date?
  public var latestEnd: Date?
  public var preferredDays: [Int]?
  public var preferredWindows: [PlanningTimeWindow]?
  public var location: String?
  public var bufferMinutes: Int?
  public var courseID: UUID?
  public init(
    earliestStart: Date? = nil, latestEnd: Date? = nil, preferredDays: [Int]? = nil,
    preferredWindows: [PlanningTimeWindow]? = nil, location: String? = nil,
    bufferMinutes: Int? = nil, courseID: UUID? = nil
  ) {
    self.earliestStart = earliestStart
    self.latestEnd = latestEnd
    self.preferredDays = preferredDays
    self.preferredWindows = preferredWindows
    self.location = location
    self.bufferMinutes = bufferMinutes
    self.courseID = courseID
  }
  public var isValid: Bool {
    (earliestStart == nil || latestEnd == nil || earliestStart! < latestEnd!)
      && (preferredDays ?? []).allSatisfy { (1...7).contains($0) }
      && (preferredWindows ?? []).allSatisfy(\.isValid)
      && (bufferMinutes == nil || (0...1440).contains(bufferMinutes!))
  }
}
public struct SchedulingTask: Sendable {
  public var duration: Int
  public var flexibility: String = "flexible"
  public var earliestStart: Date?
  public var latestEnd: Date?
  public var preferredDays: [Int] = []
  public var preferredWindows: [PlanningTimeWindow] = []
  public var preferredStart: Date?
  public var preferredEnd: Date?
  public var energyRequirement: String = "medium"
  public var splittable = true
  public var minimumChunkMinutes = 5
  public var maximumChunkMinutes = 480
  public var locked = false
  public var scheduledStart: Date?
  public var location = ""
  public var bufferMinutes = 0
  public var courseID: UUID?
  public init(duration: Int) { self.duration = duration }
  public init(_ session: SessionDraft) {
    self.init(duration: session.duration_minutes)
    energyRequirement = session.energy_level
    preferredStart = session.preferred_time
    apply(session.scheduling)
    flexibility = session.flexibility ?? "flexible"
    splittable = session.splittable ?? true
    minimumChunkMinutes = session.minimum_chunk_minutes ?? 5
    maximumChunkMinutes = session.maximum_chunk_minutes ?? 480
  }
  public init(_ session: DraftSession) {
    self.init(duration: session.duration)
    flexibility = session.flexibility
    energyRequirement = session.energyLevel
    preferredStart = session.preferredTiming
    preferredEnd = session.preferredEnd
    splittable = session.splittable
    minimumChunkMinutes = session.minimumChunk
    maximumChunkMinutes = session.maximumChunk
    locked = session.locked
    scheduledStart = session.scheduledStart
    apply(session.scheduling)
  }
  private mutating func apply(_ shape: SessionSchedulingProperties?) {
    earliestStart = shape?.earliestStart
    latestEnd = shape?.latestEnd
    preferredDays = shape?.preferredDays ?? []
    preferredWindows = shape?.preferredWindows ?? []
    location = shape?.location ?? ""
    bufferMinutes = shape?.bufferMinutes ?? 0
    courseID = shape?.courseID
  }
}

public enum ConstraintStrength: String, Codable, Sendable { case hard, soft }
public enum ConstraintSource: String, Codable, Sendable {
  case explicit, temporary, inferred, suggested
}
public enum PlanningConstraintKey: String, Codable, Sendable {
  case legacyAvailability = "availability"
  case excludedWeekdays = "excluded_weekdays"
  case blockedWindow = "blocked_window"
  case dailyWorkLimit = "daily_work_limit"
  case energyLimit = "energy_limit"
  case preferredWindow = "preferred_window"
  case preferredDays = "preferred_days"
  case lightDay = "light_day"
  case avoidLateEvening = "avoid_late_evening"
  case avoidAfterTraining = "avoid_after_training"
  case balanceWorkload = "balance_workload"
  case preserveBlocks = "preserve_blocks"
}
public struct PlanningConstraintValue: Codable, Equatable, Sendable {
  public var weekdays: [Int]?
  public var startMinute: Int?
  public var endMinute: Int?
  public var minutes: Int?
  public var energy: String?
  public init(
    weekdays: [Int]? = nil, startMinute: Int? = nil, endMinute: Int? = nil,
    minutes: Int? = nil, energy: String? = nil
  ) {
    self.weekdays = weekdays
    self.startMinute = startMinute
    self.endMinute = endMinute
    self.minutes = minutes
    self.energy = energy
  }
}
public struct PlanningConstraint: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var type: ConstraintStrength
  public var key: PlanningConstraintKey
  public var value: PlanningConstraintValue
  public var source: ConstraintSource
  public var startDate: Date?
  public var expiration: Date?
  public var active: Bool
  public var text: String
  public init(
    id: UUID = UUID(), type: ConstraintStrength, key: PlanningConstraintKey,
    value: PlanningConstraintValue = .init(), source: ConstraintSource = .explicit,
    startDate: Date? = nil, expiration: Date? = nil, active: Bool = true, text: String
  ) {
    self.id = id
    self.type = type
    self.key = key
    self.value = value
    self.source = source
    self.startDate = startDate
    self.expiration = expiration
    self.active = active
    self.text = text
  }
  /// Compatibility with the original draft constraints. Invalid hours remain invalid (no overflow).
  public init(id: UUID = UUID(), text: String, excludedWeekdays: [Int] = [], latestHour: Int? = nil)
  {
    self.init(
      id: id, type: .hard, key: .legacyAvailability,
      value: .init(
        weekdays: excludedWeekdays,
        endMinute: latestHour.map { (1...24).contains($0) ? $0 * 60 : -1 }), text: text)
  }
  private enum CodingKeys: String, CodingKey {
    case id, type, key, value, source, startDate, expiration, active, text, excludedWeekdays,
      latestHour
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let id = try c.decode(UUID.self, forKey: .id)
    let text = try c.decode(String.self, forKey: .text)
    if !c.contains(.key) {
      self.init(
        id: id, text: text,
        excludedWeekdays: try c.decodeIfPresent([Int].self, forKey: .excludedWeekdays) ?? [],
        latestHour: try c.decodeIfPresent(Int.self, forKey: .latestHour))
    } else {
      self.init(
        id: id, type: try c.decode(ConstraintStrength.self, forKey: .type),
        key: try c.decode(PlanningConstraintKey.self, forKey: .key),
        value: try c.decode(PlanningConstraintValue.self, forKey: .value),
        source: try c.decode(ConstraintSource.self, forKey: .source),
        startDate: try c.decodeIfPresent(Date.self, forKey: .startDate),
        expiration: try c.decodeIfPresent(Date.self, forKey: .expiration),
        active: try c.decode(Bool.self, forKey: .active), text: text)
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(type, forKey: .type)
    try c.encode(key, forKey: .key)
    try c.encode(value, forKey: .value)
    try c.encode(source, forKey: .source)
    try c.encode(active, forKey: .active)
    try c.encode(text, forKey: .text)
    try c.encodeIfPresent(startDate, forKey: .startDate)
    try c.encodeIfPresent(expiration, forKey: .expiration)
  }
  public var isValid: Bool {
    guard !text.isEmpty, (value.weekdays ?? []).allSatisfy({ (1...7).contains($0) }),
      value.startMinute == nil || (0..<1440).contains(value.startMinute!),
      value.endMinute == nil || (1...1440).contains(value.endMinute!),
      value.minutes == nil || (0...1440).contains(value.minutes!),
      value.energy == nil || ["low", "medium", "high"].contains(value.energy!),
      startDate == nil || expiration == nil || startDate! < expiration!
    else { return false }
    // A valid typed rule cannot silently ignore additional value fields.
    let hasWindow = value.startMinute != nil || value.endMinute != nil
    switch key {
    case .legacyAvailability:
      guard value.startMinute == nil, value.minutes == nil, value.energy == nil else {
        return false
      }
    case .excludedWeekdays, .preferredDays:
      guard !hasWindow, value.minutes == nil, value.energy == nil else { return false }
    case .blockedWindow, .preferredWindow:
      guard value.minutes == nil, value.energy == nil else { return false }
    case .energyLimit:
      guard value.minutes == nil else { return false }
    case .dailyWorkLimit, .lightDay, .avoidAfterTraining:
      guard !hasWindow, value.energy == nil else { return false }
    case .avoidLateEvening:
      guard value.endMinute == nil, value.minutes == nil, value.energy == nil else { return false }
    case .balanceWorkload, .preserveBlocks:
      guard value == PlanningConstraintValue() else { return false }
    }
    let window =
      value.startMinute != nil && value.endMinute != nil && value.startMinute! < value.endMinute!
    switch key {
    case .legacyAvailability: return !(value.weekdays ?? []).isEmpty || value.endMinute != nil
    case .excludedWeekdays, .preferredDays: return !(value.weekdays ?? []).isEmpty
    case .blockedWindow, .preferredWindow: return window
    case .energyLimit: return window && value.energy != nil
    case .dailyWorkLimit, .lightDay, .avoidAfterTraining: return value.minutes != nil
    case .avoidLateEvening: return value.startMinute != nil
    case .balanceWorkload, .preserveBlocks: return type == .soft
    }
  }
  /// Rules apply to the overlapping part of a candidate, and stop at their expiration.
  public func applies(start: Date, end: Date) -> Bool {
    active && (startDate == nil || end > startDate!) && (expiration == nil || start < expiration!)
  }
}
public typealias DraftConstraint = PlanningConstraint

public enum SchedulingFactor: String, Codable, CaseIterable, Sendable {
  case preferredTime, preferredDay, workloadBalance, energyMatch, lateEveningPenalty
  case postTrainingPenalty, fragmentationPenalty, courseProximity, historicalSuccess, softConstraint
}
/// Unit weights are neutral with respect to people; absent preference/evidence produces zero.
public struct SchedulingWeights: Codable, Equatable, Sendable {
  public var preferredTime = 1.0
  public var preferredDay = 1.0
  public var workloadBalance = 1.0
  public var energyMatch = 1.0
  public var lateEveningPenalty = 1.0
  public var postTrainingPenalty = 1.0
  public var fragmentationPenalty = 1.0
  public var courseProximity = 1.0
  public var historicalSuccess = 1.0
  public var softConstraint = 1.0
  public init() {}
  public func weight(for factor: SchedulingFactor) -> Double {
    switch factor {
    case .preferredTime: return preferredTime
    case .preferredDay: return preferredDay
    case .workloadBalance: return workloadBalance
    case .energyMatch: return energyMatch
    case .lateEveningPenalty: return lateEveningPenalty
    case .postTrainingPenalty: return postTrainingPenalty
    case .fragmentationPenalty: return fragmentationPenalty
    case .courseProximity: return courseProximity
    case .historicalSuccess: return historicalSuccess
    case .softConstraint: return softConstraint
    }
  }
}
/// Search bounds and normalization are explicit policy, not hidden scoring constants.
public struct SchedulingPolicy: Sendable {
  public var horizonDays = 28
  public var granularityMinutes = 15
  public var alternativeCount = 3
  public var alternativeSeparationMinutes = 60
  public var courseProximityHours = 24.0
  public var preferredDateFalloffHours = 24.0
  public var historyFullConfidenceSamples = 20.0
  public var weakScoreThreshold = 0.0
  public init() {}
}
public enum SchedulingReasonCode: String, Codable, Sendable {
  case withinAvailability = "within_availability"
  case avoidsBusyPeriod = "avoids_busy_period"
  case withinDeadline = "within_deadline"
  case hardConstraint = "hard_constraint"
  case preferredTime = "preferred_time"
  case preferredDay = "preferred_day"
  case balancedDailyLoad = "balanced_daily_load"
  case energyMatch = "energy_match"
  case lateEvening = "late_evening_penalty"
  case postTraining = "post_training_penalty"
  case preservesBlocks = "preserves_uninterrupted_blocks"
  case courseProximity = "course_proximity"
  case historicalSuccess = "historical_success"
  case lightDay = "light_day_constraint"
  case softConstraint = "soft_constraint"
  case lockedSession = "locked_session"
  case preservedSession = "preserved_session"
  case noFeasibleSlot = "no_feasible_slot"
  case invalidInput = "invalid_input"
  case dependency = "dependency"
}
public struct SchedulingReason: Codable, Equatable, Sendable {
  public var code: SchedulingReasonCode
  public var detail: String
  public var constraintID: UUID?
  public init(_ code: SchedulingReasonCode, _ detail: String, constraintID: UUID? = nil) {
    self.code = code
    self.detail = detail
    self.constraintID = constraintID
  }
}
public struct SchedulingContribution: Codable, Equatable, Sendable {
  public var factor: SchedulingFactor
  public var feature: Double
  public var weight: Double
  public var contribution: Double { feature * weight }
}
public struct SchedulingCandidate: Codable, Equatable, Identifiable, Sendable {
  public var id: Date { start }
  public var start: Date
  public var end: Date
  public var score: Double
  public var contributions: [SchedulingContribution]
  public var reasons: [SchedulingReason]
}
public struct SchedulingEvaluation: Sendable {
  public var selected: SchedulingCandidate?
  public var alternatives: [SchedulingCandidate]
  public var reasons: [SchedulingReason]
  public var feasibleCandidateCount: Int
  public var isWeak: Bool
}
