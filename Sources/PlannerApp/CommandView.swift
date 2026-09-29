import PlannerCore
import SwiftData
import SwiftUI

struct CommandView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  var initialInput = ""
  var initialArea = "Study"
  var inboxID: UUID?
  var courseID: UUID?
  @EnvironmentObject private var preview: PlanningPreview
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @Query private var events: [CalendarEvent]
  @Query private var sessions: [Session]
  @Query private var profiles: [UserPlanningProfile]
  @Query private var courseSessions: [CourseSession]
  @Query private var inboxItems: [InboxItem]
  @AppStorage("responseTextPath") private var responsePath = "choices.0.message.content"
  @State private var input = ""
  @State private var request = ""
  @State private var loading = false
  @State private var error: String?
  @State private var draft: DraftPlan?
  @State private var changes: [DraftChange] = []
  @State private var previous: DraftPlan?
  @State private var editing: DraftSession?
  @State private var planChanges: [String] = []
  @State private var requestTask: Task<Void, Never>?
  @State private var start = Date()
  @State private var area = "Study"
  private let shortcuts = [
    "Make lighter", "Finish sooner", "Use fewer sessions", "Avoid evenings", "Keep weekend free",
    "Balance workload", "Split long sessions",
  ]
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(L("Planning Workspace"), systemImage: "sparkles").font(.title2.bold())
        Spacer()
        Button(L("Close")) {
          requestTask?.cancel()
          dismiss()
        }
        Button(L("Discard draft"), role: .destructive) {
          requestTask?.cancel()
          preview.clear()
          dismiss()
        }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if loading { ProgressView(L("Updating your draft…")) }
      if let draft {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 12) {
            Text(draft.title).font(.title2)
            Text(draft.goal).foregroundStyle(.secondary)
            Text(L("\(draft.estimatedWorkload) minutes · \(draft.sessions.count) sessions"))
            Text(L("Priority: \(L10n.label(draft.priority))"))
            Text(
              L("Deadline: ")
                + (draft.deadline?.plannerFormatted(date: .abbreviated, time: .shortened)
                  ?? L("None"))
            )
            Text(L("\(draft.sessions.filter(\.locked).count) sessions locked")).font(.caption)
            ForEach(draft.constraints) { constraint in
              Text(L("\(L10n.label(constraint.type.rawValue.capitalized)): \(constraint.text)"))
                .font(.caption)
            }
            Spacer()
            Button(L("Review in Calendar")) {
              preview.destination = "Calendar"
              dismiss()
            }
            Button(L("Undo last change")) {
              if let previous {
                self.draft = previous
                self.previous = nil
                changes = []
                planChanges = []
                sync()
              }
            }.disabled(previous == nil || loading)
            Button(L("Commit final plan")) { commit(draft) }.buttonStyle(.borderedProminent)
              .disabled(loading || draft.sessions.contains { $0.scheduledStart == nil })
          }.frame(width: 205)
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(draft.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                  HStack {
                    Text(session.title).font(.headline)
                    Spacer()
                    Button(L("Edit")) { editing = session }.disabled(loading || session.locked)
                    Button {
                      toggleLock(session)
                    } label: {
                      Label(
                        session.locked ? L("Unlock") : L("Lock"),
                        systemImage: session.locked ? "lock.fill" : "lock.open")
                    }.disabled(loading || session.scheduledStart == nil)
                  }
                  Text(L("\(session.duration) min · \(L10n.label(session.energyLevel)) energy"))
                  Text(
                    session.scheduledStart?.plannerFormatted(date: .abbreviated, time: .shortened)
                      ?? L("Unscheduled")
                  )
                  .foregroundStyle(session.scheduledStart == nil ? .orange : .teal)
                  Text(session.purpose).font(.callout)
                  Text(session.actions.joined(separator: " • ")).font(.callout)
                  Text(L("Done: \(session.definitionOfDone)")).font(.caption)
                  if let explanation = session.schedulingExplanation {
                    Text(L10n.systemText(explanation)).font(.caption).foregroundStyle(.secondary)
                  }
                  if let reasons = session.schedulingReasons, !reasons.isEmpty {
                    DisclosureGroup(L("Why here?")) {
                      VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                          Text(L10n.systemText(reason.detail)).font(.caption)
                        }
                        if let score = session.schedulingScore {
                          Text(L("Candidate score: \(String(format: "%.2f", score))")).font(
                            .caption
                          )
                          .foregroundStyle(.secondary)
                        }
                      }
                    }
                  }
                  if !session.locked, let alternatives = session.schedulingAlternatives,
                    !alternatives.isEmpty
                  {
                    DisclosureGroup(L("Alternatives")) {
                      VStack(alignment: .leading, spacing: 5) {
                        ForEach(alternatives) { alternative in
                          Text(
                            alternative.start.plannerFormatted(date: .abbreviated, time: .shortened)
                              + " · " + String(format: "%.2f", alternative.score)
                          ).font(.caption)
                        }
                        Text(
                          L("Ranked alternatives from this scheduling pass. Recheck before moving.")
                        ).font(.caption).foregroundStyle(.secondary)
                      }
                    }
                  }
                  if changes.contains(where: { $0.id == session.id }) {
                    Text(L("Changed in last edit")).font(.caption.bold()).foregroundStyle(.blue)
                  }
                }.padding().background(
                  .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
              }
              ForEach(planChanges, id: \.self) {
                Text(L10n.systemText($0)).font(.caption).foregroundStyle(.blue)
              }
              if !changes.isEmpty {
                Text(L("Last edit · \(changes.count) sessions changed")).font(.headline)
                ForEach(changes) { change in
                  VStack(alignment: .leading) {
                    Text(change.after?.title ?? change.before?.title ?? L("Session")).bold()
                    Text(L("Before: \(describe(change.before))"))
                    Text(L("After: \(describe(change.after))"))
                  }.font(.caption)
                }
              }
            }
          }.frame(minWidth: 350)
          VStack(alignment: .leading, spacing: 10) {
            Text(L("Planning Copilot")).font(.headline)
            Text(L("Changes apply only to this draft. Lock sessions to keep them unchanged.")).font(
              .caption
            ).foregroundStyle(.secondary)
            ScrollView {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(draft.assistantMessages) { message in
                  VStack(alignment: .leading) {
                    Text(message.role == "user" ? L("You") : L("Copilot")).font(.caption.bold())
                    Text(message.role == "user" ? message.text : L10n.systemText(message.text))
                      .font(.callout).textSelection(.enabled)
                  }.padding(8).background(
                    .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
              }
            }
            Menu(L("Quick adjustments")) {
              ForEach(shortcuts, id: \.self) { text in
                Button(L10n.label(text)) { modify(L10n.label(text)) }
              }
            }.disabled(loading)
            TextField(L("Move Friday’s session…"), text: $request, axis: .vertical).lineLimit(2...5)
            Button(L("Apply to draft")) {
              let text = request
              request = ""
              modify(text)
            }
            .disabled(loading || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }.frame(width: 260)
        }.frame(height: 550)
      } else {
        Text(L("Describe the outcome. Review and edit before saving anything."))
        TextField(L("Review Machine Learning weeks 1–3…"), text: $input, axis: .vertical).lineLimit(
          3...6)
        DatePicker(L("Schedule from"), selection: $start)
        Picker(L("Area"), selection: $area) {
          ForEach(["Study", "Training", "Meals", "Life", "Travel"], id: \.self) {
            Text(L10n.label($0)).tag($0)
          }
        }
        Button(L("Create AI draft")) { generate() }.buttonStyle(.borderedProminent)
          .disabled(loading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: draft == nil ? 710 : 1080)
      .sheet(item: $editing) { session in
        DraftSessionForm(session: session) { updated in
          var update = SessionUpdate()
          update.title = updated.title
          update.purpose = updated.purpose
          update.actions = updated.actions
          update.definitionOfDone = updated.definitionOfDone
          update.energyLevel = updated.energyLevel
          var content = DraftOperation(type: .update_session, session_id: session.id)
          content.update = update
          var operations = [content]
          if updated.duration != session.duration {
            var duration = DraftOperation(type: .change_duration, session_id: session.id)
            duration.duration = updated.duration
            operations.append(duration)
          }
          try apply(
            .init(
              message:
                "Session edited. Other sessions are preserved unless dependencies require a timing change.",
              operations: operations))
        }
      }
      .onAppear {
        draft = preview.draft
        input = preview.draft == nil ? initialInput : preview.input
        area = preview.draft == nil ? initialArea : preview.area
        start = preview.draft == nil ? Date() : preview.start
        if preview.draft == nil {
          preview.inboxID = inboxID
          preview.courseID = courseID ?? inboxItems.first(where: { $0.id == inboxID })?.course?.id
        }
      }.onDisappear { requestTask?.cancel() }
  }
  func describe(_ s: DraftSession?) -> String {
    guard let s else { return L("Absent") }
    return s.title + " · " + s.purpose
      + L(" · \(L10n.label(s.energyLevel)) energy · \(s.duration) min · ")
      + (s.scheduledStart?.plannerFormatted(date: .abbreviated, time: .shortened)
        ?? L("Unscheduled"))
      + " · " + (s.locked ? L("Locked") : L("Unlocked")) + " · " + s.actions.joined(separator: "; ")
      + " · " + s.definitionOfDone
  }
  var preferences: SchedulingPreferences {
    planningPreferences(profiles.first, area: area)
  }
  func busy() -> [BusyInterval] {
    let padding =
      Double(
        max(
          preferences.breakMinutes, events.map(\.bufferMinutes).max() ?? 0,
          sessions.map(\.bufferMinutes).max() ?? 0,
          preferences.travelTimes.map(\.minutes).max() ?? 0)) * 60
    let range = start.addingTimeInterval(-padding)..<start.addingTimeInterval(28 * 86400 + padding)
    let occurrences = CalendarRepository.expand(events, range: range, busyOnly: true)
    let calendarBusy = occurrences.map { occurrence -> BusyInterval in
      let sources = events.filter { $0.remoteID == occurrence.uid && $0.source?.useAsBusy != false }
      let source = sources.count == 1 ? sources.first : nil
      let course = source.flatMap { event in
        courseSessions.first { $0.event?.id == event.id }?.course?.id
      }
      return BusyInterval(
        start: occurrence.start, end: occurrence.end,
        bufferMinutes: sources.map(\.bufferMinutes).max() ?? 0,
        location: occurrence.location, courseID: course)
    }
    return calendarBusy
      + sessions.filter { !["skip", "abandoned"].contains($0.status) }.compactMap { session in
        guard let start = session.start, let end = session.end else { return nil }
        return BusyInterval(
          start: start, end: end, bufferMinutes: session.bufferMinutes,
          location: session.location, kind: session.area == "Training" ? .training : .focus,
          courseID: session.course?.id)
      }
  }
  func scopedContext() throws -> String {
    let situation = try CurrentSituationBuilder(context: context).build(
      now: max(start, Date()), days: 28)
    var info = ContextBuilder.build(situation: situation)
    // The copilot needs availability and profile, never unrelated notes or history.
    info.activePlans = []
    info.pendingSessions = []
    info.deadlines = []
    info.overdueTasks = []
    info.recentlyPostponedSessions = []
    info.recentInbox = []
    info.knowledgeGaps = []
    info.upcomingCourseSessions = info.upcomingCourseSessions.filter { course in
      preview.courseID.map { $0 == course.courseID }
        ?? (draft?.title ?? input).localizedCaseInsensitiveContains(course.course)
    }
    let boundary = draft?.deadline ?? info.rangeEnd
    info.upcomingEvents = info.upcomingEvents.filter { $0.start < boundary && $0.end > start }
    info.freeWindows = info.freeWindows.filter { $0.start < boundary && $0.end > start }
    struct RankingProfile: Encodable {
      var preferredDays: [Int]
      var preferredWindows: [PlanningTimeWindow]
      var lateEveningStartsMinute: Int?
      var postTrainingRecoveryMinutes: Int?
    }
    let p = preferences
    let ranking = RankingProfile(
      preferredDays: p.preferredDays, preferredWindows: p.preferredWindows,
      lateEveningStartsMinute: p.lateEveningStartsMinute,
      postTrainingRecoveryMinutes: p.postTrainingRecoveryMinutes)
    let rankingJSON = String(decoding: try JSONEncoder().encode(ranking), as: UTF8.self)
    return try info.serialized() + "\nExplicit scheduling preferences:\n" + rankingJSON
  }
  func sync() {
    preview.draft = draft
    preview.suggestions = draft?.suggestions ?? []
    preview.input = input
    preview.area = area
    preview.start = start
  }
  func generate() {
    loading = true
    error = nil
    requestTask = Task {
      defer { loading = false }
      do {
        let result = try await AIService().plan(
          input: input, context: scopedContext(),
          outputLanguage: L10n.language.resolved() == .simplifiedChinese
            ? "Simplified Chinese" : "English",
          configuration: .init(key: KeychainStore.read(), responseTextPath: responsePath))
        try Task.checkCancellation()
        var value = DraftPlan(result)
        if let courseID = preview.courseID {
          for index in value.sessions.indices {
            var shape = value.sessions[index].scheduling ?? .init()
            shape.courseID = courseID
            value.sessions[index].scheduling = shape
          }
        }
        draft = try DraftEditor.schedule(
          value, affected: Set(value.sessions.map(\.id)), busy: busy(), from: max(start, Date()),
          preferences: preferences)
        sync()
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  func modify(_ text: String) {
    guard let draft else { return }
    loading = true
    error = nil
    requestTask = Task {
      defer { loading = false }
      do {
        let patch = try await AIService().patch(
          input: text, draft: draft, context: scopedContext(),
          outputLanguage: L10n.language.resolved() == .simplifiedChinese
            ? "Simplified Chinese" : "English",
          configuration: .init(key: KeychainStore.read(), responseTextPath: responsePath))
        try Task.checkCancellation()
        try apply(patch, userText: text)
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  func apply(_ patch: DraftPatch, userText: String? = nil) throws {
    guard var current = draft else { return }
    let before = current
    if patch.operations.isEmpty {
      if let userText { current.assistantMessages.append(.init(role: "user", text: userText)) }
      current.assistantMessages.append(.init(role: "assistant", text: patch.message))
      draft = current
      sync()
      return
    }
    if let userText { current.assistantMessages.append(.init(role: "user", text: userText)) }
    let result = try DraftEditor.apply(
      patch, to: current, busy: busy(), from: max(start, Date()), preferences: preferences)
    planChanges = []
    if before.deadline != result.draft.deadline {
      planChanges.append(
        L("Deadline: ")
          + (before.deadline?.plannerFormatted(date: .abbreviated, time: .shortened) ?? L("None"))
          + " → "
          + (result.draft.deadline?.plannerFormatted(date: .abbreviated, time: .shortened)
            ?? L("None"))
      )
    }
    if before.priority != result.draft.priority {
      planChanges.append("Priority: \(before.priority) → \(result.draft.priority)")
    }
    for c in result.draft.constraints where !before.constraints.contains(c) {
      planChanges.append("Added constraint: " + c.text)
    }
    for c in before.constraints where !result.draft.constraints.contains(c) {
      planChanges.append("Removed constraint: " + c.text)
    }
    previous = before
    draft = result.draft
    changes = result.changes
    sync()
  }
  func toggleLock(_ session: DraftSession) {
    do {
      try apply(
        .init(
          message: session.locked
            ? "Session unlocked." : "Session locked. Later changes will preserve it.",
          operations: [
            .init(type: session.locked ? .unlock_session : .lock_session, session_id: session.id)
          ]))
    } catch { self.error = error.localizedDescription }
  }
  func commit(_ draft: DraftPlan) {
    do {
      try DraftCommitter.commit(
        draft, area: area, busy: busy(), context: context,
        inboxItem: inboxItems.first(where: { $0.id == preview.inboxID }),
        course: try context.fetch(FetchDescriptor<Course>()).first(where: { $0.id == preview.courseID }),
        preferences: preferences)
      preview.clear()
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
private struct DraftSessionForm: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @State var session: DraftSession
  let save: (DraftSession) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var error: String?
  var body: some View {
    let _ = appLanguage
    Form {
      Text(L("Edit draft session")).font(.title2)
      TextField(L("Title"), text: $session.title)
      TextField(L("Purpose"), text: $session.purpose)
      Stepper(
        L("Duration: \(session.duration) minutes"), value: $session.duration, in: 5...480, step: 5)
      TextField(
        L("Actions (one per line)"),
        text: Binding(
          get: { session.actions.joined(separator: "\n") },
          set: { session.actions = $0.components(separatedBy: "\n") }), axis: .vertical
      ).lineLimit(3...8)
      TextField(L("Definition of done"), text: $session.definitionOfDone, axis: .vertical)
      Picker(L("Energy"), selection: $session.energyLevel) {
        ForEach(["low", "medium", "high"], id: \.self) { Text(L10n.label($0)).tag($0) }
      }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button(L("Cancel")) { dismiss() }
        Button(L("Save draft changes")) {
          do {
            try save(session)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent)
      }
    }.padding(24).frame(width: 520)
  }
}

struct SettingsView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @Query private var profiles: [UserPlanningProfile]
  @State private var key = ""
  @State private var message = ""
  @AppStorage("responseTextPath") private var path = "choices.0.message.content"
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    Form {
      Section(L("Language")) {
        Picker(L("App language"), selection: $appLanguage) {
          Text(L("Follow system")).tag("system")
          Text("English").tag("en")
          Text("简体中文").tag("zh-Hans")
        }
        Text(L("Language changes apply immediately. Your existing content stays unchanged."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(L("Planning API")) {
        Text("api.ia.limos.fr · general_nothink").font(.headline)
        SecureField(L("API key"), text: $key)
        TextField(L("Response text path"), text: $path)
        Button(L("Save key to Keychain")) {
          do {
            try KeychainStore.save(key)
            key = ""
            message = L("Credential saved.")
          } catch { message = error.localizedDescription }
        }
        Text(message).font(.caption)
        Text(
          L(
            "Requests use the supplied API contract. The response path was verified against a live response. Keys are never stored in the database."
          )
        ).font(.caption).foregroundStyle(.secondary)
      }
      if let profile = profiles.first {
        ProactivitySettings(profile: profile)
        PreferencesForm(profile: profile)
      }
    }.formStyle(.grouped).navigationTitle(L("Settings")).task {
      if profiles.isEmpty { context.insert(UserPlanningProfile()) }
    }
  }
}
struct PreferencesForm: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var profile: UserPlanningProfile
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    Section(L("Availability & capacity")) {
      Stepper(
        L("Day starts: \(profile.startHour):00"), value: $profile.startHour,
        in: 0...max(0, profile.endHour - 1))
      Stepper(
        L("Day ends: \(profile.endHour):00"), value: $profile.endHour,
        in: min(24, profile.startHour + 1)...24)
      Stepper(
        L("Daily capacity: \(profile.dailyMinutes) min"), value: $profile.dailyMinutes,
        in: 30...720,
        step: 30)
      Stepper(
        L("Maximum session: \(profile.maxSessionMinutes) min"), value: $profile.maxSessionMinutes,
        in: 15...240, step: 15)
      Stepper(
        L("Break: \(profile.breakMinutes) min"), value: $profile.breakMinutes, in: 0...60, step: 5)
    }
    Section(L("Scheduling preferences (soft)")) {
      Text(
        L(
          "Optional preferences rank feasible times. They never override availability, locks or deadlines."
        )
      ).font(.caption)
      Toggle(
        L("Prefer a focus window"),
        isOn: Binding(
          get: { profile.preferredStartHour != nil },
          set: { enabled in
            profile.preferredStartHour = enabled ? profile.startHour : nil
            profile.preferredEndHour = enabled ? min(profile.endHour, profile.startHour + 3) : nil
          }))
      if profile.preferredStartHour != nil {
        Stepper(
          L("Preferred start: \(profile.preferredStartHour ?? 9):00"),
          value: Binding(
            get: { profile.preferredStartHour ?? 9 }, set: { profile.preferredStartHour = $0 }),
          in: 0...max(0, (profile.preferredEndHour ?? 12) - 1))
        Stepper(
          L("Preferred end: \(profile.preferredEndHour ?? 12):00"),
          value: Binding(
            get: { profile.preferredEndHour ?? 12 }, set: { profile.preferredEndHour = $0 }),
          in: min(24, (profile.preferredStartHour ?? 9) + 1)...24)
      }
      HStack {
        Text(L("Preferred days"))
        ForEach(1...7, id: \.self) { day in
          Toggle(
            L10n.calendar.shortWeekdaySymbols[day - 1],
            isOn: Binding(
              get: { profile.preferredWeekdays.contains(day) },
              set: { enabled in
                profile.preferredWeekdays.removeAll { $0 == day }
                if enabled { profile.preferredWeekdays.append(day) }
              })
          ).toggleStyle(.button)
        }
      }
      Toggle(
        L("Prefer to avoid late work"),
        isOn: Binding(
          get: { profile.lateEveningStartsHour != nil },
          set: {
            profile.lateEveningStartsHour = $0 ? max(profile.startHour, profile.endHour - 2) : nil
          }))
      if profile.lateEveningStartsHour != nil {
        Stepper(
          L("Late work starts: \(profile.lateEveningStartsHour ?? 19):00"),
          value: Binding(
            get: { profile.lateEveningStartsHour ?? 19 },
            set: { profile.lateEveningStartsHour = $0 }), in: 0...23)
      }
      Stepper(
        L(
          "Recovery before high-energy work after training: \(profile.trainingRecoveryMinutes) min"),
        value: $profile.trainingRecoveryMinutes, in: 0...240, step: 15)
    }
  }
}
