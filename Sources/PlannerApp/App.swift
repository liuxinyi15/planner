import AppKit
import PlannerCore
import SwiftData
import SwiftUI

@main struct IntentPlannerApp: App {
  @NSApplicationDelegateAdaptor(IntentAppDelegate.self) private var appDelegate
  @AppStorage("appLanguage") private var appLanguage = "system"
  var container: ModelContainer?
  let startupError: String?
  init() {
    do {
      let demo = ProcessInfo.processInfo.arguments.contains("--demo")
      container = try ModelContainer(
        for: Area.self, Goal.self, Plan.self, Session.self, Action.self, PlannerTask.self,
        Note.self, CalendarSource.self, CalendarEvent.self, Course.self, CourseSession.self,
        KnowledgeGap.self, ExecutionRecord.self, UserPlanningProfile.self, WeeklyReview.self,
        InboxItem.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: demo))
      if demo, let container { try DemoData.populate(container.mainContext) }
      startupError = nil
    } catch {
      container = nil
      startupError = error.localizedDescription
    }
  }
  var body: some Scene {
    let _ = appLanguage
    WindowGroup {
      if let container {
        RootView().frame(minWidth: 1000, minHeight: 700).modelContainer(container).environment(
          \.locale, L10n.locale)
      } else {
        ContentUnavailableView(
          L("Unable to open your planner"), systemImage: "externaldrive.badge.exclamationmark",
          description: Text(startupError ?? L("Unknown persistence error"))
        ).frame(width: 600, height: 350)
      }
    }
    Settings {
      if let container {
        SettingsView().frame(width: 570, height: 480).modelContainer(container).environment(
          \.locale, L10n.locale)
      }
    }
    MenuBarExtra("Intent", systemImage: "circle.dotted.circle") {
      if let container {
        MenuOverview().modelContainer(container).environment(\.locale, L10n.locale)
      }
    }
  }
}
struct RootView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("appLanguage") private var appLanguage = "system"
  @State private var selection = "Today"
  @State private var smartImport = false
  @State private var command = false
  @State private var query = ""
  @StateObject private var preview = PlanningPreview()
  let pages = ["Today", "Calendar", "Inbox", "Plans", "Insights"]
  let icons = [
    "Today": "sun.max", "Calendar": "calendar", "Inbox": "tray", "Plans": "square.stack.3d.up",
    "Insights": "chart.bar.xaxis",
  ]
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          IntentBrandIcon().frame(width: 28, height: 28)
          Text("Intent").font(.title2.bold())
        }.padding(.horizontal, 16).padding(.top, 20)
        List(selection: $selection) {
          Section(L("WORKSPACE")) {
            ForEach(pages, id: \.self) { page in
              Label(L10n.label(page), systemImage: icons[page]!).tag(page)
            }
          }
          Section {
            Label(L("Courses"), systemImage: "graduationcap").tag("Courses")
            Label(L("Settings"), systemImage: "gearshape").tag("Settings")
          }
        }.listStyle(.sidebar)
        Button {
          command = true
        } label: {
          HStack {
            Image(systemName: "sparkles")
            Text(L("Make a plan"))
            Spacer()
            Text("⌘K").foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain).padding(16)
      }.navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
    } detail: {
      Group {
        if !query.isEmpty {
          SearchView(query: query)
        } else {
          switch selection {
          case "Today": TodayView()
          case "Calendar": CalendarView()
          case "Inbox": InboxView()
          case "Plans": PlansView()
          case "Insights": InsightsDestination()
          case "Settings": SettingsView()
          case "Courses": CoursesView()
          case "Tasks": TasksView()
          default: TodayView()
          }
        }
      }.toolbar {
        ToolbarItem {
          Button { smartImport = true } label: {
            Label(L("Smart Import"), systemImage: "square.and.arrow.down")
          }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        ToolbarItem {
          Button {
            command = true
          } label: {
            Label(L("Plan with AI"), systemImage: "sparkles")
          }.keyboardShortcut("k", modifiers: .command)
        }
      }.searchable(text: $query, prompt: L("Search your workspace"))
    }.onChange(of: preview.destination) {
      if let destination = preview.destination {
        selection = destination
        query = ""
        preview.destination = nil
      }
    }.sheet(isPresented: $command) { CommandView() }
      .sheet(isPresented: $smartImport) { SmartImportView() }.environmentObject(preview).tint(.teal)
      .task {
        while !Task.isCancelled {
          await RecommendationNotificationService.shared.refresh(context: context)
          do { try await Task.sleep(for: .seconds(60)) } catch { break }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .intentOpenRecommendation)) { _ in
        selection = "Today"
        query = ""
      }
      .onChange(of: appLanguage) {
        RecommendationNotificationService.shared.invalidate()
        Task { await RecommendationNotificationService.shared.refresh(context: context) }
      }
      .onChange(of: scenePhase) {
        if scenePhase == .active { Task { await RecommendationNotificationService.shared.refresh(context: context) } }
      }
      .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
        RecommendationNotificationService.shared.invalidate()
        Task { await RecommendationNotificationService.shared.refresh(context: context) }
      }
  }
}
struct PageHeader: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  var eyebrow: String
  var title: String
  var subtitle: String
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 8) {
      Text(eyebrow.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.teal)
      Text(title).font(.system(size: 32, weight: .semibold, design: .rounded))
      Text(subtitle).foregroundStyle(.secondary)
    }.padding(.bottom, 12)
  }
}
struct Metric: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  var title: String
  var value: String
  var symbol: String
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title2.bold().monospacedDigit())
    }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(
      .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
  }
}
struct EmptyState: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  var title: String
  var text: String
  var icon: String = "sparkles"
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    ContentUnavailableView(title, systemImage: icon, description: Text(text)).frame(
      maxWidth: .infinity, minHeight: 200)
  }
}
struct MenuOverview: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Query private var sessions: [Session]
  var today: [Session] {
    sessions.filter { $0.start.map { Calendar.current.isDateInToday($0) } ?? false }.sorted {
      ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
    }
  }
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    Text(L("Today · \(today.filter { $0.status == "complete" }.count) / \(today.count)"))
    Divider()
    ForEach(today.prefix(8)) { session in
      Label(
        session.title,
        systemImage: session.status == "complete" ? "checkmark.circle.fill" : "circle")
    }
    if today.isEmpty { Text(L("No sessions scheduled")) }
  }
}
