import Foundation
import TailregCore

/// A bordered, labelled ASCII table.
///
/// ASCII rather than box-drawing characters so the report survives being piped, grepped, and
/// read out of a CI log on a terminal that has no idea what a `┌` is.
struct StatusTable {
  enum Alignment: Sendable {
    case left
    case right
  }

  /// Nil for a key/value table, which labels its rows rather than its columns.
  var headers: [String]?
  var alignments: [Alignment]
  var rows: [[String]]

  func lines() -> [String] {
    let columns = max(headers?.count ?? 0, rows.map(\.count).max() ?? 0)
    guard columns > 0 else { return [] }
    let widths = (0..<columns)
      .map { column in
        max(
          cell(headers ?? [], column).count,
          rows.map { cell($0, column).count }.max() ?? 0
        )
      }

    let border =
      "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+")
      + "+"
    var lines = [border]
    if let headers {
      // Headers are always left-aligned; a right-aligned label over a right-aligned number reads
      // as part of the number.
      lines.append(row(headers, widths: widths, alignments: widths.map { _ in .left }))
      lines.append(border)
    }
    for values in rows { lines.append(row(values, widths: widths, alignments: alignments)) }
    lines.append(border)
    return lines
  }

  private func row(_ values: [String], widths: [Int], alignments: [Alignment]) -> String {
    let padded = widths.indices.map { column in
      pad(
        cell(values, column),
        to: widths[column],
        alignment: column < alignments.count ? alignments[column] : .left
      )
    }
    return "| " + padded.joined(separator: " | ") + " |"
  }

  private func pad(_ value: String, to width: Int, alignment: Alignment) -> String {
    let padding = String(repeating: " ", count: max(0, width - value.count))
    // A placeholder is not a number, so it is not right-aligned under one.
    guard alignment == .right, value != Self.placeholder else { return value + padding }
    return padding + value
  }

  static let placeholder = "-"

  private func cell(_ values: [String], _ column: Int) -> String {
    column < values.count ? values[column] : ""
  }
}

/// Renders a report as labelled tables.
///
/// The problems table is built from the report's own `problems`, not recomputed here, so the
/// human view and `--json` cannot disagree about whether something is wrong.
struct StatusTextRenderer: Sendable {
  func render(_ report: StatusReport, now: Date = Date()) -> String {
    report.projects
      .map { render($0, now: now) }
      .joined(separator: "\n\n")
  }

  private func render(_ project: ProjectStatus, now: Date) -> String {
    var sections = [
      section("project", projectTable(project)),
      section("mux", muxTable(project.mux, now: now)),
      section("applications", applicationsTable(project.applications))
    ]
    // Omitted entirely when empty: a healthy project should be quiet, not print a table saying
    // that nothing is wrong.
    if !project.problems.isEmpty {
      sections.append(section("problems", problemsTable(project.problems)))
    }
    return sections.joined(separator: "\n\n")
  }

  private func section(_ label: String, _ table: StatusTable) -> String {
    ([label] + table.lines()).joined(separator: "\n")
  }

  private func projectTable(_ project: ProjectStatus) -> StatusTable {
    StatusTable(
      headers: nil,
      alignments: [.left, .left],
      rows: [
        ["name", project.name],
        ["root", project.root],
        ["url", project.url?.absoluteString ?? "-"],
        ["exposure", project.exposure?.rawValue ?? "-"]
      ]
    )
  }

  private func muxTable(_ mux: MuxStatus, now: Date) -> StatusTable {
    StatusTable(
      headers: ["state", "pid", "ingress", "admin", "uptime"],
      alignments: [.left, .right, .right, .right, .left],
      rows: [
        [
          mux.state.label,
          mux.pid.map(String.init) ?? "-",
          mux.ingressPort.map(String.init) ?? "-",
          mux.adminPort.map(String.init) ?? "-",
          mux.startedAt.map { uptime(since: $0, now: now) } ?? "-"
        ]
      ]
    )
  }

  private func applicationsTable(_ applications: [ApplicationStatus]) -> StatusTable {
    StatusTable(
      headers: ["app", "state", "owner", "process", "route", "upstream"],
      alignments: [.left, .left, .left, .left, .left, .left],
      rows: applications.map { application in
        [
          application.name,
          application.state.rawValue,
          application.ownership?.rawValue ?? "-",
          process(of: application),
          route(of: application),
          application.route?.upstreamURL ?? "-"
        ]
      }
    )
  }

  private func problemsTable(_ problems: [StatusProblem]) -> StatusTable {
    StatusTable(
      headers: ["subject", "problem", "detail"],
      alignments: [.left, .left, .left],
      rows: problems.map { [$0.subject, $0.kind.label, $0.detail] }
    )
  }

  /// The process column means different things by ownership, because a PID and a listening
  /// upstream are the only liveness each kind of run has.
  private func process(of application: ApplicationStatus) -> String {
    switch application.ownership {
    case .managed:
      guard let pid = application.pid else { return "-" }
      return application.state == .stale ? "pid \(pid) gone" : "pid \(pid)"
    case .attached:
      switch application.state {
      case .running: return "listening"
      case .unreachable: return "not listening"
      case .stale, .unverified, .stopped: return "-"
      }
    case .none:
      return "-"
    }
  }

  /// An application configured with `expose = false` is named as such rather than shown as `-`,
  /// which would read as something missing instead of something chosen.
  private func route(of application: ApplicationStatus) -> String {
    if let route = application.route { return route.path }
    if application.state != .stopped, application.isExposed == false { return "not exposed" }
    return "-"
  }

  private func uptime(since start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h\(minutes % 60)m" }
    return "\(hours / 24)d\(hours % 24)h"
  }
}

extension MuxStatus.State {
  var label: String {
    switch self {
    case .running: "running"
    case .unreachable: "unreachable"
    case .stale: "stale"
    case .notRunning: "not running"
    }
  }
}
