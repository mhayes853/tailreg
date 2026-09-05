import Foundation
import TailregCLI
import Testing

@Suite
struct `Project specification tests` {
  @Test
  func `Loads applications and orders dependency levels`() throws {
    let fixture = try TOMLFixture(
      """
      [project]
      name = "storefront"

      [apps.api]
      route = "api"
      port = 8080
      command = ["swift", "run", "API"]

      [apps.web]
      route = "web"
      port = 5173
      command = ["npm", "run", "dev"]
      depends_on = ["api"]

      [apps.worker]
      command = ["swift", "run", "Worker"]
      expose = false
      """
    )

    let specification = try ProjectSpecification.load(from: fixture.file)
    let selected = try specification.selected(["web"])

    #expect(specification.name == "storefront")
    #expect(specification.applications.map(\.name) == ["api", "web", "worker"])
    #expect(selected.map { $0.map(\.name) } == [["api"], ["web"]])
  }

  @Test
  func `Rejects duplicate routes`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.api]
      route = "server"
      port = 8080
      command = ["server"]

      [apps.web]
      route = "server"
      port = 3000
      command = ["web"]
      """
    )

    #expect(throws: ProjectSpecificationError.duplicateRoute) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }

  @Test
  func `Rejects dependency cycles`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.first]
      port = 3000
      command = ["first"]
      depends_on = ["second"]

      [apps.second]
      port = 3001
      command = ["second"]
      depends_on = ["first"]
      """
    )

    #expect(throws: ProjectSpecificationError.dependencyCycle) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }
}

private final class TOMLFixture {
  let directory: URL
  let file: URL

  init(_ contents: String) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-cli-tests-\(UUID().uuidString)", isDirectory: true)
    file = directory.appendingPathComponent("tailreg.toml")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: file)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }
}
