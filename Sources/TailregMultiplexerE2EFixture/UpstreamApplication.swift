import Hummingbird

func upstreamApplication(
  binding: String,
  port: Int
) -> Application<RouterResponder<BasicRequestContext>> {
  let router = Router()
  router.get("/") { _, _ in
    Response(
      status: .ok,
      headers: [.contentType: "text/html; charset=utf-8"],
      body: ResponseBody(
        byteBuffer: ByteBuffer(
          string: "<!doctype html><title>Tailreg fixture</title><main id=app>\(binding)</main>"
        )
      )
    )
  }
  router.get("/route/endpoint") { _, _ in
    FixtureEndpointResponse(binding: binding, result: "correct-upstream")
  }
  router.post("/echo") { request, _ in
    let body = try await request.body.collect(upTo: 1_048_576)
    return Response(
      status: .ok,
      headers: [.contentType: request.headers[.contentType] ?? "application/octet-stream"],
      body: ResponseBody(byteBuffer: body)
    )
  }

  return Application(
    router: router,
    configuration: ApplicationConfiguration(
      address: .hostname("127.0.0.1", port: port),
      serverName: "tailreg-mux-e2e-upstream-\(binding)"
    )
  )
}
