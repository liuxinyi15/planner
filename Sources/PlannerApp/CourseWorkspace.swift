import PlannerCore
import SwiftData
import SwiftUI

struct CourseWorkspace: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var course: Course
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var preview: PlanningPreview
  @Query private var events: [CalendarEvent]
  @Query private var links: [CourseSession]
  @Query private var sessions: [Session]
  @Query private var plans: [Plan]
  @Query private var notes: [Note]
  @Query private var inbox: [InboxItem]
  @Query private var gaps: [KnowledgeGap]
  @Query private var records: [ExecutionRecord]
  @State private var editingFocus = false
  @State private var focusText = ""
  @State private var assessmentEditor = false
  @State private var gapTitle = ""
  @State private var allClasses = false
  @State private var error: String?
  @State private var proposal: CourseStudyProposal?
  @State private var focusSession: Session?
  @State private var selectedNote: Note?
  @State private var importMaterial = false
  @State private var planning = false
  @State private var now = Date()
  var body: some View {
    let _ = appLanguage
    let summary = CourseSummaryService.build(course: course, events: events, links: links, sessions: sessions,
      plans: plans, notes: notes, inbox: inbox, gaps: gaps, records: records, now: now)
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(course.title).font(.title.bold())
          if !course.moduleCode.isEmpty { Text(course.moduleCode).font(.subheadline.monospaced()).foregroundStyle(.secondary) }
        }
        Spacer()
        Button(L("Done")) { dismiss() }
      }
      if let error { Text(error).foregroundStyle(.red) }
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(alignment: .top, spacing: 18) {
            classCard(L("Next class"), value: summary.nextClass)
            classCard(L("Next tutorial / lab"), value: summary.nextPractical)
          }
          VStack(alignment: .leading, spacing: 10) {
            Text(L("This week")).font(.headline)
            Text((summary.classesThisWeek.keys.sorted().map { L("\(summary.classesThisWeek[$0] ?? 0) \(L10n.label($0))") }
              + [L("\(summary.studiesThisWeek) study sessions")]).joined(separator: " · "))
          }
          if let action = summary.suggestedAction {
            VStack(alignment: .leading, spacing: 10) {
              Text(L("Suggested next action")).font(.headline).foregroundStyle(.teal)
              Text(action.title).font(.title3.bold())
              Text(action.reason).foregroundStyle(.secondary)
              HStack {
                Text(L("\(action.minutes) minutes"))
                Spacer()
                Button(L("Arrange")) {
                  perform {
                    let start = try CourseSummaryService.suggestedStart(action: action, course: course, context: context)
                    proposal = .init(action: action, start: start)
                  }
                }.buttonStyle(.borderedProminent)
              }
            }.padding(18).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
          }
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(L("Current focus")).font(.headline)
              Spacer()
              Button(L("Edit")) { focusText = course.currentFocus.isEmpty ? course.topic : course.currentFocus; editingFocus = true }
            }
            if summary.focus.isEmpty {
              Text(L("A focus will emerge from your imported material or linked study sessions.")).foregroundStyle(.secondary)
            } else {
              Text(summary.focus)
              Text(summary.focusSource).font(.caption).foregroundStyle(.secondary)
            }
          }
          assessmentsSection(summary)
          VStack(alignment: .leading, spacing: 12) {
            Text(L("Pending study work")).font(.headline)
            if summary.pendingStudies.isEmpty {
              Text(L("No pending study sessions linked yet.")).foregroundStyle(.secondary)
            }
            ForEach(summary.pendingStudies.prefix(5)) { session in
              SessionRow(session: session) { focusSession = session }
            }
            if summary.pendingStudies.count > 5 {
              DisclosureGroup(L("View all pending study work")) {
                ForEach(Array(summary.pendingStudies.dropFirst(5))) { session in
                  SessionRow(session: session) { focusSession = session }
                }
              }
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            Text(L("Needs attention")).font(.headline)
            ForEach(summary.gaps) { GapRow(gap: $0) }
            let unfinished = summary.pendingStudies.filter { $0.status == "partial" || ($0.end ?? .distantFuture) < now }
            ForEach(unfinished) { session in
              Text(L("Review unfinished work: \(session.title)")).foregroundStyle(.orange)
            }
            if summary.gaps.isEmpty && unfinished.isEmpty { Text(L("Nothing flagged right now.")).foregroundStyle(.secondary) }
            DisclosureGroup(L("Add something to revisit")) {
              HStack {
                TextField(L("Topic to work on"), text: $gapTitle)
                Button(L("Add")) { perform { context.insert(KnowledgeGap(gapTitle, course: course)); try context.save(); gapTitle = "" } }
                  .disabled(gapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }
            }
          }
          timetableSection(summary)
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(L("Plans for this course")).font(.headline)
              Spacer()
              Button(L("Make a study plan")) { planning = true }.disabled(preview.draft != nil)
            }
            Text(L("A course is the learning context. Each plan is a specific objective.")).font(.caption).foregroundStyle(.secondary)
            ForEach(summary.plans) { plan in
              VStack(alignment: .leading) { Text(plan.title).bold(); Text(plan.purpose).font(.caption).foregroundStyle(.secondary) }
            }
          }
          DisclosureGroup(L("Study material & notes")) {
            VStack(alignment: .leading, spacing: 12) {
              Button(L("Import study material")) { importMaterial = true }
              Button(L("Add note")) {
                perform {
                  let note = Note(title: L("Untitled note")); note.course = course
                  context.insert(note); try context.save(); selectedNote = note
                }
              }
              ForEach(summary.importedMaterial) { item in
                VStack(alignment: .leading) { Text(item.title).bold(); Text(item.note).font(.caption).lineLimit(4) }
              }
              ForEach(summary.notes) { note in Button(note.title) { selectedNote = note } }
            }.padding(.top, 10)
          }
          DisclosureGroup(L("Execution history")) {
            Text(L("\(summary.executionCount) execution records · \(summary.actualMinutes) actual minutes"))
          }
        }.padding(.vertical, 8)
      }
    }.padding(28).frame(width: 820, height: 740)
      .sheet(isPresented: $editingFocus) {
        VStack(alignment: .leading, spacing: 16) {
          Text(L("Current focus")).font(.title2)
          TextField(L("Current focus"), text: $focusText, axis: .vertical)
          HStack {
            Button(L("Cancel")) { editingFocus = false }
            Button(L("Save")) {
              perform { course.currentFocus = focusText; course.topic = focusText; try context.save(); editingFocus = false }
            }
          }
        }.padding(24).frame(width: 500)
      }
      .sheet(isPresented: $assessmentEditor) { CourseAssessmentEditor(course: course) }
      .sheet(isPresented: $allClasses) {
        VStack(alignment: .leading, spacing: 16) {
          HStack { Text(L("All classes")).font(.title2); Spacer(); Button(L("Done")) { allClasses = false } }
          Text(L("Previous 4 weeks and next 12 weeks. Repeated classes are expanded locally.")).font(.caption).foregroundStyle(.secondary)
          List(summary.classes.sorted { a, b in
            let aFuture = a.end > now; let bFuture = b.end > now
            if aFuture != bFuture { return aFuture }
            return aFuture ? a.start < b.start : a.start > b.start
          }) { value in
            VStack(alignment: .leading) {
              Text(L10n.label(value.kind)).font(.headline)
              Text(value.start.plannerFormatted(date: .abbreviated, time: .shortened))
              if !value.location.isEmpty { Text(value.location).font(.caption) }
            }
          }
        }.padding(24).frame(width: 650, height: 560)
      }
      .sheet(item: $proposal) { value in
        let existing = sessions.first { $0.id == value.action.sessionID }
        SessionEditor(existing: existing, suggestedStart: value.start,
          resumeOnSave: true, suggestedTitle: existing == nil ? value.action.title : nil,
          suggestedPurpose: existing == nil ? value.action.reason : nil,
          suggestedMinutes: existing == nil ? value.action.minutes : nil, suggestedCourse: course)
      }
      .sheet(item: $focusSession) { FocusView(session: $0) }
      .sheet(item: $selectedNote) { note in
        VStack { HStack { Spacer(); Button(L("Done")) { selectedNote = nil } }.padding(); NoteEditor(note: note) }.frame(width: 720, height: 560)
      }
      .sheet(isPresented: $planning) { CommandView(initialInput: course.title + "\n" + summary.focus, initialArea: "Study", courseID: course.id) }
      .sheet(isPresented: $importMaterial) { SmartImportView(targetCourse: course) }
      .task {
        while !Task.isCancelled {
          now = Date()
          do { try await Task.sleep(for: .seconds(60)) } catch { break }
        }
      }
  }
  private func classCard(_ title: String, value: CourseClass?) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.headline)
      if let value {
        Text(value.start.plannerFormatted(date: .abbreviated, time: .shortened)).font(.title3)
        Text(L10n.label(value.kind)).foregroundStyle(.teal)
        if !value.location.isEmpty { Text(value.location).font(.caption).foregroundStyle(.secondary) }
      } else { Text(L("No upcoming class found.")).foregroundStyle(.secondary) }
    }.frame(maxWidth: .infinity, minHeight: 95, alignment: .topLeading).padding(16)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
  }
  private func assessmentsSection(_ summary: CourseSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        if !summary.assessments.isEmpty { Text(L("Assessments & deadlines")).font(.headline) }
        Spacer()
        Button(L("Add Assessment")) { assessmentEditor = true }
      }
      ForEach(summary.assessments) { value in
        HStack {
          VStack(alignment: .leading) {
            Text(value.title).bold()
            if let date = value.deadline {
              Text(date.plannerFormatted(date: .abbreviated, time: .shortened)).foregroundStyle(date < now ? .orange : .secondary)
            }
            if !value.notes.isEmpty { Text(value.notes).font(.caption).foregroundStyle(.secondary) }
          }
          Spacer()
          if course.assessments.contains(where: { $0.id == value.id }) {
            Button(L("Mark complete")) {
              perform {
                var values = course.assessments
                if let index = values.firstIndex(where: { $0.id == value.id }) { values[index].completed = true }
                try course.setAssessments(values); try context.save()
              }
            }
          }
        }
      }
    }
  }
  private func timetableSection(_ summary: CourseSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack { Text(L("Weekly timetable pattern")).font(.headline); Spacer(); Button(L("View all classes")) { allClasses = true } }
      Text(L("Class counts cover the next 12 weeks.")).font(.caption).foregroundStyle(.secondary)
      ForEach(summary.patterns) { pattern in
        HStack {
          Text(L10n.label(pattern.kind)).bold().frame(width: 100, alignment: .leading)
          Text(L10n.calendar.weekdaySymbols[pattern.weekday - 1] + " · " + String(format: "%02d:%02d", pattern.minute / 60, pattern.minute % 60))
          Spacer()
          Text(L("\(pattern.count) upcoming")).foregroundStyle(.secondary)
        }
      }
      if summary.patterns.isEmpty { Text(L("Accept a timetable match in Courses to connect classes.")).foregroundStyle(.secondary) }
    }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action(); error = nil } catch { context.rollback(); self.error = error.localizedDescription }
  }
}
private struct CourseStudyProposal: Identifiable {
  let id = UUID()
  var action: CourseNextAction
  var start: Date
}
private struct CourseAssessmentEditor: View {
  let course: Course
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var hasDate = true
  @State private var deadline = Date()
  @State private var notes = ""
  @State private var error: String?
  var body: some View {
    Form {
      Text(L("Add Assessment")).font(.title2)
      TextField(L("Title"), text: $title)
      Toggle(L("Has a deadline"), isOn: $hasDate)
      if hasDate { DatePicker(L("Deadline"), selection: $deadline) }
      TextField(L("Notes"), text: $notes, axis: .vertical)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button(L("Cancel")) { dismiss() }
        Button(L("Save")) {
          do {
            try course.setAssessments(course.assessments + [.init(title: title, deadline: hasDate ? deadline : nil, notes: notes)])
            try context.save(); dismiss()
          } catch { context.rollback(); self.error = error.localizedDescription }
        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 520)
  }
}
