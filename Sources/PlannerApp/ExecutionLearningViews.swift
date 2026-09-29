import PlannerCore
import SwiftData
import SwiftUI

extension ExecutionRecord {
  var observation: ExecutionObservation? {
    guard let outcome = ExecutionOutcome(rawValue: status) else { return nil }
    return .init(
      sessionID: sessionID, date: date, scheduledStart: scheduledStart,
      localHour: localHour, estimated: estimated, actual: actual, outcome: outcome,
      area: area, energy: energyRequirement,
      reason: feedbackReason.flatMap(ExecutionReason.init(rawValue:)))
  }
  var offersFeedback: Bool {
    status == "skip" || status == "partial" || (status == "postponed" && postponementOrdinal >= 2)
      || (estimated > 0 && actual >= estimated + max(10, estimated / 4))
  }
}
struct ExecutionFeedbackView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var record: ExecutionRecord
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @State private var reason = ""
  @State private var detail = ""
  @State private var error: String?
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 16) {
      Text(L("Anything that got in the way?")).font(.headline)
      Text(L("Optional. This helps Intent learn which plans work for you.")).foregroundStyle(
        .secondary)
      Picker(L("Reason"), selection: $reason) {
        Text(L("No feedback")).tag("")
        ForEach(ExecutionReason.allCases, id: \.rawValue) {
          Text(L10n.label($0.rawValue)).tag($0.rawValue)
        }
      }
      if reason == "other" { TextField(L("Details (optional)"), text: $detail) }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button(L("Not now")) { dismiss() }
        Spacer()
        Button(L("Save feedback")) {
          record.feedbackReason = reason.isEmpty ? nil : reason
          record.feedbackDetail = reason == "other" ? detail : ""
          do {
            try context.save()
            dismiss()
          } catch { self.error = error.localizedDescription }
        }
      }
    }.padding(24).frame(width: 440)
  }
}
struct ExecutionLearningView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let records: [ExecutionRecord]
  let weekly: Bool
  @Query private var profiles: [UserPlanningProfile]
  @Environment(\.modelContext) private var context
  @State private var error: String?
  var learning: ExecutionLearning { ExecutionLearning(records.compactMap(\.observation)) }
  var profile: ExecutionProfile { profiles.first?.executionProfile ?? .init() }
  var suggestions: [ExecutionAdaptation] { profile.pending(learning.suggestions) }
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 14) {
      Text(weekly ? L("What Intent learned this week") : L("Observed execution patterns")).font(
        .title3.bold())
      Text(
        L(
          "Observed app behavior only. Suggestions need at least five distinct sessions per area; comparisons need five per group. Repeated feedback needs three distinct sessions. Explicit preferences are kept separately."
        )
      )
      .font(.caption).foregroundStyle(.secondary)
      if learning.suggestions.isEmpty {
        Text(L("More evidence is needed before suggesting changes.")).foregroundStyle(.secondary)
      }
      ForEach(learning.suggestions) { suggestion in
        Text(L10n.systemText(suggestion.evidence)).font(.callout)
      }
      ForEach(
        [
          ("Duration", \ExecutionObservation.durationBucket),
          ("Time of day", \ExecutionObservation.timeBucket), ("Area", \ExecutionObservation.area),
          ("Energy", \ExecutionObservation.energy),
        ], id: \.0
      ) { label, key in
        let rates = learning.rates(by: key).filter {
          $0.value.count >= ExecutionLearning.minimumSamples
        }.sorted { $0.key < $1.key }
        ForEach(rates, id: \.key) { item in
          Text(
            L(
              "\(L10n.label(label)) · \(L10n.label(item.key)): \(Int(item.value.rate * 100))% completed (\(item.value.count) sessions)"
            )
          ).font(.caption)
        }
      }
      Text(L("Suggested changes for next week")).font(.headline)
      ForEach(suggestions) { suggestion in
        HStack {
          Text(L10n.systemText(suggestion.proposal))
          Spacer()
          Button(L("Apply")) { decide([suggestion], apply: true) }
          Button(L("Ignore")) { decide([suggestion], apply: false) }
        }
      }
      if !suggestions.isEmpty { Button(L("Apply all")) { decide(suggestions, apply: true) } }
      if !profile.accepted.isEmpty {
        Text(L("Accepted adaptations")).font(.headline)
        ForEach(profile.accepted) { adaptation in
          HStack {
            Text(L("\(L10n.systemText(adaptation.proposal)) · Accepted")).font(.caption)
            Button(L("Remove")) { remove(adaptation) }
          }
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
    }.padding().background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
  }
  func decide(_ suggestions: [ExecutionAdaptation], apply: Bool) {
    let saved = profiles.first ?? UserPlanningProfile()
    if profiles.isEmpty { context.insert(saved) }
    var value = saved.executionProfile
    for suggestion in suggestions {
      if apply { value.apply(suggestion) } else { value.ignore(suggestion) }
    }
    saved.executionProfile = value
    do { try context.save() } catch {
      context.rollback()
      self.error = error.localizedDescription
    }
  }
  func remove(_ adaptation: ExecutionAdaptation) {
    guard let saved = profiles.first else { return }
    var value = saved.executionProfile
    value.accepted.removeAll { $0.id == adaptation.id }
    value.ignore(adaptation)
    saved.executionProfile = value
    do { try context.save() } catch {
      context.rollback()
      self.error = error.localizedDescription
    }
  }
}
