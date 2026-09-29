import Foundation

public struct ImportedEvent: Identifiable, Sendable {
  public var id: String { uid + "|" + (recurrenceID ?? "master") }
  public init(
    uid: String, title: String, start: Date, end: Date, notes: String = "", location: String = "",
    url: String = "", rule: String? = nil, recurrenceID: String? = nil, excluded: [Date] = [],
    allDay: Bool = false, cancelled: Bool = false, timeZoneID: String = TimeZone.current.identifier
  ) {
    self.uid = uid
    self.title = title
    self.start = start
    self.end = end
    self.notes = notes
    self.location = location
    self.url = url
    self.rule = rule
    self.recurrenceID = recurrenceID
    self.excluded = excluded
    self.allDay = allDay
    self.cancelled = cancelled
    self.timeZoneID = timeZoneID
  }
  public var uid: String
  public var title: String
  public var start: Date
  public var end: Date
  public var notes: String
  public var location: String
  public var url: String
  public var rule: String?
  public var recurrenceID: String?
  public var excluded: [Date]
  public var allDay: Bool
  public var timeZoneID: String
  public var cancelled: Bool
}
public struct ICSImport: Sendable {
  public var events: [ImportedEvent]
  public var warnings: [String]
}
public struct ICSParser {
  public init() {}
  public func parse(_ text: String) throws -> ICSImport {
    guard text.contains("BEGIN:VCALENDAR") else {
      throw PlanningError.invalid(L("This file is not an iCalendar calendar."))
    }
    let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\n ", with: ""
    ).replacingOccurrences(of: "\n\t", with: "")
    var events: [ImportedEvent] = []
    var warnings: [String] = []
    var fields: [(String, String)] = []
    var inside = false
    for line in unfolded.components(separatedBy: "\n") {
      if line == "BEGIN:VEVENT" {
        fields = []
        inside = true
        continue
      }
      if line == "END:VEVENT" {
        inside = false
        func field(_ name: String) -> (String, String)? {
          fields.first { $0.0.components(separatedBy: ";")[0] == name }
        }
        guard let uid = field("UID")?.1, let startField = field("DTSTART"),
          let start = date(startField.1, parameters: startField.0)
        else {
          warnings.append(L("An event without a valid UID or DTSTART was skipped."))
          continue
        }
        let allDay = startField.0.contains("VALUE=DATE") || startField.1.count == 8
        let end =
          field("DTEND").flatMap { date($0.1, parameters: $0.0) }
          ?? start.addingTimeInterval(allDay ? 86400 : 3600)
        guard end > start else {
          warnings.append(L("Invalid duration for \(uid)."))
          continue
        }
        let rule = field("RRULE")?.1
        if let rule, !supported(rule) {
          warnings.append(
            L(
              "Unsupported recurrence for \(field("SUMMARY")?.1 ?? uid); only its original occurrence will be shown."
            )
          )
        }
        if field("DURATION") != nil {
          warnings.append(L("DURATION is not supported; verify the default end time for \(uid)."))
        }
        events.append(
          ImportedEvent(
            uid: uid, title: unescape(field("SUMMARY")?.1 ?? L("Untitled event")), start: start,
            end: end, notes: unescape(field("DESCRIPTION")?.1 ?? ""),
            location: unescape(field("LOCATION")?.1 ?? ""), url: field("URL")?.1 ?? "", rule: rule,
            recurrenceID: field("RECURRENCE-ID").flatMap {
              date($0.1, parameters: $0.0)?.ISO8601Format()
            },
            excluded: fields.filter { $0.0.hasPrefix("EXDATE") }.flatMap { pair in
              pair.1.split(separator: ",").compactMap { date(String($0), parameters: pair.0) }
            }, allDay: allDay, cancelled: field("STATUS")?.1 == "CANCELLED",
            timeZoneID: zone(value: startField.1, parameters: startField.0).identifier))
        continue
      }
      if inside, let colon = line.firstIndex(of: ":") {
        fields.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
      }
    }
    return ICSImport(events: events, warnings: warnings)
  }
  public func occurrences(_ event: ImportedEvent, in range: Range<Date>, limit: Int = 1000)
    -> [ImportedEvent]
  {
    guard !event.cancelled else { return [] }
    guard let rule = event.rule, supported(rule), event.recurrenceID == nil else {
      return event.start < range.upperBound && event.end > range.lowerBound ? [event] : []
    }
    let values = Dictionary(
      rule.split(separator: ";").compactMap { item -> (String, String)? in
        let p = item.split(separator: "=", maxSplits: 1)
        return p.count == 2 ? (String(p[0]), String(p[1])) : nil
      }, uniquingKeysWith: { _, b in b })
    let interval = max(1, Int(values["INTERVAL"] ?? "1") ?? 1)
    let count = Int(values["COUNT"] ?? "") ?? Int.max
    let until = values["UNTIL"].flatMap { date($0, parameters: "") } ?? .distantFuture
    let component: Calendar.Component = values["FREQ"] == "WEEKLY" ? .weekOfYear : .day
    var recurrenceCalendar = Calendar(identifier: .gregorian)
    recurrenceCalendar.timeZone = TimeZone(identifier: event.timeZoneID) ?? .current
    var result: [ImportedEvent] = []
    var current = event.start
    var index = 0
    while current < range.upperBound && current <= until && index < count && index < 10000
      && result.count < limit
    {
      if current.addingTimeInterval(event.end.timeIntervalSince(event.start)) > range.lowerBound
        && !event.excluded.contains(current)
      {
        var occurrence = event
        occurrence.start = current
        occurrence.end = current.addingTimeInterval(event.end.timeIntervalSince(event.start))
        occurrence.recurrenceID = ISO8601DateFormatter().string(from: current)
        result.append(occurrence)
      }
      index += 1
      guard let next = recurrenceCalendar.date(byAdding: component, value: interval, to: current)
      else { break }
      current = next
    }
    return result
  }
  private func supported(_ rule: String) -> Bool {
    let parts = rule.split(separator: ";").map { $0.split(separator: "=", maxSplits: 1) }
    return parts.allSatisfy {
      $0.count == 2 && ["FREQ", "INTERVAL", "COUNT", "UNTIL"].contains(String($0[0]))
    } && (rule.contains("FREQ=DAILY") || rule.contains("FREQ=WEEKLY"))
  }
  private func zone(value: String, parameters: String) -> TimeZone {
    if value.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
    let identifier = parameters.components(separatedBy: "TZID=").dropFirst().first?.components(
      separatedBy: ";"
    ).first?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return identifier.flatMap(TimeZone.init(identifier:)) ?? .current
  }
  private func date(_ value: String, parameters: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.isLenient = false
    if value.hasSuffix("Z") {
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
    } else if let zone = parameters.components(separatedBy: "TZID=").dropFirst().first?.components(
      separatedBy: ";"
    ).first {
      formatter.timeZone = TimeZone(
        identifier: zone.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    } else {
      formatter.timeZone = .current
    }
    formatter.dateFormat =
      value.count == 8
      ? "yyyyMMdd" : (value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
    return formatter.date(from: value)
  }
  private func unescape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
      .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }
}
