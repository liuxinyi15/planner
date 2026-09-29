import AppKit
import PlannerCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SmartImportView: View {
  var targetCourse: Course?
  @AppStorage("appLanguage") private var appLanguage = "system"
  @AppStorage("responseTextPath") private var responsePath = "choices.0.message.content"
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var preview: PlanningPreview
  @State private var text = ""
  @State private var correction = ""
  @State private var source = "Paste"
  @State private var area = "Study"
  @State private var document: IntakeDocument?
  @State private var selected = Set<UUID>()
  @State private var editing: IntakeEntity?
  @State private var error: String?
  @State private var loading = false
  @State private var filePicker = false
  @State private var calendarPicker = false
  @State private var request: Task<Void, Never>?
  @State private var calendarImport: ICSImport?
  @State private var calendarSelection = Set<String>()
  @State private var planning = false
  @State private var imported = false
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(L("Smart Import")).font(.title2.bold())
        Spacer()
        Button(L("Cancel")) { request?.cancel(); dismiss() }
      }
      Text(L("Bring in something you already have.")).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if loading { ProgressView(L("Analysing imported content…")) }
      if let parsed = calendarImport {
        Text(L("Review calendar import")).font(.headline)
        List(parsed.events) { event in
          Toggle(isOn: Binding(get: { calendarSelection.contains(event.id) }, set: {
            if $0 { calendarSelection.insert(event.id) } else { calendarSelection.remove(event.id) }
          })) {
            VStack(alignment: .leading) {
              Text(event.title)
              Text(event.start.plannerFormatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
          }
        }
        ForEach(parsed.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        HStack {
          Button(L("Back")) { calendarImport = nil }
          Spacer()
          Button(L("Import events")) {
            do {
              let source = CalendarSource(name: L("Imported calendar"))
              context.insert(source)
              try CalendarRepository.upsert(parsed.events.filter { calendarSelection.contains($0.id) }, source: source, context: context)
              dismiss()
            } catch { context.rollback(); self.error = error.localizedDescription }
          }.buttonStyle(.borderedProminent).disabled(calendarSelection.isEmpty)
        }
      } else if let doc = document {
        Text(L("Detected from imported content")).font(.headline)
        Text(doc.title).font(.title3)
        Text(doc.summary).foregroundStyle(.secondary)
        ContextPicker(area: $area)
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(IntakeKind.allCases, id: \.self) { kind in
              if !doc[kind].isEmpty {
                Text(L(LocalizedMessage(key: "Import category: " + kind.rawValue))).font(.headline)
                ForEach(doc[kind]) { entity in
                  IntakePreviewRow(entity: entity, selected: Binding(
                    get: { selected.contains(entity.id) }, set: {
                      if $0 { selected.insert(entity.id) } else { selected.remove(entity.id) }
                    }), edit: { editing = entity }).disabled(loading)
                }
              }
            }
          }.padding(4)
        }
        TextField(L("Tell Intent what I meant"), text: $correction)
        HStack {
          Button(L("Reinterpret")) { analyse() }.disabled(correction.isEmpty || loading)
          Button(L("Edit source")) { document = nil; error = nil }
          Spacer()
          Button(L("Import Only")) { accept(arrange: false) }.disabled(selected.isEmpty || loading || imported)
          Button(L("Import & Arrange")) { accept(arrange: true) }
            .buttonStyle(.borderedProminent)
            .disabled(loading || imported || preview.draft != nil || !doc.sessions.contains { selected.contains($0.id) })
        }
        Text(L("Import Only saves to Inbox. Arranging opens a draft; calendar time requires final confirmation.")).font(.caption).foregroundStyle(.secondary)
        if preview.draft != nil { Text(L("Review or discard the current draft before arranging another import.")).font(.caption).foregroundStyle(.orange) }
      } else {
        HStack {
          Button(L("Paste")) { source = "Paste" }
          Button(L("Clipboard")) {
            if let value = NSPasteboard.general.string(forType: .string), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              text = value; source = "Clipboard"; error = nil
            } else { error = L("The clipboard has no text.") }
          }
          Button(L("File")) { calendarPicker = false; filePicker = true }
          Button(L("Calendar")) { calendarPicker = true; filePicker = true }
        }.disabled(loading)
        Text(L("Paste a study plan, syllabus, task list, ChatGPT plan, email, or schedule…")).font(.callout).foregroundStyle(.secondary)
        TextEditor(text: $text).font(.body).frame(minHeight: 300).border(.quaternary)
          .disabled(loading)
        Text(L("Text interpretation sends only this content and your correction to the configured AI. Structured JSON and ICS are validated locally.")).font(.caption).foregroundStyle(.secondary)
        HStack {
          Text(L10n.systemText(source)).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(L("Analyse")) { analyse() }.buttonStyle(.borderedProminent)
            .disabled(loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }.padding(24).frame(width: 780, height: 700)
      .fileImporter(isPresented: $filePicker, allowedContentTypes: calendarPicker
        ? [UTType(filenameExtension: "ics") ?? .data]
        : [.plainText, .json, UTType(filenameExtension: "md") ?? .text, UTType(filenameExtension: "ics") ?? .data]) { result in
          do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            text = try IntakeFile.read(url); source = url.lastPathComponent
            error = nil
            if url.pathExtension.lowercased() == "ics" { try parseCalendar() }
            else if url.pathExtension.lowercased() == "json" {
              setDocument(try IntakeDocument.decode(text))
            }
          } catch { self.error = error.localizedDescription }
        }
      .sheet(item: $editing) { entity in
        IntakeEntityEditor(entity: entity) { updated in
          guard var doc = document else { return }
          for kind in IntakeKind.allCases {
            if let index = doc[kind].firstIndex(where: { $0.id == updated.id }) { doc[kind][index] = updated }
          }
          try doc.validate()
          document = doc
        }
      }
      .sheet(isPresented: $planning, onDismiss: { if imported { dismiss() } }) { CommandView() }
      .onDisappear { request?.cancel() }
  }
  private func setDocument(_ value: IntakeDocument) {
    document = value; selected = Set(value.entities.map(\.id)); error = nil
  }
  private func parseCalendar() throws {
    let parsed = try ICSParser().parse(text)
    calendarImport = parsed
    calendarSelection = Set(parsed.events.map(\.id))
  }
  private func analyse() {
    error = nil
    if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("BEGIN:VCALENDAR") {
      do { try parseCalendar() } catch { self.error = error.localizedDescription }
      return
    }
    if correction.isEmpty {
      do {
        if let local = try ImportInterpreter.localDocument(text) { setDocument(local); return }
      } catch { self.error = error.localizedDescription; return }
    }
    loading = true
    request = Task { @MainActor in
      defer { loading = false }
      do {
        let value = try await ImportInterpreter().interpret(text, correction: correction,
          configuration: .init(key: KeychainStore.read(), responseTextPath: responsePath),
          language: L10n.language.resolved() == .simplifiedChinese ? "Simplified Chinese" : "English")
        try Task.checkCancellation()
        setDocument(value)
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  private func accept(arrange: Bool) {
    guard let doc = document?.selecting(selected), !imported else { return }
    do {
      let draft = arrange ? try IntakeCoordinator.arrange(doc, area: area, context: context) : nil
      let item = try IntakeCoordinator.importOnly(doc, source: text, area: area, context: context, targetCourse: targetCourse)
      imported = true
      if let draft {
        IntakeCoordinator.open(draft, item: item, preview: preview)
        planning = true
      } else { preview.destination = "Inbox"; dismiss() }
    } catch { self.error = error.localizedDescription }
  }
}

private struct IntakeEntityEditor: View {
  @State var entity: IntakeEntity
  var save: (IntakeEntity) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var error: String?
  private func field(_ key: WritableKeyPath<IntakeEntity, String?>) -> Binding<String> {
    Binding(get: { entity[keyPath: key] ?? "" }, set: { entity[keyPath: key] = $0.isEmpty ? nil : $0 })
  }
  var body: some View {
    Form {
      Text(L("Edit detected item")).font(.title2)
      TextField(L("Title"), text: $entity.title)
      TextField(L("Details"), text: field(\.details), axis: .vertical)
      TextField(L("Purpose"), text: field(\.purpose))
      Toggle(L("Known duration"), isOn: Binding(get: { entity.duration_minutes != nil }, set: { entity.duration_minutes = $0 ? 60 : nil }))
      if let duration = entity.duration_minutes {
        Stepper(L("\(duration) minutes"), value: Binding(get: { entity.duration_minutes ?? 60 }, set: { entity.duration_minutes = $0 }), in: 5...480, step: 5)
      }
      Picker(L("Preferred day"), selection: field(\.preferred_day)) {
        Text(L("None")).tag("")
        ForEach(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], id: \.self) { day in
          Text(L10n.calendar.weekdaySymbols[IntakeDocument.weekday(day)! - 1]).tag(day)
        }
      }
      TextField(L("Preferred time (HH:mm)"), text: field(\.preferred_time))
      TextField(L("Actions (one per line)"), text: Binding(get: { (entity.actions ?? []).joined(separator: "\n") }, set: { entity.actions = $0.components(separatedBy: "\n").filter { !$0.isEmpty } }), axis: .vertical)
      Toggle(L("Truly fixed appointment"), isOn: Binding(get: { entity.fixed_start != nil }, set: {
        entity.fixed_start = $0 ? Date() : nil; entity.flexibility = $0 ? "fixed" : "flexible"
      }))
      if entity.fixed_start != nil { DatePicker(L("Start"), selection: Binding(get: { entity.fixed_start! }, set: { entity.fixed_start = $0 })) }
      Toggle(L("Has a deadline"), isOn: Binding(get: { entity.deadline != nil }, set: { entity.deadline = $0 ? Date() : nil }))
      if entity.deadline != nil { DatePicker(L("Deadline"), selection: Binding(get: { entity.deadline! }, set: { entity.deadline = $0 })) }
      TextField(L("Original date wording"), text: field(\.date_text))
      TextField(L("Unresolved ambiguity (clear after correction)"), text: field(\.ambiguity), axis: .vertical)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button(L("Cancel")) { dismiss() }
        Button(L("Save")) {
          do { try save(entity); dismiss() } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent)
      }
    }.padding(24).frame(width: 600, height: 650)
  }
}

