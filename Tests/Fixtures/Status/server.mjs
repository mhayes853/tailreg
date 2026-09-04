import http from "node:http";

// Stands in for an application that was already listening when the project came up, so the
// project's applications are attached and nothing supervises them.
const port = Number(process.env.PORT);

http
  .createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "text/plain" });
    response.end(`served by ${process.env.TAILREG_APP_PATH ?? "/"}`);
  })
  .listen(port, "127.0.0.1");
