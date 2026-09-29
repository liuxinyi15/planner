import PlannerCore
import SwiftData
import SwiftUI

struct ProactivitySettings: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Bindable var profile: UserPlanningProfile
  @Environment(\.modelContext) private var context
  @State private var requesting = false
  @State private var message = ""
  var body: some View {
    let _ = appLanguage
    Section(L("Planning assistance")) {
      Picker(L("Planning Style"), selection: $profile.planningStyleRaw) {
        ForEach(PlanningStyle.allCases, id: \.rawValue) {
          Text(L10n.label($0.rawValue)).tag($0.rawValue)
        }
      }.onChange(of: profile.planningStyleRaw) { saveAndRefresh() }
      Text(
        L(
          "Quiet: in-app suggestions and essential session/deadline reminders. Balanced: also preparation and missed-session recovery. Proactive: also free-window and capacity nudges."
        )
      )
      .font(.caption).foregroundStyle(.secondary)
      if profile.remindersEnabled {
        Button(L("Disable reminders")) {
          profile.remindersEnabled = false
          RecommendationNotificationService.shared.disable()
          saveAndRefresh()
        }
      } else {
        Button(requesting ? L("Requesting permission…") : L("Enable reminders…")) {
          requesting = true
          Task { @MainActor in
            defer { requesting = false }
            do {
              let allowed = try await RecommendationNotificationService.shared.requestPermission()
              profile.remindersEnabled = allowed
              message =
                allowed
                ? L("Reminders enabled.")
                : L(
                  "Permission was not granted. You can change it in macOS System Settings → Notifications."
                )
              saveAndRefresh()
            } catch { message = error.localizedDescription }
          }
        }.disabled(requesting)
      }
      Text(
        L(
          "Suggestions remain in Today with reminders off. Alerts are limited to 2/day in Quiet, 3/day in Balanced, or 5/day in Proactive, with a 3-hour or 1-hour cooldown. Nonessential alerts stay between 09:00 and 21:00."
        )
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        L(
          "Intent checks while running and queues eligible reminders up to 24 hours ahead. New opportunities are discovered when it next runs."
        )
      ).font(.caption).foregroundStyle(.secondary)
      if !message.isEmpty { Text(message).font(.caption) }
    }
  }
  private func saveAndRefresh() {
    do { try context.save() } catch {
      context.rollback()
      message = error.localizedDescription
      return
    }
    Task { await RecommendationNotificationService.shared.refresh(context: context) }
  }
}
struct RecommendationCard: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let recommendation: Recommendation
  var act: (Date?) -> Void
  var later: () -> Void
  var ignore: () -> Void
  var body: some View {
    let _ = appLanguage
    VStack(alignment: .leading, spacing: 12) {
      Text(L("SUGGESTED NEXT STEP")).font(.caption.bold()).foregroundStyle(.teal)
      Text(recommendation.title).font(.title2.bold())
      Text(recommendation.reason).foregroundStyle(.secondary)
      if recommendation.alternatives.count > 1 {
        ForEach(recommendation.alternatives, id: \.self) { date in
          Button(date.plannerFormatted(date: .abbreviated, time: .shortened)) { act(date) }
        }
      }
      HStack {
        Button(recommendation.suggestedAction) { act(nil) }.buttonStyle(.borderedProminent)
        Button(L("Later")) { later() }
        Button(L("Dismiss")) { ignore() }
      }
    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
      .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
  }
}
struct RecommendationEditor: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let recommendation: Recommendation
  let proposedStart: Date?
  @Environment(\.modelContext) private var context
  @State private var session: Session?
  @State private var course: Course?
  @State private var loaded = false
  @State private var error: String?
  var body: some View {
    let _ = appLanguage
    Group {
      if let error {
        Text(error).padding(30)
      } else if loaded {
        if recommendation.action == .move, let session {
          SessionEditor(
            existing: session, suggestedStart: proposedStart, resumeOnSave: true, onSaved: resolved)
        } else if recommendation.action == .plan {
          SessionEditor(
            suggestedStart: proposedStart, suggestedTitle: recommendation.title,
            suggestedPurpose: recommendation.reason, suggestedMinutes: 30, suggestedCourse: course,
            onSaved: resolved)
        } else {
          Text(L("This session is no longer available.")).padding(30)
        }
      } else {
        ProgressView().padding(30)
      }
    }.task {
      do {
        if let id = recommendation.entityID {
          if recommendation.action == .move {
            session = try context.fetch(
              FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
            ).first
          } else if recommendation.action == .plan {
            course = try context.fetch(
              FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })
            ).first
          }
        }
        loaded = true
      } catch { self.error = error.localizedDescription }
    }
  }
  private func resolved() {
    RecommendationNotificationService.shared.dismiss(
      recommendation, until: recommendation.expiration)
  }

}
