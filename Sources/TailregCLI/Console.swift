import Foundation

/// Serialises everything the CLI prints, so lines from concurrent supervisors do not interleave.
///
/// A global actor rather than an instance per coordinator: two instances would each be ordered
/// internally and still interleave with each other on the same terminal.
@globalActor
actor Console {
  static let shared = Console()

  func write(_ message: String, toStandardError: Bool = false) {
    let data = Data((message + "\n").utf8)
    try? (toStandardError ? FileHandle.standardError : FileHandle.standardOutput)
      .write(contentsOf: data)
  }

  /// Something worth tracing that is not a failure: the work was done, but not as intended.
  func warning(_ message: String) {
    write("warning: \(message)", toStandardError: true)
  }

  /// Something that leaves the system in a state the caller did not ask for.
  func error(_ message: String) {
    write("error: \(message)", toStandardError: true)
  }
}
