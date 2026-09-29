import PlannerCore
import SwiftUI

/// Presentation-only union: no draft is persisted as an event or supplied as busy time.
struct CalendarDisplayItem: Identifiable {
  var id: String
  var start: Date
  var session: Session?
  var event: ImportedEvent?
  var suggestion: ScheduledSuggestion?
  var end: Date {
    event?.end ?? session?.end ?? suggestion?.start?.addingTimeInterval(
      Double((suggestion?.session.duration_minutes ?? 0) * 60)) ?? start
  }
  var allDay: Bool { event?.allDay == true }
  var title: String { event?.title ?? session?.title ?? suggestion?.session.title ?? "" }
  init(session: Session) {
    id = session.id.uuidString
    start = session.start ?? .distantFuture
    self.session = session
  }
  init(event: ImportedEvent) {
    id = "event:" + event.id
    start = event.start
    self.event = event
  }
  init(suggestion: ScheduledSuggestion) {
    id = "draft:\(suggestion.id)"
    start = suggestion.start ?? .distantFuture
    self.suggestion = suggestion
  }
}
struct FixedEventRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let event: ImportedEvent
  var body: some View {
    let _ = appLanguage
    HStack(spacing: 12) {
      Image(systemName: "lock.fill").foregroundStyle(.indigo)
      Text(
        event.allDay ? L("All day") : event.start.plannerFormatted(date: .omitted, time: .shortened)
      ).monospacedDigit().frame(width: 76, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        Text(event.title).font(.headline)
        if !event.location.isEmpty {
          Label(event.location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(L("Fixed")).font(.caption).foregroundStyle(.indigo)
    }.padding(14).background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }
}
struct DraftEventRow: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let suggestion: ScheduledSuggestion
  var review: () -> Void
  var body: some View {
    let _ = appLanguage
    HStack {
      Image(systemName: "sparkles").foregroundStyle(.orange)
      Text(suggestion.start?.plannerFormatted(date: .omitted, time: .shortened) ?? L("Unscheduled"))
        .monospacedDigit()
      Text(suggestion.session.title)
      Spacer()
      Text(L("AI draft · not confirmed")).font(.caption).foregroundStyle(.orange)
      Button(L("Review"), action: review)
    }.padding(14).overlay(
      RoundedRectangle(cornerRadius: 10).stroke(
        .orange.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
  }
}
