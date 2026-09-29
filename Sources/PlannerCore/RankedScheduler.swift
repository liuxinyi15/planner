import Foundation

extension Scheduler {
  /// At most 28 days, one candidate per 15-minute boundary by default. Ties are chronological.
  public func rank(
    _ task: SchedulingTask, busy: [BusyInterval], from: Date, deadline: Date? = nil,
    preferences: SchedulingPreferences = .init(), constraints: [PlanningConstraint] = [],
    calendar: Calendar = .current
  ) -> SchedulingEvaluation {
    guard valid(task, preferences: preferences), constraints.allSatisfy(\.isValid) else {
      return .init(
        selected: nil, alternatives: [],
        reasons: [
          .init(.invalidInput, "Invalid session shape, scheduling preferences or constraint.")
        ], feasibleCandidateCount: 0, isWeak: true)
    }
    let horizon = min(
      deadline ?? .distantFuture, task.latestEnd ?? .distantFuture,
      calendar.date(byAdding: .day, value: preferences.policy.horizonDays, to: from)!)
    var candidates: [SchedulingCandidate] = []
    let pinned = task.locked || task.flexibility == "fixed"
    if pinned {
      if let start = task.scheduledStart
        ?? (task.flexibility == "fixed" ? task.earliestStart : nil),
        let candidate = candidate(
          task, at: start, busy: busy, from: from, deadline: horizon,
          preferences: preferences, constraints: constraints, calendar: calendar)
      {
        var result = candidate
        result.reasons.append(
          .init(
            task.locked ? .lockedSession : .preservedSession, "The fixed session time is preserved."
          ))
        candidates = [result]
      }
    } else {
      let step = Double(preferences.policy.granularityMinutes) * 60
      var cursor = Date(
        timeIntervalSince1970: ceil(
          max(from, task.earliestStart ?? from).timeIntervalSince1970 / step) * step)
      // Cache per-day unioned load; repeated calendar events never double-count workload.
      var loads: [Date: Int] = [:]
      while cursor.addingTimeInterval(Double(task.duration) * 60) <= horizon {
        let day = calendar.startOfDay(for: cursor)
        let load: Int
        if let saved = loads[day] {
          load = saved
        } else {
          load = dailyLoad(busy, day: day, calendar: calendar)
          loads[day] = load
        }
        if let value = evaluatedCandidate(
          task, at: cursor, busy: busy, from: from, deadline: horizon,
          preferences: preferences, constraints: constraints, calendar: calendar, knownLoad: load)
        {
          candidates.append(value)
        }
        cursor = cursor.addingTimeInterval(step)
      }
    }
    candidates.sort { $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score }
    guard let selected = candidates.first else {
      let detail =
        pinned
        ? "The locked or fixed time is infeasible. It has not been moved; resolve the conflict or unlock it."
        : "No feasible slot satisfies availability, buffers, capacity, duration, deadline and hard constraints. Change a hard boundary or split the session explicitly."
      return .init(
        selected: nil, alternatives: [], reasons: [.init(.noFeasibleSlot, detail)],
        feasibleCandidateCount: 0, isWeak: true)
    }
    var alternatives: [SchedulingCandidate] = []
    if !pinned {
      for candidate in candidates.dropFirst() {
        if alternatives.count >= preferences.policy.alternativeCount { break }
        if ([selected] + alternatives).allSatisfy({
          abs($0.start.timeIntervalSince(candidate.start)) >= Double(
            preferences.policy.alternativeSeparationMinutes) * 60
        }) {
          alternatives.append(candidate)
        }
      }
    }
    return .init(
      selected: selected, alternatives: alternatives, reasons: selected.reasons,
      feasibleCandidateCount: candidates.count,
      isWeak: selected.score < preferences.policy.weakScoreThreshold)
  }

