import PlannerCore
import SwiftData
import SwiftUI

struct SessionRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var session: Session
  @Environment(\.modelContext) private var context
  @State private var editing = false
  @State private var feedback: ExecutionRecord?
  @State private var saveError: String?
  var start: () -> Void
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    HStack(spacing: 16) {
      Image(
        systemName: session.status == "complete"
          ? "checkmark.circle.fill" : (session.status == "skip" ? "minus.circle" : "circle")
      ).font(.title3).foregroundStyle(session.status == "complete" ? .teal : .secondary)
      Text(session.start?.plannerFormatted(date: .omitted, time: .shortened) ?? L("Anytime")).font(
        .callout.monospacedDigit()
      ).frame(width: 70, alignment: .leading)
      VStack(alignment: .leading, spacing: 5) {
        Text(session.title).font(.headline)
        Text(
          L(
            "\(L10n.label(session.area)) · \(session.minutes) min · \(L10n.label(session.priority))"
          )
        ).font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(L10n.label(session.status)).font(.caption).foregroundStyle(.secondary)
      Button(L("Open"), action: start).buttonStyle(.borderless)
      Menu {
        Button(L("Edit / reschedule")) { editing = true }
        Button(L("Tomorrow")) { postpone(days: 1) }
        Button(L("Later this week")) { postpone(days: 3) }
        Button(L("Skip")) { record("skip") }
        Button(L("Abandon")) { record("abandoned") }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).frame(width: 24)
    }.padding(16).background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
      .sheet(isPresented: $editing) { SessionEditor(existing: session) }
      .sheet(item: $feedback) { ExecutionFeedbackView(record: $0) }
      .alert(
        L("Could not save execution"),
        isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button(L("OK")) { saveError = nil }
      } message: {
        Text(saveError ?? "")
      }
  }
  func postpone(days: Int) {
    let entry = ExecutionRecord(session: session, actual: 0, status: "postponed")
    context.insert(entry)
    session.start = Calendar.current.date(
      byAdding: .day, value: days, to: max(Date(), session.start ?? Date()))
    session.postponedCount += 1
    session.status = "planned"
    session.startedAt = nil
    do {
      try context.save()
      if entry.offersFeedback { feedback = entry }
    } catch {
      context.rollback()
      saveError = error.localizedDescription
    }
  }
  func record(_ status: String) {
    guard session.status != status else { return }
    let entry = ExecutionRecord(session: session, actual: 0, status: status)
    context.insert(entry)
    session.status = status
    session.startedAt = nil
    do {
      try context.save()
      if entry.offersFeedback { feedback = entry }
    } catch {
      context.rollback()
      saveError = error.localizedDescription
    }
  }
}
struct SessionEditor: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  var existing: Session?
  var initialPlan: Plan?
  var suggestedStart: Date?
  var resumeOnSave = false
  var suggestedTitle: String?
  var suggestedPurpose: String?
  var suggestedMinutes: Int?
  var suggestedCourse: Course?
  var onSaved: (() -> Void)?
  @State private var showDetails = false
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var purpose = ""
  @State private var done = ""
  @State private var actions = ""
  @State private var minutes = 60
  @State private var date = Date()
  @State private var area = "Study"
  @State private var priority = "Should"
  @State private var energy = "unknown"
  @State private var scheduled = true
  @State private var error: String?
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 20) {
      Text(existing == nil ? L("Create a meaningful session") : L("Adjust session")).font(
        .title2.bold())
      Form {
        TextField(L("Title"), text: $title)
        DisclosureGroup(L("Details"), isExpanded: $showDetails) {
          TextField(L("Purpose"), text: $purpose)
          TextField(L("Done means"), text: $done)
          TextField(L("Actions (one per line)"), text: $actions, axis: .vertical).lineLimit(3...8)
          Picker(L("Area"), selection: $area) {
            ForEach(["Study", "Training", "Meals", "Life", "Travel"], id: \.self) {
              Text(L10n.label($0)).tag($0)
            }
          }
          Picker(L("Energy requirement"), selection: $energy) {
            ForEach(["unknown", "low", "medium", "high"], id: \.self) {
              Text(L10n.label($0)).tag($0)
            }
          }
          Picker(L("Priority"), selection: $priority) {
            ForEach(["Must", "Should", "Optional"], id: \.self) { Text(L10n.label($0)).tag($0) }
          }
        }
        Stepper(L("\(minutes) minutes"), value: $minutes, in: 5...480, step: 5)
        Toggle(L("Schedule"), isOn: $scheduled)
        if scheduled { DatePicker(L("Start"), selection: $date) }
      }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button(L("Cancel")) { dismiss() }
        Spacer()
        Button(L("Save session")) { save() }.buttonStyle(.borderedProminent).disabled(
          title.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }.padding(28).frame(width: 550).onAppear {
      if let s = existing {
        title = s.title
        purpose = s.purpose
        done = s.definitionOfDone
        actions = s.actions.map(\.title).joined(separator: "\n")
        minutes = s.minutes
        date = s.start ?? Date()
        scheduled = s.start != nil
        area = s.area
        priority = s.priority
        energy = s.energyRequirement
      }
      if let suggestedStart {
        date = suggestedStart
        scheduled = true
      }
      if let suggestedTitle { title = suggestedTitle }
      if let suggestedPurpose { purpose = suggestedPurpose }
      if let suggestedMinutes { minutes = suggestedMinutes }
      if suggestedCourse != nil { area = "Study" }
    }
  }
  func save() {
    let session = existing ?? Session(title: title)
    if existing == nil { context.insert(session) }
    if let initialPlan { session.plan = initialPlan; session.course = initialPlan.course }
    if let suggestedCourse { session.course = suggestedCourse }
    if resumeOnSave {
      session.status = "planned"
      session.startedAt = nil
    }
    session.title = title
    session.purpose = purpose
    session.definitionOfDone = done
    session.minutes = minutes
    session.start = scheduled ? date : nil
    session.area = area
    session.priority = priority
    session.energyRequirement = energy
    let titles = actions.split(separator: "\n").map(String.init)
    if titles != session.actions.map(\.title) {
      session.actions.forEach { context.delete($0) }
      session.actions = titles.map(Action.init)
    }
    do {
      try context.save()
      onSaved?()
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
struct FocusView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var session: Session
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @State private var notes = ""
  @State private var actual = 0
  @State private var feedback: ExecutionRecord?
  @State private var finished = false
  @State private var error: String?
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 22) {
      PageHeader(eyebrow: L("Focus session"), title: session.title, subtitle: session.purpose)
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        let elapsed =
          session.startedAt.map { max(0, Int(timeline.date.timeIntervalSince($0))) } ?? 0
        Text(
          L(
            "\(max(0,session.minutes*60-elapsed)/60):\(String(format:"%02d",max(0,session.minutes*60-elapsed)%60))"
          )
        ).font(.system(size: 48, weight: .light, design: .monospaced)).foregroundStyle(.teal)
      }
      ForEach(session.actions) { action in ActionToggle(action: action) }
      Label(
        session.definitionOfDone.isEmpty
          ? L("Define your completion criteria in Edit session.") : session.definitionOfDone,
        systemImage: "flag.checkered"
      ).foregroundStyle(.secondary)
      TextField(L("Session notes or follow-up thoughts"), text: $notes, axis: .vertical).lineLimit(
        3...5)
      HStack {
        Button(L("Save as note")) {
          let n = Note(title: session.title, body: notes)
          n.session = session
          context.insert(n)
          notes = ""
        }.disabled(notes.isEmpty)
        Button(L("Create follow-up task")) {
          context.insert(PlannerTask(notes))
          notes = ""
        }.disabled(notes.isEmpty)
      }
      Stepper(L("Actual time: \(actual) min (0 uses timer)"), value: $actual, in: 0...1440, step: 5)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button(L("Close")) { dismiss() }
        Spacer()
        Button(L("Abandon")) { finish("abandoned") }.disabled(cannotFinish)
        Button(L("Partial")) { finish("partial") }.disabled(cannotFinish)
        Button(L("Complete"), systemImage: "checkmark") { finish("complete") }.buttonStyle(
          .borderedProminent
        ).disabled(cannotFinish)
      }
    }.padding(32).frame(width: 620)
      .sheet(item: $feedback, onDismiss: { dismiss() }) { ExecutionFeedbackView(record: $0) }
      .onAppear {
        if session.startedAt == nil && !["complete", "skip", "abandoned"].contains(session.status) {
          session.startedAt = Date()
        }
      }
  }
  var cannotFinish: Bool { finished || ["complete", "skip", "abandoned"].contains(session.status) }
  func finish(_ status: String) {
    let measured = max(1, Int(Date().timeIntervalSince(session.startedAt ?? Date()) / 60))
    guard !cannotFinish else { return }
    if status == "complete" { session.actions.forEach { $0.completed = true } }
    let entry = ExecutionRecord(
      session: session, actual: actual > 0 ? actual : measured, status: status, notes: notes)
    context.insert(entry)
    session.status = status
    session.startedAt = nil
    do {
      try context.save()
      finished = true
      if entry.offersFeedback { feedback = entry } else { dismiss() }
    } catch {
      context.rollback()
      self.error = error.localizedDescription
    }
  }
}
struct ActionToggle: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var action: Action
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    Toggle(action.title, isOn: $action.completed).toggleStyle(.checkbox)
  }
}
