import Foundation

public struct DraftSession: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID = UUID()
  public var title: String
  public var purpose: String
  public var duration: Int
  public var actions: [String]
  public var definitionOfDone: String
  public var energyLevel: String
  public var flexibility = "flexible"
  public var splittable = true
  public var minimumChunk = 5
  public var maximumChunk = 480
  public var preferredTiming: Date?
  public var preferredEnd: Date?
  public var locked = false
  public var scheduledStart: Date?
  public var schedulingExplanation: String?
  public var dependencies: [UUID] = []
  public var scheduling: SessionSchedulingProperties?
  public var schedulingReasons: [SchedulingReason]?
  public var schedulingAlternatives: [SchedulingCandidate]?
  public var schedulingScore: Double?
  public var end: Date? { scheduledStart?.addingTimeInterval(Double(duration * 60)) }
  public init(_ source: SessionDraft) {
    title = source.title
    purpose = source.purpose
    duration = source.duration_minutes
    actions = source.actions
    definitionOfDone = source.definition_of_done
    energyLevel = source.energy_level
    preferredTiming = source.preferred_time
    scheduling = source.scheduling
    flexibility = source.flexibility ?? "flexible"
    splittable = source.splittable ?? true
    minimumChunk = source.minimum_chunk_minutes ?? 5
    maximumChunk = source.maximum_chunk_minutes ?? 480
  }
  public var legacy: SessionDraft {
    var result = SessionDraft(
      title: title, purpose: purpose, duration_minutes: duration, actions: actions,
      definition_of_done: definitionOfDone, energy_level: energyLevel,
      preferred_time: preferredTiming)
    result.scheduling = scheduling
    result.flexibility = flexibility
    result.splittable = splittable
    result.minimum_chunk_minutes = minimumChunk
    result.maximum_chunk_minutes = maximumChunk
    return result
  }
}
public struct DraftMessage: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var role: String
  public var text: String
  public init(role: String, text: String) {
    self.role = role
    self.text = text
  }
}
public struct DraftPlan: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var title: String
  public var goal: String
  public var deadline: Date?
  public var priority: String
  public var sessions: [DraftSession]
  public var constraints: [DraftConstraint] = []
  public var assistantMessages: [DraftMessage] = []
  public var status = "review"
  public var estimatedWorkload: Int { sessions.reduce(0) { $0 + $1.duration } }
  private enum CodingKeys: String, CodingKey {
    case id, title, goal, deadline, priority, sessions, constraints, assistantMessages, status
  }
  private enum WorkloadKey: String, CodingKey { case estimatedWorkload }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(title, forKey: .title)
    try c.encode(goal, forKey: .goal)
    try c.encodeIfPresent(deadline, forKey: .deadline)
    try c.encode(priority, forKey: .priority)
    try c.encode(sessions, forKey: .sessions)
    try c.encode(constraints, forKey: .constraints)
    try c.encode(assistantMessages, forKey: .assistantMessages)
    try c.encode(status, forKey: .status)
    var workload = encoder.container(keyedBy: WorkloadKey.self)
    try workload.encode(estimatedWorkload, forKey: .estimatedWorkload)
  }
  public init(_ source: PlanDraft) {
    title = source.title
    goal = source.goal
    deadline = source.deadline
    priority = source.priority
    constraints = source.constraints ?? []
    sessions = source.sessions.map(DraftSession.init)
    for index in sessions.indices {
      sessions[index].dependencies = source.sessions[index].dependencies.map { sessions[$0].id }
    }
    assistantMessages = source.notes.map { DraftMessage(role: "assistant", text: $0) }
  }
  public var suggestions: [ScheduledSuggestion] {
    sessions.enumerated().map {
      ScheduledSuggestion(
        id: $0.offset, session: $0.element.legacy,
        start: $0.element.scheduledStart,
        warning: $0.element.scheduledStart == nil ? $0.element.schedulingExplanation : nil,
        reasons: $0.element.schedulingReasons ?? [],
        alternatives: $0.element.schedulingAlternatives ?? [], score: $0.element.schedulingScore)
    }
  }
  public func validate() throws {
    guard !title.isEmpty, !sessions.isEmpty, sessions.count <= 60,
      Set(sessions.map(\.id)).count == sessions.count,
      Set(constraints.map(\.id)).count == constraints.count,
      ["low", "medium", "high", "critical"].contains(priority)
    else { throw invalid("Invalid draft.") }
    var seen = Set<UUID>()
    for s in sessions {
      guard !s.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !s.actions.isEmpty,
        s.actions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        !s.definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        (5...480).contains(s.duration), (5...480).contains(s.minimumChunk),
        (s.minimumChunk...480).contains(s.maximumChunk),
        ["low", "medium", "high"].contains(s.energyLevel),
        ["flexible", "fixed"].contains(s.flexibility),
        s.dependencies.allSatisfy({ seen.contains($0) }),
        s.preferredEnd == nil || (s.preferredTiming != nil && s.preferredEnd! > s.preferredTiming!),
        s.scheduling?.isValid != false,
        !s.locked || s.scheduledStart != nil
      else { throw invalid("Invalid session: \(s.title)") }
      seen.insert(s.id)
    }
    guard constraints.allSatisfy(\.isValid) else { throw invalid("Invalid planning constraint.") }
  }
}
private func invalid(_ message: String) -> PlanningError { .invalid(message) }

