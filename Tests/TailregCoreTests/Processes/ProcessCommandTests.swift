import Foundation
import Testing

@testable import TailregCore

@Suite
struct `Process command tests` {
  @Test(arguments: [
    ("npm run dev", ["npm", "run", "dev"]),
    ("npm   run\tdev -- --port 3000", ["npm", "run", "dev", "--", "--port", "3000"]),
    ("tool 'a value' \"another value\"", ["tool", "a value", "another value"]),
    ("tool '' \"\"", ["tool", "", ""]),
    ("tool one\\ two \\\"quoted\\\"", ["tool", "one two", "\"quoted\""]),
    ("tool '$(literal); `literal` $HOME'", ["tool", "$(literal); `literal` $HOME"]),
    ("tool *.swift ~/project", ["tool", "*.swift", "~/project"]),
    ("tool café 🚀", ["tool", "café", "🚀"])
  ])
  func `Parses Safe Command Text`(commandLine: String, expected: [String]) throws {
    let command = try ProcessCommand(commandLine: commandLine)
    #expect([command.executable] + command.arguments == expected)
  }

  @Test(arguments: [
    ("", CommandLineParseError.empty),
    ("   \t", CommandLineParseError.empty),
    ("tool \\", CommandLineParseError.trailingEscape),
    ("tool 'unfinished", CommandLineParseError.unterminatedSingleQuote),
    ("tool \"unfinished", CommandLineParseError.unterminatedDoubleQuote),
    ("FOO=bar tool", CommandLineParseError.environmentAssignment("FOO=bar")),
    ("tool; next", CommandLineParseError.unsupportedShellSyntax(";")),
    ("tool | next", CommandLineParseError.unsupportedShellSyntax("|")),
    ("tool && next", CommandLineParseError.unsupportedShellSyntax("&")),
    ("tool > output", CommandLineParseError.unsupportedShellSyntax(">")),
    ("tool < input", CommandLineParseError.unsupportedShellSyntax("<")),
    ("tool $HOME", CommandLineParseError.unsupportedShellSyntax("$")),
    ("tool $(whoami)", CommandLineParseError.unsupportedShellSyntax("$")),
    ("tool `whoami`", CommandLineParseError.unsupportedShellSyntax("`")),
    ("tool {a,b}", CommandLineParseError.unsupportedShellSyntax("{")),
    ("tool\nnext", CommandLineParseError.unsupportedShellSyntax("\n"))
  ])
  func `Rejects Shell Syntax And Malformed Command Text`(
    commandLine: String,
    expected: CommandLineParseError
  ) {
    #expect(throws: expected) {
      _ = try ProcessCommand(commandLine: commandLine)
    }
  }

  @Test
  func `Rejects An Embedded Nul Byte`() {
    #expect(throws: CommandLineParseError.nulByte) {
      _ = try ProcessCommand(commandLine: "tool\0argument")
    }
  }

  @Test
  func `Never Launches A Rejected Injection Attempt`() throws {
    let temporaryDirectory = try TempDirectory()
    let sentinel = temporaryDirectory.url.appendingPathComponent("sentinel")
    let attempts = [
      "printf hello; touch \(sentinel.path)",
      "printf $(touch \(sentinel.path))",
      "printf `touch \(sentinel.path)`",
      "printf hello > \(sentinel.path)",
      "printf hello | touch \(sentinel.path)",
      "printf hello && touch \(sentinel.path)",
      "printf ${HOME}/\(sentinel.lastPathComponent)"
    ]

    for commandLine in attempts {
      #expect(throws: CommandLineParseError.self) {
        _ = try ProcessCommand(commandLine: commandLine)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
  }

  @Test
  func `Handles ACorpus Of Weird Input Without Crashing`() {
    let tokens = ["'", "\"", "\\", " ", ";", "$", "`", "(", ")", "{", "}", "\t", "🚀", "\0"]
    for first in tokens {
      for second in tokens {
        _ = try? ProcessCommand(commandLine: "tool\(first)\(second)")
      }
    }
  }
}
