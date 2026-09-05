import http from "node:http";

const host = "127.0.0.1";
const port = Number(process.env.PORT ?? 19109);

const server = http
  .createServer((request, response) => {
    if (request.url === "/assets/app.js") {
      response.writeHead(200, { "Content-Type": "text/javascript" });
      response.end(`
        document.body.dataset.assets = "loaded";
        fetch("/api/products")
          .then((response) => response.json())
          .then(({ products }) => {
            document.querySelector("[data-testid=products]").textContent = products.join(", ");
          });
      `);
      return;
    }

    response.writeHead(200, { "Content-Type": "text/html" });
    response.end(`<!doctype html>
      <html><body>
        <h1>Storefront</h1>
        <p data-testid="products">Loading</p>
        <script src="/assets/app.js"></script>
      </body></html>`);
  })
  .listen(port, host);

if (process.env.TAILREG_E2E_AUTO_EXIT_MS) {
  setTimeout(() => server.close(), Number(process.env.TAILREG_E2E_AUTO_EXIT_MS));
}