private struct IntakePreviewRow: View {
  let entity: IntakeEntity
  @Binding var selected: Bool
  let edit: () -> Void
  var body: some View {
HStack(alignment: .top) {
                    Toggle(isOn: $selected) {
                      VStack(alignment: .leading, spacing: 4) {
                        Text(entity.title)
                        if let duration = entity.duration_minutes { Text(L("\(duration) minutes")).font(.caption) }
                        if let day = entity.preferred_day {
                          Text(L("Prefer: ") + (IntakeDocument.weekday(day).map { L10n.calendar.weekdaySymbols[$0 - 1] } ?? day)).font(.caption)
                        }
                        if let time = entity.preferred_time { Text(L("Prefer: ") + time).font(.caption) }
                        if let fixed = entity.fixed_start { Text(L("Fixed: ") + fixed.plannerFormatted(date: .abbreviated, time: .shortened)).font(.caption) }
                        if let rule = entity.rule { Text(L("Supported scheduling rule") + ": " + rule.text).font(.caption) }
                        if let date = entity.deadline { Text(L("Deadline: ") + date.plannerFormatted(date: .abbreviated, time: .shortened)).font(.caption) }
                        let details = [entity.details, entity.purpose, entity.date_text, entity.ambiguity,
                          entity.actions?.joined(separator: "\n")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                        if !details.isEmpty { Text(details).font(.caption).foregroundStyle(.secondary) }
                      }
                    }
                    Spacer()
                    Button(L("Edit"), action: edit)
                  }
  }
}
