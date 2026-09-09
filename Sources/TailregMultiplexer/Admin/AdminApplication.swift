import Foundation
import Hummingbird
import TailregCore

extension Multiplexer {
  /// The loopback-only admin listener: health and route mutation, never public traffic.
  public func buildApplication() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/status") { _, _ in
      MultiplexerStatus(status: "ok", id: configuration.id)
    }
    router.get("/routes") { _, _ in
      try await routes().map(MuxRouteResponse.init)
    }
    router.post("/routes") { request, context -> MuxRouteResponse in
      let registration: MuxRouteRegistrationRequest
      do {
        registration = try await request.decode(
          as: MuxRouteRegistrationRequest.self,
          context: context
        )
      } catch {
        throw HTTPError(.badRequest)
      }
      guard let upstream = URL(string: registration.upstreamURL) else {
        throw HTTPError(.badRequest)
      }
      do {
        return try await MuxRouteResponse(
          registerRoute(
            name: registration.name,
            route: registration.route,
            upstream: upstream,
            pathMode: registration.pathMode
          )
        )
      } catch MuxRouteError.invalidName, MuxRouteError.routeAlreadyExists,
        MuxRouteError.invalidUpstream
      {
        throw HTTPError(.badRequest)
      }
    }
    router.put("/routes/:route") { request, context -> MuxRouteResponse in
      let route = try Self.requiredRoute(in: context)
      let update: MuxRouteUpdateRequest
      do {
        update = try await request.decode(as: MuxRouteUpdateRequest.self, context: context)
      } catch {
        throw HTTPError(.badRequest)
      }
      guard let upstream = URL(string: update.upstreamURL) else {
        throw HTTPError(.badRequest)
      }
      do {
        return try await MuxRouteResponse(
          updateRoute(route: route, upstream: upstream, pathMode: update.pathMode)
        )
      } catch MuxRouteError.routeNotFound {
        throw HTTPError(.notFound)
      } catch MuxRouteError.invalidUpstream {
        throw HTTPError(.badRequest)
      }
    }
    router.delete("/routes/:route") { _, context -> HTTPResponse.Status in
      let route = try Self.requiredRoute(in: context)
      guard try await unregisterRoute(route: route) != nil else {
        throw HTTPError(.notFound)
      }
      return .noContent
    }

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname(configuration.adminHost, port: configuration.adminPort.intValue),
        serverName: "tailreg-mux"
      )
    )
  }

  /// A path parameter that is not a route name is a 404 rather than a 400: nothing can be
  /// registered under it, so there is nothing there to replace or end.
  private static func requiredRoute(in context: BasicRequestContext) throws -> MuxRouteName {
    guard let route = MuxRouteName(rawValue: try context.parameters.require("route")) else {
      throw HTTPError(.notFound)
    }
    return route
  }
}
