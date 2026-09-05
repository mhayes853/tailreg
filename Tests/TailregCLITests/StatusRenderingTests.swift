import Foundation
import TailregCore
import Testing
import UUIDV7

@testable import TailregCLI

/// These pin the rendered output itself. The table is the command's interface, so a change to a
/// width, a label or a placeholder should have to be made deliberately.
@Suite
struct `Status rendering tests` {
  @Test
  func `A running project renders as labelled tables`() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let report = StatusReport(projects: [
      ProjectStatus(
        name: "demo",
        root: "/tmp/demo",
        url: URL(string: "http://127.0.0.1:39428/"),
        exposure: .local,
        mux: MuxStatus(
          state: .running,
          pid: 48_213,
          ingressPort: 39_428,
          adminPort: 39_429,
          startedAt: now.addingTimeInterval(-14 * 60)
        ),
        applications: [
          application(
            "api",
            state: .running,
            ownership: .managed,
            pid: 48_260,
            route: route("api", port: 19_112)
          ),
          application("batch", state: .stopped),
          application("jobs", state: .running, ownership: .managed, pid: 48_266, isExposed: false),
          application(
            "web",
            state: .running,
            ownership: .attached,
            route: route("web", port: 19_111)
          )
        ],
        problems: []
      )
    ])

    let rendered = StatusTextRenderer().render(report, now: now)

    #expect(
      rendered == """
        project
        +----------+-------------------------+
        | name     | demo                    |
        | root     | /tmp/demo               |
        | url      | http://127.0.0.1:39428/ |
        | exposure | local                   |
        +----------+-------------------------+

        mux
        +---------+-------+---------+-------+--------+
        | state   | pid   | ingress | admin | uptime |
        +---------+-------+---------+-------+--------+
        | running | 48213 |   39428 | 39429 | 14m    |
        +---------+-------+---------+-------+--------+

        applications
        +-------+---------+----------+-----------+-------------+------------------------+
        | app   | state   | owner    | process   | route       | upstream               |
        +-------+---------+----------+-----------+-------------+------------------------+
        | api   | running | managed  | pid 48260 | /api/       | http://127.0.0.1:19112 |
        | batch | stopped | -        | -         | -           | -                      |
        | jobs  | running | managed  | pid 48266 | not exposed | -                      |
        | web   | running | attached | listening | /web/       | http://127.0.0.1:19111 |
        +-------+---------+----------+-----------+-------------+------------------------+
        """
    )
  }

  @Test
  func `Problems are rendered as a table of their own`() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let report = StatusReport(projects: [
      ProjectStatus(
        name: "demo",
        root: "/tmp/demo",
        exposure: .tailnet,
        mux: MuxStatus(
          state: .unreachable,
          pid: 48_213,
          ingressPort: 39_428,
          adminPort: 39_429,
          startedAt: now.addingTimeInterval(-(3 * 3600 + 12 * 60))
        ),
        applications: [
          application(
            "web",
            state: .stale,
            ownership: .managed,
            pid: 48_260,
            route: route("web", port: 19_111)
          )
        ],
        problems: [
          StatusProblem(
            subject: "binding",
            kind: .missing,
            detail: "no live binding for ingress port 39428"
          ),
          StatusProblem(
            subject: "mux",
            kind: .unreachable,
            detail: "alive as pid 48213, not answering on admin port 39429"
          ),
          StatusProblem(
            subject: "web",
            kind: .staleProcess,
            detail: "pid 48260 is not the process that started it"
          )
        ]
      )
    ])

    let rendered = StatusTextRenderer().render(report, now: now)

    #expect(
      rendered == """
        project
        +----------+-----------+
        | name     | demo      |
        | root     | /tmp/demo |
        | url      | -         |
        | exposure | tailnet   |
        +----------+-----------+

        mux
        +-------------+-------+---------+-------+--------+
        | state       | pid   | ingress | admin | uptime |
        +-------------+-------+---------+-------+--------+
        | unreachable | 48213 |   39428 | 39429 | 3h12m  |
        +-------------+-------+---------+-------+--------+

        applications
        +-----+-------+---------+----------------+-------+------------------------+
        | app | state | owner   | process        | route | upstream               |
        +-----+-------+---------+----------------+-------+------------------------+
        | web | stale | managed | pid 48260 gone | /web/ | http://127.0.0.1:19111 |
        +-----+-------+---------+----------------+-------+------------------------+

        problems
        +---------+---------------+-------------------------------------------------------+
        | subject | problem       | detail                                                |
        +---------+---------------+-------------------------------------------------------+
        | binding | missing       | no live binding for ingress port 39428                |
        | mux     | unreachable   | alive as pid 48213, not answering on admin port 39429 |
        | web     | stale process | pid 48260 is not the process that started it          |
        +---------+---------------+-------------------------------------------------------+
        """
    )
  }

  @Test
  func `A project that is not running still describes itself`() {
    let report = StatusReport(projects: [
      ProjectStatus(
        name: "demo",
        root: "/tmp/demo",
        mux: MuxStatus(state: .notRunning),
        applications: [application("api", state: .stopped)],
        problems: []
      )
    ])

    let rendered = StatusTextRenderer().render(report)

    #expect(rendered.contains("| not running | -   | -       | -     | -      |"))
    #expect(rendered.contains("| api | stopped | -     | -       | -     | -        |"))
    #expect(!rendered.contains("problems"), "a healthy project prints no problems table")
  }

  @Test
  func `The JSON view round-trips the report it renders`() throws {
    let report = StatusReport(projects: [
      ProjectStatus(
        name: "demo",
        root: "/tmp/demo",
        url: URL(string: "http://127.0.0.1:39428/"),
        exposure: .local,
        // Whole seconds: ISO 8601 has no room for the fraction, so anything finer would not
        // survive the round trip and the comparison below would be meaningless.
        mux: MuxStatus(
          state: .running,
          pid: 48_213,
          ingressPort: 39_428,
          adminPort: 39_429,
          startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        applications: [
          application(
            "api",
            state: .running,
            ownership: .managed,
            pid: 48_260,
            route: route("api", port: 19_112)
          )
        ],
        problems: [
          StatusProblem(
            subject: "api",
            kind: .staleProcess,
            detail: "pid 48260 is not the process that started it"
          )
        ]
      )
    ])

    let json = try StatusJSONRenderer().render(report)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(try decoder.decode(StatusReport.self, from: Data(json.utf8)) == report)
    // The wire spellings are an interface, not an implementation detail of the Swift names.
    #expect(json.contains("\"kind\" : \"stale-process\""))
    #expect(json.contains("\"pathMode\" : \"strip-route-prefix\""))
    #expect(json.contains("\"url\" : \"http://127.0.0.1:39428/\""), "slashes are not escaped")
  }

  private func application(
    _ name: String,
    state: ApplicationStatus.State,
    ownership: ApplicationOwnership? = nil,
    pid: Int? = nil,
    isExposed: Bool = true,
    route: RouteStatus? = nil
  ) -> ApplicationStatus {
    ApplicationStatus(
      name: name,
      state: state,
      ownership: ownership,
      configured: true,
      isExposed: isExposed,
      pid: pid,
      processGroupID: pid,
      route: route
    )
  }

  private func route(_ name: String, port: Int) -> RouteStatus {
    RouteStatus(
      id: UUIDV7(),
      path: "/\(name)/",
      url: URL(string: "http://127.0.0.1:39428/\(name)/"),
      upstreamURL: "http://127.0.0.1:\(port)",
      pathMode: .stripRoutePrefix
    )
  }
}
