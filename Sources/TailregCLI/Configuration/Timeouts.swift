import TailregCore

extension MillisecondsSetting {
  /// How long `up --bg` waits for the background process to report that it is ready.
  static let backgroundStartup = MillisecondsSetting(
    environmentKey: "TAILREG_BACKGROUND_STARTUP_TIMEOUT_MS",
    defaultValue: .seconds(60)
  )

  /// How long `up` waits for an application to listen on its port.
  static let applicationStartup = MillisecondsSetting(
    environmentKey: "TAILREG_STARTUP_TIMEOUT_MS",
    defaultValue: .seconds(30)
  )
}
