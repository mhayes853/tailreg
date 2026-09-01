import http from "node:http";

const host = "127.0.0.1";
const port = Number(process.env.PORT ?? 19110);

const server = http
  .createServer((request, response) => {
    if (request.url === "/products") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ products: ["Keyboard", "Monitor"] }));
      return;
    }
    response.writeHead(404).end();
  })
  .listen(port, host);

if (process.env.TAILREG_E2E_AUTO_EXIT_MS) {
  setTimeout(() => server.close(), Number(process.env.TAILREG_E2E_AUTO_EXIT_MS));
}
