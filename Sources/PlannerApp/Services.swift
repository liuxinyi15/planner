import Foundation
import PlannerCore
import Security
import SwiftData
import UserNotifications

enum KeychainStore {
  static func read() -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.intentplanner.api", kSecAttrAccount as String: "api-key",
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
  static func save(_ key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.intentplanner.api", kSecAttrAccount as String: "api-key",
    ]
    guard !key.isEmpty else { throw PlanningError.invalid(L("Enter a key before saving.")) }
    let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw PlanningError.invalid(L("Could not update the credential in Keychain."))
    }
    var item = query
    item[kSecValueData as String] = Data(key.utf8)
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw PlanningError.invalid(L("Could not save the credential in Keychain."))
    }
  }
}
@MainActor enum CalendarRepository {
  static func upsert(
    _ imported: [ImportedEvent], source: CalendarSource, context: ModelContext,
    replace: Bool = false
  ) throws {
    let existing = try context.fetch(FetchDescriptor<CalendarEvent>()).filter {
      $0.source?.id == source.id
    }
    let incoming = Set(imported.map(\.id))
    if replace {
      let removed = existing.filter { !incoming.contains($0.remoteID) }
      let removedIDs = Set(removed.map(\.id))
      for link in try context.fetch(FetchDescriptor<CourseSession>()) where link.event.map({ removedIDs.contains($0.id) }) == true {
        context.delete(link)
      }
      for event in removed { context.delete(event) }
    }
    var indexed = Dictionary(
      existing.map { ($0.remoteID, $0) }, uniquingKeysWith: { first, _ in first })
    for value in imported {
      let event =
        indexed[value.id]
        ?? CalendarEvent(
          remoteID: value.id, title: value.title, start: value.start, end: value.end, source: source
        )
      if event.modelContext == nil { context.insert(event) }
      indexed[value.id] = event
      event.timeZoneID = value.timeZoneID
      event.title = value.title
      event.start = value.start
      event.end = value.end
      event.details = value.notes
      event.location = value.location
      event.rule = value.rule
      event.excluded = value.excluded
      event.allDay = value.allDay
      event.cancelled = value.cancelled
      event.url = value.url
      event.recurrenceID = value.recurrenceID
    }
    source.lastSync = Date()
    try CourseDiscoveryRepository.reconcile(context: context)
    try context.save()
  }
  static func expand(
    _ events: [CalendarEvent], range: Range<Date>, aiOnly: Bool = false, busyOnly: Bool = false
  ) -> [ImportedEvent] {
    events.filter { event in
      (!aiOnly || event.source?.allowAI == true) && (!busyOnly || event.source?.useAsBusy != false)
    }.flatMap { event in
      let value = ImportedEventFromModel(event)
      return ICSParser().occurrences(value, in: range).filter { occurrence in
        event.recurrenceID != nil
          || !events.contains { override in
            override.source?.id == event.source?.id
              && override.remoteID.components(separatedBy: "|").first
                == event.remoteID.components(separatedBy: "|").first
              && override.recurrenceID != nil && override.recurrenceID == occurrence.recurrenceID
          }
      }
    }
  }
  private static func ImportedEventFromModel(_ event: CalendarEvent) -> ImportedEvent {
    ImportedEvent(
      uid: event.remoteID, title: event.title, start: event.start, end: event.end,
      notes: event.details, location: event.location, url: event.url, rule: event.rule,
      recurrenceID: event.recurrenceID, excluded: event.excluded, allDay: event.allDay,
      cancelled: event.cancelled, timeZoneID: event.timeZoneID)
  }

  static func fetch(url: String) async throws -> ICSImport {
    let normalized = url.replacingOccurrences(of: "webcal://", with: "https://")
    guard let endpoint = URL(string: normalized), endpoint.scheme == "https", endpoint.host != nil
    else { throw PlanningError.invalid(L("Use an HTTPS or WebCal calendar URL.")) }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      data.count < 10_000_000, let text = String(data: data, encoding: .utf8)
    else {
      throw PlanningError.invalid(
        L("The subscription did not return a valid calendar under 10 MB."))
    }
    return try ICSParser().parse(text)
  }
}
