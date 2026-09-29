import Charts
import PlannerCore
import SwiftData
import SwiftUI

struct InsightsView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let review: Bool
  @Environment(\.modelContext) private var context
  @Query private var records: [ExecutionRecord]
  @Query private var sessions: [Session]
  @Query private var reviews: [WeeklyReview]
  @State private var reflection = ""
  @State private var saved = false
  var weekStart: Date { Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start }
  var weekly: [ExecutionRecord] { records.filter { $0.date >= weekStart } }
  var scoped: [ExecutionRecord] { review ? weekly : records }
  var analytics: ExecutionAnalytics {
    ExecutionAnalytics(
      samples: scoped.map {
        ExecutionSample(
          estimated: $0.estimated, actual: $0.actual, status: $0.status, area: $0.area,
          date: $0.date)
      })
  }
  var planned: [Session] {
    sessions.filter {
      !review
        || ($0.start ?? .distantPast) >= weekStart
          && ($0.start ?? .distantFuture) < weekStart.addingTimeInterval(7 * 86400)
    }
  }
  var body: some View {
    // Read the preference here so SwiftUI tracks this view’s language dependency.
    let _ = appLanguage
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: review ? L("Reflect & adapt") : L("Learn from your execution"),
          title: review ? L("Weekly review") : L("Insights"),
          subtitle: L("Patterns from your own records. No scores, streaks, or guesswork."))
        HStack {
          Metric(
            title: L("Sessions completed"),
            value: "\(planned.filter { $0.status == "complete" }.count) / \(planned.count)",
            symbol: "checkmark.circle")
          Metric(
            title: L("Execution rate"),
            value:
              "\(planned.isEmpty ? 0 : Int(Double(planned.filter { $0.status == "complete" }.count)/Double(planned.count)*100))%",
            symbol: "chart.bar")
          Metric(
            title: L("Estimation difference"),
            value: analytics.estimationBias.map { String(format: "%+.0f%%", $0 * 100) } ?? "—",
            symbol: "clock.arrow.circlepath")
        }
        HStack {
          Metric(
            title: L("Actual time"), value: L("\(scoped.reduce(0) { $0+$1.actual }) min"),
            symbol: "timer"
          )
          Metric(
            title: L("Postponements"), value: "\(scoped.filter { $0.status == "postponed" }.count)",
            symbol: "arrow.forward")
          Metric(
            title: L("Skipped"), value: "\(scoped.filter { $0.status == "skip" }.count)",
            symbol: "minus.circle")
        }
        if scoped.isEmpty {
          EmptyState(
            title: L("Your patterns will emerge"),
            text: L("Complete sessions and record actual time to see useful insights."),
            icon: "chart.bar.xaxis")
        } else {
          Text(L("Where your time went")).font(.title3.bold())
          Chart(analytics.allocation.sorted { $0.key < $1.key }, id: \.key) { item in
            BarMark(x: .value(L("Minutes"), item.value), y: .value(L("Area"), L10n.label(item.key)))
              .foregroundStyle(
                .teal)
          }.frame(height: 190)
          Text(
            L(
              "Estimation difference compares completed-session estimates with recorded actual time. Positive means work took longer than estimated."
            )
          ).font(.caption).foregroundStyle(.secondary)
        }
        ExecutionLearningView(records: scoped, weekly: review)

        if review {
          Text(L("What will you change next week?")).font(.title3.bold())
          TextEditor(text: $reflection).frame(height: 130).border(.quaternary)
          Button(saved ? L("Review saved") : L("Save reflection")) {
            context.insert(WeeklyReview(reflection))
            reflection = ""
            saved = true
          }.disabled(reflection.isEmpty)
          ForEach(reviews.sorted { $0.date > $1.date }.prefix(4)) { review in
            VStack(alignment: .leading) {
              Text(review.date.plannerFormatted(date: .abbreviated, time: .omitted)).font(.caption)
                .foregroundStyle(.secondary)
              Text(review.reflection)
            }
          }
        }
      }.padding(32)
    }
  }
}

struct InsightsDestination: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @State private var review = false
  var body: some View {
    let _ = appLanguage
    VStack(spacing: 0) {
      Picker(L("Insights"), selection: $review) {
        Text(L("Insights")).tag(false)
        Text(L("Weekly Review")).tag(true)
      }.pickerStyle(.segmented).frame(width: 320).padding(.top, 20)
      InsightsView(review: review)
    }
  }
}