public enum DraftOperationType: String, Codable, Sendable {
  case add_session, update_session, move_session, split_session, merge_sessions, remove_session
  case change_duration, change_priority, change_deadline, add_constraint, remove_constraint
  case lock_session, unlock_session, reschedule_plan
}
public struct SessionUpdate: Codable, Sendable {
  public var title: String?
  public var purpose: String?
  public var actions: [String]?
  public var definitionOfDone: String?
  public var energyLevel: String?
  public var flexibility: String?
  public var splittable: Bool?
  public var minimumChunk: Int?
  public var maximumChunk: Int?
  public var scheduling: SessionSchedulingProperties?
  public init() {}
}
public struct DraftOperation: Codable, Sendable {
  public var type: DraftOperationType
  public var session_id: UUID?
  public var session_ids: [UUID]?
  public var session: DraftSession?
  public var update: SessionUpdate?
  public var children: [DraftSession]?
  public var duration: Int?
  public var priority: String?
  public var deadline: Date?
  public var preferred_start: Date?
  public var preferred_end: Date?
  public var constraint: DraftConstraint?
  public var constraint_id: UUID?
  func validateFields() throws {
    if let duration, !(5...480).contains(duration) { throw invalid("Impossible duration.") }
    let payloads = (children ?? []) + (session.map { [$0] } ?? [])
    guard payloads.count <= 60, payloads.allSatisfy({ (5...480).contains($0.duration) }) else {
      throw invalid("Impossible duration or session count.")
    }
    if let constraint, !constraint.isValid { throw invalid("Invalid scheduling constraint.") }
    if let shape = update?.scheduling, !shape.isValid { throw invalid("Invalid session timing.") }
    let fields: Set<String>
    switch type {
    case .add_session: fields = ["session"]
    case .update_session: fields = ["session_id", "update"]
    case .move_session: fields = ["session_id", "preferred_start", "preferred_end"]
    case .split_session: fields = ["session_id", "children"]
    case .merge_sessions: fields = ["session_ids", "session"]
    case .remove_session, .lock_session, .unlock_session: fields = ["session_id"]
    case .change_duration: fields = ["session_id", "duration"]
    case .change_priority: fields = ["priority"]
    case .change_deadline: fields = ["deadline"]
    case .add_constraint: fields = ["constraint"]
    case .remove_constraint: fields = ["constraint_id"]
    case .reschedule_plan: fields = []
    }
    let object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    guard Set(object.keys).subtracting(["type"]).isSubset(of: fields) else {
      throw invalid("Unexpected fields for operation.")
    }
    if let update {
      let values =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as! [String: Any]
      guard !values.isEmpty else { throw invalid("Empty update.") }
    }
  }
  public init(type: DraftOperationType, session_id: UUID? = nil) {
    self.type = type
    self.session_id = session_id
  }
}
public struct DraftPatch: Codable, Sendable {
  public var message: String
  public var operations: [DraftOperation]
  public init(message: String, operations: [DraftOperation]) {
    self.message = message
    self.operations = operations
  }
  public static func decode(_ text: String) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // Reject misspelled or unsupported operation fields instead of silently ignoring them.
    let data = Data(text.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    let allowed: Set<String> = [
      "type", "session_id", "session_ids", "session", "update", "children", "duration", "priority",
      "deadline", "preferred_start", "preferred_end", "constraint", "constraint_id",
    ]
    guard let root = object as? [String: Any], Set(root.keys) == ["message", "operations"],
      let operations = root["operations"] as? [[String: Any]],
      operations.allSatisfy({ Set($0.keys).isSubset(of: allowed) })
    else { throw invalid("Malformed patch.") }
    let updateKeys: Set<String> = [
      "title", "purpose", "actions", "definitionOfDone", "energyLevel", "flexibility", "splittable",
      "minimumChunk", "maximumChunk", "scheduling",
    ]
    let sessionKeys: Set<String> = [
      "id", "title", "purpose", "duration", "actions", "definitionOfDone", "energyLevel",
      "flexibility", "splittable", "minimumChunk", "maximumChunk", "preferredTiming",
      "preferredEnd", "locked", "scheduledStart", "schedulingExplanation", "dependencies",
      "scheduling",
    ]
    let constraintKeys: Set<String> = [
      "id", "text", "excludedWeekdays", "latestHour", "type", "key", "value", "source", "startDate",
      "expiration", "active",
    ]
    let shapeKeys: Set<String> = [
      "earliestStart", "latestEnd", "preferredDays", "preferredWindows", "location",
      "bufferMinutes", "courseID",
    ]
    let valueKeys: Set<String> = ["weekdays", "startMinute", "endMinute", "minutes", "energy"]
    for operation in operations {
      if let constraint = operation["constraint"] as? [String: Any],
        let value = constraint["value"] as? [String: Any], !Set(value.keys).isSubset(of: valueKeys)
      {
        throw invalid("Unknown constraint value field.")
      }
      let sessions =
        (operation["children"] as? [[String: Any]] ?? [])
        + (operation["session"].flatMap { $0 as? [String: Any] }.map { [$0] } ?? [])
      let shapeContainers =
        sessions + (operation["update"].flatMap { $0 as? [String: Any] }.map { [$0] } ?? [])
      for container in shapeContainers {
        if let shape = container["scheduling"] as? [String: Any] {
          guard Set(shape.keys).isSubset(of: shapeKeys) else {
            throw invalid("Unknown scheduling property.")
          }
          if let windows = shape["preferredWindows"] as? [[String: Any]],
            !windows.allSatisfy({
              Set($0.keys).isSubset(of: ["weekdays", "startMinute", "endMinute"])
            })
          {
            throw invalid("Unknown preferred window field.")
          }
        }
      }
      guard sessions.allSatisfy({ Set($0.keys).isSubset(of: sessionKeys) }) else {
        throw invalid("Unknown session field.")
      }
      if let constraint = operation["constraint"] as? [String: Any],
        !Set(constraint.keys).isSubset(of: constraintKeys)
      {
        throw invalid("Unknown constraint field.")
      }
      if let update = operation["update"] as? [String: Any],
        update.isEmpty || !Set(update.keys).isSubset(of: updateKeys)
      {
        throw invalid("Malformed session update.")
      }
    }
    let patch = try decoder.decode(Self.self, from: data)
    for op in patch.operations { try op.validateFields() }
    return patch
  }
}
public struct DraftChange: Identifiable, Sendable {
  public var id: UUID
  public var before: DraftSession?
  public var after: DraftSession?
}
public struct DraftPatchResult: Sendable {
  public var draft: DraftPlan
  public var changes: [DraftChange]
}
public enum DraftEditor {
  public static func apply(
    _ patch: DraftPatch, to original: DraftPlan, busy: [BusyInterval], from: Date,
    preferences: SchedulingPreferences = .init(), calendar: Calendar = .current
  ) throws -> DraftPatchResult {
    guard !patch.operations.isEmpty, patch.operations.count <= 100 else {
      throw invalid("Empty or oversized patch.")
    }
    var draft = original
    var affected = Set<UUID>()
    for op in patch.operations {
      try op.validateFields()
      let index = op.session_id.flatMap { id in draft.sessions.firstIndex { $0.id == id } }
      let global: Set<DraftOperationType> = [
        .add_session, .merge_sessions, .change_priority, .change_deadline, .add_constraint,
        .remove_constraint, .reschedule_plan,
      ]
      if !global.contains(op.type) {
        guard let index else { throw invalid("Missing target session.") }
        if draft.sessions[index].locked && op.type != .unlock_session {
          throw invalid("Unlock the session explicitly before changing it.")
        }
      }
      switch op.type {
      case .unlock_session: draft.sessions[index!].locked = false
      case .lock_session: draft.sessions[index!].locked = true
      case .update_session:
        guard let u = op.update else { throw invalid("Missing update.") }
        let i = index!
        if let v = u.title { draft.sessions[i].title = v }
        if let v = u.purpose { draft.sessions[i].purpose = v }
        if let v = u.actions { draft.sessions[i].actions = v }
        if let v = u.definitionOfDone { draft.sessions[i].definitionOfDone = v }
        if let v = u.energyLevel { draft.sessions[i].energyLevel = v }
        if let v = u.flexibility { draft.sessions[i].flexibility = v }
        if let v = u.splittable { draft.sessions[i].splittable = v }
        if let v = u.minimumChunk { draft.sessions[i].minimumChunk = v }
        if let v = u.maximumChunk { draft.sessions[i].maximumChunk = v }
        if let v = u.scheduling {
          var shape = draft.sessions[i].scheduling ?? .init()
          if let x = v.earliestStart { shape.earliestStart = x }
          if let x = v.latestEnd { shape.latestEnd = x }
          if let x = v.preferredDays { shape.preferredDays = x }
          if let x = v.preferredWindows { shape.preferredWindows = x }
          if let x = v.location { shape.location = x }
          if let x = v.bufferMinutes { shape.bufferMinutes = x }
          if let x = v.courseID { shape.courseID = x }
          draft.sessions[i].scheduling = shape
        }
        if u.scheduling != nil || u.energyLevel != nil || u.flexibility != nil
          || u.minimumChunk != nil || u.maximumChunk != nil
        {
          affected.insert(draft.sessions[i].id)
          if u.scheduling != nil || u.energyLevel != nil { draft.sessions[i].scheduledStart = nil }
        }
      case .move_session:
        guard let date = op.preferred_start else { throw invalid("Missing preferred start.") }
        draft.sessions[index!].preferredTiming = date
        draft.sessions[index!].preferredEnd = op.preferred_end
        var shape = draft.sessions[index!].scheduling ?? .init()
        shape.earliestStart = date
        shape.latestEnd = op.preferred_end
        draft.sessions[index!].scheduling = shape
        draft.sessions[index!].scheduledStart = nil
        affected.insert(op.session_id!)
      case .change_duration:
        guard let duration = op.duration else { throw invalid("Missing duration.") }
        draft.sessions[index!].duration = duration
        affected.insert(op.session_id!)
      case .remove_session:
        let id = op.session_id!
        guard !draft.sessions.contains(where: { $0.dependencies.contains(id) }) else {
          throw invalid("Remove dependent sessions first.")
        }
        draft.sessions.remove(at: index!)
      case .add_session:
        guard let session = op.session, !session.locked, session.scheduledStart == nil else {
          throw invalid("Invalid new session.")
        }
        draft.sessions.append(session)
        affected.insert(session.id)
      case .split_session:
        let parent = draft.sessions[index!]
        guard parent.splittable, let children = op.children, children.count >= 2,
          children.reduce(0, { $0 + $1.duration }) == parent.duration,
          children.allSatisfy({
            !$0.locked && $0.scheduledStart == nil && $0.duration >= parent.minimumChunk
              && $0.duration <= parent.maximumChunk
          }),
          !children.contains(where: { $0.id == parent.id })
        else { throw invalid("Malformed split: preserve workload and valid chunk sizes.") }
        var parts = children
        for i in parts.indices {
          parts[i].scheduling = inheritedShape(parts[i].scheduling, parents: [parent])
          parts[i].dependencies = i == 0 ? parent.dependencies : [parts[i - 1].id]
        }
        draft.sessions.replaceSubrange(index!...index!, with: parts)
        for i in draft.sessions.indices {
          draft.sessions[i].dependencies = draft.sessions[i].dependencies.map {
            $0 == parent.id ? parts.last!.id : $0
          }
        }
        affected.formUnion(parts.map(\.id))
      case .merge_sessions:
        guard let ids = op.session_ids, Set(ids).count == ids.count, ids.count >= 2,
          let merged = op.session, !merged.locked, merged.scheduledStart == nil
        else { throw invalid("Malformed merge.") }
        let selected = draft.sessions.filter { ids.contains($0.id) }
        guard selected.count == ids.count, !selected.contains(where: \.locked),
          merged.duration == selected.reduce(0, { $0 + $1.duration }),
          !draft.sessions.contains(where: {
            !ids.contains($0.id) && $0.dependencies.contains(where: ids.contains)
          })
        else { throw invalid("Cannot merge locked, missing, or depended-on sessions.") }
        let locations = Set(selected.compactMap { $0.scheduling?.location }.filter { !$0.isEmpty })
        guard locations.count <= 1 else {
          throw invalid("Sessions in different locations cannot be merged.")
        }
        var combined = merged
        combined.scheduling = inheritedShape(merged.scheduling, parents: selected)
        combined.dependencies = Array(
          Set(selected.flatMap(\.dependencies).filter { !ids.contains($0) }))
        draft.sessions.removeAll { ids.contains($0.id) }
        draft.sessions.append(combined)
        affected.insert(combined.id)
      case .change_priority:
        guard let priority = op.priority else { throw invalid("Missing priority.") }
        draft.priority = priority
      case .change_deadline:
        guard let deadline = op.deadline else { throw invalid("Missing deadline.") }
        draft.deadline = deadline
        affected.formUnion(draft.sessions.filter { $0.end == nil || $0.end! > deadline }.map(\.id))
      case .add_constraint:
        guard let constraint = op.constraint else { throw invalid("Missing constraint.") }
        draft.constraints.append(constraint)
        for i in draft.sessions.indices
        where !draft.sessions[i].locked && draft.sessions[i].flexibility != "fixed" {
          affected.insert(draft.sessions[i].id)
          if constraint.type == .soft { draft.sessions[i].scheduledStart = nil }
        }
      case .remove_constraint:
        guard let id = op.constraint_id, draft.constraints.contains(where: { $0.id == id }) else {
          throw invalid("Missing constraint.")
        }
        draft.constraints.removeAll { $0.id == id }
        for i in draft.sessions.indices
        where !draft.sessions[i].locked && draft.sessions[i].flexibility != "fixed" {
          affected.insert(draft.sessions[i].id)
          draft.sessions[i].scheduledStart = nil
        }
      case .reschedule_plan:
        for i in draft.sessions.indices
        where !draft.sessions[i].locked && draft.sessions[i].flexibility != "fixed" {
          affected.insert(draft.sessions[i].id)
          draft.sessions[i].scheduledStart = nil
        }
      }
    }
    for session in original.sessions where session.locked {
      let explicitlyUnlocked = patch.operations.contains {
        $0.type == .unlock_session && $0.session_id == session.id
      }
      if !explicitlyUnlocked && draft.sessions.first(where: { $0.id == session.id }) != session {
        throw invalid("A locked session would be modified indirectly. Unlock it first.")
      }
    }
    try draft.validate()
    // Propagate timing edits only to dependent sessions.
    for s in draft.sessions where s.dependencies.contains(where: affected.contains) {
      affected.insert(s.id)
    }
    draft = try schedule(
      draft, affected: affected, busy: busy, from: from, preferences: preferences,
      calendar: calendar)
    draft.assistantMessages.append(.init(role: "assistant", text: patch.message))
    let ids =
      original.sessions.map(\.id)
      + draft.sessions.filter { s in !original.sessions.contains { $0.id == s.id } }.map(\.id)
    return DraftPatchResult(
      draft: draft,
      changes: ids.compactMap { id in
        let before = original.sessions.first { $0.id == id }
        let after = draft.sessions.first { $0.id == id }
        return before == after ? nil : DraftChange(id: id, before: before, after: after)
      })
  }
  /// Structural edits must not silently discard the parent's hard timing/location requirements.
  private static func inheritedShape(_ child: SessionSchedulingProperties?, parents: [DraftSession])
    -> SessionSchedulingProperties
  {
    var result = child ?? parents.first?.scheduling ?? .init()
    let shapes = parents.compactMap(\.scheduling)
    result.earliestStart =
      (shapes.compactMap(\.earliestStart) + [result.earliestStart].compactMap { $0 }).max()
    result.latestEnd = (shapes.compactMap(\.latestEnd) + [result.latestEnd].compactMap { $0 }).min()
    result.bufferMinutes =
      (shapes.compactMap(\.bufferMinutes) + [result.bufferMinutes].compactMap { $0 }).max()
    if result.location == nil { result.location = shapes.compactMap(\.location).first }
    return result
  }
  public static func schedule(
    _ original: DraftPlan, affected: Set<UUID>, busy: [BusyInterval], from: Date,
    preferences: SchedulingPreferences = .init(), calendar: Calendar = .current
  ) throws -> DraftPlan {
    try original.validate()
    var draft = original
    let scheduler = Scheduler()
    let boundary = min(
      draft.deadline ?? .distantFuture,
      calendar.date(
        byAdding: .day, value: max(1, min(28, preferences.policy.horizonDays)), to: from)!)
    let preserved = draft.sessions.filter { $0.locked || !affected.contains($0.id) }
    func interval(_ session: DraftSession) -> BusyInterval? {
      guard let start = session.scheduledStart, let end = session.end else { return nil }
      return .init(
        start: start, end: end, bufferMinutes: session.scheduling?.bufferMinutes ?? 0,
        location: session.scheduling?.location ?? "", kind: .focus,
        courseID: session.scheduling?.courseID)
    }
    for session in preserved where session.scheduledStart != nil {
      let others = busy + preserved.filter { $0.id != session.id }.compactMap(interval)
      guard
        scheduler.candidate(
          SchedulingTask(session), at: session.scheduledStart!, busy: others,
          from: from, deadline: boundary, preferences: preferences,
          constraints: draft.constraints, calendar: calendar) != nil
      else {
        throw invalid(
          "A preserved session conflicts with a hard scheduling rule or calendar change. Unlock or explicitly reschedule it first."
        )
      }
    }
    var occupied = busy + preserved.compactMap(interval)
    for i in draft.sessions.indices
    where affected.contains(draft.sessions[i].id) && !draft.sessions[i].locked {
      var session = draft.sessions[i]
      let prerequisites = session.dependencies.compactMap { id in
        draft.sessions.first { $0.id == id }
      }
      if prerequisites.contains(where: { $0.end == nil }) {
        session.scheduledStart = nil
        session.schedulingExplanation = "A prerequisite has no available slot."
        session.schedulingReasons = [.init(.dependency, session.schedulingExplanation!)]
        session.schedulingScore = nil
        session.schedulingAlternatives = []
        draft.sessions[i] = session
        continue
      }
      let earliest = max(from, prerequisites.compactMap(\.end).max() ?? from)
      let task = SchedulingTask(session)
      var evaluation = scheduler.rank(
        task, busy: occupied, from: earliest, deadline: boundary,
        preferences: preferences, constraints: draft.constraints, calendar: calendar)
      // A local duration edit preserves an already reviewed slot if still feasible. An explicit
      // reschedule, move or changed preference clears it, and therefore selects the highest score.
      if let start = session.scheduledStart,
        var retained = scheduler.candidate(
          task, at: start,
          busy: occupied, from: earliest, deadline: boundary, preferences: preferences,
          constraints: draft.constraints, calendar: calendar)
      {
        retained.reasons.append(
          .init(.preservedSession, "Keeps the reviewed time during this local edit."))
        evaluation.alternatives =
          ([evaluation.selected].compactMap { $0 } + evaluation.alternatives)
          .filter { $0.start != retained.start }.prefix(preferences.policy.alternativeCount).map {
            $0
          }
        evaluation.selected = retained
      }
      session.scheduledStart = evaluation.selected?.start
      session.schedulingReasons = evaluation.selected?.reasons ?? evaluation.reasons
      session.schedulingAlternatives = evaluation.alternatives
      session.schedulingScore = evaluation.selected?.score
      session.schedulingExplanation =
        evaluation.selected == nil ? evaluation.reasons.map(\.detail).joined(separator: " ") : nil
      if let interval = interval(session) { occupied.append(interval) }
      draft.sessions[i] = session
    }
    for session in draft.sessions {
      if let start = session.scheduledStart,
        session.dependencies.contains(where: { id in
          guard let end = draft.sessions.first(where: { $0.id == id })?.end else { return true }
          return end > start
        })
      {
        throw invalid(
          "A prerequisite would invalidate a preserved session. Unlock or reschedule it explicitly."
        )
      }
    }
    return draft
  }
}
