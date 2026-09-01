import ArgumentParser

public struct TailregCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "tailreg",
    abstract: "Expose and observe local project applications over Tailscale.",
    subcommands: [UpCommand.self, MuxRunCommand.self],
    defaultSubcommand: UpCommand.self
  )

  public init() {}
}
