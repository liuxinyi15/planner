import Foundation

public struct FreeWindow: Codable, Equatable, Sendable {
  public var start: Date
  public var end: Date
  public var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
  public init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }
}

/// Finds gaps only. Does not rank slots, schedule work or mutate commitments.
public enum AvailabilityWindows {
  public static func find(
    in range: Range<Date>, busy: [BusyInterval], startHour: Int,
    endHour: Int, minimumMinutes: Int = 15, calendar: Calendar = .current
  ) -> [FreeWindow] {
    guard range.lowerBound < range.upperBound, (0...23).contains(startHour),
      (1...24).contains(endHour), endHour > startHour, minimumMinutes > 0
    else { return [] }
    let occupied = busy.filter {
      $0.end > range.lowerBound && $0.start < range.upperBound && $0.end > $0.start
    }.sorted { $0.start < $1.start }
    var day = calendar.startOfDay(for: range.lowerBound)
    var result: [FreeWindow] = []
    while day < range.upperBound {
      guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
        let opening = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day)
      else { break }
      let closing =
        endHour == 24
        ? nextDay : calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day)!
      let start = max(range.lowerBound, opening)
      let end = min(range.upperBound, closing)
      var cursor = start
      if start < end {
        for interval in occupied where interval.end > start && interval.start < end {
          let gapEnd = min(end, interval.start)
          if gapEnd.timeIntervalSince(cursor) >= Double(minimumMinutes * 60) {
            result.append(.init(start: cursor, end: gapEnd))
          }
          cursor = max(cursor, min(end, interval.end))
        }
        if end.timeIntervalSince(cursor) >= Double(minimumMinutes * 60) {
          result.append(.init(start: cursor, end: end))
        }
      }
      day = nextDay
    }
    return result
  }
}
