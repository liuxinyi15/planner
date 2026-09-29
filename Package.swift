// swift-tools-version: 6.0
import Foundation
import PackageDescription

let coreOnly = ProcessInfo.processInfo.environment["PLANNER_CORE_ONLY"] == "1"
let package = Package(
  name: "IntentPlanner", platforms: [.macOS(.v14)],
  products: coreOnly ? [] : [.executable(name: "IntentPlanner", targets: ["PlannerApp"])],
  targets: [
    .target(name: "PlannerCore"),
    .testTarget(name: "PlannerCoreTests", dependencies: ["PlannerCore"]),
  ] + (coreOnly ? [] : [.executableTarget(name: "PlannerApp", dependencies: ["PlannerCore"]), .testTarget(name: "PlannerAppTests", dependencies: ["PlannerApp", "PlannerCore"])]),
  swiftLanguageModes: [.v5])
