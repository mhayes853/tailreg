import ArgumentParser
import Foundation
import TailregCore

public struct DownCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "down",
    abstract: "Stop or detach applications in the current project."
  )

  @Option(name: .long, help: "Project directory or tailreg.toml path.")
  var project: String?

  @Flag(name: .long, help: "Do not change Tailscale when removing the project's binding.")
  var localOnly = false

  @Argument(help: "Configured or running application names. Omit to stop the whole project.")
  var applications: [String] = []

  public init() {}

  public func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    let coordinator = DownCoordinator(
      databasePath: environment["TAILREG_DATABASE_PATH"] ?? defaultTailregDatabasePath(),
      environment: environment
    )
    let result: DownResult
    do {
      result = try await coordinator.run(
        DownRequest(
          projectPath: project,
          applicationNames: applications,
          localOnly: localOnly
        )
      )
    } catch let error as DownError {
      guard case .unknownApplication = error else { throw error }
      throw ValidationError(error.description)
    }

    // The status reports only whether everything selected ended up down. An application that had
    // to be killed is still down, and says so through a warning rather than a failing exit code.
    guard result.isClean else { throw DownError.notFullyStopped }
  }
}