  /// Shared hard gate, also used to validate preserved sessions and commits. Never relaxes rules.
  public func candidate(
    _ task: SchedulingTask, at start: Date, busy: [BusyInterval], from: Date,
    deadline: Date? = nil, preferences: SchedulingPreferences = .init(),
    constraints: [PlanningConstraint] = [], calendar: Calendar = .current
  ) -> SchedulingCandidate? {
    evaluatedCandidate(
      task, at: start, busy: busy, from: from, deadline: deadline,
      preferences: preferences, constraints: constraints, calendar: calendar)
  }
  private func evaluatedCandidate(
    _ task: SchedulingTask, at start: Date, busy: [BusyInterval], from: Date,
    deadline: Date? = nil, preferences: SchedulingPreferences = .init(),
    constraints: [PlanningConstraint] = [],
    calendar: Calendar = .current, knownLoad: Int? = nil
  ) -> SchedulingCandidate? {
    guard valid(task, preferences: preferences), constraints.allSatisfy(\.isValid) else {
      return nil
    }
    let end = start.addingTimeInterval(Double(task.duration) * 60)
    let horizon = min(
      deadline ?? .distantFuture, task.latestEnd ?? .distantFuture,
      calendar.date(byAdding: .day, value: preferences.policy.horizonDays, to: from)!)
    guard start >= max(from, task.earliestStart ?? from), end <= horizon,
      !task.locked || task.scheduledStart == start,
      task.flexibility != "fixed" || (task.scheduledStart ?? task.earliestStart) == start,
      let window = availability(at: start, end: end, preferences: preferences, calendar: calendar)
    else { return nil }
    for interval in busy {
      let gap =
        Double(max(task.bufferMinutes, interval.bufferMinutes, preferences.breakMinutes)) * 60
      if start < interval.contentEnd.addingTimeInterval(gap)
        && end > interval.contentStart.addingTimeInterval(-gap)
      {
        return nil
      }
    }
    for interval in busy
    where !task.location.isEmpty && !interval.location.isEmpty && task.location != interval.location
    {
      if interval.contentEnd <= start {
        let minutes =
          preferences.travelTimes.filter { $0.from == interval.location && $0.to == task.location }
          .map(\.minutes).max() ?? 0
        if start.timeIntervalSince(interval.contentEnd) < Double(minutes) * 60 { return nil }
      } else if interval.contentStart >= end {
        let minutes =
          preferences.travelTimes.filter { $0.from == task.location && $0.to == interval.location }
          .map(\.minutes).max() ?? 0
        if interval.contentStart.timeIntervalSince(end) < Double(minutes) * 60 { return nil }
      }
    }
    let day = calendar.startOfDay(for: start)
    let load = knownLoad ?? dailyLoad(busy, day: day, calendar: calendar)
    guard load + task.duration <= preferences.dailyMinutes else { return nil }
    let active = constraints.filter { $0.applies(start: start, end: end) }.sorted {
      $0.id.uuidString < $1.id.uuidString
    }
    for rule in active where rule.type == .hard {
      if violation(
        rule, task: task, start: start, end: end, load: load, busy: busy, calendar: calendar) > 0
      {
        return nil
      }
    }
    return score(
      task, start: start, end: end,
      window: (max(window.0, from, task.earliestStart ?? from), min(window.1, horizon)), load: load,
      busy: busy,
      deadline: deadline, preferences: preferences, constraints: active, calendar: calendar)
  }

