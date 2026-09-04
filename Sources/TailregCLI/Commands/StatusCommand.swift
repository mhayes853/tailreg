import ArgumentParser
import Foundation
import TailregCore

public struct StatusCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show desired and observed state for the current project."
  )

  @Option(name: .long, help: "Project directory or tailreg.toml path.")
  var project: String?

  @Flag(name: .long, help: "Report every project Tailreg knows about.")
  var all = false

  @Flag(name: .long, help: "Emit the report as JSON.")
  var json = false

  public init() {}

  /// Producing a report is the whole job, so a report is a success.
  ///
  /// A project that is down is an ordinary state rather than a failure, and exiting non-zero for
  /// it would make `status` unusable in any script that also wanted to know about real faults.
  /// What went wrong, if anything, is in the report.
  public func run() async throws {
    guard !(all && project != nil) else {
      throw ValidationError("--project and --all cannot be combined")
    }
    let environment = ProcessInfo.processInfo.environment
    let coordinator = StatusCoordinator(databasePath: environment.tailregDatabasePath)
    let report = try await coordinator.run(
      StatusRequest(projectPath: project, allProjects: all)
    )
    let output =
      json
      ? try StatusJSONRenderer().render(report)
      : StatusTextRenderer().render(report)
    await Console().write(output)
  }
}
