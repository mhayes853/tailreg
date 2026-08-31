import Foundation

/// A command that can be launched without invoking a shell.
///
/// `executable` is either an absolute or relative path, or the name of an executable found in
/// `PATH`. Arguments are passed directly to the child process and are never shell-expanded.
public struct ProcessCommand: Sendable, Equatable {
  public var executable: String
  public var arguments: [String]
  public var workingDirectory: URL?

  public init(executable: String, arguments: [String] = [], workingDirectory: URL? = nil) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }

  /// Parses command text into an argv command without invoking shell syntax.
  ///
  /// Spaces, quotes, and backslashes use familiar command-line spelling. Shell control
  /// operators and expansions are rejected rather than interpreted.
  public init(commandLine: String, workingDirectory: URL? = nil) throws {
    let words = try CommandLineParser.parse(commandLine)
    guard let executable = words.first else {
      throw CommandLineParseError.empty
    }
    self.init(
      executable: executable,
      arguments: Array(words.dropFirst()),
      workingDirectory: workingDirectory
    )
  }
}

public enum CommandLineParseError: Error, Sendable, Equatable {
  case empty
  case nulByte
  case trailingEscape
  case unterminatedSingleQuote
  case unterminatedDoubleQuote
  case unsupportedShellSyntax(Character)
  case environmentAssignment(String)
}

enum CommandLineParser {
  private enum State {
    case unquoted
    case singleQuoted
    case doubleQuoted
  }

  static func parse(_ commandLine: String) throws -> [String] {
    var words: [String] = []
    var word = ""
    var wordStarted = false
    var state = State.unquoted
    let characters = Array(commandLine)
    var index = 0

    func finishWord() throws {
      guard wordStarted else { return }
      if words.isEmpty, isEnvironmentAssignment(word) {
        throw CommandLineParseError.environmentAssignment(word)
      }
      words.append(word)
      word = ""
      wordStarted = false
    }

    while index < characters.count {
      let character = characters[index]
      index += 1

      if character == "\0" {
        throw CommandLineParseError.nulByte
      }
      if character.isNewline {
        throw CommandLineParseError.unsupportedShellSyntax(character)
      }

      switch state {
      case .unquoted:
        if character.isWhitespace {
          try finishWord()
        } else if character == "'" {
          wordStarted = true
          state = .singleQuoted
        } else if character == "\"" {
          wordStarted = true
          state = .doubleQuoted
        } else if character == "\\" {
          guard index < characters.count else { throw CommandLineParseError.trailingEscape }
          wordStarted = true
          word.append(characters[index])
          index += 1
        } else if isUnsupportedShellSyntax(character) {
          throw CommandLineParseError.unsupportedShellSyntax(character)
        } else {
          wordStarted = true
          word.append(character)
        }

      case .singleQuoted:
        if character == "'" {
          state = .unquoted
        } else {
          word.append(character)
        }

      case .doubleQuoted:
        if character == "\"" {
          state = .unquoted
        } else if character == "\\" {
          guard index < characters.count else { throw CommandLineParseError.trailingEscape }
          word.append(characters[index])
          index += 1
        } else if character == "$" || character == "`" {
          throw CommandLineParseError.unsupportedShellSyntax(character)
        } else {
          word.append(character)
        }
      }
    }

    switch state {
    case .unquoted:
      try finishWord()
    case .singleQuoted:
      throw CommandLineParseError.unterminatedSingleQuote
    case .doubleQuoted:
      throw CommandLineParseError.unterminatedDoubleQuote
    }

    guard !words.isEmpty else { throw CommandLineParseError.empty }
    return words
  }

  private static func isUnsupportedShellSyntax(_ character: Character) -> Bool {
    ";|&<>$`(){}".contains(character)
  }

  private static func isEnvironmentAssignment(_ word: String) -> Bool {
    guard let separator = word.firstIndex(of: "=") else { return false }
    let name = word[..<separator]
    guard let first = name.first, first == "_" || first.isASCIIAlpha else { return false }
    return name.dropFirst().allSatisfy { $0 == "_" || $0.isASCIIAlpha || $0.isASCIIDigit }
  }
}

extension Character {
  fileprivate var isASCIIAlpha: Bool {
    unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
  }

  fileprivate var isASCIIDigit: Bool {
    unicodeScalars.allSatisfy { (48...57).contains($0.value) }
  }
}
