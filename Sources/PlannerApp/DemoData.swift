import Foundation
import SwiftData

/// Explicit opt-in development content. Call only with an in-memory container.
@MainActor enum DemoData {
  static func populate(_ context: ModelContext) throws {
    for title in ["Machine Learning", "Neural Computation", "Human-Computer Interaction"] {
      context.insert(Course(title))
    }
    let study = Area("Study", symbol: "graduationcap")
    let goal = Goal(
      title: "Understand logistic regression", outcome: "Explain and implement the classifier",
      area: study)
    let plan = Plan(
      title: "A week of deliberate practice", purpose: "Understand → practice → review", goal: goal)
    context.insert(study)
    context.insert(goal)
    context.insert(plan)
    let day = Calendar.current.startOfDay(for: Date())
    let examples: [(String, String, Int, Int, [String])] = [
      (
        "Logistic regression", "Study", 14, 60,
        [
          "Review the lecture", "Solve exercises 1–3",
          "Explain the loss function in your own words",
        ]
      ),
      (
        "Badminton practice", "Training", 18, 90,
        ["Warm up", "Practice rear-court footwork", "Play two matches", "Cool down"]
      ),
      (
        "Prepare dinners for the week", "Meals", 20, 45,
        ["Choose three meals", "List ingredients", "Prepare vegetables"]
      ),
    ]
    for (title, area, hour, duration, actions) in examples {
      let session = Session(
        title: title,
        purpose: area == "Study"
          ? "Build understanding through practice." : "Make time for a balanced week.",
        minutes: duration, start: Calendar.current.date(byAdding: .hour, value: hour, to: day),
        area: area, definitionOfDone: "Finish and check each action.",
        plan: area == "Study" ? plan : nil)
      session.actions = actions.map(Action.init)
      context.insert(session)
    }
    context.insert(
      Note(
        title: "London day trip",
        body: "Choose a Saturday, check train times, and leave enough time for the return journey.")
    )
    context.insert(UserPlanningProfile())
    try context.save()
  }
}
