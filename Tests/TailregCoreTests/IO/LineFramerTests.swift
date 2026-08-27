import Foundation
import Testing

@testable import TailregCore

@Suite
struct `LineFramer tests` {
  private func framer(limit: Int = 64 * 1024) -> LineFramer {
    LineFramer(limit: limit)
  }

  private func consume(_ text: String, into framer: inout LineFramer) -> [String] {
    framer.consume(Data(text.utf8))
  }

  @Test
  func `Splits Whole Lines`() {
    var framer = framer()
    #expect(consume("one\ntwo\nthree\n", into: &framer) == ["one", "two", "three"])
    #expect(framer.finish() == nil)
  }

  @Test
  func `Holds A Partial Line Until Its Newline Arrives`() {
    var framer = framer()
    #expect(consume("par", into: &framer).isEmpty)
    #expect(consume("ti", into: &framer).isEmpty)
    #expect(consume("al\n", into: &framer) == ["partial"])
  }

  @Test
  func `Emits A Trailing Line With No Newline On Finish`() {
    var framer = framer()
    #expect(consume("done\ntail", into: &framer) == ["done"])
    #expect(framer.finish() == "tail")
    #expect(framer.finish() == nil)
  }

  @Test
  func `Strips The Carriage Return From Windows Line Endings`() {
    var framer = framer()
    #expect(consume("one\r\ntwo\r\n", into: &framer) == ["one", "two"])
  }

  @Test
  func `Collapses A Carriage Return Redraw To Its Final Segment`() {
    var framer = framer()
    #expect(
      consume("building 10%\rbuilding 50%\rbuilding 100%\n", into: &framer) == ["building 100%"]
    )
  }

  @Test
  func `Keeps The Last Written Segment When A Redraw Ends Empty`() {
    var framer = framer()
    #expect(consume("done\r\r\n", into: &framer) == ["done"])
  }

  @Test
  func `Forces Out A Line That Never Terminates`() {
    var framer = framer(limit: 8)
    let lines = consume("aaaaaaaaaaaaaaaaaa", into: &framer)
    #expect(lines == ["aaaaaaaa", "aaaaaaaa"])
    #expect(framer.finish() == "aa")
  }

  @Test
  func `Preserves Ansi Escapes`() {
    var framer = framer()
    let coloured = "\u{1B}[32mready\u{1B}[0m"
    #expect(consume("\(coloured)\n", into: &framer) == [coloured])
  }

  @Test
  func `Reassembles A Multi Byte Character Split Across Reads`() {
    var framer = framer()
    let bytes = Array("née 🚀".utf8)
    #expect(framer.consume(Data(bytes[0..<3])).isEmpty)
    #expect(framer.consume(Data(bytes[3...])).isEmpty)
    #expect(framer.finish() == "née 🚀")
  }

  @Test
  func `Survives Invalid Utf8 Without Dropping The Line`() {
    var framer = framer()
    let lines = framer.consume(Data([0x61, 0xFF, 0x62, 0x0A]))
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("a"))
    #expect(lines[0].hasSuffix("b"))
  }

  @Test
  func `Emits An Empty Line For A Bare Newline`() {
    var framer = framer()
    #expect(consume("\n\n", into: &framer) == ["", ""])
  }

  @Test
  func `Consuming Nothing Yields Nothing`() {
    var framer = framer()
    #expect(framer.consume(Data()).isEmpty)
  }
}
