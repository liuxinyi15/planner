import PlannerCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CalendarView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @Query private var events: [CalendarEvent]
  @Query private var sources: [CalendarSource]
  @Query private var sessions: [Session]
  @EnvironmentObject private var preview: PlanningPreview
  @State private var mode = CalendarMode.agenda
  @State private var reviewDraft = false
  @State private var showSources = false
  @State private var date = Date()
  @State private var importing = false
  @State private var parsed: ICSImport?
  @State private var error: String?
  @State private var url = ""
  @State private var sourceName = ""
  @State private var sourceID: UUID?
  @State private var loading = false
  @State private var newSession = false
  @State private var focus: Session?
  @State private var selectedItem: CalendarDisplayItem?
  @State private var editingSession: Session?
  @State private var newSessionStart: Date?
  var range: Range<Date> {
    let start =
      mode == .week
      ? WeekGridLayout.weekStart(containing: date) : Calendar.current.startOfDay(for: date)
    return start..<Calendar.current.date(byAdding: .day, value: mode.dayCount, to: start)!
  }
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          eyebrow: L("Your time, made visible"), title: L("Calendar"),
          subtitle: L("Fixed commitments and flexible sessions, together."))
        HStack {
          DatePicker(L("Date"), selection: $date, displayedComponents: .date)
          Spacer()
          Button(L("Add session")) {
            newSessionStart = date
            newSession = true
          }
          Button(L("Import .ics"), systemImage: "square.and.arrow.down") { importing = true }
        }
        if let error { Text(error).foregroundStyle(.red) }
        Picker(L("Calendar view"), selection: $mode) {
          ForEach(CalendarMode.allCases, id: \.self) { Text(L10n.label($0.rawValue)).tag($0) }
        }.pickerStyle(.segmented).frame(width: 330)
        HStack {
          Button {
            date = Calendar.current.date(byAdding: .day, value: -mode.dayCount, to: date)!
          } label: {
            Image(systemName: "chevron.left")
          }.help(L("Previous"))
          Button(L("Today")) { date = Date() }
          Button {
            date = Calendar.current.date(byAdding: .day, value: mode.dayCount, to: date)!
          } label: {
            Image(systemName: "chevron.right")
          }.help(L("Next"))
          Text(
            range.lowerBound.plannerFormatted(date: .abbreviated, time: .omitted) + " – "
              + Calendar.current.date(byAdding: .day, value: -1, to: range.upperBound)!
              .plannerFormatted(date: .abbreviated, time: .omitted)
          ).font(.callout).foregroundStyle(.secondary)
        }
        HStack(spacing: 20) {
          Label(L("Fixed"), systemImage: "lock.fill").foregroundStyle(.indigo)
          Label(L("Confirmed session"), systemImage: "checkmark.circle").foregroundStyle(.teal)
          Label(L("AI draft · not confirmed"), systemImage: "sparkles").foregroundStyle(.orange)
        }.font(.caption)
        if preview.draft != nil {
          HStack {
            Text(L("A draft is waiting for your review in Calendar."))
            Spacer()
            Button(L("Review draft")) { reviewDraft = true }
          }
          if preview.suggestions.contains(where: { $0.start == nil }) {
            Text(L("Some draft sessions have no time yet. Review the plan to adjust them.")).font(
              .caption
            ).foregroundStyle(.orange)
          }
        }
        if mode == .week {
          CalendarWeekGrid(
            start: range.lowerBound, items: displayItems,
            select: { item in
              if item.suggestion != nil { reviewDraft = true } else { selectedItem = item }
            },
            create: { day in
              newSessionStart = day
              newSession = true
            })

        } else {
          ForEach(0..<mode.dayCount, id: \.self) { offset in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: range.lowerBound)!
            VStack(alignment: .leading, spacing: 10) {
              Text(day.formatted(.dateTime.weekday(.wide).month().day().locale(L10n.locale))).font(
                .headline)
              let rows = displayItems(on: day)
              if rows.isEmpty {
                Text(L("Open space")).font(.caption).foregroundStyle(.secondary).padding(
                  .vertical, 8)
              }
              ForEach(rows) { row in
                if let event = row.event {
                  FixedEventRow(event: event)
                } else if let session = row.session {
                  VStack(alignment: .leading, spacing: 4) {
                    Label(L("Confirmed session"), systemImage: "checkmark.circle").font(.caption)
                      .foregroundStyle(.teal)
                    SessionRow(session: session) { focus = session }
                  }
                } else if let suggestion = row.suggestion {
                  DraftEventRow(suggestion: suggestion) { reviewDraft = true }
                }
              }
            }
            Divider()
          }
        }
        DisclosureGroup(L("Calendar sources"), isExpanded: $showSources) {
          Text(L("Calendar sources")).font(.title2.bold())
          ForEach(sources) { source in
            SourceRow(source: source, onRefresh: { refresh(source) }, onDelete: { delete(source) })
          }
          HStack {
            TextField(L("Calendar name"), text: $sourceName)
            TextField(L("https://… or webcal://…"), text: $url)
            Button(L("Subscribe")) { subscribe() }.disabled(
              url.isEmpty || sourceName.isEmpty || loading)
          }
          if loading { ProgressView(L("Syncing calendar…")) }
          Text(
            L(
              "Drop an .ics file anywhere on this page to preview it. Subscription refresh is manual in V1."
            )
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.padding(32)
    }.fileImporter(
      isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data]
    ) { result in do { try read(result.get()) } catch { self.error = error.localizedDescription } }
    .dropDestination(for: URL.self) { urls, _ in
      guard let first = urls.first, first.pathExtension.lowercased() == "ics" else { return false }
      do {
        try read(first)
        return true
      } catch {
        self.error = error.localizedDescription
        return false
      }
    }.sheet(isPresented: Binding(get: { parsed != nil }, set: { if !$0 { parsed = nil } })) {
      importPreview
    }.sheet(isPresented: $reviewDraft) { CommandView() }.sheet(isPresented: $newSession) {
      SessionEditor(suggestedStart: newSessionStart)
    }.sheet(item: $focus) {
      FocusView(session: $0)
    }.sheet(item: $editingSession) { SessionEditor(existing: $0) }
    .sheet(item: $selectedItem) { item in
      VStack(alignment: .leading, spacing: 16) {
        Text(item.title).font(.title2.bold())
        Text(
          item.allDay
            ? L("All day")
            : item.start.plannerFormatted(date: .abbreviated, time: .shortened) + " – "
              + item.end.plannerFormatted(date: .abbreviated, time: .shortened))
        if let event = item.event {
          if !event.location.isEmpty { Label(event.location, systemImage: "mappin") }
          Text(event.notes).textSelection(.enabled)
          Label(L("Fixed"), systemImage: "lock.fill").foregroundStyle(.indigo)
        }
        HStack {
          Button(L("Close")) { selectedItem = nil }
          if let session = item.session {
            Button(L("Edit / reschedule")) {
              selectedItem = nil
              editingSession = session
            }
            Button(L("Open")) {
              selectedItem = nil
              focus = session
            }
          }
        }
      }.padding(28).frame(width: 480)
    }
  }
  private func displayItems(on day: Date) -> [CalendarDisplayItem] {
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
    let fixed = CalendarRepository.expand(
      events.filter { $0.source?.visible != false }, range: day..<dayEnd
    ).map { CalendarDisplayItem(event: $0) }
    let confirmed = sessions.filter {
      ($0.start ?? .distantFuture) < dayEnd && ($0.end ?? .distantPast) > day
    }.map { CalendarDisplayItem(session: $0) }
    let drafts = preview.suggestions.filter {
      ($0.start ?? .distantFuture) < dayEnd
        && ($0.start?.addingTimeInterval(Double($0.session.duration_minutes * 60)) ?? .distantPast)
          > day
    }.map { CalendarDisplayItem(suggestion: $0) }
    return (fixed + confirmed + drafts).sorted { $0.start < $1.start }
  }
  var importPreview: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L("Review calendar import")).font(.title2.bold())
      Picker(L("Target calendar"), selection: $sourceID) {
        Text(L("New imported calendar")).tag(nil as UUID?)
        ForEach(sources.filter { $0.url.isEmpty }) { Text($0.name).tag(Optional($0.id)) }
      }
      List {
        ForEach(parsed?.events ?? []) { event in
          VStack(alignment: .leading) {
            Text(event.title)
            Text(event.start.plannerFormatted(date: .abbreviated, time: .shortened)).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        ForEach(parsed?.warnings ?? [], id: \.self) { Text($0).foregroundStyle(.orange) }
      }
      HStack {
        Button(L("Cancel")) { parsed = nil }
        Spacer()
        Button(L("Import events")) {
          do {
            let source =
              sources.first { $0.id == sourceID } ?? CalendarSource(name: L("Imported calendar"))
            if source.modelContext == nil { context.insert(source) }
            try CalendarRepository.upsert(parsed?.events ?? [], source: source, context: context)
            parsed = nil
          } catch {
            self.error = error.localizedDescription
            parsed = nil
          }
        }.buttonStyle(.borderedProminent)
      }
    }.padding(24).frame(width: 650, height: 480)
  }
  func read(_ url: URL) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    guard data.count < 10_000_000, let text = String(data: data, encoding: .utf8) else {
      throw PlanningError.invalid(L("Calendar must be UTF-8 and under 10 MB."))
    }
    parsed = try ICSParser().parse(text)
  }
  func subscribe() {
    let source = CalendarSource(name: sourceName, url: url)
    loading = true
    error = nil
    Task {
      do {
        let result = try await CalendarRepository.fetch(url: url)
        context.insert(source)
        try CalendarRepository.upsert(result.events, source: source, context: context)
        error = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
        sourceName = ""
        url = ""
      } catch { self.error = error.localizedDescription }
      loading = false
    }
  }
  func refresh(_ source: CalendarSource) {
    loading = true
    Task {
      do {
        let result = try await CalendarRepository.fetch(url: source.url)
        try CalendarRepository.upsert(
          result.events, source: source, context: context, replace: true)
        error = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
      } catch { self.error = error.localizedDescription }
      loading = false
    }
  }
  func delete(_ source: CalendarSource) {
    events.filter { $0.source?.id == source.id }.forEach { context.delete($0) }
    context.delete(source)
  }
}
struct SourceRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var source: CalendarSource
  var onRefresh: () -> Void
  var onDelete: () -> Void
  @State private var confirm = false
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading) {
      HStack {
        Text(source.name).font(.headline)
        Spacer()
        if !source.url.isEmpty { Button(L("Refresh"), action: onRefresh) }
        Button(L("Remove"), role: .destructive) { confirm = true }
      }
      HStack {
        Toggle(L("Visible"), isOn: $source.visible)
        Toggle(L("Busy time"), isOn: $source.useAsBusy)
        Toggle(L("Allow AI context"), isOn: $source.allowAI)
      }.toggleStyle(.checkbox)
      if let sync = source.lastSync {
        Text(L("Synced \(sync.plannerFormatted(date: .abbreviated, time: .shortened))")).font(
          .caption
        ).foregroundStyle(.secondary)
      }
    }.padding().background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
      .confirmationDialog(L("Remove this source and its imported events?"), isPresented: $confirm) {
        Button(L("Remove source"), role: .destructive, action: onDelete)
      }
  }
}
