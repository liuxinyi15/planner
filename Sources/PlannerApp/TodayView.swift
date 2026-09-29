import PlannerCore
import SwiftData
import SwiftUI

struct TodayView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @EnvironmentObject private var preview: PlanningPreview
  @State private var situation: CurrentSituation?
  @State private var error: String?
  @State private var focus: Session?
  @State private var create = false
  @State private var recommendations: [Recommendation] = []
  @State private var editingRecommendation: Recommendation?
  @State private var suggestedStart: Date?
  var body: some View {
    let _ = appLanguage
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              Text(
                timeline.date.formatted(.dateTime.weekday(.wide).month().day().locale(L10n.locale))
              ).foregroundStyle(.secondary)
              Text(L("Today")).font(.largeTitle.bold())
            }
            Spacer()
            Button(L("Add session"), systemImage: "plus") { create = true }.buttonStyle(.borderless)
          }
          if let error {
            Text(error).foregroundStyle(.red)
            Button(L("Refresh")) { refresh() }
          }
          if let recommendation = recommendations.first {
            RecommendationCard(recommendation: recommendation, act: { act(recommendation, at: $0) }, later: {
              RecommendationNotificationService.shared.dismiss(recommendation, until: Date().addingTimeInterval(3600))
              refresh()
            }, ignore: {
              RecommendationNotificationService.shared.dismiss(recommendation, until: recommendation.expiration)
              refresh()
            })
          }
          if let situation {
            if let fixed = situation.nextFixedCommitment {
              VStack(alignment: .leading, spacing: 8) {
                Text(L("Next fixed commitment")).font(.headline)
                Text(fixed.start.plannerFormatted(date: .abbreviated, time: .shortened)).font(
                  .caption
                ).foregroundStyle(.secondary)
                FixedEventRow(event: fixed.imported)
              }
            }
            if let next = situation.nextPlannedSession {
              NextSessionView(session: next) { open(next.id) }
            } else {
              VStack(alignment: .leading, spacing: 12) {
                Text(L("NEXT")).font(.caption.bold()).foregroundStyle(.teal)
                Text(L("Nothing else scheduled right now")).font(.title2.bold())
                Text(L("Leave some space, or choose an intention from your Inbox."))
                  .foregroundStyle(.secondary)
                Button(L("Open Inbox")) { preview.destination = "Inbox" }
              }.padding(.vertical, 18)
            }
            if situation.attentionCount > 0 || !situation.deadlines.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text(L("Needs attention")).font(.headline)
                if let deadline = situation.deadlines.first {
                  Text(
                    L(
                      "Deadline: \(deadline.title) · \(deadline.date.plannerFormatted(date: .abbreviated, time: .shortened))"
                    ))
                }
                if let task = situation.overdueTasks.first {
                  Text(L("Overdue task: \(task.title)"))
                }
                if let missed = situation.unfinishedSessions.first(where: {
                  ($0.end ?? .distantFuture) <= situation.currentDate
                }) {
                  Text(L("\(missed.title) needs a new time. Open Calendar to adjust it."))
                }
                if !situation.recentInbox.isEmpty {
                  Button(L("\(situation.recentInbox.count) recent intentions to process")) {
                    preview.destination = "Inbox"
                  }
                }
              }
            }
            if situation.truncated {
              Text(L("Some records could not fit in this snapshot. Free capacity is unavailable."))
                .foregroundStyle(.orange)
            }
            Divider()
            HStack {
              Text(L("Later today")).font(.title3.bold())
              Spacer()
              Text(L("\(situation.freeCapacityToday) min of flexible capacity")).font(.callout)
                .foregroundStyle(.secondary)
            }
            ForEach(
              situation.upcomingEvents.filter {
                Calendar.current.isDateInToday($0.start) && $0.visible
                  && $0.id != situation.nextFixedCommitment?.id
              }
            ) { event in FixedEventRow(event: event.imported) }
            ForEach(
              situation.unfinishedSessions.filter {
                $0.id != situation.nextPlannedSession?.id
                  && $0.start.map { Calendar.current.isDateInToday($0) } == true
                  && ($0.end ?? .distantPast) > situation.currentDate
              }
            ) { session in
              HStack {
                Text(
                  session.start?.plannerFormatted(date: .omitted, time: .shortened) ?? L("Anytime"))
                Text(session.title)
                Spacer()
                Button(L("Open")) { open(session.id) }
              }.padding(.vertical, 8)
            }
          } else if error == nil {
            ProgressView()
          }
        }.padding(36).frame(maxWidth: 1050, alignment: .leading)
      }.task(id: timeline.date) { refresh(now: timeline.date) }
    }.sheet(item: $focus, onDismiss: { refresh() }) { FocusView(session: $0) }
      .sheet(isPresented: $create, onDismiss: { refresh() }) { SessionEditor() }
      .sheet(item: $editingRecommendation, onDismiss: { refresh() }) { rec in
        RecommendationEditor(recommendation: rec, proposedStart: suggestedStart)
      }
      .onChange(of: appLanguage) { refresh() }
      .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in refresh() }
  }
  private func refresh(now: Date = Date()) {
    do {
      let loaded = try RecommendationLoader.load(context: context, now: now)
      situation = loaded.0
      recommendations = RecommendationNotificationService.shared.history.visible(loaded.1, now: now)
      error = nil
    } catch {
      situation = nil
      recommendations = []
      self.error = error.localizedDescription
    }
  }
  private func act(_ recommendation: Recommendation, at date: Date?) {
    switch recommendation.action {
    case .start:
      if let id = recommendation.entityID { open(id) }
    case .move, .plan:
      suggestedStart = date ?? recommendation.alternatives.first
      editingRecommendation = recommendation
    case .inbox: preview.destination = "Inbox"
    case .tasks: preview.destination = "Tasks"
    case .courses: preview.destination = "Courses"
    case .review:
      preview.destination = recommendation.type == .moveHighEnergyWork ? "Insights" : "Calendar"
    }
  }
  private func open(_ id: UUID) {
    do {
      var request = FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
      request.fetchLimit = 1
      focus = try context.fetch(request).first
    } catch { self.error = error.localizedDescription }
  }
}

struct NextSessionView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let session: SituationSession
  var start: () -> Void
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(L("NEXT")).font(.caption.bold()).tracking(2).foregroundStyle(.teal)
        Spacer()
        Text(
          session.start?.plannerFormatted(
            date: session.start.map { Calendar.current.isDateInToday($0) } == true
              ? .omitted : .abbreviated, time: .shortened) ?? L("Anytime"))
        Text(L("\(session.minutes) min")).foregroundStyle(.secondary)
      }
      Text(session.title).font(.system(size: 30, weight: .semibold))
      if !session.purpose.isEmpty { Text(session.purpose).foregroundStyle(.secondary) }
      Label(
        session.definitionOfDone.isEmpty
          ? L("Define your completion criteria in Edit session.") : session.definitionOfDone,
        systemImage: "flag.checkered"
      ).font(.callout)
      ForEach(session.actions) { action in
        Label(action.title, systemImage: action.completed ? "checkmark.circle.fill" : "circle")
      }
      Button(L("Start session"), systemImage: "play.fill", action: start).buttonStyle(
        .borderedProminent
      ).controlSize(.large)
    }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(
      .teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
  }
}
