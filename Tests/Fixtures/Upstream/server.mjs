import http from "node:http";

// One trivial upstream, shared by every CLI end-to-end fixture. Nothing these suites test is
// about the application: `up`, `down` and `status` only need something that listens on a port
// and answers, whether Tailreg launched it or found it already running.
const port = Number(process.env.PORT);

http
  .createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "text/plain" });
    response.end(`served by ${process.env.TAILREG_APP_PATH ?? "/"}`);
  })
  .listen(port, "127.0.0.1");
