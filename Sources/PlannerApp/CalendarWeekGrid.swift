import PlannerCore
import SwiftUI

struct CalendarWeekGrid: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  let start: Date
  let items: (Date) -> [CalendarDisplayItem]
  let select: (CalendarDisplayItem) -> Void
  let create: (Date) -> Void
  private let hourHeight: CGFloat = 64
  private let gutter: CGFloat = 54
  private var days: [Date] {
    (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! }
  }
  var body: some View {
    let _ = appLanguage
    GeometryReader { geometry in
      let width = max(90, (geometry.size.width - gutter) / 7)
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            Text(L("Time")).font(.caption).frame(width: gutter)
            ForEach(days, id: \.self) { day in
              VStack(spacing: 5) {
                Text(day.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale))).font(
                  .caption)
                Text(day.formatted(.dateTime.month().day().locale(L10n.locale))).font(.headline)
              }.foregroundStyle(Calendar.current.isDateInToday(day) ? .teal : .primary)
                .frame(width: width, height: 54)
            }
          }
          HStack(alignment: .top, spacing: 0) {
            Text(L("All day")).font(.caption2).foregroundStyle(.secondary).frame(
              width: gutter, height: 30)
            ForEach(days, id: \.self) { day in
              VStack(spacing: 3) {
                ForEach(items(day).filter(\.allDay)) { item in
                  eventButton(item).frame(minHeight: 26)
                }
              }.padding(3).frame(width: width, alignment: .topLeading)
            }
          }.frame(minHeight: 34).background(.quaternary.opacity(0.25))
          Divider()
          ScrollViewReader { scroll in
            ScrollView(.vertical) {
              ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                  ForEach(0..<24, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 0) {
                      Text(String(format: "%02d:00", hour)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: gutter)
                      Rectangle().fill(.quaternary).frame(height: 1)
                    }.frame(height: hourHeight, alignment: .top).id(hour)
                  }
                }
                HStack(spacing: 0) {
                  Color.clear.frame(width: gutter)
                  ForEach(days, id: \.self) { day in
                    dayColumn(day, width: width)
                  }
                }
              }.frame(width: gutter + 7 * width, height: 24 * hourHeight)
            }.frame(height: 540).onAppear { scroll.scrollTo(8, anchor: .top) }
          }
        }.frame(width: gutter + 7 * width)
      }.background(.background).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }.frame(height: 690)
  }
  private func dayColumn(_ day: Date, width: CGFloat) -> some View {
    let rows = items(day)
    let positions = WeekGridLayout.placements(
      rows.map { .init(id: $0.id, start: $0.start, end: $0.end, allDay: $0.allDay) }, on: day)
    return ZStack(alignment: .topLeading) {
      VStack(spacing: 0) {
        ForEach(0..<24, id: \.self) { hour in
          Button {
            if let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day)
            {
              create(date)
            }
          } label: {
            Rectangle().fill(
              Calendar.current.isDateInToday(day) ? Color.teal.opacity(0.035) : Color.clear
            )
            .contentShape(Rectangle())
          }.buttonStyle(.plain).frame(height: hourHeight)
            .accessibilityLabel(L("Create a session at \(hour):00"))
        }
      }.overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
      ForEach(positions) { position in
        if let item = rows.first(where: { $0.id == position.id }) {
          eventButton(item)
            .frame(
              width: max(12, width / Double(position.laneCount) - 4),
              height: max(16, (position.endMinute - position.startMinute) / 60 * hourHeight - 2)
            )
            .offset(
              x: Double(position.lane) * width / Double(position.laneCount) + 2,
              y: position.startMinute / 60 * hourHeight)
        }
      }
      TimelineView(.periodic(from: .now, by: 60)) { timeline in
        if Calendar.current.isDate(timeline.date, inSameDayAs: day) {
          let parts = Calendar.current.dateComponents([.hour, .minute], from: timeline.date)
          Rectangle().fill(.red).frame(width: width, height: 1.5)
            .offset(y: Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight)
            .allowsHitTesting(false)
        }
      }
    }.frame(width: width, height: 24 * hourHeight)
  }
  private func eventButton(_ item: CalendarDisplayItem) -> some View {
    let color: Color = item.event != nil ? .indigo : (item.suggestion != nil ? .orange : .teal)
    return Button {
      select(item)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Label(
          item.title,
          systemImage: item.event != nil
            ? "lock.fill" : (item.suggestion != nil ? "sparkles" : "checkmark.circle")
        )
        .font(.caption.bold()).lineLimit(2)
        if !item.allDay {
          Text(item.start.plannerFormatted(date: .omitted, time: .shortened)).font(.caption2)
            .lineLimit(1)
        }
      }.padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(color).background(color.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
          RoundedRectangle(cornerRadius: 5).stroke(
            color.opacity(0.45),
            style: StrokeStyle(lineWidth: 1, dash: item.suggestion == nil ? [] : [4, 3]))
        )
        .clipped()
    }.buttonStyle(.plain).help(
      item.title + " · "
        + (item.allDay
          ? L("All day") : item.start.plannerFormatted(date: .abbreviated, time: .shortened)))
  }
}
