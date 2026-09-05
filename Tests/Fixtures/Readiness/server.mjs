import http from "node:http";

// Two applications run this same server on different ports, so `down` has more than one route to
// remove and the project stays up until the last one goes.
const port = Number(process.env.PORT);

http
  .createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "text/plain" });
    response.end(`served by ${process.env.TAILREG_APP_PATH ?? "/"}`);
  })
  .listen(port, "127.0.0.1");
