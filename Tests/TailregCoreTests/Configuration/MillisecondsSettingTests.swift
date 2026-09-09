import Testing

@testable import TailregCore

@Suite
struct `Milliseconds setting tests` {
  private let setting = MillisecondsSetting(
    environmentKey: "TAILREG_TEST_MS",
    defaultValue: .seconds(2)
  )

  @Test
  func `A millisecond setting falls back to its default when unconfigured`() throws {
    #expect(try setting.resolve(from: [:]) == .seconds(2))
  }

  @Test
  func `A millisecond setting reads a configured value`() throws {
    #expect(try setting.resolve(from: ["TAILREG_TEST_MS": "1500"]) == .milliseconds(1500))
  }

  @Test(arguments: ["0", "-1", "soon", ""])
  func `A millisecond setting rejects values that are not positive milliseconds`(_ value: String) {
    #expect(throws: MillisecondsSettingError.invalid(key: "TAILREG_TEST_MS", value: value)) {
      try setting.resolve(from: ["TAILREG_TEST_MS": value])
    }
  }
}
