import PlannerCore
import SwiftData
import SwiftUI

struct InboxView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @Query(sort: \InboxItem.created, order: .reverse) private var items: [InboxItem]
  @State private var title = ""
  @State private var note = ""
  @State private var area = "Life"
  @State private var details = false
  @State private var filter = "unprocessed"
  @State private var library: String?
  @State private var error: String?
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(
        eyebrow: L("Capture first, decide later"), title: L("Inbox"),
        subtitle: L("Put it here. You don't need a plan yet."))
      HStack {
        TextField(L("What's on your mind?"), text: $title).onSubmit(add)
        Button(L("Add"), action: add).buttonStyle(.borderedProminent).disabled(
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      DisclosureGroup(L("Add details"), isExpanded: $details) {
        TextField(L("Optional note"), text: $note, axis: .vertical).lineLimit(2...4)
        ContextPicker(area: $area)
      }
      HStack {
        Picker(L("Status"), selection: $filter) {
          ForEach(["unprocessed", "someday", "processed", "archived"], id: \.self) {
            Text(L10n.label($0)).tag($0)
          }
        }.pickerStyle(.segmented)
        Menu(L("Saved items")) {
          Button(L("Tasks")) { library = "Tasks" }
          Button(L("Notes")) { library = "Notes" }
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
      let visible = items.filter { $0.status == filter }
      if visible.isEmpty {
        EmptyState(
          title: L("Nothing waiting here"),
          text: L("Capture an intention above, or find existing tasks and notes in Saved items."),
          icon: "tray")
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(visible) { item in InboxRow(item: item) }
        }
      }
    }.padding(32).sheet(
      isPresented: Binding(get: { library != nil }, set: { if !$0 { library = nil } })
    ) {
      VStack {
        HStack {
          Spacer()
          Button(L("Done")) { library = nil }
        }.padding()
        if library == "Tasks" { TasksView() } else { NotesView() }
      }.frame(width: 820, height: 600)
    }
  }
  private func add() {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    let item = InboxItem(title: clean, note: note, area: area)
    context.insert(item)
    do {
      try context.save()
      title = ""
      note = ""
      filter = "unprocessed"
      error = nil
    } catch {
      context.delete(item)
      self.error = error.localizedDescription
    }
  }
}

struct ContextPicker: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Binding var area: String
  var body: some View {
    let _ = appLanguage
    Picker(L("Context"), selection: $area) {
      ForEach(["Study", "Training", "Meals", "Life", "Travel"], id: \.self) {
        Text(L10n.label($0)).tag($0)
      }
    }
  }
}

struct InboxRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @EnvironmentObject private var preview: PlanningPreview
  @Bindable var item: InboxItem
  @State private var expanded = false
  @State private var planning = false
  @State private var error: String?
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(item.title).font(.headline)
          Text(L("\(L10n.label(item.area)) · \(L10n.label(item.status)) · \(L10n.label(item.kind))"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if item.status != "archived" {
          Button(item.intakeData == nil ? L("Plan this") : L("Arrange imported plan")) {
            if preview.inboxID == item.id, preview.draft != nil {
              planning = true
            } else if let data = item.intakeData {
              perform {
                let doc = try IntakeDocument.decode(String(decoding: data, as: UTF8.self))
                let draft = try IntakeCoordinator.arrange(doc, area: item.area, context: context)
                IntakeCoordinator.open(draft, item: item, preview: preview)
                planning = true
              }
            } else { planning = true }
          }.disabled(
            (preview.draft != nil && preview.inboxID != item.id) || (item.intakeData != nil && item.plan != nil))
          Menu {
            Button(L("Convert to task")) {
              perform { try InboxActions.convertToTask(item, context: context) }
            }.disabled(item.task != nil)
            Button(L("Make a goal")) {
              perform { try InboxActions.convertToGoal(item, context: context) }
            }.disabled(item.goal != nil)
            Button(L("Create draft plan")) {
              perform { try InboxActions.makeDraftPlan(item, context: context) }
            }.disabled(item.plan != nil)
            Button(L("Someday")) {
              item.status = "someday"
              item.kind = "idea"
              save()
            }
            Button(L("Archive")) {
              item.status = "archived"
              save()
            }
          } label: {
            Image(systemName: "ellipsis")
          }
        } else {
          Button(L("Restore to Inbox")) {
            item.status = "unprocessed"
            save()
          }
        }
      }
      if let plan = item.plan {
        Text(L("Plan · \(plan.title)")).font(.caption).foregroundStyle(.teal)
      }
      if let goal = item.goal {
        Text(L("Goal · \(goal.title)")).font(.caption).foregroundStyle(.teal)
      }
      DisclosureGroup(L("Details"), isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 12) {
          if let data = item.intakeData,
            let document = try? IntakeDocument.decode(String(decoding: data, as: UTF8.self)) {
            DisclosureGroup(L("Source facts")) {
              ForEach(IntakeKind.allCases, id: \.self) { kind in
                if !document[kind].isEmpty {
                  Text(L(LocalizedMessage(key: "Import category: " + kind.rawValue))).bold()
                  ForEach(document[kind]) { entity in
                    Text(entity.title + (entity.duration_minutes.map { " · " + L("\($0) minutes") } ?? ""))
                    if !entity.description.isEmpty { Text(entity.description).font(.caption) }
                  }
                }
              }
            }
          }
          TextField(L("Title"), text: $item.title)
          TextField(L("Optional note"), text: $item.note, axis: .vertical).lineLimit(2...5)
          ContextPicker(area: $item.area)
          Toggle(
            L("Has a deadline"),
            isOn: Binding(get: { item.deadline != nil }, set: { item.deadline = $0 ? Date() : nil })
          )
          if item.deadline != nil {
            DatePicker(
              L("Deadline"),
              selection: Binding(get: { item.deadline ?? Date() }, set: { item.deadline = $0 }))
            Button(L("Create deadline task")) {
              perform { try InboxActions.convertToTask(item, context: context) }
            }.disabled(item.task != nil)
          }
          Button(L("Save details"), action: save)
        }.padding(.top, 8)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.padding(18).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
      .sheet(isPresented: $planning) {
        CommandView(
          initialInput: item.title + (item.note.isEmpty ? "" : "\n" + item.note),
          initialArea: item.area, inboxID: item.id)
      }
  }
  private func save() { perform { try context.save() } }
  private func perform(_ action: () throws -> Void) {
    do {
      try action()
      error = nil
    } catch {
      context.rollback()
      self.error = error.localizedDescription
    }
  }
}
