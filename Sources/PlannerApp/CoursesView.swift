import PlannerCore
import SwiftData
import SwiftUI

struct CoursesView: View {
  @AppStorage("appLanguage") private var appLanguage = "system"
  @Environment(\.modelContext) private var context
  @Query(sort: \Course.title) private var courses: [Course]
  @Query private var events: [CalendarEvent]
  @Query private var links: [CourseSession]
  @Query private var profiles: [UserPlanningProfile]
  @State private var chosen = Set<String>()
  @State private var name = ""
  @State private var selected: Course?
  @State private var error: String?
  var body: some View {
    let _ = appLanguage
    let candidates = CourseDiscoveryRepository.candidates(events: events, courses: courses,
      ignored: profiles.first?.ignoredCourseKeys ?? [])
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(eyebrow: L("Learning in context"), title: L("Courses"),
          subtitle: L("Your timetable, study work and learning needs, brought together."))
        if let error { Text(error).foregroundStyle(.red) }
        if !candidates.isEmpty {
          VStack(alignment: .leading, spacing: 16) {
            Text(L("Courses detected from your timetable")).font(.title2.bold())
            Text(L("Review once. Matching classes from these calendar sources will stay connected.")).foregroundStyle(.secondary)
            Text(L("Class counts cover the next 12 weeks.")).font(.caption).foregroundStyle(.secondary)
            ForEach(candidates) { candidate in
              HStack {
                Toggle(isOn: Binding(get: { chosen.contains(candidate.id) }, set: {
                  if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) }
                })) {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.name).font(.headline)
                    if let code = candidate.moduleCode { Text(code).font(.caption.monospaced()) }
                    Text(candidate.counts.keys.sorted().map { L("\(candidate.counts[$0] ?? 0) \(L10n.label($0))") }.joined(separator: " · ")).font(.caption)
                    if courses.contains(where: { CourseDetectionService.normalizedName($0.title) == CourseDetectionService.normalizedName(candidate.name) }) {
                      Text(L("Connect to the saved course when unambiguous")).font(.caption).foregroundStyle(.teal)
                    }
                  }
                }
                Spacer()
                Button(L("Ignore")) { perform { try CourseDiscoveryRepository.ignore(candidate.id, context: context); chosen.remove(candidate.id) } }
                Button(L("Add")) { accept([candidate.id]) }.buttonStyle(.bordered)
              }.padding(.vertical, 6)
              Divider()
            }
            HStack {
              Button(L("Add selected")) { accept(chosen) }.disabled(chosen.intersection(candidates.map(\.id)).isEmpty)
              Button(L("Add all")) { accept(Set(candidates.map(\.id))) }.buttonStyle(.borderedProminent)
            }
          }.padding(22).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        }
        Text(L("Your learning contexts")).font(.title2.bold())
        if courses.isEmpty {
          EmptyState(title: L("Start with your timetable or study material"),
            text: L("Import a timetable in Calendar or a syllabus with Smart Import. Review detected courses here."), icon: "graduationcap")
        }
        ForEach(courses) { course in
          Button { selected = course } label: {
            HStack(spacing: 16) {
              Image(systemName: "graduationcap").font(.title2).foregroundStyle(.teal)
              VStack(alignment: .leading, spacing: 6) {
                Text(course.title).font(.headline)
                if !course.moduleCode.isEmpty { Text(course.moduleCode).font(.caption.monospaced()).foregroundStyle(.secondary) }
                let focus = course.currentFocus.isEmpty ? course.topic : course.currentFocus
                if !focus.isEmpty { Text(focus).lineLimit(2).foregroundStyle(.secondary) }
                let count = Set(links.filter { $0.course?.id == course.id }.compactMap { $0.event?.id }).count
                if count > 0 { Text(L("\(count) timetable entries connected")).font(.caption).foregroundStyle(.secondary) }
              }
              Spacer()
              Image(systemName: "chevron.right")
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
              .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
          }.buttonStyle(.plain)
        }
        DisclosureGroup(L("Other ways to add a course")) {
          HStack {
            TextField(L("Course name"), text: $name)
            Button(L("Add manually")) {
              perform {
                let course = Course(name.trimmingCharacters(in: .whitespacesAndNewlines))
                context.insert(course); try context.save(); name = ""; selected = course
              }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }.padding(.vertical, 8)
        }
        if let profile = profiles.first, !profile.ignoredCourseKeys.isEmpty {
          DisclosureGroup(L("Ignored timetable modules")) {
            Text(L("Ignored modules stay hidden across imports and subscription refreshes.")).font(.caption)
            Button(L("Review ignored modules again")) {
              perform { profile.ignoredCourseKeys = []; try context.save() }
            }
          }
        }
      }.padding(32)
    }.sheet(item: $selected) { CourseWorkspace(course: $0) }
  }
  private func accept(_ ids: Set<String>) {
    perform { _ = try CourseDiscoveryRepository.accept(ids, context: context); chosen.subtract(ids) }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action(); error = nil } catch { context.rollback(); self.error = error.localizedDescription }
  }
}
