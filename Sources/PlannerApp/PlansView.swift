import PlannerCore
import SwiftData
import SwiftUI

struct PlansView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Query private var plans: [Plan]
  @Query private var inbox: [InboxItem]
  @Query private var sessions: [Session]
  @EnvironmentObject private var preview: PlanningPreview
  @State private var section = PlanSection.active
  @State private var area = "All contexts"
  @State private var focus: Session?
  @State private var addToPlan: Plan?
  @State private var command = false
  var body: some View {
    let _ = appLanguage
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          eyebrow: L("Outcomes, made actionable"), title: L("Plans"),
          subtitle: L("Keep the outcome in view. Take the next step when you're ready."))
        HStack {
          Picker(L("Status"), selection: $section) {
            ForEach(PlanSection.allCases, id: \.self) { Text(L10n.label($0.rawValue)).tag($0) }
          }.pickerStyle(.segmented).frame(width: 360)
          Spacer()
          Picker(L("Context"), selection: $area) {
            ForEach(["All contexts", "Study", "Training", "Meals", "Life", "Travel"], id: \.self) {
              Text(L10n.label($0)).tag($0)
            }
          }.frame(width: 200)
        }
        if section == .draft, let draft = preview.draft {
          HStack {
            VStack(alignment: .leading) {
              Text(draft.title).font(.headline)
              Text(L("AI draft · not confirmed")).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button(L("Review draft")) { command = true }
          }.padding().overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
              .orange.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        let visible = plans.filter { plan in
          let related = sessions.filter { $0.plan?.id == plan.id }
          return PlanSection.classify(related) == section
            && (area == "All contexts" || related.contains { $0.area == area }
              || plan.goal?.area?.name == area
              || inbox.contains { $0.plan?.id == plan.id && $0.area == area })
        }
        if visible.isEmpty && !(section == .draft && preview.draft != nil) {
          EmptyState(
            title: L("No plans in this view"),
            text: L("Start in Inbox, or use ⌘K when you want help shaping a plan."),
            icon: "square.stack.3d.up")
        }
        ForEach(visible) { plan in
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Text(plan.title).font(.title2.bold())
              Spacer()
              Button(L("Add session")) { addToPlan = plan }
            }
            if !plan.purpose.isEmpty { Text(plan.purpose).foregroundStyle(.secondary) }
            let related = sessions.filter { $0.plan?.id == plan.id }.sorted {
              ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
            }
            if related.isEmpty {
              Text(L("A draft outcome. Add its first session when you're ready.")).foregroundStyle(
                .secondary)
            }
            ForEach(related) { s in SessionRow(session: s) { focus = s } }
          }.padding(.vertical, 12)
          Divider()
        }
        DisclosureGroup(L("Sessions without a plan")) {
          ForEach(sessions.filter { $0.plan == nil && (area == "All contexts" || $0.area == area) })
          { s in SessionRow(session: s) { focus = s } }
        }
      }.padding(32)
    }.sheet(item: $focus) { FocusView(session: $0) }
      .sheet(item: $addToPlan) { SessionEditor(initialPlan: $0) }
      .sheet(isPresented: $command) { CommandView() }
  }
}
