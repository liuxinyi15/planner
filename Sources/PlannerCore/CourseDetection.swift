import Foundation

public struct DetectedCourseTitle: Equatable, Sendable {
  public var courseName: String
  public var moduleCode: String?
  public var sessionType: String
  public var key: String { moduleCode.map { "code:" + $0 } ?? "name:" + CourseDetectionService.normalizedName(courseName) }
}

public struct TimetableCourseEvent: Sendable {
  public var id: UUID
  public var sourceID: UUID?
  public var title: String
  public var upcomingCount: Int
  public init(id: UUID, sourceID: UUID? = nil, title: String, upcomingCount: Int = 1) {
    self.id = id; self.sourceID = sourceID; self.title = title; self.upcomingCount = upcomingCount
  }
}
public struct DetectedCourseCandidate: Identifiable, Sendable {
  public var id: String
  public var name: String
  public var moduleCode: String?
  public var eventIDs: [UUID]
  public var sourceIDs: [UUID]
  public var counts: [String: Int]
}

/// Conservative, local parsing. A bare unrelated calendar title is never a course.
public enum CourseDetectionService {
  public static func normalizedName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
  }
  public static func parse(_ title: String) -> DetectedCourseTitle? {
    var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let typePattern = #"(?i)(?:\s*[/|–—-]\s*|\s+)(lecture|tutorial|laboratory|lab|seminar|workshop)\s*$"#
    var kind: String?
    if let match = captures(typePattern, value) {
      kind = canonicalType(match.groups[0])
      value = String(value[..<match.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let match = captures(#"(?i)^(lecture|tutorial|laboratory|lab|seminar|workshop)\s*:\s*"#, value) {
      kind = canonicalType(match.groups[0])
      value = String(value[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var code: String?
    if let match = captures(#"\s*\(([A-Za-z]{0,8}[0-9]{3,8}[A-Za-z]?)\)\s*$"#, value) {
      code = match.groups[0].uppercased()
      value = String(value[..<match.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if kind == nil, let code, code.count == 4, Int(code).map({ (1900...2099).contains($0) }) == true { return nil }
    // Known timetable prefixes only; do not remove arbitrary words or initials.
    if let match = captures(#"(?i)^(?:LH|LC)\s+"#, value) { value = String(value[match.range.upperBound...]) }
    guard code != nil || kind != nil, value.count >= 2,
      value.rangeOfCharacter(from: .letters) != nil,
      !["lecture", "tutorial", "lab", "seminar", "workshop"].contains(normalizedName(value))
    else { return nil }
    return .init(courseName: value, moduleCode: code, sessionType: kind ?? "class")
  }
  public static func group(_ events: [TimetableCourseEvent]) -> [DetectedCourseCandidate] {
    var grouped: [String: DetectedCourseCandidate] = [:]
    let unique = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values
    for event in unique.sorted(by: { $0.title < $1.title }) {
      guard let parsed = parse(event.title) else { continue }
      var candidate = grouped[parsed.key] ?? .init(id: parsed.key, name: parsed.courseName,
        moduleCode: parsed.moduleCode, eventIDs: [], sourceIDs: [], counts: [:])
      candidate.eventIDs.append(event.id)
      if let source = event.sourceID, !candidate.sourceIDs.contains(source) { candidate.sourceIDs.append(source) }
      candidate.counts[parsed.sessionType, default: 0] += event.upcomingCount
      grouped[parsed.key] = candidate
    }
    return grouped.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
  }
  public static func matches(_ parsed: DetectedCourseTitle, moduleCode: String, name: String) -> Bool {
    if !moduleCode.isEmpty { return parsed.moduleCode == moduleCode.uppercased() }
    // A name-only acceptance cannot silently absorb another numbered module.
    return parsed.moduleCode == nil && normalizedName(parsed.courseName) == normalizedName(name)
  }
  private static func canonicalType(_ value: String) -> String {
    let lower = value.lowercased(); return lower == "laboratory" ? "lab" : lower
  }
  private static func captures(_ pattern: String, _ text: String) -> (range: Range<String.Index>, groups: [String])? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range, in: text) else { return nil }
    return (range, (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } })
  }
}
