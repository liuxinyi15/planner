import Foundation

public struct WeekGridInterval: Sendable {
  public var id: String
  public var start: Date
  public var end: Date
  public var allDay: Bool
  public init(id: String, start: Date, end: Date, allDay: Bool = false) {
    self.id = id
    self.start = start
    self.end = end
    self.allDay = allDay
  }
}
public struct WeekGridPlacement: Identifiable, Sendable {
  public var id: String
  public var startMinute: Double
  public var endMinute: Double
  public var lane: Int
  public var laneCount: Int
}
public enum WeekGridLayout {
  /// Monday–Sunday is stable across UI languages. Date arithmetic follows the local calendar/DST.
  public static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
    let day = calendar.startOfDay(for: date)
    let offset = (calendar.component(.weekday, from: day) + 5) % 7
    return calendar.date(byAdding: .day, value: -offset, to: day)!
  }
  public static func placements(
    _ intervals: [WeekGridInterval], on day: Date,
    calendar: Calendar = .current
  ) -> [WeekGridPlacement] {
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    func minute(_ date: Date) -> Double {
      if date <= start { return 0 }
      if date >= end { return 1440 }
      let c = calendar.dateComponents([.hour, .minute, .second], from: date)
      return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }
    var clipped: [WeekGridPlacement] = []
    for value in intervals
    where !value.allDay && value.end > value.start && value.start < end && value.end > start {
      let top: Double = minute(max(start, value.start))
      let bottom: Double = minute(min(end, value.end))
      let visibleBottom: Double = min(1440.0, max(top + 20.0, bottom))
      clipped.append(
        WeekGridPlacement(
          id: value.id, startMinute: top, endMinute: visibleBottom, lane: 0, laneCount: 1))
    }
    clipped.sort {
      if $0.startMinute == $1.startMinute { return $0.id < $1.id }
      return $0.startMinute < $1.startMinute
    }
    var result: [WeekGridPlacement] = []
    var group: [WeekGridPlacement] = []
    var groupEnd: Double = -1
    func finishGroup() {
      var ends: [Double] = []
      for var item in group {
        let lane = ends.firstIndex { $0 <= item.startMinute } ?? ends.count
        if lane == ends.count { ends.append(item.endMinute) } else { ends[lane] = item.endMinute }
        item.lane = lane
        result.append(item)
      }
      for index in (result.count - group.count)..<result.count {
        result[index].laneCount = ends.count
      }
      group = []
      groupEnd = -1
    }
    for item in clipped {
      if !group.isEmpty && item.startMinute >= groupEnd { finishGroup() }
      group.append(item)
      groupEnd = max(groupEnd, item.endMinute)
    }
    if !group.isEmpty { finishGroup() }
    return result
  }
}