  private func valid(_ task: SchedulingTask, preferences p: SchedulingPreferences) -> Bool {
    (5...480).contains(task.duration) && (5...480).contains(task.minimumChunkMinutes)
      && (5...480).contains(task.maximumChunkMinutes)
      && task.minimumChunkMinutes <= task.maximumChunkMinutes
      && task.duration >= task.minimumChunkMinutes
      && task.duration <= min(task.maximumChunkMinutes, p.maxSessionMinutes)
      && ["flexible", "fixed"].contains(task.flexibility)
      && ["low", "medium", "high"].contains(task.energyRequirement)
      && (task.earliestStart == nil || task.latestEnd == nil
        || task.earliestStart! < task.latestEnd!)
      && (0...1440).contains(task.bufferMinutes)
      && task.preferredDays.allSatisfy { (1...7).contains($0) }
      && task.preferredWindows.allSatisfy(\.isValid) && (0...23).contains(p.startHour)
      && (1...24).contains(p.endHour) && p.startHour < p.endHour
      && (1...1440).contains(p.dailyMinutes) && (0...1440).contains(p.breakMinutes)
      && p.availabilityWindows.allSatisfy(\.isValid)
      && p.preferredWindows.allSatisfy(\.isValid)
      && p.preferredDays.allSatisfy { (1...7).contains($0) }
      && p.energyWindows.allSatisfy {
        $0.window.isValid && ["low", "medium", "high"].contains($0.energy)
      }
      && (p.lateEveningStartsMinute == nil || (0..<1440).contains(p.lateEveningStartsMinute!))
      && (p.postTrainingRecoveryMinutes == nil
        || (0...1440).contains(p.postTrainingRecoveryMinutes!))
      && p.travelTimes.allSatisfy { (0...1440).contains($0.minutes) }
      && p.historicalSuccess.allSatisfy {
        $0.window.isValid && (0...1).contains($0.successRate) && $0.sampleCount >= 0
      }
      && SchedulingFactor.allCases.allSatisfy {
        p.weights.weight(for: $0).isFinite && (0...100).contains(p.weights.weight(for: $0))
      }
      && (1...28).contains(p.policy.horizonDays) && (1...60).contains(p.policy.granularityMinutes)
      && (0...10).contains(p.policy.alternativeCount)
      && (1...1440).contains(p.policy.alternativeSeparationMinutes)
      && p.policy.courseProximityHours > 0 && p.policy.courseProximityHours.isFinite
      && p.policy.preferredDateFalloffHours > 0 && p.policy.preferredDateFalloffHours.isFinite
      && p.policy.historyFullConfidenceSamples > 0 && p.policy.historyFullConfidenceSamples.isFinite
      && p.policy.weakScoreThreshold.isFinite
  }
  private func bounds(_ window: PlanningTimeWindow, on date: Date, calendar: Calendar) -> (
    Date, Date
  )? {
    guard window.isValid,
      window.weekdays.isEmpty || window.weekdays.contains(calendar.component(.weekday, from: date))
    else { return nil }
    let day = calendar.startOfDay(for: date)
    func clock(_ minute: Int) -> Date? {
      if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: day) }
      return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
    guard let start = clock(window.startMinute), let end = clock(window.endMinute), end > start
    else { return nil }
    return (start, end)
  }
  private func availability(
    at start: Date, end: Date, preferences p: SchedulingPreferences, calendar: Calendar
  ) -> (Date, Date)? {
    guard
      let daily = bounds(
        .init(startMinute: p.startHour * 60, endMinute: p.endHour * 60), on: start,
        calendar: calendar), start >= daily.0, end <= daily.1
    else { return nil }
    if p.availabilityWindows.isEmpty { return daily }
    return p.availabilityWindows.compactMap { bounds($0, on: start, calendar: calendar) }
      .map { (max(daily.0, $0.0), min(daily.1, $0.1)) }
      .filter { start >= $0.0 && end <= $0.1 }.sorted { $0.0 == $1.0 ? $0.1 > $1.1 : $0.0 < $1.0 }
      .first
  }
  private func dailyLoad(_ busy: [BusyInterval], day: Date, calendar: Calendar) -> Int {
    let next = calendar.date(byAdding: .day, value: 1, to: day)!
    var intervals: [(Date, Date)] = []
    for interval in busy
    where interval.contentEnd > day && interval.contentStart < next
      && interval.contentEnd > interval.contentStart
    {
      intervals.append((max(day, interval.contentStart), min(next, interval.contentEnd)))
    }
    intervals.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
    var cursor = day
    var seconds = 0.0
    for interval in intervals {
      seconds += max(0, interval.1.timeIntervalSince(max(cursor, interval.0)))
      cursor = max(cursor, interval.1)
    }
    return Int(ceil(seconds / 60))
  }
  private func overlap(_ window: PlanningTimeWindow, start: Date, end: Date, calendar: Calendar)
    -> Double
  {
    guard let window = bounds(window, on: start, calendar: calendar) else { return 0 }
    return max(0, min(end, window.1).timeIntervalSince(max(start, window.0)))
      / end.timeIntervalSince(start)
  }
  private func violation(
    _ rule: PlanningConstraint, task: SchedulingTask, start: Date, end: Date, load: Int,
    busy: [BusyInterval], calendar: Calendar
  ) -> Double {
    let v = rule.value
    let weekday = calendar.component(.weekday, from: start)
    let appliesDay = (v.weekdays ?? []).isEmpty || v.weekdays!.contains(weekday)
    let clippedStart = max(start, rule.startDate ?? start)
    let clippedEnd = min(end, rule.expiration ?? end)
    let window = PlanningTimeWindow(
      weekdays: v.weekdays ?? [], startMinute: v.startMinute ?? 0, endMinute: v.endMinute ?? 1440)
    switch rule.key {
    case .legacyAvailability:
      if (v.weekdays ?? []).contains(weekday) { return 1 }
      if let minute = v.endMinute,
        let boundary = bounds(
          .init(startMinute: 0, endMinute: minute), on: start, calendar: calendar),
        clippedEnd > boundary.1
      {
        return 1
      }
      return 0
    case .excludedWeekdays: return appliesDay ? 1 : 0
    case .blockedWindow:
      return overlap(window, start: clippedStart, end: clippedEnd, calendar: calendar)
    case .energyLimit:
      return task.energyRequirement == v.energy
        ? overlap(window, start: clippedStart, end: clippedEnd, calendar: calendar) : 0
    case .dailyWorkLimit, .lightDay:
      return appliesDay
        ? Double(max(0, load + task.duration - v.minutes!)) / Double(max(1, v.minutes!)) : 0
    case .preferredWindow:
      return 1 - overlap(window, start: clippedStart, end: clippedEnd, calendar: calendar)
    case .preferredDays: return appliesDay ? 0 : 1
    case .avoidLateEvening:
      return appliesDay
        ? overlap(
          .init(startMinute: v.startMinute!, endMinute: 1440), start: clippedStart, end: clippedEnd,
          calendar: calendar) : 0
    case .avoidAfterTraining:
      guard task.energyRequirement == "high", appliesDay else { return 0 }
      return postTraining(start: start, busy: busy, recoveryMinutes: v.minutes!)
    case .balanceWorkload, .preserveBlocks: return 0
    }
  }
  private func postTraining(start: Date, busy: [BusyInterval], recoveryMinutes: Int) -> Double {
    guard recoveryMinutes > 0 else { return 0 }
    return busy.filter { $0.kind == .training && $0.contentEnd <= start }.map {
      max(0, 1 - start.timeIntervalSince($0.contentEnd) / (Double(recoveryMinutes) * 60))
    }.max() ?? 0
  }
  private func score(
    _ task: SchedulingTask, start: Date, end: Date, window: (Date, Date), load: Int,
    busy: [BusyInterval], deadline: Date?, preferences p: SchedulingPreferences,
    constraints: [PlanningConstraint], calendar: Calendar
  ) -> SchedulingCandidate {
    var features = Dictionary(uniqueKeysWithValues: SchedulingFactor.allCases.map { ($0, 0.0) })
    var reasons: [SchedulingReason] = [
      .init(.withinAvailability, "Inside your available hours."),
      .init(
        .avoidsBusyPeriod, "Clear of calendar commitments, required buffers and known travel times."
      ),
    ]
    if deadline != nil || task.latestEnd != nil {
      reasons.append(.init(.withinDeadline, "Finishes within the scheduling boundary."))
    }
    let windows = task.preferredWindows.isEmpty ? p.preferredWindows : task.preferredWindows
    features[.preferredTime] =
      windows.map { overlap($0, start: start, end: end, calendar: calendar) }.max() ?? 0
    if let preferred = task.preferredStart {
      let match: Double
      if let preferredEnd = task.preferredEnd, preferredEnd > preferred {
        match =
          max(0, min(end, preferredEnd).timeIntervalSince(max(start, preferred)))
          / end.timeIntervalSince(start)
      } else {
        match = max(
          0,
          1 - abs(start.timeIntervalSince(preferred)) / (p.policy.preferredDateFalloffHours * 3600))
      }
      features[.preferredTime] = max(features[.preferredTime]!, match)
    }
    let days = task.preferredDays.isEmpty ? p.preferredDays : task.preferredDays
    features[.preferredDay] = days.contains(calendar.component(.weekday, from: start)) ? 1 : 0
    features[.workloadBalance] = -Double(load) / Double(p.dailyMinutes)
    features[.energyMatch] =
      p.energyWindows.filter { $0.energy == task.energyRequirement }.map {
        overlap($0.window, start: start, end: end, calendar: calendar)
      }.max() ?? 0
    if let minute = p.lateEveningStartsMinute {
      features[.lateEveningPenalty] = -overlap(
        .init(startMinute: minute, endMinute: 1440), start: start, end: end, calendar: calendar)
    }
    if let minutes = p.postTrainingRecoveryMinutes, task.energyRequirement == "high" {
      features[.postTrainingPenalty] = -postTraining(
        start: start, busy: busy, recoveryMinutes: minutes)
    }
    let left = max(
      window.0,
      busy.filter { $0.contentEnd <= start }.map {
        $0.contentEnd.addingTimeInterval(
          Double(max(task.bufferMinutes, $0.bufferMinutes, p.breakMinutes)) * 60)
      }.max() ?? window.0)
    let right = min(
      window.1,
      busy.filter { $0.contentStart >= end }.map {
        $0.contentStart.addingTimeInterval(
          -Double(max(task.bufferMinutes, $0.bufferMinutes, p.breakMinutes)) * 60)
      }.min() ?? window.1)
    features[.fragmentationPenalty] =
      -max(0, min(start.timeIntervalSince(left), right.timeIntervalSince(end)))
      / max(1, right.timeIntervalSince(left))
    if let courseID = task.courseID {
      features[.courseProximity] =
        busy.filter { $0.courseID == courseID }.map {
          let gap = max(
            0, start.timeIntervalSince($0.contentEnd), $0.contentStart.timeIntervalSince(end))
          return max(0, 1 - gap / (p.policy.courseProximityHours * 3600))
        }.max() ?? 0
    }
    let evidence = p.historicalSuccess.filter {
      overlap($0.window, start: start, end: end, calendar: calendar) == 1
    }
    if !evidence.isEmpty {
      let total = evidence.reduce(0.0) { $0 + Double($1.sampleCount) }
      if total > 0 {
        let rate = evidence.reduce(0.0) { $0 + $1.successRate * Double($1.sampleCount) } / total
        features[.historicalSuccess] =
          (rate - 0.5) * 2 * min(1, total / p.policy.historyFullConfidenceSamples)
      }
    }
    let baseFragmentation = features[.fragmentationPenalty]!
    for rule in constraints {
      let penalty = violation(
        rule, task: task, start: start, end: end, load: load, busy: busy, calendar: calendar)
      if rule.type == .hard {
        reasons.append(.init(.hardConstraint, "Respects: " + rule.text, constraintID: rule.id))
        continue
      }
      switch rule.key {
      case .preferredWindow: features[.preferredTime]! += 1 - penalty
      case .preferredDays: features[.preferredDay]! += 1 - penalty
      case .avoidLateEvening: features[.lateEveningPenalty]! -= penalty
      case .avoidAfterTraining: features[.postTrainingPenalty]! -= penalty
      case .balanceWorkload: features[.workloadBalance]! -= Double(load) / Double(p.dailyMinutes)
      case .preserveBlocks: features[.fragmentationPenalty]! += baseFragmentation
      default: features[.softConstraint]! -= penalty
      }
      let prefix =
        (rule.key == .balanceWorkload || rule.key == .preserveBlocks)
        ? "Preference considered: "
        : (penalty == 0 ? "Respects preference: " : "Trade-off against preference: ")
      reasons.append(
        .init(
          rule.key == .lightDay ? .lightDay : .softConstraint, prefix + rule.text,
          constraintID: rule.id))
    }
    if features[.preferredTime]! > 0 && p.weights.preferredTime > 0 {
      reasons.append(
        .init(
          .preferredTime, "Overlaps your preferred time window or is close to the preferred time."))
    }
    if features[.preferredDay]! > 0 && p.weights.preferredDay > 0 {
      reasons.append(.init(.preferredDay, "Falls on a preferred day."))
    }
    if p.weights.workloadBalance > 0 {
      reasons.append(
        .init(
          .balancedDailyLoad,
          "This day has \(load) minutes of existing commitments; lighter days score higher."))
    }
    if features[.energyMatch]! > 0 && p.weights.energyMatch > 0 {
      reasons.append(.init(.energyMatch, "Matches an energy window you supplied."))
    }
    if features[.lateEveningPenalty]! < 0 && p.weights.lateEveningPenalty > 0 {
      reasons.append(.init(.lateEvening, "Includes time after your preferred evening cutoff."))
    }
    if features[.postTrainingPenalty]! < 0 && p.weights.postTrainingPenalty > 0 {
      reasons.append(
        .init(.postTraining, "Falls within your requested recovery period after training."))
    }
    if p.weights.fragmentationPenalty > 0 {
      reasons.append(
        .init(
          .preservesBlocks,
          features[.fragmentationPenalty] == 0
            ? "At an edge of a free window, preserving an uninterrupted block."
            : "Splits a free window; this is included in the score."))
    }
    if features[.courseProximity]! > 0 && p.weights.courseProximity > 0 {
      reasons.append(
        .init(.courseProximity, "Near a calendar session explicitly linked to the same course."))
    }
    if features[.historicalSuccess] != 0 && p.weights.historicalSuccess > 0 {
      reasons.append(
        .init(.historicalSuccess, "Uses the supplied completion evidence for this window."))
    }
    let contributions = SchedulingFactor.allCases.map {
      SchedulingContribution(factor: $0, feature: features[$0]!, weight: p.weights.weight(for: $0))
    }
    return .init(
      start: start, end: end, score: contributions.reduce(0) { $0 + $1.contribution },
      contributions: contributions, reasons: reasons)
  }
}
