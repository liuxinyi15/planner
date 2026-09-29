import Foundation

public enum AppLanguage: String, CaseIterable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"
  public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
    guard self == .system else { return self }
    return preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
  }
}

/// English keys and stable model identifiers are independent of the selected UI language.
public enum L10n {
  public static var language: AppLanguage {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system")
      ?? .system
  }
  public static var locale: Locale { Locale(identifier: language.resolved().rawValue) }
  public static func label(_ key: String, language: AppLanguage = language) -> String {
    if language.resolved() == .simplifiedChinese { return chinese[key] ?? key }
    let statuses = [
      "planned": "Planned", "complete": "Complete", "partial": "Partial", "skip": "Skipped",
      "postponed": "Postponed", "abandoned": "Abandoned", "unknown": "Unspecified",
      "low": "Low", "medium": "Medium", "high": "High", "critical": "Critical",
      "lecture": "Lecture", "lab": "Lab",
    ]
    return statuses[key] ?? key
  }
  public static func render(_ message: LocalizedMessage, language: AppLanguage = language) -> String
  {
    let template = label(message.key, language: language)
    // Replace ranges from the original template so user text cannot introduce placeholders.
    let matches = placeholder.matches(
      in: template, range: NSRange(template.startIndex..., in: template))
    let output = NSMutableString(string: template)
    for match in matches.reversed() {
      let token = (template as NSString).substring(with: match.range(at: 1))
      if let index = Int(token), message.values.indices.contains(index) {
        output.replaceCharacters(in: match.range, with: message.values[index])
      }
    }
    return output as String
  }
  private static let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
}

public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  public let key: String
  public let values: [String]
  public init(key: String, values: [String] = []) {
    self.key = key
    self.values = values
  }
  public init(stringLiteral value: String) {
    key = value
    values = []
  }
  public init(stringInterpolation: StringInterpolation) {
    key = stringInterpolation.key
    values = stringInterpolation.values
  }
  public struct StringInterpolation: StringInterpolationProtocol {
    var key = ""
    var values: [String] = []
    public init(literalCapacity: Int, interpolationCount: Int) {
      values.reserveCapacity(interpolationCount)
    }
    public mutating func appendLiteral(_ literal: String) { key += literal }
    public mutating func appendInterpolation<T>(_ value: T) {
      key += "{\(values.count)}"
      values.append(String(describing: value))
    }
  }
}
public func L(_ message: LocalizedMessage) -> String { L10n.render(message) }

extension Date {
  public func plannerFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle)
    -> String
  {
    formatted(Date.FormatStyle(date: date, time: time).locale(L10n.locale))
  }
}

extension L10n {
  /// Only for app-generated, previously stored explanations. Never apply to user titles/notes.
  public static func systemText(_ text: String, language: AppLanguage = language) -> String {
    guard language.resolved() == .simplifiedChinese else { return text }
    if let exact = chinese[text] { return exact }
    for (key, regex) in systemTemplates {
      guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
      else { continue }
      let values = (1..<match.numberOfRanges).map {
        label((text as NSString).substring(with: match.range(at: $0)), language: language)
      }
      return render(LocalizedMessage(key: key, values: values), language: language)
    }
    return text
  }
  private static let systemTemplates: [(String, NSRegularExpression)] = {
    let marker = try! NSRegularExpression(pattern: #"\{\d+\}"#)
    return chinese.keys.filter { $0.contains("{0}") }.sorted {
      let left = $0.components(separatedBy: marker).joined().count
      let right = $1.components(separatedBy: marker).joined().count
      return left == right ? $0 < $1 : left > right
    }.compactMap { key in
      let pattern =
        "^"
        + key.components(separatedBy: marker).map(NSRegularExpression.escapedPattern(for:)).joined(
          separator: "(.+?)") + "$"
      return (key, try! NSRegularExpression(pattern: pattern))
    }
  }()
  public static var calendar: Calendar {
    var value = Calendar.current
    value.locale = locale
    return value
  }
}
extension String {
  fileprivate func components(separatedBy regex: NSRegularExpression) -> [String] {
    let source = self as NSString
    let matches = regex.matches(in: self, range: NSRange(location: 0, length: source.length))
    var result: [String] = []
    var start = 0
    for match in matches {
      result.append(
        source.substring(with: NSRange(location: start, length: match.range.location - start)))
      start = NSMaxRange(match.range)
    }
    result.append(source.substring(from: start))
    return result
  }
}
