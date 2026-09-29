import PlannerCore
import SwiftData
import SwiftUI

struct TasksView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @Query private var tasks: [PlannerTask]
  @State private var title = ""
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(
        eyebrow: L("Capture"), title: L("Tasks"),
        subtitle: L("Capture the small things. Turn deeper work into sessions."))
      HStack {
        TextField(L("Add a concrete action…"), text: $title).onSubmit(add)
        Button(L("Add"), action: add).disabled(
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if tasks.isEmpty {
        EmptyState(
          title: L("Nothing loose to hold"),
          text: L("Capture a task here, or use ⌘K to build a plan."),
          icon: "checklist")
      }
      List { ForEach(tasks) { task in TaskRow(task: task) } }
    }.padding(32)
  }
  func add() {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    context.insert(PlannerTask(title))
    title = ""
  }
}
struct TaskRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var task: PlannerTask
  @Environment(\.modelContext) private var context
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    HStack {
      Toggle(task.title, isOn: $task.done).toggleStyle(.checkbox)
      Spacer()
      if task.session == nil {
        Button(L("Make session")) {
          let s = Session(title: task.title, definitionOfDone: task.title)
          s.actions = [Action(task.title)]
          context.insert(s)
          task.session = s
        }.buttonStyle(.borderless)
      } else {
        Text(L("Session created")).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct NotesView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @Query(sort: \Note.updated, order: .reverse) private var notes: [Note]
  @State private var selected: Note?
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    HSplitView {
      VStack(alignment: .leading) {
        HStack {
          Text(L("Notes")).font(.title.bold())
          Spacer()
          Button {
            let note = Note(title: L("Untitled note"))
            context.insert(note)
            selected = note
          } label: {
            Image(systemName: "plus")
          }
        }.padding()
        List(notes, selection: $selected) { note in
          VStack(alignment: .leading, spacing: 4) {
            Text(note.title).font(.headline)
            Text(note.body).lineLimit(2).font(.caption).foregroundStyle(.secondary)
          }.tag(note)
        }
      }.frame(minWidth: 220, idealWidth: 260, maxWidth: 330)
      if let selected {
        NoteEditor(note: selected)
      } else {
        EmptyState(
          title: L("Thoughts that lead somewhere"),
          text: L("Create a note. Capture questions, observations, and next actions."),
          icon: "note.text")
      }
    }.padding(20)
  }
}
struct NoteEditor: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var note: Note
  @Environment(\.modelContext) private var context
  @Query private var courses: [Course]
  @State private var captured = false
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 18) {
      TextField(L("Title"), text: $note.title).font(.title)
      TextEditor(text: $note.body).font(.body).scrollContentBackground(.hidden)
      HStack {
        Button(captured ? L("Task captured") : L("Convert note to task")) {
          context.insert(PlannerTask(note.body.isEmpty ? note.title : note.body))
          captured = true
        }.disabled(captured)
        Button(L("Capture knowledge gap")) {
          context.insert(KnowledgeGap(note.title, course: note.course))
        }
        Menu(L("Link course")) {
          Button(L("None")) { note.course = nil }
          ForEach(courses) { course in Button(course.title) { note.course = course } }
        }
      }
      if let course = note.course {
        Label(course.title, systemImage: "graduationcap").foregroundStyle(.secondary)
      }
    }.padding(24).onChange(of: note.body) {
      note.updated = Date()
      captured = false
    }
  }
}
struct AreaView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let area: String
  @Environment(\.modelContext) private var context
  @Query private var sessions: [Session]
  @Query private var courses: [Course]
  @State private var courseName = ""
  @State private var selected: Course?
  @State private var focus: Session?
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          eyebrow: L("Area of life"), title: L10n.label(area),
          subtitle: area == "Study"
            ? L("Connect classes, deliberate practice, and the gaps you want to close.")
            : L("Make a realistic plan for this part of your life."))
        if area == "Study" {
          HStack {
            TextField(L("Add a course"), text: $courseName)
            Button(L("Add course")) {
              context.insert(Course(courseName))
              courseName = ""
            }.disabled(courseName.isEmpty)
          }
          ForEach(courses) { course in
            Button {
              selected = course
            } label: {
              HStack {
                Label(course.title, systemImage: "graduationcap")
                Spacer()
                Text(course.topic).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
              }.padding()
            }.buttonStyle(.bordered)
          }
        }
        let related = sessions.filter { $0.area == area }
        if related.isEmpty {
          EmptyState(
            title: L("Make space for \(L10n.label(area))"),
            text: L("Use ⌘K to create a plan, or add a session from Today."))
        }
        ForEach(related) { s in SessionRow(session: s) { focus = s } }
      }.padding(32)
    }.sheet(item: $selected) { CourseWorkspace(course: $0) }.sheet(item: $focus) {
      FocusView(session: $0)
    }
  }
}
struct GapRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var gap: KnowledgeGap
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    HStack {
      Text(gap.title)
      Spacer()
      Picker("", selection: $gap.strength) {
        ForEach(["Weak", "Developing", "Strong"], id: \.self) { Text(L10n.label($0)).tag($0) }
      }.frame(width: 150)
    }
  }
}
struct SearchView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let query: String
  @Query private var inbox: [InboxItem]
  @Query private var tasks: [PlannerTask]
  @Query private var plans: [Plan]
  @Query private var notes: [Note]
  @Query private var courses: [Course]
  @Query private var goals: [Goal]
  @Query private var events: [CalendarEvent]
  @Query private var sessions: [Session]
  var matches: [String] {
    var results = inbox.filter { matches($0.title + " " + $0.note) }.map {
      L("Inbox · \($0.title)")
    }
    results += tasks.filter { matches($0.title) }.map { L("Task · \($0.title)") }
    results += plans.filter { matches($0.title) }.map { L("Plan · \($0.title)") }
    results += notes.filter { matches($0.title + " " + $0.body) }.map { L("Note · \($0.title)") }
    results += courses.filter { matches($0.title) }.map { L("Course · \($0.title)") }
    results += goals.filter { matches($0.title) }.map { L("Goal · \($0.title)") }
    results += events.filter { matches($0.title) }.map { L("Event · \($0.title)") }
    results += sessions.filter { matches($0.title) }.map { L("Session · \($0.title)") }
    return results
  }
  func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(query) }
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading) {
      Text(L("Search results")).font(.title).padding()
      List(Array(matches.enumerated()), id: \.offset) { _, text in
        Text(text).textSelection(.enabled)
      }
      if matches.isEmpty {
        EmptyState(
          title: L("No matches"), text: L("Try a course, session, plan, or note title."),
          icon: "magnifyingglass")
      }
    }
  }
}
