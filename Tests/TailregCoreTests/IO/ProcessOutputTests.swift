import AsyncAlgorithms
import Foundation
import Testing

@testable import TailregCore

@Suite(.timeLimit(.minutes(1)))
struct `Process output reading tests` {
  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

  private func collect(
    _ output: some AsyncSequence<LogLine, Never> & Sendable
  ) async -> [LogLine] {
    var collected: [LogLine] = []
    for await line in output {
      collected.append(line)
    }
    return collected
  }

  private func lines(
    _ handle: FileHandle,
    as stream: ProcessStream = .standardOutput
  ) -> AsyncStream<LogLine> {
    processOutputLines(handle, as: stream, now: { Self.stamp })
  }

  @Test
  func `Reads Whole Lines Until The Writer Closes`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading)

    try pipe.fileHandleForWriting.write(contentsOf: Data("one\ntwo\nthree\n".utf8))
    try pipe.fileHandleForWriting.close()

    #expect(await collect(output).map(\.message) == ["one", "two", "three"])
  }

  @Test
  func `Tags Every Line With The Given Stream`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading, as: .standardError)

    try pipe.fileHandleForWriting.write(contentsOf: Data("boom\n".utf8))
    try pipe.fileHandleForWriting.close()

    #expect(await collect(output).map(\.stream) == [.standardError])
  }

  @Test
  func `Delivers A Trailing Line With No Newline`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading)

    try pipe.fileHandleForWriting.write(contentsOf: Data("first\nno-newline-tail".utf8))
    try pipe.fileHandleForWriting.close()

    #expect(await collect(output).map(\.message) == ["first", "no-newline-tail"])
  }

  @Test
  func `Stamps Lines With The Injected Clock`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading)

    try pipe.fileHandleForWriting.write(contentsOf: Data("now\n".utf8))
    try pipe.fileHandleForWriting.close()

    #expect(await collect(output).map(\.at) == [Self.stamp])
  }

  @Test
  func `Reassembles Lines Across Separate Writes`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading)

    let writer = Task {
      for chunk in ["par", "ti", "al\ndone\n"] {
        try pipe.fileHandleForWriting.write(contentsOf: Data(chunk.utf8))
      }
      try pipe.fileHandleForWriting.close()
    }
    let collected = await collect(output)
    try await writer.value

    #expect(collected.map(\.message) == ["partial", "done"])
  }

  @Test
  func `Reads A Burst Larger Than One Read`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading)
    let expected = (0..<2000).map { "line \($0)" }

    let writer = Task {
      try pipe.fileHandleForWriting.write(
        contentsOf: Data(expected.map { $0 + "\n" }.joined().utf8)
      )
      try pipe.fileHandleForWriting.close()
    }
    let collected = await collect(output)
    try await writer.value

    #expect(collected.map(\.message) == expected)
  }

  @Test
  func `Closes The Handle Once The Stream Finishes`() async throws {
    let pipe = Pipe()
    let handle = pipe.fileHandleForReading
    let output = lines(handle)

    #expect(handle.fileDescriptor >= 0)

    try pipe.fileHandleForWriting.close()
    _ = await collect(output)

    #expect(handle.fileDescriptor == -1)
  }

  @Test
  func `Merges Standard Output And Standard Error`() async throws {
    let out = Pipe()
    let err = Pipe()
    let output = merge(
      lines(out.fileHandleForReading, as: .standardOutput),
      lines(err.fileHandleForReading, as: .standardError)
    )

    try out.fileHandleForWriting.write(contentsOf: Data("to-out\n".utf8))
    try err.fileHandleForWriting.write(contentsOf: Data("to-err\n".utf8))
    try out.fileHandleForWriting.close()
    try err.fileHandleForWriting.close()

    let collected = await collect(output)
    #expect(collected.count == 2)
    #expect(
      Set(collected.map { [$0.stream.rawValue, $0.message] })
        == [["stdout", "to-out"], ["stderr", "to-err"]]
    )
  }

  @Test
  func `An Empty Stream Finishes Without Emitting`() async throws {
    let pipe = Pipe()
    let output = lines(pipe.fileHandleForReading)

    try pipe.fileHandleForWriting.close()

    #expect(await collect(output).isEmpty)
  }
}
