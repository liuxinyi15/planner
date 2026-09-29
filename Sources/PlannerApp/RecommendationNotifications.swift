import Foundation
import PlannerCore
import SwiftData
import UserNotifications

@MainActor enum RecommendationLoader {
  static func load(context: ModelContext, now: Date = Date()) throws -> (
    CurrentSituation, [Recommendation], UserPlanningProfile?
  ) {
    let situation = try CurrentSituationBuilder(context: context).build(now: now)
    var query = FetchDescriptor<UserPlanningProfile>()
    query.fetchLimit = 1
    let profile = try context.fetch(query).first
    let cutoff = now.addingTimeInterval(-90 * 86400)
    var records = FetchDescriptor<ExecutionRecord>(
      predicate: #Predicate { $0.date >= cutoff && $0.date <= now },
      sortBy: [SortDescriptor(\.date, order: .reverse)])
    records.fetchLimit = 1000
    let patterns = ExecutionLearning(try context.fetch(records).compactMap(\.observation))
      .suggestions
    return (
      situation,
      RecommendationEngine().recommendations(
        situation: situation,
        execution: profile?.executionProfile ?? .init(), patterns: patterns), profile
    )
  }
}

/// One local coordinator across app windows. No authorization requests occur in refresh.
/// Payloads contain stable recommendation/entity/action IDs for future interactive categories.
@MainActor final class RecommendationNotificationService {
  static let shared = RecommendationNotificationService()
  private let defaults: UserDefaults
  private let key = "intent.recommendationNotificationHistory.v1"
  private var refreshing = false
  private var refreshAgain = false
  private var revision = 0
  private(set) var lastError: String?
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  var history: RecommendationNotificationHistory {
    get {
      defaults.data(forKey: key).flatMap {
        try? JSONDecoder().decode(RecommendationNotificationHistory.self, from: $0)
      } ?? .init()
    }
    set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) } }
  }
  var available: Bool { Bundle.main.bundleIdentifier != nil }
  func requestPermission() async throws -> Bool {
    guard available else {
      throw PlanningError.invalid(
        "Reminders require the bundled Intent app. Launch the installed app to enable them.")
    }
    return try await UNUserNotificationCenter.current().requestAuthorization(options: [
      .alert, .sound,
    ])
  }
  func disable() {
    revision += 1
    guard available else { return }
    // This app owns its local notification queue, including old session reminders.
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    var state = history
    state.sent = state.sent.filter { $0.value <= Date() }
    history = state
  }
  func dismiss(_ recommendation: Recommendation, until: Date) {
    revision += 1
    var state = history
    state.dismissedUntil[recommendation.id] = until
    if let queued = state.sent[recommendation.id], queued > Date() {
      state.sent.removeValue(forKey: recommendation.id)
    }
    history = state
    if available {
      UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
        recommendation.id
      ])
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
        recommendation.id
      ])
    }
  }
  func invalidate() { revision += 1 }
  func refresh(context: ModelContext, now: Date = Date()) async {
    guard !refreshing else {
      refreshAgain = true
      return
    }
    refreshing = true
    defer {
      refreshing = false
      if refreshAgain {
        refreshAgain = false
        Task { await self.refresh(context: context) }
      }
    }
    do {
      let (_, recommendations, profile) = try RecommendationLoader.load(context: context, now: now)
      guard available else { return }
      let center = UNUserNotificationCenter.current()
      center.delegate = RecommendationNotificationDelegate.shared
      let token = revision
      let settings = await center.notificationSettings()
      guard token == revision else { return }
      guard profile?.remindersEnabled == true, settings.authorizationStatus == .authorized else {
        disable()
        return
      }
      let style = PlanningStyle(rawValue: profile?.planningStyleRaw ?? "") ?? .balanced
      let pending = await center.pendingNotificationRequests()
      guard token == revision, profile?.remindersEnabled == true else { return }
      var state = history
      let validIDs = Set(
        recommendations.filter {
          $0.expiration > now && $0.notificationEligible(style: style)
            && (state.dismissedUntil[$0.id] ?? .distantPast) <= now
        }.map(\.id))
      let delivered = await center.deliveredNotifications()
      guard token == revision, profile?.remindersEnabled == true else { return }
      center.removeDeliveredNotifications(
        withIdentifiers: delivered.filter { !validIDs.contains($0.request.identifier) }.map {
          $0.request.identifier
        })
      let queued = Dictionary(
        uniqueKeysWithValues: pending.map {
          (
            $0.identifier,
            ($0.content.userInfo["deliveryAt"] as? Double).map(Date.init(timeIntervalSince1970:))
              ?? state.sent[$0.identifier] ?? .distantPast
          )
        })
      let previousStyle = defaults.string(forKey: "intent.lastNotificationPlanningStyle")
      let stale =
        previousStyle != style.rawValue
          || defaults.string(forKey: "intent.lastNotificationLanguage")
            != L10n.language.resolved().rawValue
        ? Array(queued.keys)
        : RecommendationNotificationPolicy().invalidPendingIDs(
          queued,
          recommendations: recommendations, style: style, history: state, now: now)
      defaults.set(style.rawValue, forKey: "intent.lastNotificationPlanningStyle")
      defaults.set(L10n.language.resolved().rawValue, forKey: "intent.lastNotificationLanguage")
      center.removePendingNotificationRequests(withIdentifiers: stale)
      for id in stale where (state.sent[id] ?? .distantPast) > now {
        state.sent.removeValue(forKey: id)
      }
      // Bound persistent history, retaining stable IDs long enough to suppress repeated events.
      state.sent = state.sent.filter { $0.value > now.addingTimeInterval(-30 * 86400) }
      state.dismissedUntil = state.dismissedUntil.filter { $0.value > now }
      history = state
      let chosen = RecommendationNotificationPolicy().select(
        recommendations, style: style,
        enabled: true, authorized: true, history: state, now: now)
      for (rec, delivery) in chosen {
        guard token == revision, profile?.remindersEnabled == true,
          (PlanningStyle(rawValue: profile?.planningStyleRaw ?? "") ?? .balanced) == style
        else { return }
        let content = UNMutableNotificationContent()
        content.title = rec.title
        content.body = L("\(rec.reason) \(rec.suggestedAction) in Intent.")
        content.userInfo = [
          "recommendationID": rec.id, "type": rec.type.rawValue,
          "action": rec.action.rawValue, "entityID": rec.entityID?.uuidString ?? "",
          "expiresAt": rec.expiration.timeIntervalSince1970,
          "deliveryAt": delivery.timeIntervalSince1970,
        ]
        let trigger = UNTimeIntervalNotificationTrigger(
          timeInterval: max(1, delivery.timeIntervalSinceNow), repeats: false)
        try await center.add(.init(identifier: rec.id, content: content, trigger: trigger))
        guard token == revision, profile?.remindersEnabled == true,
          (PlanningStyle(rawValue: profile?.planningStyleRaw ?? "") ?? .balanced) == style
        else {
          center.removePendingNotificationRequests(withIdentifiers: [rec.id])
          return
        }
        state.sent[rec.id] = delivery
        history = state
      }
      lastError = nil
    } catch { lastError = error.localizedDescription }
  }
}

extension Notification.Name {
  static let intentOpenRecommendation = Notification.Name("intent.openRecommendation")
}

/// Tapping a reminder opens the live Today recommendation list, which revalidates
/// expiration and entity state. No schedule mutation runs from a stale OS payload.
final class RecommendationNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = RecommendationNotificationDelegate()
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor in
      NotificationCenter.default.post(name: .intentOpenRecommendation, object: nil)
    }
    completionHandler()
  }
}
